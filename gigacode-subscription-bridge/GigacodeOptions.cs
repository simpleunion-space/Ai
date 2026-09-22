using System.Globalization;

namespace AiStand.GigacodeBridge;

internal sealed class GigacodeOptions
{
    public required Uri BaseUri { get; init; }
    public required string ConfigPath { get; init; }
    public required string AuthPath { get; init; }
    public required string FallbackChatPath { get; init; }
    public required string DeviceIdFile { get; init; }
    public required string InternalBearerFile { get; init; }
    public required string ModelAlias { get; init; }
    public required string FallbackModel { get; init; }
    public required string PluginName { get; init; }
    public required string PluginVersion { get; init; }
    public required string Login { get; init; }
    public required string Locale { get; init; }
    public required int ContextWindow { get; init; }
    public required int TokenRefreshSkewSeconds { get; init; }
    public required int RequestTimeoutSeconds { get; init; }
    public required int StreamIdleTimeoutSeconds { get; init; }

    public static GigacodeOptions FromEnvironment()
    {
        var baseUri = RequiredUri("GIGACODE_BASE_URL", "https://gigacode.ru");
        if (baseUri.Scheme != Uri.UriSchemeHttps || !string.IsNullOrEmpty(baseUri.Query) || !string.IsNullOrEmpty(baseUri.Fragment))
        {
            throw new InvalidOperationException("GIGACODE_BASE_URL must be an HTTPS origin without query or fragment");
        }

        return new GigacodeOptions
        {
            BaseUri = new Uri(baseUri.GetLeftPart(UriPartial.Authority), UriKind.Absolute),
            ConfigPath = RequiredPath("GIGACODE_CONFIG_PATH", "/api/v2/config"),
            AuthPath = RequiredPath("GIGACODE_AUTH_PATH", "/api/v2/auth/plugin"),
            FallbackChatPath = RequiredPath("GIGACODE_FALLBACK_CHAT_PATH", "/api/v2/chat/completions"),
            DeviceIdFile = Required("GIGACODE_DEVICE_ID_FILE", "/run/secrets/gigacode-device-id"),
            InternalBearerFile = Required("GIGACODE_INTERNAL_BEARER_FILE", "/run/secrets/ai-stand-gigacode-internal-bearer"),
            ModelAlias = Required("GIGACODE_MODEL_ALIAS", "gigacode/codechat"),
            FallbackModel = Required("GIGACODE_FALLBACK_MODEL", "CodeChat"),
            // These non-secret values deliberately match the supported external
            // GigaCode plugin contract. The bridge contains no CLI binaries.
            PluginName = Required("GIGACODE_PLUGIN_NAME", "cli-plugin"),
            PluginVersion = Required("GIGACODE_PLUGIN_VERSION", "26.7.33"),
            Login = Required("GIGACODE_LOGIN", "node"),
            Locale = Required("GIGACODE_LOCALE", "ru"),
            ContextWindow = PositiveInteger("GIGACODE_CONTEXT_WINDOW", 65536),
            TokenRefreshSkewSeconds = PositiveInteger("GIGACODE_TOKEN_REFRESH_SKEW_SECONDS", 60),
            RequestTimeoutSeconds = PositiveInteger("GIGACODE_REQUEST_TIMEOUT_SECONDS", 86400),
            StreamIdleTimeoutSeconds = PositiveInteger("GIGACODE_STREAM_IDLE_TIMEOUT_SECONDS", 86400),
        };
    }

    public Uri ResolvePath(string path) => new(BaseUri, path);

    public bool IsAllowedChatUri(Uri uri) =>
        uri.Scheme == Uri.UriSchemeHttps &&
        string.Equals(uri.Host, BaseUri.Host, StringComparison.OrdinalIgnoreCase) &&
        uri.Port == BaseUri.Port &&
        uri.AbsolutePath.Contains("/chat/", StringComparison.Ordinal) &&
        uri.AbsolutePath.EndsWith("/completions", StringComparison.Ordinal);

    private static string Required(string name, string defaultValue)
    {
        var value = Environment.GetEnvironmentVariable(name)?.Trim();
        return string.IsNullOrEmpty(value) ? defaultValue : value;
    }

    private static string RequiredPath(string name, string defaultValue)
    {
        var value = Required(name, defaultValue);
        if (!value.StartsWith("/", StringComparison.Ordinal) || value.Contains("..", StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"{name} must be an absolute, normalized URL path");
        }

        return value;
    }

    private static Uri RequiredUri(string name, string defaultValue)
    {
        var value = Required(name, defaultValue);
        return Uri.TryCreate(value, UriKind.Absolute, out var uri)
            ? uri
            : throw new InvalidOperationException($"{name} must be an absolute URI");
    }

    private static int PositiveInteger(string name, int defaultValue)
    {
        var raw = Required(name, defaultValue.ToString(CultureInfo.InvariantCulture));
        return int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value > 0
            ? value
            : throw new InvalidOperationException($"{name} must be a positive integer");
    }
}
