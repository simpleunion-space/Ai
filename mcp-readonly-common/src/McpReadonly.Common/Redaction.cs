using System.Text.RegularExpressions;

namespace AiStand.McpReadonly;

/// <summary>Removes common credential-shaped values before an exception reaches a log sink.</summary>
public static partial class Redaction
{
    public static string Safe(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;
        return SecretPattern().Replace(value, "$1[redacted]");
    }

    [GeneratedRegex("(?i)(authorization|bearer|password|token|secret|client_secret)\\s*[:=]\\s*[^,\\s]+")]
    private static partial Regex SecretPattern();
}
