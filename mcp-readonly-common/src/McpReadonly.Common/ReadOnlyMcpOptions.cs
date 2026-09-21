namespace AiStand.McpReadonly;

/// <summary>Common operational limits for an outbound, read-only MCP adapter.</summary>
public sealed class ReadOnlyMcpOptions
{
    public required Uri BaseUri { get; init; }
    public int RequestTimeoutSeconds { get; init; } = 60;
    public int DefaultPageSize { get; init; } = 25;
    public int MaximumPageSize { get; init; } = 100;
    public int MaximumResults { get; init; } = 100;
    public int MaximumAttachmentBytes { get; init; } = 10 * 1024 * 1024;

    public void Validate(bool requireHttps = true)
    {
        if (!BaseUri.IsAbsoluteUri || (requireHttps && BaseUri.Scheme != Uri.UriSchemeHttps))
        {
            throw new InvalidOperationException("The configured upstream URL must be an absolute HTTPS URL.");
        }

        if (RequestTimeoutSeconds is < 1 or > 86400 || DefaultPageSize < 1 || MaximumPageSize < DefaultPageSize || MaximumResults < 1 || MaximumAttachmentBytes < 1)
        {
            throw new InvalidOperationException("The configured read-only MCP limits are invalid.");
        }
    }

    public int ClampPageSize(int? requested) => Math.Clamp(requested ?? DefaultPageSize, 1, MaximumPageSize);
}
