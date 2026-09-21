using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AiStand.ConfluenceReadonlyMcp;

public interface IConfluenceAuthenticator
{
    Task ApplyAsync(HttpRequestMessage request, CancellationToken cancellationToken);
}

public static class ConfluenceAuthenticatorFactory
{
    public static IConfluenceAuthenticator Create(ConfluenceOptions options, IHttpClientFactory httpClientFactory)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(httpClientFactory);

        return options.AuthMode switch
        {
            ConfluenceAuthMode.Basic => new BasicAuthenticator(
                options.ResolveUsername(),
                options.ResolvePassword()),
            ConfluenceAuthMode.Pat => new BearerAuthenticator(options.ResolvePat()),
            ConfluenceAuthMode.OAuth2ClientCredentials => new OAuth2Authenticator(
                httpClientFactory.CreateClient("confluence-oauth"),
                options,
                refreshTokenStore: null),
            ConfluenceAuthMode.OAuth2RefreshToken => new OAuth2Authenticator(
                httpClientFactory.CreateClient("confluence-oauth"),
                options,
                new EncryptedRefreshTokenStore(
                    options.TokenStateFile!,
                    ReadKey(options.TokenStateKeyFile!),
                    options.ResolveOAuthRefreshToken())),
            _ => throw new InvalidOperationException("Unsupported Confluence auth mode"),
        };
    }

    private static byte[] ReadKey(string path)
    {
        var raw = File.ReadAllText(path).Trim();
        if (string.IsNullOrEmpty(raw))
        {
            throw new InvalidOperationException("A configured Confluence secret file is empty");
        }
        try
        {
            var decoded = Convert.FromBase64String(raw);
            if (decoded.Length == 32)
            {
                return decoded;
            }
        }
        catch (FormatException)
        {
            // A literal 32-byte secret is also accepted for local deployment.
        }

        var bytes = Encoding.UTF8.GetBytes(raw);
        return bytes.Length == 32
            ? bytes
            : throw new InvalidOperationException("The OAuth token-state key must be exactly 32 bytes or base64-encoded 32 bytes");
    }
}

public sealed class BasicAuthenticator(string username, string password) : IConfluenceAuthenticator
{
    public Task ApplyAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{username}:{password}"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", encoded);
        return Task.CompletedTask;
    }
}

public sealed class BearerAuthenticator(string token) : IConfluenceAuthenticator
{
    public Task ApplyAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return Task.CompletedTask;
    }
}

public sealed class OAuth2Authenticator : IConfluenceAuthenticator, IDisposable
{
    private readonly HttpClient _client;
    private readonly ConfluenceOptions _options;
    private readonly EncryptedRefreshTokenStore? _refreshTokenStore;
    private readonly string _clientId;
    private readonly string _clientSecret;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private AccessToken? _accessToken;

    public OAuth2Authenticator(HttpClient client, ConfluenceOptions options, EncryptedRefreshTokenStore? refreshTokenStore)
    {
        _client = client;
        _options = options;
        _refreshTokenStore = refreshTokenStore;
        _clientId = options.ResolveOAuthClientId();
        _clientSecret = options.ResolveOAuthClientSecret();
    }

    public async Task ApplyAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var token = await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Value);
    }

    private async Task<AccessToken> GetAccessTokenAsync(CancellationToken cancellationToken)
    {
        if (_accessToken is { } current && current.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(60))
        {
            return current;
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_accessToken is { } cached && cached.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(60))
            {
                return cached;
            }

            var values = new Dictionary<string, string>
            {
                ["client_id"] = _clientId,
                ["client_secret"] = _clientSecret,
            };

            if (!string.IsNullOrWhiteSpace(_options.OAuthScope))
            {
                values["scope"] = _options.OAuthScope;
            }

            if (_options.AuthMode == ConfluenceAuthMode.OAuth2ClientCredentials)
            {
                values["grant_type"] = "client_credentials";
            }
            else
            {
                values["grant_type"] = "refresh_token";
                values["refresh_token"] = _refreshTokenStore!.GetRefreshToken();
            }

            using var message = new HttpRequestMessage(HttpMethod.Post, _options.OAuthTokenUri)
            {
                Content = new FormUrlEncodedContent(values),
            };
            using var response = await _client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new ConfluenceClientException("Confluence OAuth token request failed", response.StatusCode);
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
            var root = document.RootElement;
            if (!root.TryGetProperty("access_token", out var accessTokenElement) || string.IsNullOrWhiteSpace(accessTokenElement.GetString()))
            {
                throw new ConfluenceClientException("Confluence OAuth response did not contain an access token");
            }

            var expiresIn = root.TryGetProperty("expires_in", out var expiresElement) && expiresElement.TryGetInt32(out var seconds)
                ? Math.Clamp(seconds, 1, 24 * 60 * 60)
                : 300;
            if (_refreshTokenStore is not null && root.TryGetProperty("refresh_token", out var refreshElement) && !string.IsNullOrWhiteSpace(refreshElement.GetString()))
            {
                _refreshTokenStore.Save(refreshElement.GetString()!);
            }

            _accessToken = new AccessToken(accessTokenElement.GetString()!, DateTimeOffset.UtcNow.AddSeconds(expiresIn));
            return _accessToken;
        }
        finally
        {
            _gate.Release();
        }
    }

    private sealed record AccessToken(string Value, DateTimeOffset ExpiresAt);

    public void Dispose() => _gate.Dispose();
}

public sealed class EncryptedRefreshTokenStore
{
    private readonly string _path;
    private readonly byte[] _key;
    private readonly string _initialRefreshToken;
    private readonly object _sync = new();

    public EncryptedRefreshTokenStore(string path, byte[] key, string initialRefreshToken)
    {
        _path = path;
        _key = key;
        _initialRefreshToken = initialRefreshToken;
    }

    public string GetRefreshToken()
    {
        lock (_sync)
        {
            if (!File.Exists(_path))
            {
                return _initialRefreshToken;
            }

            try
            {
                var encoded = File.ReadAllBytes(_path);
                if (encoded.Length < 28)
                {
                    throw new CryptographicException("Encrypted token state is too short");
                }

                var nonce = encoded[..12];
                var tag = encoded[12..28];
                var ciphertext = encoded[28..];
                var plaintext = new byte[ciphertext.Length];
                using var aes = new AesGcm(_key, tagSizeInBytes: 16);
                aes.Decrypt(nonce, ciphertext, tag, plaintext);
                var token = Encoding.UTF8.GetString(plaintext);
                CryptographicOperations.ZeroMemory(plaintext);
                return !string.IsNullOrWhiteSpace(token)
                    ? token
                    : throw new CryptographicException("Encrypted token state is empty");
            }
            catch (Exception exception) when (exception is IOException or CryptographicException or UnauthorizedAccessException)
            {
                throw new ConfluenceClientException("Stored Confluence OAuth refresh token cannot be read");
            }
        }
    }

    public void Save(string refreshToken)
    {
        lock (_sync)
        {
            var directory = Path.GetDirectoryName(_path);
            if (string.IsNullOrEmpty(directory))
            {
                throw new ConfluenceClientException("OAuth token-state path must include a directory");
            }

            Directory.CreateDirectory(directory);
            var plaintext = Encoding.UTF8.GetBytes(refreshToken);
            var nonce = RandomNumberGenerator.GetBytes(12);
            var ciphertext = new byte[plaintext.Length];
            var tag = new byte[16];
            try
            {
                using var aes = new AesGcm(_key, tagSizeInBytes: 16);
                aes.Encrypt(nonce, plaintext, ciphertext, tag);
                var payload = new byte[nonce.Length + tag.Length + ciphertext.Length];
                Buffer.BlockCopy(nonce, 0, payload, 0, nonce.Length);
                Buffer.BlockCopy(tag, 0, payload, nonce.Length, tag.Length);
                Buffer.BlockCopy(ciphertext, 0, payload, nonce.Length + tag.Length, ciphertext.Length);
                var temporary = _path + ".tmp";
                File.WriteAllBytes(temporary, payload);
                File.Move(temporary, _path, overwrite: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or CryptographicException)
            {
                throw new ConfluenceClientException("Stored Confluence OAuth refresh token cannot be saved");
            }
            finally
            {
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
    }
}
