using System.Text;
using System.Text.Json.Nodes;
using AiStand.ImapReadonlyMcp;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging.Abstractions;

namespace ImapReadonlyMcp.Tests;

public sealed class McpProtocolTests
{
    [Fact]
    public async Task InitializeAndToolsListUseJsonRpcStreamableHttpResponse()
    {
        var response = await InvokeAsync("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}
        """);
        Assert.Equal("2025-03-26", response["result"]!["protocolVersion"]!.GetValue<string>());

        var toolResponse = await InvokeAsync("""
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}
        """);
        var names = toolResponse["result"]!["tools"]!.AsArray().Select(tool => tool!["name"]!.GetValue<string>()).ToArray();
        Assert.Equal(McpToolCatalog.Names, names);
    }

    [Fact]
    public async Task ToolErrorsAreMcpResultsAndDoNotInvokeUnknownTool()
    {
        var response = await InvokeAsync("""
        {"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"imap_delete_message","arguments":{}}}
        """);

        Assert.True(response["result"]!["isError"]!.GetValue<bool>());
        Assert.Equal("Unknown MCP tool", response["result"]!["content"]![0]!["text"]!.GetValue<string>());
    }

    [Fact]
    public async Task SearchRejectsUnexpectedArgumentsBeforeUpstreamCall()
    {
        var response = await InvokeAsync("""
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"imap_search_messages","arguments":{"mailbox":"INBOX","injected":"x"}}}
        """);

        Assert.True(response["result"]!["isError"]!.GetValue<bool>());
        Assert.Equal("Unexpected tool argument", response["result"]!["content"]![0]!["text"]!.GetValue<string>());
    }

    [Fact]
    public void ReadOnlyPolicyForbidsAllStateChangingImapCommands()
    {
        Assert.Equal(new[] { "APPEND", "COPY", "EXPUNGE", "MOVE", "STORE" }, ImapReadOnlyPolicy.ForbiddenImapCommands.OrderBy(command => command));
        Assert.All(McpToolCatalog.Names, name => Assert.True(ImapReadOnlyPolicy.IsReadOnlyTool(name)));
        Assert.DoesNotContain(McpToolCatalog.Names, name => name.Contains("delete", StringComparison.OrdinalIgnoreCase));
    }

    private static async Task<JsonObject> InvokeAsync(string payload)
    {
        var context = new DefaultHttpContext();
        context.Request.Body = new MemoryStream(Encoding.UTF8.GetBytes(payload));
        context.Response.Body = new MemoryStream();
        await McpEndpoint.HandleAsync(context, new McpToolDispatcher(new FakeImapReadService(), TestOptions()), NullLoggerFactory.Instance);
        context.Response.Body.Position = 0;
        return (await JsonNode.ParseAsync(context.Response.Body))!.AsObject();
    }

    private static ImapOptions TestOptions() => new(
        "mail.example.test", 993, ImapTlsMode.Implicit, ImapAuthenticationMode.Basic,
        new ImapCredentialSecret("reader", "password", null, null, null, null, null, null), "/run/secrets/mcp-internal-token", null,
        new HashSet<string>(StringComparer.Ordinal) { "INBOX" }, 10, 1024, 4096, 1024, 60);

    private sealed class FakeImapReadService : IImapReadService
    {
        public Task<IReadOnlyList<MailboxInfo>> ListMailboxesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<MailboxInfo>>([]);

        public Task<SearchMessagesResult> SearchMessagesAsync(SearchMessagesRequest request, CancellationToken cancellationToken) =>
            Task.FromResult(new SearchMessagesResult([], request.Page, request.PageSize, false));

        public Task<MessageDetail> GetMessageAsync(string mailbox, uint uid, CancellationToken cancellationToken) => throw new NotSupportedException();

        public Task<IReadOnlyList<AttachmentInfo>> ListAttachmentsAsync(string mailbox, uint uid, CancellationToken cancellationToken) => throw new NotSupportedException();

        public Task<AttachmentContent> GetAttachmentAsync(string mailbox, uint uid, int index, CancellationToken cancellationToken) => throw new NotSupportedException();
    }
}
