using System.Net.Http.Json;
using System.Text.Json.Serialization;
using MailKit.Security;

namespace AiStand.ImapReadonlyMcp;

public interface IImapCredentialProvider
{
    Task<IImapCredential> GetCredentialAsync(CancellationToken cancellationToken);
}

public interface IImapCredential
{
    SaslMechanism? CreateSaslMechanism();

    string? Password { get; }
}

public sealed class BasicCredentialProvider(ImapOptions options) : IImapCredentialProvider
{
    public Task<IImapCredential> GetCredentialAsync(CancellationToken cancellationToken)
    {
        return Task.FromResult<IImapCredential>(new BasicCredential(options.Credentials.Password!));
    }
}

public sealed class OAuthCredentialProvider(
    ImapOptions options,
    IHttpClientFactory httpClientFactory,
    ILogger<OAuthCredentialProvider> logger,
    TokenStateStore? tokenStateStore) : IImapCredentialProvider
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _cachedToken;
    private DateTimeOffset _refreshAt;

    public async Task<IImapCredential> GetCredentialAsync(CancellationToken cancellationToken)
    {
        if (options.AuthenticationMode == ImapAuthenticationMode.OAuthClientCredentials && options.Credentials.AccessToken is { } staticToken)
        {
            return new OAuthCredential(options.Credentials.Username, staticToken);
        }

        var oauth = options.OAuth ?? throw new ConfigurationException("OAuth configuration is missing");
        if (_cachedToken is not null && DateTimeOffset.UtcNow < _refreshAt)
        {
            return new OAuthCredential(options.Credentials.Username, _cachedToken);
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_cachedToken is not null && DateTimeOffset.UtcNow < _refreshAt)
            {
                return new OAuthCredential(options.Credentials.Username, _cachedToken);
            }

            var form = new Dictionary<string, string>
            {
                ["grant_type"] = oauth.AuthenticationMode == ImapAuthenticationMode.OAuthClientCredentials ? "client_credentials" : "refresh_token",
                ["client_id"] = oauth.ClientId,
                ["client_secret"] = oauth.ClientSecret,
            };
            if (!string.IsNullOrWhiteSpace(oauth.Scope))
            {
                form["scope"] = oauth.Scope;
            }
            if (oauth.AuthenticationMode == ImapAuthenticationMode.OAuthRefreshToken)
            {
                form["refresh_token"] = (tokenStateStore ?? throw new ConfigurationException("IMAP OAuth token state store is missing")).ReadRefreshToken();
            }

            using var request = new HttpRequestMessage(HttpMethod.Post, oauth.TokenEndpoint)
            {
                Content = new FormUrlEncodedContent(form),
            };
            using var response = await httpClientFactory.CreateClient("imap-oauth").SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                logger.LogWarning("IMAP OAuth token request failed with HTTP {StatusCode}", (int)response.StatusCode);
                throw new McpToolException("IMAP OAuth authentication is unavailable");
            }

            var token = await response.Content.ReadFromJsonAsync<TokenResponse>(cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(token?.AccessToken))
            {
                throw new McpToolException("IMAP OAuth authentication returned no access token");
            }

            _cachedToken = token.AccessToken;
            _refreshAt = DateTimeOffset.UtcNow.AddSeconds(Math.Max(1, token.ExpiresIn - 60));
            if (oauth.AuthenticationMode == ImapAuthenticationMode.OAuthRefreshToken && !string.IsNullOrWhiteSpace(token.RefreshToken))
            {
                (tokenStateStore ?? throw new ConfigurationException("IMAP OAuth token state store is missing")).WriteRotatedRefreshToken(token.RefreshToken);
            }
            return new OAuthCredential(options.Credentials.Username, _cachedToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    private sealed record TokenResponse(
        [property: JsonPropertyName("access_token")] string? AccessToken,
        [property: JsonPropertyName("expires_in")] int ExpiresIn,
        [property: JsonPropertyName("refresh_token")] string? RefreshToken);
}

public sealed class BasicCredential(string password) : IImapCredential
{
    public SaslMechanism? CreateSaslMechanism() => null;

    public string? Password => password;
}

public sealed class OAuthCredential(string username, string accessToken) : IImapCredential
{
    public SaslMechanism? CreateSaslMechanism() => new SaslMechanismOAuth2(username, accessToken);

    public string? Password => null;
}
