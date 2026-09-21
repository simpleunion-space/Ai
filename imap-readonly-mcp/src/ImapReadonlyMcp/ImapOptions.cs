using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AiStand.ImapReadonlyMcp;

public enum ImapTlsMode
{
    Implicit,
    StartTls,
}

public enum ImapAuthenticationMode
{
    Basic,
    OAuthClientCredentials,
    OAuthRefreshToken,
}

public sealed record ImapCredentialSecret(
    string Username,
    string? Password,
    string? AccessToken,
    Uri? TokenEndpoint,
    string? ClientId,
    string? ClientSecret,
    string? RefreshToken,
    string? Scope)
{
    private static readonly IReadOnlySet<string> AllowedProperties = new HashSet<string>(StringComparer.Ordinal)
    {
        "username", "password", "token", "token_url", "client_id", "client_secret", "refresh_token", "scope",
    };

    public static ImapCredentialSecret FromFile(string path, ImapAuthenticationMode authenticationMode)
    {
        var json = SecretFile.ReadRequired(path);
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object || document.RootElement.EnumerateObject().Any(property => !AllowedProperties.Contains(property.Name)))
            {
                throw new ConfigurationException("IMAP credential secret has an invalid JSON shape");
            }

            var raw = JsonSerializer.Deserialize<CredentialDocument>(json)
                ?? throw new ConfigurationException("IMAP credential secret is invalid");
            var secret = new ImapCredentialSecret(
                Required(raw.Username, "username"),
                Optional(raw.Password),
                Optional(raw.Token),
                ParseTokenEndpoint(raw.TokenUrl),
                Optional(raw.ClientId),
                Optional(raw.ClientSecret),
                Optional(raw.RefreshToken),
                Optional(raw.Scope));
            secret.Validate(authenticationMode);
            return secret;
        }
        catch (ConfigurationException)
        {
            throw;
        }
        catch (JsonException)
        {
            throw new ConfigurationException("IMAP credential secret is not valid JSON");
        }
    }

    private void Validate(ImapAuthenticationMode mode)
    {
        if (Username.Length > 512 || Username.Any(char.IsControl))
        {
            throw new ConfigurationException("IMAP credential username is invalid");
        }

        switch (mode)
        {
            case ImapAuthenticationMode.Basic when string.IsNullOrWhiteSpace(Password):
                throw new ConfigurationException("IMAP basic credential requires password");
            case ImapAuthenticationMode.OAuthClientCredentials when string.IsNullOrWhiteSpace(AccessToken) &&
                (TokenEndpoint is null || string.IsNullOrWhiteSpace(ClientId) || string.IsNullOrWhiteSpace(ClientSecret)):
                throw new ConfigurationException("IMAP OAuth client credential requires token or token_url/client_id/client_secret");
            case ImapAuthenticationMode.OAuthRefreshToken when TokenEndpoint is null || string.IsNullOrWhiteSpace(ClientId) ||
                string.IsNullOrWhiteSpace(ClientSecret) || string.IsNullOrWhiteSpace(RefreshToken):
                throw new ConfigurationException("IMAP OAuth refresh credential requires token_url/client_id/client_secret/refresh_token");
        }

        if (Scope is { Length: > 2048 } || Scope?.Any(char.IsControl) == true)
        {
            throw new ConfigurationException("IMAP OAuth scope is invalid");
        }
    }

    private static Uri? ParseTokenEndpoint(string? value)
    {
        var endpointText = Optional(value);
        if (endpointText is null)
        {
            return null;
        }
        if (!Uri.TryCreate(endpointText, UriKind.Absolute, out var endpoint) || endpoint.Scheme != Uri.UriSchemeHttps ||
            !string.IsNullOrEmpty(endpoint.UserInfo) || !string.IsNullOrEmpty(endpoint.Fragment))
        {
            throw new ConfigurationException("IMAP credential token_url must be an HTTPS URL");
        }
        return endpoint;
    }

    private static string Required(string? value, string name) => Optional(value) ?? throw new ConfigurationException($"IMAP credential {name} is required");

    private static string? Optional(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private sealed record CredentialDocument(
        [property: JsonPropertyName("username")] string? Username,
        [property: JsonPropertyName("password")] string? Password,
        [property: JsonPropertyName("token")] string? Token,
        [property: JsonPropertyName("token_url")] string? TokenUrl,
        [property: JsonPropertyName("client_id")] string? ClientId,
        [property: JsonPropertyName("client_secret")] string? ClientSecret,
        [property: JsonPropertyName("refresh_token")] string? RefreshToken,
        [property: JsonPropertyName("scope")] string? Scope);
}

public sealed record OAuthOptions(
    Uri TokenEndpoint,
    string ClientId,
    string ClientSecret,
    string? Scope,
    ImapAuthenticationMode AuthenticationMode,
    string? InitialRefreshToken,
    string? TokenStateDirectory,
    string? TokenStateKeyFile);

public sealed record ImapOptions(
    string Host,
    int Port,
    ImapTlsMode TlsMode,
    ImapAuthenticationMode AuthenticationMode,
    ImapCredentialSecret Credentials,
    string InternalTokenFile,
    OAuthOptions? OAuth,
    IReadOnlySet<string> AllowedMailboxes,
    int MaxPageSize,
    int MaxBodyBytes,
    int MaxMessageBytes,
    int MaxAttachmentBytes,
    int RequestTimeoutSeconds)
{
    public static ImapOptions FromEnvironment(Func<string, string?>? getEnvironment = null)
    {
        getEnvironment ??= Environment.GetEnvironmentVariable;
        var host = Required(getEnvironment, "IMAP_HOST");
        if (host.Contains("://", StringComparison.Ordinal) || host.Contains('/') || host.Contains('\\') ||
            host.Any(char.IsWhiteSpace) || Uri.CheckHostName(host) == UriHostNameType.Unknown)
        {
            throw new ConfigurationException("IMAP_HOST must be a hostname or IP address, not a URL");
        }

        var tlsMode = ParseEnum(getEnvironment("IMAP_TLS_MODE") ?? "implicit", "IMAP_TLS_MODE", new Dictionary<string, ImapTlsMode>(StringComparer.OrdinalIgnoreCase)
        {
            ["implicit"] = ImapTlsMode.Implicit,
            ["starttls"] = ImapTlsMode.StartTls,
        });
        var authenticationMode = ParseEnum(getEnvironment("IMAP_AUTH_MODE") ?? "basic", "IMAP_AUTH_MODE", new Dictionary<string, ImapAuthenticationMode>(StringComparer.OrdinalIgnoreCase)
        {
            ["basic"] = ImapAuthenticationMode.Basic,
            ["oauth-client-credentials"] = ImapAuthenticationMode.OAuthClientCredentials,
            ["oauth-refresh-token"] = ImapAuthenticationMode.OAuthRefreshToken,
        });
        var credentialSecret = ImapCredentialSecret.FromFile(Required(getEnvironment, "IMAP_CREDENTIAL_SECRET_FILE"), authenticationMode);
        var oauth = authenticationMode switch
        {
            ImapAuthenticationMode.OAuthClientCredentials when credentialSecret.AccessToken is null => CreateOAuthOptions(credentialSecret, authenticationMode, getEnvironment),
            ImapAuthenticationMode.OAuthRefreshToken => CreateOAuthOptions(credentialSecret, authenticationMode, getEnvironment),
            _ => null,
        };

        return new ImapOptions(
            host,
            PositiveInt(getEnvironment, "IMAP_PORT", null, 993, 1, 65535),
            tlsMode,
            authenticationMode,
            credentialSecret,
            Required(getEnvironment, "MCP_INTERNAL_TOKEN_FILE"),
            oauth,
            ParseMailboxAllowlist(getEnvironment("IMAP_ALLOWED_MAILBOXES")),
            PositiveInt(getEnvironment, "IMAP_MAX_PAGE_SIZE", getEnvironment("IMAP_MAX_RESULTS"), 50, 1, 100),
            PositiveInt(getEnvironment, "IMAP_MAX_BODY_BYTES", null, 262144, 1024, 1048576),
            PositiveInt(getEnvironment, "IMAP_MAX_MESSAGE_BYTES", null, 10485760, 1024, 52428800),
            PositiveInt(getEnvironment, "IMAP_MAX_ATTACHMENT_BYTES", null, 5242880, 1, 26214400),
            PositiveInt(getEnvironment, "IMAP_REQUEST_TIMEOUT_SECONDS", null, 60, 1, 300));
    }

    private static OAuthOptions CreateOAuthOptions(ImapCredentialSecret credential, ImapAuthenticationMode mode, Func<string, string?> getEnvironment)
    {
        var directory = NullIfWhiteSpace(getEnvironment("IMAP_TOKEN_STATE_DIR"));
        var keyFile = NullIfWhiteSpace(getEnvironment("IMAP_TOKEN_STATE_KEY_FILE")) ?? NullIfWhiteSpace(getEnvironment("IMAP_TOKEN_PROTECTION_KEY_FILE"));
        if (mode == ImapAuthenticationMode.OAuthRefreshToken && (directory is null || keyFile is null))
        {
            throw new ConfigurationException("IMAP_TOKEN_STATE_DIR and IMAP_TOKEN_STATE_KEY_FILE are required for oauth-refresh-token");
        }

        return new OAuthOptions(
            credential.TokenEndpoint!,
            credential.ClientId!,
            credential.ClientSecret!,
            credential.Scope,
            mode,
            credential.RefreshToken,
            directory,
            keyFile);
    }

    private static IReadOnlySet<string> ParseMailboxAllowlist(string? value)
    {
        var names = (value ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var name in names)
        {
            InputValidation.EnsureMailboxSyntax(name);
        }
        return new HashSet<string>(names, StringComparer.Ordinal);
    }

    private static T ParseEnum<T>(string value, string name, IReadOnlyDictionary<string, T> choices) where T : struct =>
        choices.TryGetValue(value, out var parsed) ? parsed : throw new ConfigurationException($"{name} has an unsupported value");

    private static int PositiveInt(Func<string, string?> getEnvironment, string name, string? fallbackValue, int fallback, int minimum, int maximum)
    {
        var raw = getEnvironment(name) ?? fallbackValue;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return fallback;
        }
        return int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) && parsed >= minimum && parsed <= maximum
            ? parsed
            : throw new ConfigurationException($"{name} must be an integer from {minimum} to {maximum}");
    }

    private static string Required(Func<string, string?> getEnvironment, string name) =>
        NullIfWhiteSpace(getEnvironment(name)) ?? throw new ConfigurationException($"{name} is required");

    private static string? NullIfWhiteSpace(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}

public sealed class ConfigurationException(string message) : Exception(message);
