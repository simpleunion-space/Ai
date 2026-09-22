using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AiStand.GigacodeBridge;

internal sealed class GigacodeUpstreamException : Exception
{
    public GigacodeUpstreamException(string message, HttpStatusCode statusCode = HttpStatusCode.BadGateway) : base(message)
    {
        StatusCode = statusCode;
    }

    public HttpStatusCode StatusCode { get; }
}

internal sealed record GigacodeConfiguration(Uri ChatCompletionsUri, string ModelId);

internal sealed class GigacodeClient
{
    private readonly HttpClient _httpClient;
    private readonly GigacodeOptions _options;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private readonly ILogger<GigacodeClient> _logger;
    private AccessToken? _accessToken;
    private GigacodeConfiguration? _configuration;

    public GigacodeClient(HttpClient httpClient, GigacodeOptions options, ILogger<GigacodeClient> logger)
    {
        _httpClient = httpClient;
        _options = options;
        _logger = logger;
    }

    public async Task<GigacodeConfiguration> GetConfigurationAsync(CancellationToken cancellationToken)
    {
        var token = await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        if (_configuration is not null)
        {
            return _configuration;
        }

        return await FetchConfigurationAsync(token, retryAfterAuthenticationFailure: true, cancellationToken).ConfigureAwait(false);
    }

    public async Task<HttpResponseMessage> SendChatAsync(JsonObject request, CancellationToken cancellationToken)
    {
        var configuration = await GetConfigurationAsync(cancellationToken).ConfigureAwait(false);
        var response = await SendChatWithConfigurationAsync(configuration, request, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode is not HttpStatusCode.Unauthorized and not HttpStatusCode.Forbidden)
        {
            return response;
        }

        response.Dispose();
        InvalidateAuthentication();
        configuration = await GetConfigurationAsync(cancellationToken).ConfigureAwait(false);
        return await SendChatWithConfigurationAsync(configuration, request, cancellationToken).ConfigureAwait(false);
    }

    private async Task<HttpResponseMessage> SendChatWithConfigurationAsync(
        GigacodeConfiguration configuration,
        JsonObject request,
        CancellationToken cancellationToken)
    {
        var token = await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        var payload = request.DeepClone().AsObject();
        payload["model"] = configuration.ModelId;
        var requestBytes = Encoding.UTF8.GetBytes(payload.ToJsonString(JsonSerializerOptions.Web));

        using var upstreamRequest = new HttpRequestMessage(HttpMethod.Post, configuration.ChatCompletionsUri)
        {
            Content = new ByteArrayContent(requestBytes),
        };
        upstreamRequest.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        upstreamRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Value);
        upstreamRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        upstreamRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        var response = await _httpClient.SendAsync(
            upstreamRequest,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        _logger.LogInformation("GigaCode upstream response: status={StatusCode}", (int)response.StatusCode);
        return response;
    }

    private async Task<GigacodeConfiguration> FetchConfigurationAsync(
        AccessToken token,
        bool retryAfterAuthenticationFailure,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, _options.ResolvePath(_options.ConfigPath));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Value);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);

        if ((response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) && retryAfterAuthenticationFailure)
        {
            InvalidateAuthentication();
            var refreshed = await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
            return await FetchConfigurationAsync(refreshed, retryAfterAuthenticationFailure: false, cancellationToken).ConfigureAwait(false);
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new GigacodeUpstreamException(
                $"GigaCode configuration endpoint returned HTTP {(int)response.StatusCode}",
                response.StatusCode == HttpStatusCode.Unauthorized ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.BadGateway);
        }

        JsonNode? document;
        try
        {
            document = await JsonNode.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (JsonException exception)
        {
            throw new GigacodeUpstreamException("GigaCode configuration is not valid JSON", HttpStatusCode.BadGateway) { Source = exception.Source };
        }

        var parsed = ParseConfiguration(document?.AsObject() ?? throw new GigacodeUpstreamException("GigaCode configuration is empty"));
        _configuration = parsed;
        return parsed;
    }

    private GigacodeConfiguration ParseConfiguration(JsonObject document)
    {
        var chat = document["chat"]?.AsObject();
        var configuredUrl = chat?["url"]?.GetValue<string>();
        var chatUri = string.IsNullOrWhiteSpace(configuredUrl)
            ? _options.ResolvePath(_options.FallbackChatPath)
            : Uri.TryCreate(configuredUrl, UriKind.Absolute, out var parsedUri)
                ? parsedUri
                : throw new GigacodeUpstreamException("GigaCode configuration contains an invalid chat.url");

        if (!_options.IsAllowedChatUri(chatUri))
        {
            throw new GigacodeUpstreamException("GigaCode configuration selected a disallowed chat endpoint");
        }

        var configuredModels = EnumerateModels(chat?["models"])
            .Concat(EnumerateModels(document["agent"]?["models"]))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var model = configuredModels.FirstOrDefault(candidate => candidate == _options.FallbackModel)
            ?? configuredModels.FirstOrDefault()
            ?? _options.FallbackModel;

        return new GigacodeConfiguration(chatUri, model);
    }

    private static IEnumerable<string> EnumerateModels(JsonNode? node)
    {
        if (node is not JsonArray models)
        {
            yield break;
        }

        foreach (var entry in models)
        {
            var model = entry switch
            {
                JsonValue value when value.TryGetValue<string>(out var text) => text,
                JsonObject modelObject => modelObject["model"]?.GetValue<string>()
                    ?? modelObject["id"]?.GetValue<string>(),
                _ => null,
            };
            if (!string.IsNullOrWhiteSpace(model))
            {
                yield return model;
            }
        }
    }

    private async Task<AccessToken> GetAccessTokenAsync(CancellationToken cancellationToken)
    {
        var current = _accessToken;
        if (current is not null && current.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(_options.TokenRefreshSkewSeconds))
        {
            return current;
        }

        await _refreshLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            current = _accessToken;
            if (current is not null && current.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(_options.TokenRefreshSkewSeconds))
            {
                return current;
            }

            var deviceId = await ReadDeviceIdAsync(cancellationToken).ConfigureAwait(false);
            var payload = new JsonObject
            {
                ["device_code"] = deviceId,
                ["env_name"] = "linux",
                ["plugin_version"] = _options.PluginVersion,
                ["plugin_name"] = _options.PluginName,
                ["env_version"] = Environment.Version.ToString(),
                ["login"] = _options.Login,
                ["locale"] = _options.Locale,
            };
            using var request = new HttpRequestMessage(HttpMethod.Post, _options.ResolvePath(_options.AuthPath))
            {
                Content = JsonContent.Create(payload),
            };
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using var response = await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new GigacodeUpstreamException(
                    $"GigaCode authentication endpoint returned HTTP {(int)response.StatusCode}",
                    HttpStatusCode.ServiceUnavailable);
            }

            var responseNode = await JsonNode.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), cancellationToken: cancellationToken).ConfigureAwait(false);
            var responseObject = responseNode?.AsObject() ?? throw new GigacodeUpstreamException("GigaCode authentication response is empty", HttpStatusCode.ServiceUnavailable);
            var value = responseObject["access_token"]?.GetValue<string>();
            var expiresIn = responseObject["expires_in"]?.GetValue<int>();
            if (string.IsNullOrWhiteSpace(value) || expiresIn is null or <= 0)
            {
                throw new GigacodeUpstreamException("GigaCode authentication response has no usable access token", HttpStatusCode.ServiceUnavailable);
            }

            current = new AccessToken(value, DateTimeOffset.UtcNow.AddSeconds(expiresIn.Value));
            _accessToken = current;
            _configuration = null;
            _logger.LogInformation("GigaCode access token obtained; expires in {ExpiresInSeconds}s", expiresIn.Value);
            return current;
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private async Task<string> ReadDeviceIdAsync(CancellationToken cancellationToken)
    {
        var deviceId = (await File.ReadAllTextAsync(_options.DeviceIdFile, cancellationToken).ConfigureAwait(false)).Trim();
        if (deviceId.Length != 64 || !deviceId.All(character => char.IsAsciiHexDigit(character) && !char.IsUpper(character)))
        {
            throw new GigacodeUpstreamException("GigaCode device secret is malformed", HttpStatusCode.ServiceUnavailable);
        }

        // Avoid keeping a second mutable copy of the credential in service state.
        return deviceId;
    }

    private void InvalidateAuthentication()
    {
        _accessToken = null;
        _configuration = null;
    }

    private sealed record AccessToken(string Value, DateTimeOffset ExpiresAt);
}
