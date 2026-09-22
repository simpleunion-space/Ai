using System.Security.Cryptography;
using System.Text;

namespace AiStand.GigacodeBridge;

internal sealed class InternalBearerAuthentication
{
    private readonly byte[] _expected;

    public InternalBearerAuthentication(GigacodeOptions options)
    {
        if (!File.Exists(options.InternalBearerFile))
        {
            throw new InvalidOperationException("GIGACODE_INTERNAL_BEARER_FILE does not exist");
        }

        var value = File.ReadAllText(options.InternalBearerFile, Encoding.UTF8).Trim();
        if (value.Length is < 32 or > 512 || value.Any(char.IsWhiteSpace))
        {
            throw new InvalidOperationException("GIGACODE_INTERNAL_BEARER_FILE is invalid");
        }

        _expected = Encoding.UTF8.GetBytes(value);
    }

    public bool IsAuthorized(HttpRequest request)
    {
        if (!request.Headers.Authorization.ToString().StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var supplied = request.Headers.Authorization.ToString()["Bearer ".Length..].Trim();
        var suppliedBytes = Encoding.UTF8.GetBytes(supplied);
        return suppliedBytes.Length == _expected.Length && CryptographicOperations.FixedTimeEquals(suppliedBytes, _expected);
    }
}
