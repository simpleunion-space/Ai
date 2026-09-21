using System.Net;
using System.Text.Json;
using JiraReadonlyMcp;

var builder = WebApplication.CreateBuilder(args);
var options = JiraOptions.FromEnvironment();
var internalAuth = McpInternalAuth.FromEnvironment();

builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(logging =>
{
    logging.SingleLine = true;
    logging.TimestampFormat = "O ";
});
builder.Logging.SetMinimumLevel(LogLevel.Information);

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(internalAuth);
builder.Services.AddSingleton(JiraCredentials.Load(options));
builder.Services.AddHttpClient("jira", client =>
{
    client.Timeout = Timeout.InfiniteTimeSpan;
})
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None,
        PooledConnectionLifetime = TimeSpan.FromMinutes(15),
    });
builder.Services.AddSingleton<JiraApiClient>(services => new JiraApiClient(
    services.GetRequiredService<IHttpClientFactory>().CreateClient("jira"),
    services.GetRequiredService<JiraOptions>(),
    services.GetRequiredService<JiraCredentials>(),
    services.GetRequiredService<ILogger<JiraApiClient>>()));
builder.Services.AddSingleton<McpServer>();

var app = builder.Build();
app.Urls.Clear();
app.Urls.Add(Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://+:8080");

app.Use(async (context, next) =>
{
    if ((context.Request.Path == "/mcp" || context.Request.Path == "/readyz") &&
        !internalAuth.IsAuthorized(context.Request.Headers.Authorization))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        context.Response.ContentType = "application/json; charset=utf-8";
        await context.Response.WriteAsJsonAsync(new { error = "Unauthorized" }, context.RequestAborted).ConfigureAwait(false);
        return;
    }
    await next(context).ConfigureAwait(false);
});

app.MapGet("/healthz", () => Results.Json(new { status = "ok", service = "jira-readonly-mcp" }));
app.MapGet("/readyz", async (HttpContext context, JiraApiClient client) =>
{
    try
    {
        await client.ProbeAsync(context.RequestAborted).ConfigureAwait(false);
        return Results.Json(new { status = "ready" });
    }
    catch
    {
        // Upstream detail can contain hostnames or credential-specific
        // diagnostics, so this endpoint deliberately returns no exception
        // text.  The reconciler only needs the readiness status.
        return Results.Json(new { status = "unavailable" }, statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});
app.MapPost("/mcp", HandleMcpAsync);
app.MapMethods("/mcp", ["GET", "DELETE"], () => Results.StatusCode(StatusCodes.Status405MethodNotAllowed));

await app.RunAsync();

static async Task<IResult> HandleMcpAsync(HttpContext context, McpServer server)
{
    if (!context.Request.HasJsonContentType())
    {
        return Results.BadRequest(new { error = "MCP requests must use application/json" });
    }

    JsonDocument request;
    try
    {
        request = await JsonDocument.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted).ConfigureAwait(false);
    }
    catch (JsonException)
    {
        return Results.Json(new { jsonrpc = "2.0", id = (object?)null, error = new { code = -32700, message = "Parse error" } }, statusCode: StatusCodes.Status400BadRequest);
    }

    using (request)
    {
        var response = await server.HandleAsync(request.RootElement, context.RequestAborted).ConfigureAwait(false);
        if (response is null)
        {
            return Results.Accepted();
        }

        context.Response.Headers["MCP-Protocol-Version"] = "2025-03-26";
        return Results.Json(response, options: new JsonSerializerOptions(JsonSerializerDefaults.Web));
    }
}
