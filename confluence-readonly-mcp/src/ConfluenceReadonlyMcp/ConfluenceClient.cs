using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AiStand.ConfluenceReadonlyMcp;

public sealed class ConfluenceClientException : Exception
{
    public ConfluenceClientException(string message, HttpStatusCode? statusCode = null, Exception? innerException = null)
        : base(message, innerException) => StatusCode = statusCode;

    public HttpStatusCode? StatusCode { get; }
}

public sealed record ConfluenceAttachment(string ContentType, byte[] Bytes);

public sealed class ConfluenceClient
{
    private const string SafeContentExpand = "body.storage,version,space,history,metadata.labels";
    private const string SafeAttachmentExpand = "metadata,version,_links";
    private readonly HttpClient _client;
    private readonly ConfluenceOptions _options;
    private readonly IConfluenceAuthenticator _authenticator;

    public ConfluenceClient(HttpClient client, ConfluenceOptions options, IConfluenceAuthenticator authenticator)
    {
        _client = client;
        _options = options;
        _authenticator = authenticator;
    }

    public Task<JsonNode> SearchContentAsync(string cql, int start, int limit, CancellationToken cancellationToken)
    {
        ValidateSearch(cql, start, limit);
        return GetJsonAsync($"rest/api/content/search?cql={Uri.EscapeDataString(cql)}&start={start}&limit={limit}", cancellationToken);
    }

    // A fixed GET identity endpoint validates the PAT without creating,
    // updating or touching any Confluence content.
    public Task ProbeAsync(CancellationToken cancellationToken) =>
        GetJsonAsync("rest/api/user/current", cancellationToken);

    public Task<JsonNode> GetContentAsync(string contentId, CancellationToken cancellationToken) =>
        GetJsonAsync($"rest/api/content/{EscapeContentId(contentId)}?expand={Uri.EscapeDataString(SafeContentExpand)}", cancellationToken);

    public Task<JsonNode> ListCommentsAsync(string contentId, int start, int limit, CancellationToken cancellationToken)
    {
        ValidatePagination(start, limit);
        return GetJsonAsync($"rest/api/content/{EscapeContentId(contentId)}/child/comment?start={start}&limit={limit}", cancellationToken);
    }

    public Task<JsonNode> ListAttachmentsAsync(string contentId, int start, int limit, CancellationToken cancellationToken)
    {
        ValidatePagination(start, limit);
        return GetJsonAsync($"rest/api/content/{EscapeContentId(contentId)}/child/attachment?start={start}&limit={limit}&expand={Uri.EscapeDataString(SafeAttachmentExpand)}", cancellationToken);
    }

    public async Task<ConfluenceAttachment> GetAttachmentAsync(string attachmentId, CancellationToken cancellationToken)
    {
        var metadata = await GetJsonAsync($"rest/api/content/{EscapeContentId(attachmentId)}?expand={Uri.EscapeDataString(SafeAttachmentExpand)}", cancellationToken).ConfigureAwait(false);
        if (!string.Equals(metadata["type"]?.GetValue<string>(), "attachment", StringComparison.Ordinal))
        {
            throw new ArgumentException("content_id does not identify a Confluence attachment");
        }

        var download = metadata["_links"]?["download"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(download))
        {
            throw new ConfluenceClientException("Confluence attachment does not have a download link");
        }

        var downloadUri = ToSameOriginDownloadUri(download);
        using var request = new HttpRequestMessage(HttpMethod.Get, downloadUri);
        request.Headers.Accept.ParseAdd("application/octet-stream");
        await _authenticator.ApplyAsync(request, cancellationToken).ConfigureAwait(false);
        using var timeout = CreateTimeout(cancellationToken);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        EnsureSuccess(response);
        var declaredLength = response.Content.Headers.ContentLength;
        if (declaredLength is > 0 && declaredLength > _options.MaxAttachmentBytes)
        {
            throw new ConfluenceClientException("Confluence attachment exceeds the configured size limit");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        var bytes = await ReadBoundedAsync(stream, _options.MaxAttachmentBytes, timeout.Token).ConfigureAwait(false);
        return new ConfluenceAttachment(response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream", bytes);
    }

    private async Task<JsonNode> GetJsonAsync(string relativePathAndQuery, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, ToConfiguredEndpoint(relativePathAndQuery));
        request.Headers.Accept.ParseAdd("application/json");
        await _authenticator.ApplyAsync(request, cancellationToken).ConfigureAwait(false);
        using var timeout = CreateTimeout(cancellationToken);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        EnsureSuccess(response);
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        var bytes = await ReadBoundedAsync(stream, _options.MaxResponseBytes, timeout.Token).ConfigureAwait(false);
        try
        {
            return JsonNode.Parse(bytes) ?? throw new ConfluenceClientException("Confluence returned an empty JSON response");
        }
        catch (JsonException exception)
        {
            throw new ConfluenceClientException("Confluence returned an invalid JSON response", innerException: exception);
        }
    }

    private Uri ToConfiguredEndpoint(string relativePathAndQuery)
    {
        if (!Uri.TryCreate(relativePathAndQuery, UriKind.Relative, out var relative) || relative.OriginalString.StartsWith("//", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Confluence client accepts only fixed relative REST paths");
        }

        var uri = new Uri(_options.BaseUri, relative);
        EnsureSameOrigin(uri);
        return uri;
    }

    private Uri ToSameOriginDownloadUri(string relativeDownloadUri)
    {
        if (!Uri.TryCreate(relativeDownloadUri, UriKind.Relative, out var relative) || relative.OriginalString.StartsWith("//", StringComparison.Ordinal))
        {
            throw new ConfluenceClientException("Confluence attachment download link is not a relative path");
        }

        // Confluence _links.download is normally origin-relative, whereas the
        // configured base URL can include a context path such as /confluence.
        var origin = new UriBuilder(_options.BaseUri.Scheme, _options.BaseUri.Host, _options.BaseUri.Port).Uri;
        var uri = new Uri(origin, relative);
        EnsureSameOrigin(uri);
        return uri;
    }

    private void EnsureSameOrigin(Uri uri)
    {
        if (!string.Equals(uri.Scheme, _options.BaseUri.Scheme, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(uri.Host, _options.BaseUri.Host, StringComparison.OrdinalIgnoreCase) ||
            uri.Port != _options.BaseUri.Port ||
            !string.Equals(uri.UserInfo, string.Empty, StringComparison.Ordinal))
        {
            throw new ConfluenceClientException("Confluence request would leave the configured origin");
        }
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream stream, int maximumBytes, CancellationToken cancellationToken)
    {
        await using var destination = new MemoryStream(capacity: Math.Min(maximumBytes, 64 * 1024));
        var buffer = new byte[32 * 1024];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                return destination.ToArray();
            }

            if (destination.Length + count > maximumBytes)
            {
                throw new ConfluenceClientException("Confluence response exceeds the configured size limit");
            }

            await destination.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
        }
    }

    private static void EnsureSuccess(HttpResponseMessage response)
    {
        if (!response.IsSuccessStatusCode)
        {
            throw new ConfluenceClientException($"Confluence request failed with HTTP {(int)response.StatusCode}", response.StatusCode);
        }
    }

    private CancellationTokenSource CreateTimeout(CancellationToken requestAborted)
    {
        var timeout = CancellationTokenSource.CreateLinkedTokenSource(requestAborted);
        timeout.CancelAfter(_options.RequestTimeout);
        return timeout;
    }

    private void ValidateSearch(string cql, int start, int limit)
    {
        if (string.IsNullOrWhiteSpace(cql) || cql.Length > 4096)
        {
            throw new ArgumentException("cql must contain from 1 to 4096 characters");
        }

        ValidatePagination(start, limit);
    }

    private void ValidatePagination(int start, int limit)
    {
        if (start < 0 || start > _options.MaxResults)
        {
            throw new ArgumentException("start is outside the configured result range");
        }

        if (limit < 1 || limit > _options.MaxPageSize || start + limit > _options.MaxResults)
        {
            throw new ArgumentException("limit is outside the configured result range");
        }
    }

    private static string EscapeContentId(string contentId)
    {
        if (string.IsNullOrWhiteSpace(contentId) || contentId.Length > 128)
        {
            throw new ArgumentException("content_id must contain from 1 to 128 characters");
        }

        return Uri.EscapeDataString(contentId);
    }
}
