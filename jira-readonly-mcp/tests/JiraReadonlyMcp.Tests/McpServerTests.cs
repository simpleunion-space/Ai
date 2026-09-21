using System.Net;
using System.Text;
using System.Text.Json;
using JiraReadonlyMcp;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace JiraReadonlyMcp.Tests;

public sealed class McpServerTests
{
    [Fact]
    public void Internal_bearer_auth_accepts_only_exact_secret()
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "test-internal-token\n");
            var auth = McpInternalAuth.FromSecretFile(path);

            Assert.True(auth.IsAuthorized("Bearer test-internal-token"));
            Assert.False(auth.IsAuthorized("Bearer wrong-token"));
            Assert.False(auth.IsAuthorized("Basic test-internal-token"));
            Assert.False(auth.IsAuthorized(null));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task Rotating_refresh_token_is_persisted_and_reused()
    {
        var stateDirectory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var keyPath = Path.GetTempFileName();
        Directory.CreateDirectory(stateDirectory);
        File.WriteAllText(keyPath, Convert.ToBase64String(new byte[32]
        {
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
            17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        }));

        try
        {
            var firstTokenBodies = new List<string>();
            var firstClient = CreateOAuthClient(new StubHandler(request =>
            {
                if (request.Method == HttpMethod.Post)
                {
                    firstTokenBodies.Add(request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
                    return Json("""{"access_token":"access-one","expires_in":60,"refresh_token":"rotated-token"}""");
                }
                return Json("""{"values":[]}""");
            }), stateDirectory, keyPath);

            await firstClient.GetJsonAsync("rest/api/2/project/search?startAt=0&maxResults=1", CancellationToken.None);

            var secondTokenBodies = new List<string>();
            var secondClient = CreateOAuthClient(new StubHandler(request =>
            {
                if (request.Method == HttpMethod.Post)
                {
                    secondTokenBodies.Add(request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
                    return Json("""{"access_token":"access-two","expires_in":60}""");
                }
                return Json("""{"values":[]}""");
            }), stateDirectory, keyPath);

            await secondClient.GetJsonAsync("rest/api/2/project/search?startAt=0&maxResults=1", CancellationToken.None);

            Assert.Contains("refresh_token=bootstrap-token", firstTokenBodies.Single(), StringComparison.Ordinal);
            Assert.Contains("refresh_token=rotated-token", secondTokenBodies.Single(), StringComparison.Ordinal);
            var stateText = File.ReadAllText(Path.Combine(stateDirectory, "jira-refresh-token.v1.json"));
            Assert.DoesNotContain("rotated-token", stateText, StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(keyPath);
            Directory.Delete(stateDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task Initialize_returns_streamable_http_capabilities()
    {
        var server = CreateServer(new StubHandler(_ => Json("{}")));
        using var request = JsonDocument.Parse("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}""");

        var response = await server.HandleAsync(request.RootElement, CancellationToken.None);

        Assert.Equal("2025-03-26", response!["result"]!["protocolVersion"]!.GetValue<string>());
        Assert.Equal("jira-readonly-mcp", response["result"]!["serverInfo"]!["name"]!.GetValue<string>());
    }

    [Fact]
    public async Task Tools_list_contains_only_read_tools()
    {
        var server = CreateServer(new StubHandler(_ => Json("{}")));
        using var request = JsonDocument.Parse("""{"jsonrpc":"2.0","id":1,"method":"tools/list"}""");

        var response = await server.HandleAsync(request.RootElement, CancellationToken.None);
        var tools = response!["result"]!["tools"]!.AsArray().Select(x => x!["name"]!.GetValue<string>()).ToArray();

        Assert.Equal(new[] { "jira_search_issues", "jira_get_issue", "jira_list_comments", "jira_list_projects", "jira_get_attachment" }, tools);
        Assert.DoesNotContain(tools, tool => tool.Contains("create", StringComparison.OrdinalIgnoreCase) || tool.Contains("update", StringComparison.OrdinalIgnoreCase) || tool.Contains("delete", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task Search_uses_configured_jira_origin_and_page_limit()
    {
        Uri? seenUri = null;
        var server = CreateServer(new StubHandler(request =>
        {
            seenUri = request.RequestUri;
            return Json("""{"issues":[],"total":0}""");
        }));
        using var request = JsonDocument.Parse("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jira_search_issues","arguments":{"jql":"project = ABC","max_results":50}}}""");

        var response = await server.HandleAsync(request.RootElement, CancellationToken.None);

        Assert.NotNull(seenUri);
        Assert.Equal("https://jira.example.test/jira/rest/api/2/search", seenUri!.GetLeftPart(UriPartial.Path));
        Assert.Contains("jql=project%20%3D%20ABC", seenUri.Query, StringComparison.Ordinal);
        Assert.Equal(0, response!["result"]!["structuredContent"]!["total"]!.GetValue<int>());
    }

    [Fact]
    public async Task Search_rejects_page_size_above_configured_limit()
    {
        var calls = 0;
        var server = CreateServer(new StubHandler(_ =>
        {
            calls++;
            return Json("{}");
        }));
        using var request = JsonDocument.Parse("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jira_search_issues","arguments":{"jql":"project = ABC","max_results":51}}}""");

        var response = await server.HandleAsync(request.RootElement, CancellationToken.None);

        Assert.Equal(0, calls);
        Assert.Equal(-32602, response!["error"]!["code"]!.GetValue<int>());
    }

    [Fact]
    public async Task Invalid_issue_key_never_reaches_jira()
    {
        var calls = 0;
        var server = CreateServer(new StubHandler(_ =>
        {
            calls++;
            return Json("{}");
        }));
        using var request = JsonDocument.Parse("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jira_get_issue","arguments":{"issue_key":"https://attacker.example"}}}""");

        var response = await server.HandleAsync(request.RootElement, CancellationToken.None);

        Assert.Equal(0, calls);
        Assert.Equal(-32602, response!["error"]!["code"]!.GetValue<int>());
    }

    [Fact]
    public async Task Attachment_content_from_another_origin_is_rejected()
    {
        var handler = new StubHandler(_ => Json("""{"id":"123","content":"https://attacker.example/file"}"""));
        var server = CreateServer(handler);
        using var request = JsonDocument.Parse("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jira_get_attachment","arguments":{"attachment_id":"123","include_content":true}}}""");

        var response = await server.HandleAsync(request.RootElement, CancellationToken.None);

        Assert.True(response!["result"]!["isError"]!.GetValue<bool>());
        Assert.Equal(502, response["result"]!["structuredContent"]!["status"]!.GetValue<int>());
        Assert.Equal(1, handler.CallCount);
    }

    private static McpServer CreateServer(StubHandler handler)
    {
        var options = new JiraOptions
        {
            BaseUri = new Uri("https://jira.example.test/jira/"),
            AuthMode = JiraAuthMode.Pat,
            CredentialSecretFile = "/run/secrets/jira",
            MaxResults = 50,
            MaxAttachmentBytes = 1024,
            MaxJsonResponseBytes = 1024 * 1024,
            RequestTimeoutSeconds = 30,
        };
        var client = new JiraApiClient(
            new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan },
            options,
            new JiraCredentials { Token = "test-token" },
            NullLogger<JiraApiClient>.Instance);
        return new McpServer(client, options);
    }

    private static JiraApiClient CreateOAuthClient(StubHandler handler, string stateDirectory, string keyPath)
    {
        var options = new JiraOptions
        {
            BaseUri = new Uri("https://jira.example.test/jira/"),
            AuthMode = JiraAuthMode.OAuthRefreshToken,
            CredentialSecretFile = "/run/secrets/jira",
            OAuthTokenUri = new Uri("https://auth.example.test/token"),
            TokenStateDirectory = stateDirectory,
            TokenStateKeyFile = keyPath,
            MaxResults = 50,
            MaxAttachmentBytes = 1024,
            MaxJsonResponseBytes = 1024 * 1024,
            RequestTimeoutSeconds = 30,
        };
        return new JiraApiClient(
            new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan },
            options,
            new JiraCredentials { ClientId = "client", ClientSecret = "secret", RefreshToken = "bootstrap-token" },
            NullLogger<JiraApiClient>.Instance);
    }

    private static HttpResponseMessage Json(string content) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(content, Encoding.UTF8, "application/json"),
    };

    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _handler;
        public StubHandler(Func<HttpRequestMessage, HttpResponseMessage> handler) => _handler = handler;
        public int CallCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++;
            return Task.FromResult(_handler(request));
        }
    }
}
