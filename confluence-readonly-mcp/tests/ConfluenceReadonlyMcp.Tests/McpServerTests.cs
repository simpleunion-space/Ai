using System.Text.Json.Nodes;
using AiStand.ConfluenceReadonlyMcp;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace ConfluenceReadonlyMcp.Tests;

public sealed class McpServerTests
{
    private static readonly string[] ExpectedToolNames =
    [
        "confluence_search_content",
        "confluence_get_content",
        "confluence_list_comments",
        "confluence_list_attachments",
        "confluence_get_attachment",
    ];

    [Fact]
    public async Task InitializeAndListToolsExposeOnlyReadOnlyOperations()
    {
        var server = CreateServer();
        var initialized = await server.DispatchAsync(Request(1, "initialize"), CancellationToken.None);
        var tools = await server.DispatchAsync(Request(2, "tools/list"), CancellationToken.None);

        Assert.NotNull(initialized.SessionId);
        Assert.Equal("2025-03-26", initialized.Body!["result"]!["protocolVersion"]!.GetValue<string>());
        var names = tools.Body!["result"]!["tools"]!.AsArray()
            .Select(tool => tool!["name"]!.GetValue<string>())
            .ToArray();
        Assert.Equal(ExpectedToolNames, names);
        Assert.DoesNotContain(names, name => name.Contains("create", StringComparison.OrdinalIgnoreCase) || name.Contains("update", StringComparison.OrdinalIgnoreCase) || name.Contains("delete", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task NotificationsDoNotProduceJsonRpcBody()
    {
        var server = CreateServer();
        var notification = new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" };

        var result = await server.DispatchAsync(notification, CancellationToken.None);

        Assert.Null(result.Body);
    }

    private static McpServer CreateServer()
    {
        var options = new ConfluenceOptions(
            new Uri("https://confluence.example.test/wiki/"), ConfluenceAuthMode.Pat, 25, 100, 1024, 1024, TimeSpan.FromSeconds(10),
            null, null, "unused", null, null, null, null, null, null, "unused", null, null);
        var client = new ConfluenceClient(new HttpClient(new NeverCalledHandler()), options, new BearerAuthenticator("test-token"));
        return new McpServer(new ConfluenceTools(client, options, NullLogger<ConfluenceTools>.Instance));
    }

    private static JsonObject Request(int id, string method) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id,
        ["method"] = method,
    };

    private sealed class NeverCalledHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new Xunit.Sdk.XunitException("No upstream call is expected from this MCP protocol test");
    }
}
