using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using AiStand.GigacodeBridge;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace GigacodeBridge.Tests;

public sealed class GigacodeClientTests : IDisposable
{
    private readonly string _deviceFile = Path.GetTempFileName();

    public GigacodeClientTests()
    {
        File.WriteAllText(_deviceFile, new string('a', 64));
    }

    [Fact]
    public async Task ReauthenticatesAndUsesDynamicChatUrlWithoutSendingDeviceIdToChat()
    {
        var handler = new ScriptedHandler(
            Json("{\"access_token\":\"test-token-1\",\"expires_in\":3600}"),
            Json("{\"chat\":{\"url\":\"https://gigacode.ru/api/v2/chat/completions\",\"models\":[{\"model\":\"CodeChat\"}]}}"),
            new HttpResponseMessage(HttpStatusCode.Unauthorized),
            Json("{\"access_token\":\"test-token-2\",\"expires_in\":3600}"),
            Json("{\"chat\":{\"url\":\"https://gigacode.ru/api/v2/chat/completions\",\"models\":[{\"model\":\"CodeChat\"}]}}"),
            Json("{\"id\":\"chatcmpl_test\",\"choices\":[]}"));
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var gigacode = new GigacodeClient(client, CreateOptions(), NullLogger<GigacodeClient>.Instance);

        using var response = await gigacode.SendChatAsync(new JsonObject
        {
            ["model"] = "gigacode/codechat",
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "ping" }),
        }, CancellationToken.None);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(
            new[]
            {
                "/api/v2/auth/plugin",
                "/api/v2/config",
                "/api/v2/chat/completions",
                "/api/v2/auth/plugin",
                "/api/v2/config",
                "/api/v2/chat/completions",
            },
            handler.RequestPaths);
        foreach (var index in Enumerable.Range(0, handler.RequestPaths.Count)
                     .Where(index => handler.RequestPaths[index].EndsWith("/chat/completions", StringComparison.Ordinal)))
        {
            Assert.DoesNotContain(new string('a', 64), handler.RequestBodies[index]!, StringComparison.Ordinal);
        }
    }

    private GigacodeOptions CreateOptions() => new()
    {
        BaseUri = new Uri("https://gigacode.ru"),
        ConfigPath = "/api/v2/config",
        AuthPath = "/api/v2/auth/plugin",
        FallbackChatPath = "/api/v2/chat/completions",
        DeviceIdFile = _deviceFile,
        InternalBearerFile = "/run/secrets/test-internal-bearer",
        ModelAlias = "gigacode/codechat",
        FallbackModel = "CodeChat",
        PluginName = "cli-plugin",
        PluginVersion = "26.7.33",
        Login = "node",
        Locale = "ru",
        ContextWindow = 65536,
        TokenRefreshSkewSeconds = 60,
        RequestTimeoutSeconds = 86400,
        StreamIdleTimeoutSeconds = 86400,
    };

    private static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(value, Encoding.UTF8, "application/json"),
    };

    public void Dispose()
    {
        File.Delete(_deviceFile);
    }

    private sealed class ScriptedHandler(params HttpResponseMessage[] responses) : HttpMessageHandler
    {
        private readonly Queue<HttpResponseMessage> _responses = new(responses);

        public List<string> RequestPaths { get; } = [];
        public List<string?> RequestBodies { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestPaths.Add(request.RequestUri!.AbsolutePath);
            RequestBodies.Add(request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken));
            return _responses.Dequeue();
        }
    }
}
