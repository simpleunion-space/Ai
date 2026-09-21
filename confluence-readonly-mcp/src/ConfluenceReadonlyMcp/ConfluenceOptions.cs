using System.Globalization;
using System.Text.Json;

namespace AiStand.ConfluenceReadonlyMcp;

public enum ConfluenceAuthMode
{
    Basic,
    Pat,
    OAuth2ClientCredentials,
    OAuth2RefreshToken,
}

/// <summary>Single-secret renderer contract. Values never appear in logs or tool responses.</summary>
public sealed record ConfluenceCredentials(
    string? Username,
    string? Password,
    string? Token,
    string? ClientId,
    string? ClientSecret,
    string? RefreshToken,
    string? TokenUrl,
    string? Scope)
{
    internal static ConfluenceCredentials Parse(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidOperationException("CONFLUENCE_CREDENTIAL_SECRET_FILE must contain a JSON object");
            }

            return new ConfluenceCredentials(
                ReadString(root, "username"),
                ReadString(root, "password"),
                // The installation-owned Vault schema calls this `pat`.
                // `token` stays as a compatibility fallback for a single
                // rotation cycle and is never emitted by the reconciler.
                ReadString(root, "pat") ?? ReadString(root, "token"),
                ReadString(root, "client_id"),
                ReadString(root, "client_secret"),
                ReadString(root, "refresh_token"),
                ReadString(root, "token_url"),
                ReadString(root, "scope"));
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException("CONFLUENCE_CREDENTIAL_SECRET_FILE must contain valid JSON", exception);
        }
    }

    private static string? ReadString(JsonElement root, string name) => root.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String
        ? property.GetString()?.Trim()
        : null;
}

public sealed record ConfluenceOptions(
    Uri BaseUri,
    ConfluenceAuthMode AuthMode,
    int MaxPageSize,
    int MaxResults,
    int MaxAttachmentBytes,
    int MaxResponseBytes,
    TimeSpan RequestTimeout,
    string? UsernameFile,
    string? PasswordFile,
    string? PatFile,
    Uri? OAuthTokenUri,
    string? OAuthClientIdFile,
    string? OAuthClientSecretFile,
    string? OAuthRefreshTokenFile,
    string? TokenStateFile,
    string? TokenStateKeyFile,
    string InternalTokenFile,
    string? OAuthScope,
    ConfluenceCredentials? Credentials)
{
    public static ConfluenceOptions FromEnvironment() => From(
        name => Environment.GetEnvironmentVariable(name),
        path => File.ReadAllText(path).Trim());

    internal static ConfluenceOptions From(Func<string, string?> get, Func<string, string> secretReader)
    {
        ArgumentNullException.ThrowIfNull(get);
        ArgumentNullException.ThrowIfNull(secretReader);

        var baseUri = RequireHttpsUri(Require(get, "CONFLUENCE_BASE_URL"), "CONFLUENCE_BASE_URL", allowPath: true);
        var authMode = ParseAuthMode(Require(get, "CONFLUENCE_AUTH_MODE"));
        var maxPageSize = BoundedInt(get, "CONFLUENCE_MAX_PAGE_SIZE", 25, 1, 100);
        var maxResults = BoundedInt(get, "CONFLUENCE_MAX_RESULTS", 100, 1, 500);
        var maxAttachmentBytes = BoundedInt(get, "CONFLUENCE_MAX_ATTACHMENT_BYTES", 10 * 1024 * 1024, 1, 50 * 1024 * 1024);
        var maxResponseBytes = BoundedInt(get, "CONFLUENCE_MAX_RESPONSE_BYTES", 2 * 1024 * 1024, 1, 8 * 1024 * 1024);
        var timeoutSeconds = BoundedInt(get, "CONFLUENCE_REQUEST_TIMEOUT_SECONDS", 60, 1, 600);
        var internalTokenFile = RequireSecretFile(get, secretReader, "MCP_INTERNAL_TOKEN_FILE");
        var credentialSecretFile = get("CONFLUENCE_CREDENTIAL_SECRET_FILE");
        var credentials = string.IsNullOrWhiteSpace(credentialSecretFile)
            ? null
            : ReadCredentials(credentialSecretFile.Trim(), secretReader);

        string? usernameFile = null;
        string? passwordFile = null;
        string? patFile = null;
        Uri? oauthTokenUri = null;
        string? clientIdFile = null;
        string? clientSecretFile = null;
        string? refreshTokenFile = null;
        string? tokenStateFile = null;
        string? tokenStateKeyFile = null;

        switch (authMode)
        {
            case ConfluenceAuthMode.Basic:
                if (credentials is null)
                {
                    usernameFile = RequireSecretFile(get, secretReader, "CONFLUENCE_USERNAME_FILE");
                    passwordFile = RequireSecretFile(get, secretReader, "CONFLUENCE_PASSWORD_FILE");
                }
                else
                {
                    RequireCredential(credentials.Username, "username");
                    RequireCredential(credentials.Password, "password");
                }

                break;
            case ConfluenceAuthMode.Pat:
                if (credentials is null)
                {
                    patFile = RequireSecretFile(get, secretReader, "CONFLUENCE_PAT_FILE");
                }
                else
                {
                    RequireCredential(credentials.Token, "pat");
                }

                break;
            case ConfluenceAuthMode.OAuth2ClientCredentials:
                oauthTokenUri = ResolveTokenUri(get, credentials);
                if (credentials is null)
                {
                    clientIdFile = RequireSecretFile(get, secretReader, "CONFLUENCE_OAUTH_CLIENT_ID_FILE");
                    clientSecretFile = RequireSecretFile(get, secretReader, "CONFLUENCE_OAUTH_CLIENT_SECRET_FILE");
                }
                else
                {
                    RequireCredential(credentials.ClientId, "client_id");
                    RequireCredential(credentials.ClientSecret, "client_secret");
                }

                break;
            case ConfluenceAuthMode.OAuth2RefreshToken:
                oauthTokenUri = ResolveTokenUri(get, credentials);
                if (credentials is null)
                {
                    clientIdFile = RequireSecretFile(get, secretReader, "CONFLUENCE_OAUTH_CLIENT_ID_FILE");
                    clientSecretFile = RequireSecretFile(get, secretReader, "CONFLUENCE_OAUTH_CLIENT_SECRET_FILE");
                    refreshTokenFile = RequireSecretFile(get, secretReader, "CONFLUENCE_OAUTH_REFRESH_TOKEN_FILE");
                }
                else
                {
                    RequireCredential(credentials.ClientId, "client_id");
                    RequireCredential(credentials.ClientSecret, "client_secret");
                    RequireCredential(credentials.RefreshToken, "refresh_token");
                }

                var tokenStateDirectory = Require(get, "CONFLUENCE_TOKEN_STATE_DIR");
                if (!Path.IsPathFullyQualified(tokenStateDirectory))
                {
                    throw new InvalidOperationException("CONFLUENCE_TOKEN_STATE_DIR must be an absolute path");
                }

                tokenStateFile = Path.Combine(tokenStateDirectory, "refresh-token.state");
                tokenStateKeyFile = RequireSecretFile(get, secretReader, "CONFLUENCE_TOKEN_STATE_KEY_FILE");
                break;
            default:
                throw new InvalidOperationException("Unsupported Confluence auth mode");
        }

        return new ConfluenceOptions(
            EnsureTrailingSlash(baseUri),
            authMode,
            maxPageSize,
            maxResults,
            maxAttachmentBytes,
            maxResponseBytes,
            TimeSpan.FromSeconds(timeoutSeconds),
            usernameFile,
            passwordFile,
            patFile,
            oauthTokenUri,
            clientIdFile,
            clientSecretFile,
            refreshTokenFile,
            tokenStateFile,
            tokenStateKeyFile,
            internalTokenFile,
            credentials?.Scope ?? get("CONFLUENCE_OAUTH_SCOPE"),
            credentials);
    }

    private static string Require(Func<string, string?> get, string name) =>
        !string.IsNullOrWhiteSpace(get(name))
            ? get(name)!.Trim()
            : throw new InvalidOperationException($"{name} is required");

    private static string RequireSecretFile(Func<string, string?> get, Func<string, string> secretReader, string name)
    {
        var path = Require(get, name);
        try
        {
            if (string.IsNullOrWhiteSpace(secretReader(path)))
            {
                throw new InvalidOperationException($"{name} points to an empty secret file");
            }
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException($"{name} cannot be read", exception);
        }

        return path;
    }

    private static ConfluenceAuthMode ParseAuthMode(string raw) => raw.ToLowerInvariant() switch
    {
        "basic" => ConfluenceAuthMode.Basic,
        "pat" => ConfluenceAuthMode.Pat,
        "oauth-client-credentials" or "oauth2_client_credentials" => ConfluenceAuthMode.OAuth2ClientCredentials,
        "oauth-refresh-token" or "oauth2_refresh_token" => ConfluenceAuthMode.OAuth2RefreshToken,
        _ => throw new InvalidOperationException("CONFLUENCE_AUTH_MODE must be basic, pat, oauth-client-credentials, or oauth-refresh-token"),
    };

    internal string ResolveUsername() => ResolveCredential(Credentials?.Username, UsernameFile, "username");

    internal string ResolvePassword() => ResolveCredential(Credentials?.Password, PasswordFile, "password");

    internal string ResolvePat() => ResolveCredential(Credentials?.Token, PatFile, "pat");

    internal string ResolveOAuthClientId() => ResolveCredential(Credentials?.ClientId, OAuthClientIdFile, "client_id");

    internal string ResolveOAuthClientSecret() => ResolveCredential(Credentials?.ClientSecret, OAuthClientSecretFile, "client_secret");

    internal string ResolveOAuthRefreshToken() => ResolveCredential(Credentials?.RefreshToken, OAuthRefreshTokenFile, "refresh_token");

    private static ConfluenceCredentials ReadCredentials(string path, Func<string, string> secretReader)
    {
        try
        {
            return ConfluenceCredentials.Parse(secretReader(path));
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException("CONFLUENCE_CREDENTIAL_SECRET_FILE cannot be read", exception);
        }
    }

    private static Uri ResolveTokenUri(Func<string, string?> get, ConfluenceCredentials? credentials)
    {
        var raw = credentials?.TokenUrl ?? Require(get, "CONFLUENCE_OAUTH_TOKEN_URL");
        return RequireHttpsUri(raw, credentials is null ? "CONFLUENCE_OAUTH_TOKEN_URL" : "token_url", allowPath: true);
    }

    private static void RequireCredential(string? value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"CONFLUENCE_CREDENTIAL_SECRET_FILE is missing {name}");
        }
    }

    private static string ResolveCredential(string? inlineValue, string? file, string name)
    {
        if (!string.IsNullOrWhiteSpace(inlineValue))
        {
            return inlineValue;
        }

        if (!string.IsNullOrWhiteSpace(file))
        {
            var value = File.ReadAllText(file).Trim();
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        throw new InvalidOperationException($"Configured Confluence {name} credential is unavailable");
    }

    private static int BoundedInt(Func<string, string?> get, string name, int defaultValue, int min, int max)
    {
        var raw = get(name);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return defaultValue;
        }

        return int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value >= min && value <= max
            ? value
            : throw new InvalidOperationException($"{name} must be an integer from {min} to {max}");
    }

    private static Uri RequireHttpsUri(string raw, string name, bool allowPath)
    {
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment) ||
            (!allowPath && uri.AbsolutePath != "/"))
        {
            throw new InvalidOperationException($"{name} must be an absolute HTTPS URL without credentials, query, or fragment");
        }

        return uri;
    }

    private static Uri EnsureTrailingSlash(Uri uri) => uri.AbsolutePath.EndsWith('/')
        ? uri
        : new UriBuilder(uri) { Path = uri.AbsolutePath + "/" }.Uri;
}
