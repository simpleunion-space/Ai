using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace JiraReadonlyMcp;

/// <summary>
/// Persists only a rotating OAuth refresh token. The state is encrypted so a
/// per-instance Docker volume never contains a usable plaintext credential.
/// </summary>
internal sealed class RefreshTokenStateStore
{
    private const string StateFileName = "jira-refresh-token.v1.json";
    private readonly string _statePath;
    private readonly byte[] _key;

    public RefreshTokenStateStore(string directory, string keyFile)
    {
        if (string.IsNullOrWhiteSpace(directory) || string.IsNullOrWhiteSpace(keyFile))
        {
            throw new InvalidOperationException("OAuth refresh token state directory and key file are required");
        }

        Directory.CreateDirectory(directory);
        _statePath = Path.Combine(directory, StateFileName);
        _key = ReadKey(keyFile);
    }

    public string LoadOrDefault(string bootstrapToken)
    {
        if (!File.Exists(_statePath))
        {
            return bootstrapToken;
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<Envelope>(File.ReadAllText(_statePath, Encoding.UTF8))
                ?? throw new InvalidOperationException("OAuth refresh token state is empty");
            var nonce = Convert.FromBase64String(envelope.Nonce);
            var ciphertext = Convert.FromBase64String(envelope.Ciphertext);
            var tag = Convert.FromBase64String(envelope.Tag);
            if (nonce.Length != 12 || tag.Length != 16 || ciphertext.Length == 0)
            {
                throw new InvalidOperationException("OAuth refresh token state is invalid");
            }

            var plaintext = new byte[ciphertext.Length];
            using var cipher = new AesGcm(_key, 16);
            cipher.Decrypt(nonce, ciphertext, tag, plaintext);
            var token = Encoding.UTF8.GetString(plaintext);
            CryptographicOperations.ZeroMemory(plaintext);
            if (string.IsNullOrWhiteSpace(token) || token.Length > 4096 || token.Any(char.IsWhiteSpace))
            {
                throw new InvalidOperationException("OAuth refresh token state is invalid");
            }
            return token;
        }
        catch (CryptographicException exception)
        {
            throw new InvalidOperationException("OAuth refresh token state cannot be decrypted", exception);
        }
        catch (FormatException exception)
        {
            throw new InvalidOperationException("OAuth refresh token state is invalid", exception);
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException("OAuth refresh token state is invalid", exception);
        }
    }

    public void Save(string refreshToken)
    {
        if (string.IsNullOrWhiteSpace(refreshToken) || refreshToken.Length > 4096 || refreshToken.Any(char.IsWhiteSpace))
        {
            throw new InvalidOperationException("Rotated OAuth refresh token is invalid");
        }

        var plaintext = Encoding.UTF8.GetBytes(refreshToken);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        try
        {
            using var cipher = new AesGcm(_key, 16);
            cipher.Encrypt(nonce, plaintext, ciphertext, tag);
            var envelope = new Envelope
            {
                Nonce = Convert.ToBase64String(nonce),
                Ciphertext = Convert.ToBase64String(ciphertext),
                Tag = Convert.ToBase64String(tag),
            };
            var temporaryPath = _statePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporaryPath, JsonSerializer.Serialize(envelope), Encoding.UTF8);
                if (!OperatingSystem.IsWindows())
                {
                    File.SetUnixFileMode(temporaryPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                }
                File.Move(temporaryPath, _statePath, overwrite: true);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private static byte[] ReadKey(string path)
    {
        var encoded = File.ReadAllText(path, Encoding.UTF8).Trim();
        try
        {
            var key = Convert.FromBase64String(encoded);
            return key.Length == 32
                ? key
                : throw new InvalidOperationException("JIRA_TOKEN_STATE_KEY_FILE must contain a base64-encoded 256-bit AES key");
        }
        catch (FormatException exception)
        {
            throw new InvalidOperationException("JIRA_TOKEN_STATE_KEY_FILE must contain a base64-encoded 256-bit AES key", exception);
        }
    }

    private sealed class Envelope
    {
        public required string Nonce { get; init; }
        public required string Ciphertext { get; init; }
        public required string Tag { get; init; }
    }
}
