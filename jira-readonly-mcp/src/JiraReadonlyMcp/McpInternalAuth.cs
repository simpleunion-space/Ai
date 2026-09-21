using System.Security.Cryptography;
using System.Text;

namespace JiraReadonlyMcp;

/// <summary>
/// Authenticates only the internal Agentgateway-to-backend hop. Human OAuth
/// authentication and user-to-container routing remain Agentgateway concerns.
/// </summary>
internal sealed class McpInternalAuth
{
    private readonly byte[] _tokenDigest;

    private McpInternalAuth(byte[] tokenDigest) => _tokenDigest = tokenDigest;

    public static McpInternalAuth FromEnvironment()
    {
        var path = Environment.GetEnvironmentVariable("MCP_INTERNAL_TOKEN_FILE")?.Trim();
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException("MCP_INTERNAL_TOKEN_FILE is required");
        }
        return FromSecretFile(path);
    }

    internal static McpInternalAuth FromSecretFile(string path)
    {
        var token = File.ReadAllText(path, Encoding.UTF8).Trim();
        if (token.Length == 0 || token.Length > 4096 || token.Any(char.IsWhiteSpace))
        {
            throw new InvalidOperationException("MCP internal bearer token is invalid");
        }
        return new McpInternalAuth(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
    }

    public bool IsAuthorized(string? authorization)
    {
        const string scheme = "Bearer ";
        if (string.IsNullOrWhiteSpace(authorization) || !authorization.StartsWith(scheme, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var candidate = authorization[scheme.Length..];
        if (candidate.Length == 0 || candidate.Length > 4096 || candidate.Any(char.IsWhiteSpace))
        {
            return false;
        }

        // Hashes always have the same length, so the comparison does not vary
        // with the secret length or with the first mismatching byte.
        var candidateDigest = SHA256.HashData(Encoding.UTF8.GetBytes(candidate));
        return CryptographicOperations.FixedTimeEquals(_tokenDigest, candidateDigest);
    }
}
