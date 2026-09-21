using System.Text;
using System.Security.Cryptography;

namespace AiStand.ImapReadonlyMcp;

public static class SecretFile
{
    public static string ReadRequired(string path)
    {
        try
        {
            var value = File.ReadAllText(path, Encoding.UTF8).Trim();
            return value.Length > 0 ? value : throw new ConfigurationException("A configured secret file is empty");
        }
        catch (ConfigurationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new ConfigurationException("A configured secret file cannot be read");
        }
    }
}

public static class SafeLog
{
    public static string SafeOperation(string operation) => operation switch
    {
        "imap_list_mailboxes" or "imap_search_messages" or "imap_get_message" or "imap_list_attachments" or "imap_get_attachment" => operation,
        _ => "unknown",
    };

    public static string RequestId() => Guid.NewGuid().ToString("N");
}

public sealed class InternalBearerAuthenticator(ImapOptions options)
{
    public bool IsAuthorized(HttpRequest request)
    {
        var authorization = request.Headers.Authorization.ToString();
        const string scheme = "Bearer ";
        if (!authorization.StartsWith(scheme, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var presented = authorization[scheme.Length..];
        if (string.IsNullOrWhiteSpace(presented) || presented.Any(char.IsWhiteSpace))
        {
            return false;
        }

        var expected = SecretFile.ReadRequired(options.InternalTokenFile);
        return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(presented), Encoding.UTF8.GetBytes(expected));
    }
}

public sealed class TokenStateStore(OAuthOptions options)
{
    private const byte Version = 1;
    private const int NonceLength = 12;
    private const int TagLength = 16;
    private const string StateFileName = "imap-oauth-refresh.v1";

    public string ReadRefreshToken()
    {
        var statePath = GetStatePath();
        return File.Exists(statePath)
            ? Decrypt(File.ReadAllBytes(statePath))
            : options.InitialRefreshToken ?? throw new ConfigurationException("IMAP OAuth initial refresh token is missing");
    }

    public void WriteRotatedRefreshToken(string refreshToken)
    {
        if (string.IsNullOrWhiteSpace(refreshToken))
        {
            throw new McpToolException("IMAP OAuth refresh response was invalid");
        }

        var statePath = GetStatePath();
        Directory.CreateDirectory(Path.GetDirectoryName(statePath)!);
        var temporaryPath = $"{statePath}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllBytes(temporaryPath, Encrypt(refreshToken));
            SetOwnerOnlyFileMode(temporaryPath);
            File.Move(temporaryPath, statePath, true);
            SetOwnerOnlyFileMode(statePath);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private string GetStatePath()
    {
        var directory = options.TokenStateDirectory ?? throw new ConfigurationException("IMAP token state directory is missing");
        if (!Path.IsPathFullyQualified(directory))
        {
            throw new ConfigurationException("IMAP_TOKEN_STATE_DIR must be an absolute path");
        }

        return Path.Combine(directory, StateFileName);
    }

    private byte[] Encrypt(string value)
    {
        var plainText = Encoding.UTF8.GetBytes(value);
        var nonce = RandomNumberGenerator.GetBytes(NonceLength);
        var ciphertext = new byte[plainText.Length];
        var tag = new byte[TagLength];
        var key = ReadKey();
        try
        {
            using var aes = new AesGcm(key, TagLength);
            aes.Encrypt(nonce, plainText, ciphertext, tag);
            return [Version, .. nonce, .. tag, .. ciphertext];
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(plainText);
        }
    }

    private string Decrypt(byte[] payload)
    {
        if (payload.Length < 1 + NonceLength + TagLength || payload[0] != Version)
        {
            throw new McpToolException("IMAP OAuth token state is invalid");
        }

        var nonce = payload.AsSpan(1, NonceLength);
        var tag = payload.AsSpan(1 + NonceLength, TagLength);
        var ciphertext = payload.AsSpan(1 + NonceLength + TagLength);
        var plaintext = new byte[ciphertext.Length];
        var key = ReadKey();
        try
        {
            using var aes = new AesGcm(key, TagLength);
            aes.Decrypt(nonce, ciphertext, tag, plaintext);
            return Encoding.UTF8.GetString(plaintext);
        }
        catch (CryptographicException)
        {
            throw new McpToolException("IMAP OAuth token state cannot be decrypted");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private byte[] ReadKey()
    {
        var path = options.TokenStateKeyFile ?? throw new ConfigurationException("IMAP token state key is missing");
        try
        {
            var encoded = File.ReadAllText(path, Encoding.UTF8).Trim();
            var key = Convert.FromBase64String(encoded);
            if (key.Length != 32)
            {
                CryptographicOperations.ZeroMemory(key);
                throw new ConfigurationException("IMAP token protection key must be 32 bytes of base64 data");
            }
            return key;
        }
        catch (ConfigurationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or FormatException)
        {
            throw new ConfigurationException("IMAP token protection key cannot be read");
        }
    }

    private static void SetOwnerOnlyFileMode(string path)
    {
        if (OperatingSystem.IsLinux())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }
}

public static class InputValidation
{
    public static void EnsureMailboxSyntax(string mailbox)
    {
        if (string.IsNullOrWhiteSpace(mailbox) || mailbox.Length > 255 || mailbox.Any(c => char.IsControl(c)))
        {
            throw new McpToolException("Mailbox name is invalid");
        }
    }

    public static uint PositiveUid(long value)
    {
        return value > 0 && value <= uint.MaxValue
            ? (uint)value
            : throw new McpToolException("uid must be a positive IMAP UID");
    }

    public static int BoundedInteger(long value, string name, int minimum, int maximum)
    {
        return value >= minimum && value <= maximum
            ? (int)value
            : throw new McpToolException($"{name} must be from {minimum} to {maximum}");
    }

    public static string BoundedText(string? value, string name, int maximum = 512)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maximum || value.Any(char.IsControl))
        {
            throw new McpToolException($"{name} is invalid");
        }

        return value;
    }
}

public sealed class McpToolException(string message) : Exception(message);
