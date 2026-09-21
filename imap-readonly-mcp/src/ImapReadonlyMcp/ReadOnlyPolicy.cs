namespace AiStand.ImapReadonlyMcp;

/// <summary>
/// Documents the protocol operations that this server must never issue. Tool
/// registration is intentionally limited to <see cref="McpToolCatalog.Names"/>
/// and every selected IMAP folder is opened read-only.
/// </summary>
public static class ImapReadOnlyPolicy
{
    public static IReadOnlySet<string> ForbiddenImapCommands { get; } = new HashSet<string>(StringComparer.Ordinal)
    {
        "APPEND",
        "COPY",
        "EXPUNGE",
        "MOVE",
        "STORE",
    };

    public static bool IsReadOnlyTool(string name) => McpToolCatalog.Names.Contains(name, StringComparer.Ordinal);
}
