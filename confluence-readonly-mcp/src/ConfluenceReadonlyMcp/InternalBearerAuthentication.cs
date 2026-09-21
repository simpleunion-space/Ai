using System.Security.Cryptography;
using System.Text;

namespace AiStand.ConfluenceReadonlyMcp;

/// <summary>Authenticates the Agentgateway-to-backend hop with a per-instance secret.</summary>
public sealed class InternalBearerAuthentication
{
    private readonly byte[] _expectedHash;

    public InternalBearerAuthentication(string tokenFile)
    {
        var token = File.ReadAllText(tokenFile).Trim();
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new InvalidOperationException("MCP_INTERNAL_TOKEN_FILE points to an empty secret file");
        }

        var tokenBytes = Encoding.UTF8.GetBytes(token);
        try
        {
            _expectedHash = SHA256.HashData(tokenBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(tokenBytes);
        }
    }

    public bool IsAuthorized(string? authorizationHeader)
    {
        const string prefix = "Bearer ";
        if (string.IsNullOrWhiteSpace(authorizationHeader) || !authorizationHeader.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var supplied = Encoding.UTF8.GetBytes(authorizationHeader[prefix.Length..]);
        try
        {
            var suppliedHash = SHA256.HashData(supplied);
            try
            {
                return CryptographicOperations.FixedTimeEquals(suppliedHash, _expectedHash);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(suppliedHash);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(supplied);
        }
    }
}
