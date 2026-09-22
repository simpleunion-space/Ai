using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

const string sessionHeader = "X-AI-Stand-Gigacode-Session";
const string internalCaller = "openclaw";

var options = AdapterOptions.Load();
var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(logging =>
{
    logging.SingleLine = true;
    logging.TimestampFormat = "O ";
});
builder.Logging.SetMinimumLevel(LogLevel.Information);
builder.Services.AddSingleton(options);
builder.Services.AddHttpClient("broker", client => client.Timeout = TimeSpan.FromSeconds(5));
builder.Services.AddHttpClient("agentgateway", client => client.Timeout = Timeout.InfiniteTimeSpan)
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None,
        PooledConnectionLifetime = TimeSpan.FromMinutes(10),
    });

var app = builder.Build();
app.Urls.Clear();
app.Urls.Add(Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://+:8080");

app.MapGet("/healthz", () => Results.Json(new { status = "ok" }));
app.MapMethods("/v1/{**path}", new[] { "POST" }, ProxyAsync);

await app.RunAsync();

static async Task ProxyAsync(HttpContext context, string? path, AdapterOptions options, IHttpClientFactory clients)
{
    if (!options.IsAuthorized(context.Request.Headers.Authorization.ToString()))
    {
        await WriteErrorAsync(context.Response, StatusCodes.Status401Unauthorized, "unauthorized", context.RequestAborted).ConfigureAwait(false);
        return;
    }

    if (path is not "chat/completions" and not "responses")
    {
        await WriteErrorAsync(context.Response, StatusCodes.Status404NotFound, "not_found", context.RequestAborted).ConfigureAwait(false);
        return;
    }

    var sessionId = context.Request.Headers[sessionHeader].ToString();
    if (!AdapterOptions.Session.IsMatch(sessionId))
    {
        await WriteErrorAsync(context.Response, StatusCodes.Status403Forbidden, "subscription_not_configured", context.RequestAborted).ConfigureAwait(false);
        return;
    }

    var subject = options.ResolveSubject(sessionId);
    if (subject is null)
    {
        await WriteErrorAsync(context.Response, StatusCodes.Status403Forbidden, "subscription_not_configured", context.RequestAborted).ConfigureAwait(false);
        return;
    }

    string accessToken;
    try
    {
        using var issueRequest = new HttpRequestMessage(HttpMethod.Post, options.BrokerUrl + "/issue")
        {
            Content = JsonContent.Create(new { subject }),
        };
        issueRequest.Headers.TryAddWithoutValidation("X-AI-Stand-Caller", internalCaller);
        issueRequest.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", options.BrokerCallerSecret);
        using var issueResponse = await clients.CreateClient("broker").SendAsync(issueRequest, context.RequestAborted).ConfigureAwait(false);
        if (!issueResponse.IsSuccessStatusCode)
        {
            await WriteErrorAsync(context.Response, StatusCodes.Status502BadGateway, "identity_broker_unavailable", context.RequestAborted).ConfigureAwait(false);
            return;
        }
        var issued = await issueResponse.Content.ReadFromJsonAsync<IssuedToken>(cancellationToken: context.RequestAborted).ConfigureAwait(false);
        accessToken = issued?.AccessToken ?? string.Empty;
        if (accessToken.Length is < 32 or > 8192)
        {
            await WriteErrorAsync(context.Response, StatusCodes.Status502BadGateway, "identity_broker_unavailable", context.RequestAborted).ConfigureAwait(false);
            return;
        }
    }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
    {
        return;
    }
    catch
    {
        await WriteErrorAsync(context.Response, StatusCodes.Status502BadGateway, "identity_broker_unavailable", context.RequestAborted).ConfigureAwait(false);
        return;
    }

    var target = $"{options.AgentgatewayUrl}/_internal/gigacode/{AdapterOptions.Slug(subject)}/{path}";
    using var upstreamRequest = new HttpRequestMessage(HttpMethod.Post, target)
    {
        Content = new StreamContent(context.Request.Body),
    };
    CopyRequestHeaders(context.Request, upstreamRequest);
    upstreamRequest.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", accessToken);
    upstreamRequest.Headers.Remove(sessionHeader);

    try
    {
        using var upstreamResponse = await clients.CreateClient("agentgateway")
            .SendAsync(upstreamRequest, HttpCompletionOption.ResponseHeadersRead, context.RequestAborted)
            .ConfigureAwait(false);
        context.Response.StatusCode = (int)upstreamResponse.StatusCode;
        CopyResponseHeaders(upstreamResponse, context.Response);
        await using var source = await upstreamResponse.Content.ReadAsStreamAsync(context.RequestAborted).ConfigureAwait(false);
        await source.CopyToAsync(context.Response.Body, context.RequestAborted).ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
    {
        // The client has disconnected. Do not emit a second response or log user content.
    }
    catch when (!context.Response.HasStarted)
    {
        await WriteErrorAsync(context.Response, StatusCodes.Status502BadGateway, "subscription_backend_unavailable", context.RequestAborted).ConfigureAwait(false);
    }
    catch
    {
        context.Abort();
    }
}

static void CopyRequestHeaders(HttpRequest request, HttpRequestMessage target)
{
    foreach (var header in request.Headers)
    {
        if (header.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase) ||
            header.Key.Equals(sessionHeader, StringComparison.OrdinalIgnoreCase) ||
            header.Key.Equals("Host", StringComparison.OrdinalIgnoreCase) ||
            header.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
        {
            continue;
        }
        if (!target.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray()))
        {
            target.Content?.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray());
        }
    }
}

static void CopyResponseHeaders(HttpResponseMessage source, HttpResponse target)
{
    foreach (var header in source.Headers)
    {
        target.Headers[header.Key] = header.Value.ToArray();
    }
    foreach (var header in source.Content.Headers)
    {
        if (!header.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
        {
            target.Headers[header.Key] = header.Value.ToArray();
        }
    }
}

static async Task WriteErrorAsync(HttpResponse response, int status, string code, CancellationToken cancellationToken)
{
    if (response.HasStarted) return;
    response.StatusCode = status;
    response.ContentType = "application/json; charset=utf-8";
    await response.WriteAsJsonAsync(new { error = new { message = code, type = "api_error", code } }, cancellationToken).ConfigureAwait(false);
}

sealed record IssuedToken([property: JsonPropertyName("access_token")] string? AccessToken);

sealed class AdapterOptions
{
    public static readonly Regex Subject = new("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
    public static readonly Regex Session = new("^[0-9a-zA-Z_-]{8,128}$", RegexOptions.CultureInvariant);
    private readonly byte[] _internalBearer;
    private readonly string _mappingPath;

    public string BrokerUrl { get; }
    public string BrokerCallerSecret { get; }
    public string AgentgatewayUrl { get; }

    private AdapterOptions(byte[] internalBearer, string mappingPath, string brokerUrl, string brokerCallerSecret, string agentgatewayUrl)
    {
        _internalBearer = internalBearer;
        _mappingPath = mappingPath;
        BrokerUrl = brokerUrl.TrimEnd('/');
        BrokerCallerSecret = brokerCallerSecret;
        AgentgatewayUrl = agentgatewayUrl.TrimEnd('/');
    }

    public static AdapterOptions Load()
    {
        var internalBearer = RequiredFile("OPENCLAW_GIGACODE_ADAPTER_BEARER_FILE", "/run/secrets/ai-stand-openclaw-gigacode-adapter", 512).Trim();
        var brokerCallerSecret = RequiredFile("OPENCLAW_GIGACODE_BROKER_CALLER_FILE", "/run/secrets/ai-stand-gigacode-broker-openclaw-caller", 512).Trim();
        if (internalBearer.Length is < 32 or > 512 || internalBearer.Any(char.IsWhiteSpace) || brokerCallerSecret.Length is < 32 or > 512 || brokerCallerSecret.Any(char.IsWhiteSpace))
        {
            throw new InvalidOperationException("OpenClaw GigaCode adapter secret is invalid");
        }
        var mappingPath = Environment.GetEnvironmentVariable("OPENCLAW_GIGACODE_SESSION_MAP") ?? "/state/sessions.json";
        var brokerUrl = RequiredUrl("GIGACODE_IDENTITY_BROKER_URL", "http://gigacode-identity-broker:8080");
        var agentgatewayUrl = RequiredUrl("AGENTGATEWAY_INTERNAL_URL", "http://agentgateway:4000");
        return new AdapterOptions(Encoding.UTF8.GetBytes(internalBearer), mappingPath, brokerUrl, brokerCallerSecret, agentgatewayUrl);
    }

    public bool IsAuthorized(string authorization)
    {
        const string prefix = "Bearer ";
        if (!authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
        var supplied = Encoding.UTF8.GetBytes(authorization[prefix.Length..].Trim());
        return supplied.Length == _internalBearer.Length && CryptographicOperations.FixedTimeEquals(supplied, _internalBearer);
    }

    public string? ResolveSubject(string sessionId)
    {
        try
        {
            var info = new FileInfo(_mappingPath);
            if (!info.Exists || info.Length is < 2 or > 1024 * 1024) return null;
            var document = JsonSerializer.Deserialize<SessionMap>(File.ReadAllText(_mappingPath, Encoding.UTF8));
            if (document?.Version != 1 || document.Entries is null || !document.Entries.TryGetValue(sessionId, out var entry) || entry is null) return null;
            if (!Subject.IsMatch(entry.Subject) || entry.ExpiresAt <= DateTimeOffset.UtcNow) return null;
            return entry.Subject.ToLowerInvariant();
        }
        catch (IOException) { return null; }
        catch (JsonException) { return null; }
    }

    public static string Slug(string subject)
    {
        var normalized = subject.ToLowerInvariant();
        var digest = SHA256.HashData(Encoding.ASCII.GetBytes(normalized));
        // Must match the reconciler and the managed Open WebUI Pipe.  A 23
        // character digest leaves room for the ai-stand Swarm service prefix.
        return "u-" + Convert.ToHexString(digest).ToLowerInvariant()[..23];
    }

    private static string RequiredFile(string name, string fallback, int maximum)
    {
        var path = Environment.GetEnvironmentVariable(name) ?? fallback;
        var value = File.ReadAllText(path, Encoding.UTF8);
        if (string.IsNullOrWhiteSpace(value) || value.Length > maximum) throw new InvalidOperationException($"{name} is empty or oversized");
        return value;
    }

    private static string RequiredUrl(string name, string fallback)
    {
        var raw = Environment.GetEnvironmentVariable(name) ?? fallback;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttp || string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new InvalidOperationException($"{name} must be an internal HTTP origin");
        }
        return uri.GetLeftPart(UriPartial.Authority);
    }
}

sealed record SessionMap(int Version, Dictionary<string, SessionMapEntry>? Entries);
sealed record SessionMapEntry(string Subject, DateTimeOffset ExpiresAt);
