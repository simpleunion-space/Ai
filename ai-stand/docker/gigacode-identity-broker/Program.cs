using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

const string issuer = "ai-stand-gigacode-identity-broker";
const string audience = "ai-stand-gigacode";
const int tokenTtlSeconds = 60;

var options = BrokerOptions.Load();
var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(logging =>
{
    logging.SingleLine = true;
    logging.TimestampFormat = "O ";
});
builder.Logging.SetMinimumLevel(LogLevel.Information);
builder.Services.AddSingleton(options);

var app = builder.Build();
app.Urls.Clear();
app.Urls.Add(Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://+:8080");

app.MapGet("/healthz", () => Results.Json(new { status = "ok" }));

// Agentgateway obtains only the public verification key. It never receives a
// Device ID, a caller credential, or the private signing key.
app.MapGet("/.well-known/jwks.json", (BrokerOptions broker) => Results.Json(new
{
    keys = new[] { broker.PublicJwk },
}));

app.MapPost("/issue", (HttpRequest request, IssueRequest body, BrokerOptions broker) =>
{
    if (body is null || !BrokerOptions.Subject.IsMatch(body.Subject))
    {
        return Results.BadRequest(new { error = "invalid_subject" });
    }

    var caller = request.Headers["X-AI-Stand-Caller"].ToString();
    if (!BrokerOptions.Caller.IsMatch(caller) || !broker.IsAuthorized(caller, request.Headers.Authorization.ToString()))
    {
        // Do not distinguish an unknown caller from an incorrect bearer.
        return Results.Unauthorized();
    }

    var now = DateTimeOffset.UtcNow;
    var payload = new Dictionary<string, object>
    {
        ["iss"] = issuer,
        ["aud"] = audience,
        ["sub"] = body.Subject.ToLowerInvariant(),
        ["caller"] = caller,
        ["jti"] = Guid.NewGuid().ToString("N"),
        ["iat"] = now.ToUnixTimeSeconds(),
        ["nbf"] = now.ToUnixTimeSeconds(),
        ["exp"] = now.AddSeconds(tokenTtlSeconds).ToUnixTimeSeconds(),
    };

    return Results.Json(new
    {
        access_token = broker.Sign(payload),
        token_type = "Bearer",
        expires_in = tokenTtlSeconds,
    });
});

await app.RunAsync();

sealed record IssueRequest(string Subject);

sealed class BrokerOptions : IDisposable
{
    public static readonly System.Text.RegularExpressions.Regex Subject = new(
        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        System.Text.RegularExpressions.RegexOptions.CultureInvariant | System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    public static readonly System.Text.RegularExpressions.Regex Caller = new(
        "^[a-z][a-z0-9-]{0,62}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private readonly RSA _privateKey;
    private readonly IReadOnlyDictionary<string, byte[]> _callerSecrets;

    public object PublicJwk { get; }

    private BrokerOptions(RSA privateKey, IReadOnlyDictionary<string, byte[]> callerSecrets)
    {
        _privateKey = privateKey;
        _callerSecrets = callerSecrets;
        var parameters = privateKey.ExportParameters(false);
        PublicJwk = new
        {
            kty = "RSA",
            use = "sig",
            alg = "RS256",
            kid = "ai-stand-gigacode-broker-v1",
            n = Base64Url(parameters.Modulus!),
            e = Base64Url(parameters.Exponent!),
        };
    }

    public static BrokerOptions Load()
    {
        var keyFile = RequiredPrivateFile("GIGACODE_IDENTITY_BROKER_SIGNING_KEY_FILE", "/run/secrets/ai-stand-gigacode-broker-signing-key", 16 * 1024);
        var callersFile = RequiredPrivateFile("GIGACODE_IDENTITY_BROKER_CALLERS_FILE", "/run/secrets/ai-stand-gigacode-broker-callers", 8 * 1024);
        var rsa = RSA.Create();
        try
        {
            rsa.ImportFromPem(keyFile);
        }
        catch (CryptographicException error)
        {
            rsa.Dispose();
            throw new InvalidOperationException("GIGACODE_IDENTITY_BROKER_SIGNING_KEY_FILE is not an RSA private key", error);
        }

        Dictionary<string, string>? parsed;
        try
        {
            parsed = JsonSerializer.Deserialize<Dictionary<string, string>>(callersFile);
        }
        catch (JsonException error)
        {
            rsa.Dispose();
            throw new InvalidOperationException("GIGACODE_IDENTITY_BROKER_CALLERS_FILE is not valid JSON", error);
        }
        if (parsed is null || parsed.Count == 0 || parsed.Any(pair => !Caller.IsMatch(pair.Key) || string.IsNullOrWhiteSpace(pair.Value) || pair.Value.Length > 512))
        {
            rsa.Dispose();
            throw new InvalidOperationException("GIGACODE_IDENTITY_BROKER_CALLERS_FILE has invalid callers");
        }
        return new BrokerOptions(rsa, parsed.ToDictionary(pair => pair.Key, pair => Encoding.UTF8.GetBytes(pair.Value)));
    }

    public bool IsAuthorized(string caller, string authorization)
    {
        const string prefix = "Bearer ";
        if (!authorization.StartsWith(prefix, StringComparison.Ordinal) || !_callerSecrets.TryGetValue(caller, out var expected))
        {
            return false;
        }
        var supplied = Encoding.UTF8.GetBytes(authorization[prefix.Length..]);
        return supplied.Length == expected.Length && CryptographicOperations.FixedTimeEquals(supplied, expected);
    }

    public string Sign(IReadOnlyDictionary<string, object> payload)
    {
        var header = Base64Url(Encoding.UTF8.GetBytes("{\"alg\":\"RS256\",\"kid\":\"ai-stand-gigacode-broker-v1\",\"typ\":\"JWT\"}"));
        var encodedPayload = Base64Url(JsonSerializer.SerializeToUtf8Bytes(payload));
        var signingInput = Encoding.ASCII.GetBytes($"{header}.{encodedPayload}");
        var signature = _privateKey.SignData(signingInput, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return $"{header}.{encodedPayload}.{Base64Url(signature)}";
    }

    public void Dispose() => _privateKey.Dispose();

    private static string RequiredPrivateFile(string variable, string fallback, int maximum)
    {
        var path = Environment.GetEnvironmentVariable(variable) ?? fallback;
        try
        {
            var value = File.ReadAllText(path, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(value) || value.Length > maximum)
            {
                throw new InvalidOperationException($"{variable} is empty or oversized");
            }
            return value;
        }
        catch (IOException error)
        {
            throw new InvalidOperationException($"{variable} does not exist", error);
        }
    }

    private static string Base64Url(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
