using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using AiStand.ConfluenceReadonlyMcp;
using Xunit;

namespace ConfluenceReadonlyMcp.Tests;

public sealed class ConfluenceClientTests
{
    [Fact]
    public async Task SearchUsesConfiguredOriginAndGetOnly()
    {
        var handler = new RecordingHandler(_ => JsonResponse("{\"results\":[]}"));
        var client = CreateClient(handler);

        var result = await client.SearchContentAsync("type = page", start: 0, limit: 10, CancellationToken.None);

        Assert.Empty(result["results"]!.AsArray());
        Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Get, handler.Requests[0].Method);
        Assert.Equal("https://confluence.example.test/wiki/rest/api/content/search?cql=type%20%3D%20page&start=0&limit=10", handler.Requests[0].RequestUri!.AbsoluteUri);
    }

    [Fact]
    public async Task AttachmentDownloadRejectsAbsoluteExternalLink()
    {
        var handler = new RecordingHandler(_ => JsonResponse("""
            {"type":"attachment","_links":{"download":"https://other.example.test/download/unsafe"}}
            """));
        var client = CreateClient(handler);

        var error = await Assert.ThrowsAsync<ConfluenceClientException>(() => client.GetAttachmentAsync("1001", CancellationToken.None));

        Assert.Contains("relative path", error.Message, StringComparison.Ordinal);
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task ResponseLargerThanStaticLimitIsRejected()
    {
        var handler = new RecordingHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent(Encoding.UTF8.GetBytes(new string('x', 2048))),
        });
        var options = CreateOptions(maxResponseBytes: 1024);
        var client = new ConfluenceClient(new HttpClient(handler), options, new BearerAuthenticator("test-token"));

        var error = await Assert.ThrowsAsync<ConfluenceClientException>(() => client.GetContentAsync("1001", CancellationToken.None));

        Assert.Contains("size limit", error.Message, StringComparison.Ordinal);
        Assert.All(handler.Requests, request => Assert.Equal(HttpMethod.Get, request.Method));
    }

    [Fact]
    public void EncryptedRefreshTokenStateDoesNotContainPlaintext()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "refresh.state");
        try
        {
            var store = new EncryptedRefreshTokenStore(path, Enumerable.Repeat((byte)42, 32).ToArray(), "initial");
            store.Save("rotated-secret-token");

            Assert.Equal("rotated-secret-token", store.GetRefreshToken());
            Assert.DoesNotContain("rotated-secret-token", File.ReadAllText(path), StringComparison.Ordinal);
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    private static ConfluenceClient CreateClient(RecordingHandler handler) => new(
        new HttpClient(handler),
        CreateOptions(),
        new BearerAuthenticator("test-token"));

    private static ConfluenceOptions CreateOptions(int maxResponseBytes = 2 * 1024 * 1024) => new(
        new Uri("https://confluence.example.test/wiki/"),
        ConfluenceAuthMode.Pat,
        MaxPageSize: 25,
        MaxResults: 100,
        MaxAttachmentBytes: 10 * 1024 * 1024,
        MaxResponseBytes: maxResponseBytes,
        RequestTimeout: TimeSpan.FromSeconds(60),
        UsernameFile: null,
        PasswordFile: null,
        PatFile: "unused",
        OAuthTokenUri: null,
        OAuthClientIdFile: null,
        OAuthClientSecretFile: null,
        OAuthRefreshTokenFile: null,
        TokenStateFile: null,
        TokenStateKeyFile: null,
        InternalTokenFile: "unused",
        OAuthScope: null,
        Credentials: null);

    private static HttpResponseMessage JsonResponse(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private sealed class RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Task.FromResult(responder(request));
        }
    }
}
