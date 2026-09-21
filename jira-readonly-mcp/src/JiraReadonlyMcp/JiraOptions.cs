using System.Globalization;

namespace JiraReadonlyMcp;

internal enum JiraAuthMode
{
    Basic,
    Pat,
    OAuthClientCredentials,
    OAuthRefreshToken,
}

internal sealed class JiraOptions
{
    public required Uri BaseUri { get; init; }
    public required JiraAuthMode AuthMode { get; init; }
    public required string CredentialSecretFile { get; init; }
    public Uri? OAuthTokenUri { get; init; }
    public string OAuthScope { get; init; } = string.Empty;
    public string? TokenStateDirectory { get; init; }
    public string? TokenStateKeyFile { get; init; }
    public int MaxResults { get; init; } = 50;
    public long MaxAttachmentBytes { get; init; } = 10 * 1024 * 1024;
    public long MaxJsonResponseBytes { get; init; } = 8 * 1024 * 1024;
    public int RequestTimeoutSeconds { get; init; } = 30;

    public static JiraOptions FromEnvironment()
    {
        var baseUri = ReadHttpsUri("JIRA_BASE_URL", required: true);
        if (!string.IsNullOrEmpty(baseUri.Query) || !string.IsNullOrEmpty(baseUri.Fragment))
        {
            throw new InvalidOperationException("JIRA_BASE_URL must not contain a query or fragment");
        }

        var authMode = (Environment.GetEnvironmentVariable("JIRA_AUTH_MODE") ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "basic" => JiraAuthMode.Basic,
            "pat" => JiraAuthMode.Pat,
            "oauth-client-credentials" => JiraAuthMode.OAuthClientCredentials,
            "oauth-refresh-token" => JiraAuthMode.OAuthRefreshToken,
            _ => throw new InvalidOperationException("JIRA_AUTH_MODE must be basic, pat, oauth-client-credentials, or oauth-refresh-token"),
        };

        var tokenUri = authMode is JiraAuthMode.OAuthClientCredentials or JiraAuthMode.OAuthRefreshToken
            ? ReadHttpsUri("JIRA_OAUTH_TOKEN_URL", required: true)
            : null;
        var tokenStateDirectory = authMode == JiraAuthMode.OAuthRefreshToken
            ? Required("JIRA_TOKEN_STATE_DIR")
            : null;
        var tokenStateKeyFile = authMode == JiraAuthMode.OAuthRefreshToken
            ? Required("JIRA_TOKEN_STATE_KEY_FILE")
            : null;

        return new JiraOptions
        {
            BaseUri = EnsureTrailingSlash(baseUri),
            AuthMode = authMode,
            CredentialSecretFile = Required("JIRA_CREDENTIAL_SECRET_FILE"),
            OAuthTokenUri = tokenUri,
            OAuthScope = Environment.GetEnvironmentVariable("JIRA_OAUTH_SCOPE")?.Trim() ?? string.Empty,
            TokenStateDirectory = tokenStateDirectory,
            TokenStateKeyFile = tokenStateKeyFile,
            MaxResults = BoundedInteger("JIRA_MAX_RESULTS", 50, 1, 100),
            MaxAttachmentBytes = BoundedLong("JIRA_MAX_ATTACHMENT_BYTES", 10 * 1024 * 1024, 1, 50 * 1024 * 1024),
            MaxJsonResponseBytes = BoundedLong("JIRA_MAX_JSON_RESPONSE_BYTES", 8 * 1024 * 1024, 1024, 50 * 1024 * 1024),
            RequestTimeoutSeconds = BoundedInteger("JIRA_REQUEST_TIMEOUT_SECONDS", 30, 1, 300),
        };
    }

    public Uri ApiUri(string relativePath)
    {
        if (!relativePath.StartsWith("rest/api/2/", StringComparison.Ordinal) || relativePath.Contains("..", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Only Jira REST API v2 relative paths are allowed");
        }

        return new Uri(BaseUri, relativePath);
    }

    private static Uri ReadHttpsUri(string name, bool required)
    {
        var value = Environment.GetEnvironmentVariable(name)?.Trim();
        if (string.IsNullOrWhiteSpace(value) && required)
        {
            throw new InvalidOperationException($"{name} is required");
        }

        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps || !string.IsNullOrEmpty(uri.UserInfo))
        {
            throw new InvalidOperationException($"{name} must be an HTTPS URI without user info");
        }

        return uri;
    }

    private static Uri EnsureTrailingSlash(Uri uri) => uri.AbsoluteUri.EndsWith("/", StringComparison.Ordinal)
        ? uri
        : new Uri(uri.AbsoluteUri + "/", UriKind.Absolute);

    private static string Required(string name) => Environment.GetEnvironmentVariable(name)?.Trim() is { Length: > 0 } value
        ? value
        : throw new InvalidOperationException($"{name} is required");

    private static int BoundedInteger(string name, int defaultValue, int minimum, int maximum)
    {
        var raw = Environment.GetEnvironmentVariable(name)?.Trim();
        return string.IsNullOrEmpty(raw)
            ? defaultValue
            : int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value >= minimum && value <= maximum
                ? value
                : throw new InvalidOperationException($"{name} must be an integer from {minimum} to {maximum}");
    }

    private static long BoundedLong(string name, long defaultValue, long minimum, long maximum)
    {
        var raw = Environment.GetEnvironmentVariable(name)?.Trim();
        return string.IsNullOrEmpty(raw)
            ? defaultValue
            : long.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value >= minimum && value <= maximum
                ? value
                : throw new InvalidOperationException($"{name} must be an integer from {minimum} to {maximum}");
    }
}
