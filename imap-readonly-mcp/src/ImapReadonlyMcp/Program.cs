using System.Net;

using AiStand.ImapReadonlyMcp;

var builder = WebApplication.CreateBuilder(args);
var options = ImapOptions.FromEnvironment();

builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(logging =>
{
    logging.SingleLine = true;
    logging.TimestampFormat = "O ";
});
builder.Logging.SetMinimumLevel(LogLevel.Information);

builder.Services.AddSingleton(options);
builder.Services.AddSingleton<InternalBearerAuthenticator>();
if (options.AuthenticationMode == ImapAuthenticationMode.OAuthRefreshToken)
{
    builder.Services.AddSingleton(new TokenStateStore(options.OAuth ?? throw new ConfigurationException("IMAP OAuth configuration is missing")));
}
builder.Services.AddHttpClient("imap-oauth", client =>
{
    client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
})
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    });
builder.Services.AddSingleton<IImapCredentialProvider>(services => options.AuthenticationMode == ImapAuthenticationMode.Basic
    ? new BasicCredentialProvider(options)
    : new OAuthCredentialProvider(
        options,
        services.GetRequiredService<IHttpClientFactory>(),
        services.GetRequiredService<ILogger<OAuthCredentialProvider>>(),
        options.AuthenticationMode == ImapAuthenticationMode.OAuthRefreshToken ? services.GetRequiredService<TokenStateStore>() : null));
builder.Services.AddSingleton<ImapConnectionFactory>();
builder.Services.AddSingleton<IImapReadService, ImapReadService>();
builder.Services.AddSingleton<McpToolDispatcher>();

var app = builder.Build();
app.Urls.Clear();
app.Urls.Add(Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://+:8080");

app.Use(async (context, next) =>
{
    if ((context.Request.Path == "/mcp" || context.Request.Path == "/readyz") &&
        !context.RequestServices.GetRequiredService<InternalBearerAuthenticator>().IsAuthorized(context.Request))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        context.Response.Headers.WWWAuthenticate = "Bearer";
        return;
    }
    await next(context).ConfigureAwait(false);
});

app.MapGet("/healthz", () => Results.Json(new { status = "ok", transport = "streamable-http", readOnly = true }));
app.MapGet("/readyz", async (HttpContext context, IImapReadService imap) =>
{
    try
    {
        // ListMailboxesAsync authenticates and disconnects without selecting
        // a folder.  It is read-only and does not set \\Seen.
        await imap.ListMailboxesAsync(context.RequestAborted).ConfigureAwait(false);
        return Results.Json(new { status = "ready" });
    }
    catch
    {
        return Results.Json(new { status = "unavailable" }, statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});
app.MapPost("/mcp", McpEndpoint.HandleAsync);
app.MapMethods("/mcp", ["GET", "DELETE"], () => Results.StatusCode(StatusCodes.Status405MethodNotAllowed));

await app.RunAsync();

public partial class Program;
