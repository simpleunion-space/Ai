using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JiraReadonlyMcp;

internal sealed class JiraApiException : Exception
{
    public JiraApiException(HttpStatusCode statusCode, string message) : base(message) => StatusCode = statusCode;
    public HttpStatusCode StatusCode { get; }
}

internal sealed class JiraApiClient
{
    private readonly HttpClient _httpClient;
    private readonly JiraOptions _options;
    private readonly JiraCredentials _credentials;
    private readonly ILogger<JiraApiClient> _logger;
    private readonly SemaphoreSlim _tokenGate = new(1, 1);
    private readonly RefreshTokenStateStore? _refreshTokenState;
    private string? _accessToken;
    private DateTimeOffset _accessTokenExpiry = DateTimeOffset.MinValue;
    private string? _refreshToken;

    public JiraApiClient(HttpClient httpClient, JiraOptions options, JiraCredentials credentials, ILogger<JiraApiClient> logger)
    {
        _httpClient = httpClient;
        _options = options;
        _credentials = credentials;
        _logger = logger;
        if (options.AuthMode == JiraAuthMode.OAuthRefreshToken)
        {
            _refreshTokenState = new RefreshTokenStateStore(options.TokenStateDirectory!, options.TokenStateKeyFile!);
            _refreshToken = _refreshTokenState.LoadOrDefault(credentials.RefreshToken!);
        }
    }

    public async Task<JsonNode> GetJsonAsync(string apiPath, CancellationToken cancellationToken)
    {
        using var response = await SendGetAsync(_options.ApiUri(apiPath), cancellationToken).ConfigureAwait(false);
        return await ReadJsonAsync(response, cancellationToken).ConfigureAwait(false);
    }

    // Deliberately a GET-only identity probe.  The reconciler calls the
    // container's authenticated /readyz endpoint before publishing a route;
    // no mutable Jira endpoint is ever needed to establish readiness.
    public Task ProbeAsync(CancellationToken cancellationToken) =>
        GetJsonAsync("rest/api/2/myself", cancellationToken);

    public async Task<JsonNode> GetAttachmentAsync(string attachmentId, bool includeContent, CancellationToken cancellationToken)
    {
        var metadata = await GetJsonAsync($"rest/api/2/attachment/{attachmentId}", cancellationToken).ConfigureAwait(false);
        if (!includeContent)
        {
            return metadata;
        }

        var contentUrl = metadata["content"]?.GetValue<string>();
        if (!Uri.TryCreate(contentUrl, UriKind.Absolute, out var contentUri) || !SameOrigin(contentUri, _options.BaseUri))
        {
            throw new JiraApiException(HttpStatusCode.BadGateway, "Jira attachment metadata contains a disallowed content URL");
        }

        using var response = await SendGetAsync(contentUri, cancellationToken).ConfigureAwait(false);
        var size = response.Content.Headers.ContentLength;
        if (size is > 0 && size > _options.MaxAttachmentBytes)
        {
            throw new JiraApiException(HttpStatusCode.RequestEntityTooLarge, "Attachment exceeds the configured size limit");
        }

        var bytes = await ReadLimitedBytesAsync(response, _options.MaxAttachmentBytes, cancellationToken).ConfigureAwait(false);
        var result = new JsonObject
        {
            ["metadata"] = metadata,
            ["content_type"] = response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream",
            ["content_base64"] = Convert.ToBase64String(bytes),
        };
        return result;
    }

    private async Task<HttpResponseMessage> SendGetAsync(Uri uri, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(_options.RequestTimeoutSeconds));
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        await ApplyAuthorizationAsync(request, timeout.Token).ConfigureAwait(false);

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new JiraApiException(HttpStatusCode.GatewayTimeout, "Jira request timed out");
        }
        catch (HttpRequestException)
        {
            throw new JiraApiException(HttpStatusCode.BadGateway, "Jira request failed");
        }

        _logger.LogInformation("Jira read-only request completed with status {StatusCode}", (int)response.StatusCode);
        if (!response.IsSuccessStatusCode)
        {
            response.Dispose();
            throw new JiraApiException(response.StatusCode, "Jira rejected the read-only request");
        }

        return response;
    }

    private async Task ApplyAuthorizationAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        switch (_options.AuthMode)
        {
            case JiraAuthMode.Basic:
                request.Headers.Authorization = _credentials.BasicHeader();
                break;
            case JiraAuthMode.Pat:
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _credentials.Token);
                break;
            case JiraAuthMode.OAuthClientCredentials:
            case JiraAuthMode.OAuthRefreshToken:
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false));
                break;
            default:
                throw new InvalidOperationException("Unsupported Jira authentication mode");
        }
    }

    private async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken)
    {
        if (_accessToken is not null && _accessTokenExpiry > DateTimeOffset.UtcNow.AddSeconds(60))
        {
            return _accessToken;
        }

        await _tokenGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_accessToken is not null && _accessTokenExpiry > DateTimeOffset.UtcNow.AddSeconds(60))
            {
                return _accessToken;
            }

            var form = _options.AuthMode == JiraAuthMode.OAuthClientCredentials
                ? new Dictionary<string, string>
                {
                    ["grant_type"] = "client_credentials",
                    ["client_id"] = _credentials.ClientId!,
                    ["client_secret"] = _credentials.ClientSecret!,
                }
                : new Dictionary<string, string>
                {
                    ["grant_type"] = "refresh_token",
                    ["client_id"] = _credentials.ClientId!,
                    ["client_secret"] = _credentials.ClientSecret!,
                    ["refresh_token"] = _refreshToken!,
                };
            if (!string.IsNullOrWhiteSpace(_options.OAuthScope))
            {
                form["scope"] = _options.OAuthScope;
            }

            using var request = new HttpRequestMessage(HttpMethod.Post, _options.OAuthTokenUri!)
            {
                Content = new FormUrlEncodedContent(form),
            };
            using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new JiraApiException(HttpStatusCode.BadGateway, "Jira OAuth token request failed");
            }

            var token = await ReadJsonAsync(response, cancellationToken).ConfigureAwait(false);
            _accessToken = token["access_token"]?.GetValue<string>();
            var expiresIn = token["expires_in"]?.GetValue<int?>() ?? 300;
            if (string.IsNullOrWhiteSpace(_accessToken) || expiresIn < 1)
            {
                throw new JiraApiException(HttpStatusCode.BadGateway, "Jira OAuth token response is invalid");
            }

            _accessTokenExpiry = DateTimeOffset.UtcNow.AddSeconds(expiresIn);
            if (_options.AuthMode == JiraAuthMode.OAuthRefreshToken && token["refresh_token"]?.GetValue<string>() is { Length: > 0 } rotatedRefreshToken)
            {
                _refreshTokenState!.Save(rotatedRefreshToken);
                _refreshToken = rotatedRefreshToken;
            }
            return _accessToken;
        }
        finally
        {
            _tokenGate.Release();
        }
    }

    private async Task<JsonNode> ReadJsonAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var bytes = await ReadLimitedBytesAsync(response, _options.MaxJsonResponseBytes, cancellationToken).ConfigureAwait(false);
        try
        {
            return JsonNode.Parse(bytes) ?? throw new JsonException();
        }
        catch (JsonException)
        {
            throw new JiraApiException(HttpStatusCode.BadGateway, "Jira returned an invalid JSON response");
        }
    }

    private static async Task<byte[]> ReadLimitedBytesAsync(HttpResponseMessage response, long maximumBytes, CancellationToken cancellationToken)
    {
        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var output = new MemoryStream();
        var buffer = new byte[32 * 1024];
        while (true)
        {
            var read = await input.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return output.ToArray();
            }
            if (output.Length + read > maximumBytes)
            {
                throw new JiraApiException(HttpStatusCode.RequestEntityTooLarge, "Jira response exceeds the configured size limit");
            }
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }
    }

    private static bool SameOrigin(Uri actual, Uri expected) =>
        actual.Scheme == expected.Scheme &&
        string.Equals(actual.Host, expected.Host, StringComparison.OrdinalIgnoreCase) &&
        actual.Port == expected.Port &&
        actual.UserInfo.Length == 0;
}
