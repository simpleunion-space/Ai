using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiStand.ConfluenceReadonlyMcp;

var builder = WebApplication.CreateBuilder(args);
var options = ConfluenceOptions.FromEnvironment();

builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(logging =>
{
    logging.SingleLine = true;
    logging.TimestampFormat = "O ";
});
builder.Logging.SetMinimumLevel(LogLevel.Information);

builder.Services.AddSingleton(options);
builder.Services.AddSingleton<InternalBearerAuthentication>(services => new InternalBearerAuthentication(
    services.GetRequiredService<ConfluenceOptions>().InternalTokenFile));
builder.Services.AddHttpClient("confluence-upstream", client => client.Timeout = Timeout.InfiniteTimeSpan)
    .ConfigurePrimaryHttpMessageHandler(CreateHttpHandler);
builder.Services.AddHttpClient("confluence-oauth", client => client.Timeout = Timeout.InfiniteTimeSpan)
    .ConfigurePrimaryHttpMessageHandler(CreateHttpHandler);
builder.Services.AddSingleton<IConfluenceAuthenticator>(services => ConfluenceAuthenticatorFactory.Create(
    services.GetRequiredService<ConfluenceOptions>(),
    services.GetRequiredService<IHttpClientFactory>()));
builder.Services.AddSingleton<ConfluenceClient>(services => new ConfluenceClient(
    services.GetRequiredService<IHttpClientFactory>().CreateClient("confluence-upstream"),
    services.GetRequiredService<ConfluenceOptions>(),
    services.GetRequiredService<IConfluenceAuthenticator>()));
builder.Services.AddSingleton<ConfluenceTools>();
builder.Services.AddSingleton<McpServer>();

var app = builder.Build();
app.Urls.Clear();
app.Urls.Add(Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://+:8080");

app.Use(async (context, next) =>
{
    if ((context.Request.Path.StartsWithSegments("/mcp") || context.Request.Path.StartsWithSegments("/readyz")) &&
        !context.RequestServices.GetRequiredService<InternalBearerAuthentication>().IsAuthorized(context.Request.Headers.Authorization))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        context.Response.Headers.Append("WWW-Authenticate", "Bearer");
        return;
    }

    await next(context).ConfigureAwait(false);
});

app.MapGet("/healthz", (ConfluenceOptions configured) => Results.Json(new
{
    status = "ok",
    mcp = "streamable-http",
    authentication = configured.AuthMode.ToString(),
}));
app.MapGet("/readyz", async (HttpContext context, ConfluenceClient client) =>
{
    try
    {
        await client.ProbeAsync(context.RequestAborted).ConfigureAwait(false);
        return Results.Json(new { status = "ready" });
    }
    catch
    {
        return Results.Json(new { status = "unavailable" }, statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});

app.MapPost("/mcp", HandleMcpAsync);
app.MapMethods("/mcp", [HttpMethods.Get, HttpMethods.Delete], () => Results.StatusCode(StatusCodes.Status405MethodNotAllowed));

await app.RunAsync();

static SocketsHttpHandler CreateHttpHandler() => new()
{
    AllowAutoRedirect = false,
    AutomaticDecompression = DecompressionMethods.None,
    PooledConnectionLifetime = TimeSpan.FromMinutes(15),
    SslOptions = new System.Net.Security.SslClientAuthenticationOptions
    {
        RemoteCertificateValidationCallback = null,
    },
};

static async Task<IResult> HandleMcpAsync(HttpContext context, McpServer server)
{
    if (!context.Request.HasJsonContentType())
    {
        return Results.StatusCode(StatusCodes.Status415UnsupportedMediaType);
    }

    JsonObject? request;
    try
    {
        request = await JsonSerializer.DeserializeAsync<JsonObject>(context.Request.Body, cancellationToken: context.RequestAborted).ConfigureAwait(false);
    }
    catch (JsonException)
    {
        return Results.Json(new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = null,
            ["error"] = new JsonObject { ["code"] = -32700, ["message"] = "Parse error" },
        }, statusCode: StatusCodes.Status400BadRequest);
    }

    if (request is null)
    {
        return Results.StatusCode(StatusCodes.Status400BadRequest);
    }

    var dispatch = await server.DispatchAsync(request, context.RequestAborted).ConfigureAwait(false);
    if (dispatch.Body is null)
    {
        return Results.Accepted();
    }

    context.Response.Headers.Append("MCP-Protocol-Version", "2025-03-26");
    if (dispatch.SessionId is not null)
    {
        context.Response.Headers.Append("Mcp-Session-Id", dispatch.SessionId);
    }

    return Results.Json(dispatch.Body, contentType: "application/json");
}

public partial class Program;
