using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiStand.GigacodeBridge;

var builder = WebApplication.CreateBuilder(args);
var options = GigacodeOptions.FromEnvironment();

builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(logging =>
{
    logging.SingleLine = true;
    logging.TimestampFormat = "O ";
});
builder.Logging.SetMinimumLevel(LogLevel.Information);

builder.Services.AddSingleton(options);
builder.Services.AddSingleton<InternalBearerAuthentication>();
builder.Services.AddHttpClient("gigacode-upstream", client =>
{
    client.Timeout = Timeout.InfiniteTimeSpan;
})
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None,
        PooledConnectionLifetime = TimeSpan.FromMinutes(15),
    });
builder.Services.AddSingleton<GigacodeClient>(services => new GigacodeClient(
    services.GetRequiredService<IHttpClientFactory>().CreateClient("gigacode-upstream"),
    services.GetRequiredService<GigacodeOptions>(),
    services.GetRequiredService<ILogger<GigacodeClient>>()));
builder.Services.AddSingleton<InferenceQueue>();
builder.Services.AddHostedService(services => services.GetRequiredService<InferenceQueue>());

var app = builder.Build();
app.Urls.Clear();
app.Urls.Add(Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://+:8080");

app.Use(async (context, next) =>
{
    // Health is intentionally unauthenticated for Docker's local task check.
    // Every inference/catalog request needs the per-subscription internal
    // bearer created by the reconciler; network membership alone is not an
    // identity boundary.
    if (context.Request.Path == "/healthz")
    {
        await next().ConfigureAwait(false);
        return;
    }

    var authentication = context.RequestServices.GetRequiredService<InternalBearerAuthentication>();
    if (!authentication.IsAuthorized(context.Request))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.CompleteAsync().ConfigureAwait(false);
        return;
    }

    await next().ConfigureAwait(false);
});

app.MapGet("/healthz", (InferenceQueue queue) => Results.Json(new
{
    status = "ok",
    queued = queue.QueuedCount,
}));

app.MapGet("/v1/models", (GigacodeOptions configured) => Results.Json(new
{
    @object = "list",
    data = new[]
    {
        new
        {
            id = configured.ModelAlias,
            @object = "model",
            owned_by = "gigacode",
            context_window = configured.ContextWindow,
        },
    },
}));

app.MapPost("/v1/chat/completions", HandleChatAsync);
app.MapPost("/v1/responses", HandleResponsesAsync);

await app.RunAsync();

static async Task HandleChatAsync(
    HttpContext context,
    GigacodeClient client,
    InferenceQueue queue,
    GigacodeOptions options,
    ILoggerFactory loggerFactory)
{
    var logger = loggerFactory.CreateLogger("GigacodeBridge");
    JsonObject request;
    try
    {
        request = await ReadJsonObjectAsync(context.Request, context.RequestAborted).ConfigureAwait(false);
    }
    catch (GigacodeUpstreamException exception)
    {
        await WriteOpenAiErrorAsync(context.Response, exception.StatusCode, exception.Message, context.RequestAborted).ConfigureAwait(false);
        return;
    }

    try
    {
        using var requestTimeout = CreateRequestTimeout(context.RequestAborted, options.RequestTimeoutSeconds);
        var streaming = request["stream"]?.GetValue<bool>() ?? false;
        // The queue owns the slot until the complete body has reached the
        // client, not merely until upstream sends headers. A streaming model
        // response is still an active inference request for its entire life.
        await queue.EnqueueAsync(async token =>
        {
            using var upstream = await client.SendChatAsync(request, token).ConfigureAwait(false);
            if (!upstream.IsSuccessStatusCode || streaming)
            {
                await CopyUpstreamResponseAsync(context.Response, upstream, options.StreamIdleTimeoutSeconds, token).ConfigureAwait(false);
                return 0;
            }

            var responseDocument = await JsonNode.ParseAsync(
                await upstream.Content.ReadAsStreamAsync(token).ConfigureAwait(false),
                cancellationToken: token).ConfigureAwait(false);
            var responseBody = responseDocument?.AsObject()
                ?? throw new GigacodeUpstreamException("GigaCode chat completion is not a JSON object");
            responseBody["model"] = options.ModelAlias;
            context.Response.StatusCode = (int)upstream.StatusCode;
            context.Response.ContentType = "application/json; charset=utf-8";
            await context.Response.WriteAsync(responseBody.ToJsonString(JsonSerializerOptions.Web), token).ConfigureAwait(false);
            return 0;
        }, requestTimeout.Token).ConfigureAwait(false);
    }
    catch (Exception exception) when (!context.Response.HasStarted)
    {
        await WriteUnhandledErrorAsync(context.Response, exception, context.RequestAborted).ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
    {
        logger.LogInformation("Client cancelled GigaCode chat request");
    }
    catch (Exception exception)
    {
        logger.LogWarning(exception, "GigaCode chat response terminated after headers were sent");
        context.Abort();
    }
}

static async Task HandleResponsesAsync(
    HttpContext context,
    GigacodeClient client,
    InferenceQueue queue,
    GigacodeOptions options,
    ILoggerFactory loggerFactory)
{
    var logger = loggerFactory.CreateLogger("GigacodeBridge");
    JsonObject responsesRequest;
    try
    {
        responsesRequest = await ReadJsonObjectAsync(context.Request, context.RequestAborted).ConfigureAwait(false);
    }
    catch (GigacodeUpstreamException exception)
    {
        await WriteOpenAiErrorAsync(context.Response, exception.StatusCode, exception.Message, context.RequestAborted).ConfigureAwait(false);
        return;
    }

    JsonObject chatRequest;
    try
    {
        chatRequest = OpenAiAdapter.ToChatCompletion(responsesRequest, options.FallbackModel);
    }
    catch (GigacodeUpstreamException exception)
    {
        await WriteOpenAiErrorAsync(context.Response, exception.StatusCode, exception.Message, context.RequestAborted).ConfigureAwait(false);
        return;
    }

    try
    {
        using var requestTimeout = CreateRequestTimeout(context.RequestAborted, options.RequestTimeoutSeconds);
        var streaming = responsesRequest["stream"]?.GetValue<bool>() ?? false;
        await queue.EnqueueAsync(async token =>
        {
            using var upstream = await client.SendChatAsync(chatRequest, token).ConfigureAwait(false);
            if (!upstream.IsSuccessStatusCode)
            {
                await CopyUpstreamResponseAsync(context.Response, upstream, options.StreamIdleTimeoutSeconds, token).ConfigureAwait(false);
                return 0;
            }

            if (streaming)
            {
                context.Response.StatusCode = (int)upstream.StatusCode;
                context.Response.ContentType = "text/event-stream; charset=utf-8";
                context.Response.Headers.CacheControl = "no-cache";
                await OpenAiAdapter.WriteResponsesStreamAsync(
                    await upstream.Content.ReadAsStreamAsync(token).ConfigureAwait(false),
                    context.Response.Body,
                    options.ModelAlias,
                    options.StreamIdleTimeoutSeconds,
                    token).ConfigureAwait(false);
                return 0;
            }

            var chatResponse = await JsonNode.ParseAsync(
                await upstream.Content.ReadAsStreamAsync(token).ConfigureAwait(false),
                cancellationToken: token).ConfigureAwait(false);
            var responseBody = OpenAiAdapter.ToResponsesCompletion(
                chatResponse?.AsObject() ?? throw new GigacodeUpstreamException("GigaCode chat completion is not a JSON object"),
                options.ModelAlias);
            context.Response.StatusCode = (int)upstream.StatusCode;
            context.Response.ContentType = "application/json; charset=utf-8";
            await context.Response.WriteAsync(responseBody.ToJsonString(JsonSerializerOptions.Web), token).ConfigureAwait(false);
            return 0;
        }, requestTimeout.Token).ConfigureAwait(false);
    }
    catch (Exception exception) when (!context.Response.HasStarted)
    {
        await WriteUnhandledErrorAsync(context.Response, exception, context.RequestAborted).ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
    {
        logger.LogInformation("Client cancelled GigaCode responses request");
    }
    catch (Exception exception)
    {
        logger.LogWarning(exception, "GigaCode responses stream terminated after headers were sent");
        context.Abort();
    }
}

static CancellationTokenSource CreateRequestTimeout(CancellationToken requestAborted, int timeoutSeconds)
{
    var cancellation = CancellationTokenSource.CreateLinkedTokenSource(requestAborted);
    cancellation.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
    return cancellation;
}

static async Task<JsonObject> ReadJsonObjectAsync(HttpRequest request, CancellationToken cancellationToken)
{
    try
    {
        var node = await JsonNode.ParseAsync(request.Body, cancellationToken: cancellationToken).ConfigureAwait(false);
        return node?.AsObject() ?? throw new GigacodeUpstreamException("Request body must be a JSON object", HttpStatusCode.BadRequest);
    }
    catch (JsonException)
    {
        throw new GigacodeUpstreamException("Request body is not valid JSON", HttpStatusCode.BadRequest);
    }
}

static async Task CopyUpstreamResponseAsync(
    HttpResponse destination,
    HttpResponseMessage source,
    int idleTimeoutSeconds,
    CancellationToken cancellationToken)
{
    destination.StatusCode = (int)source.StatusCode;
    destination.ContentType = source.Content.Headers.ContentType?.ToString() ?? "application/json; charset=utf-8";
    if (source.Headers.RetryAfter?.Delta is { } retryAfter)
    {
        destination.Headers.RetryAfter = ((int)Math.Ceiling(retryAfter.TotalSeconds)).ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    await CopyWithIdleTimeoutAsync(
        await source.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false),
        destination.Body,
        idleTimeoutSeconds,
        cancellationToken).ConfigureAwait(false);
}

static async Task CopyWithIdleTimeoutAsync(
    Stream source,
    Stream destination,
    int idleTimeoutSeconds,
    CancellationToken cancellationToken)
{
    await using var disposableSource = source;
    var buffer = new byte[32 * 1024];
    while (true)
    {
        using var idleCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        idleCancellation.CancelAfter(TimeSpan.FromSeconds(idleTimeoutSeconds));
        int read;
        try
        {
            read = await source.ReadAsync(buffer.AsMemory(), idleCancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new GigacodeUpstreamException("GigaCode stream idle timeout", HttpStatusCode.GatewayTimeout);
        }

        if (read == 0)
        {
            return;
        }

        await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
    }
}

static async Task WriteUnhandledErrorAsync(HttpResponse response, Exception exception, CancellationToken cancellationToken)
{
    var error = BridgeErrors.From(exception);
    await WriteOpenAiErrorAsync(response, error.Status, error.Message, cancellationToken).ConfigureAwait(false);
}

static async Task WriteOpenAiErrorAsync(HttpResponse response, HttpStatusCode status, string message, CancellationToken cancellationToken)
{
    response.StatusCode = (int)status;
    response.ContentType = "application/json; charset=utf-8";
    if (status == HttpStatusCode.TooManyRequests)
    {
        response.Headers.RetryAfter = "1";
    }

    var errorType = status == HttpStatusCode.TooManyRequests ? "rate_limit_error" : "api_error";
    var error = new JsonObject
    {
        ["error"] = new JsonObject
        {
            ["message"] = message,
            ["type"] = errorType,
            ["code"] = (int)status,
        },
    };
    await response.WriteAsync(error.ToJsonString(JsonSerializerOptions.Web), cancellationToken).ConfigureAwait(false);
}
