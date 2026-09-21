using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiStand.McpReadonly;

namespace AiStand.ConfluenceReadonlyMcp;

public sealed class McpServer
{
    private const string ProtocolVersion = "2025-03-26";
    private readonly ConfluenceTools _tools;
    private readonly ConcurrentDictionary<string, byte> _sessions = new(StringComparer.Ordinal);

    public McpServer(ConfluenceTools tools) => _tools = tools;

    public async Task<McpDispatchResult> DispatchAsync(JsonObject request, CancellationToken cancellationToken)
    {
        var id = request["id"]?.DeepClone();
        var method = request["method"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(method))
        {
            return new McpDispatchResult(McpJson.Error(id, -32600, "Invalid JSON-RPC request"), null);
        }

        if (id is null)
        {
            // JSON-RPC notifications have no response body. MCP clients use
            // notifications/initialized after receiving initialize.
            return new McpDispatchResult(null, null);
        }

        try
        {
            return method switch
            {
                "initialize" => Initialize(id),
                "ping" => new McpDispatchResult(McpJson.Result(id, new JsonObject()), null),
                "tools/list" => new McpDispatchResult(McpJson.Result(id, new JsonObject { ["tools"] = ConfluenceTools.Definitions.DeepClone() }), null),
                "tools/call" => new McpDispatchResult(McpJson.Result(id, await CallToolAsync(request["params"] as JsonObject, cancellationToken).ConfigureAwait(false)), null),
                _ => new McpDispatchResult(McpJson.Error(id, -32601, "Method not found"), null),
            };
        }
        catch (JsonException)
        {
            return new McpDispatchResult(McpJson.Error(id, -32602, "Invalid request parameters"), null);
        }
        catch (ArgumentException)
        {
            return new McpDispatchResult(McpJson.Error(id, -32602, "Invalid request parameters"), null);
        }
    }

    private McpDispatchResult Initialize(JsonNode id)
    {
        var sessionId = Guid.NewGuid().ToString("N");
        _sessions.TryAdd(sessionId, 0);
        return new McpDispatchResult(McpJson.Result(id, new JsonObject
        {
            ["protocolVersion"] = ProtocolVersion,
            ["capabilities"] = new JsonObject
            {
                ["tools"] = new JsonObject { ["listChanged"] = false },
            },
            ["serverInfo"] = new JsonObject
            {
                ["name"] = "confluence-readonly-mcp",
                ["version"] = typeof(McpServer).Assembly.GetName().Version?.ToString() ?? "0.0.0",
            },
            ["instructions"] = "This server provides read-only Confluence Data Center tools. Do not request write operations.",
        }), sessionId);
    }

    private async Task<JsonObject> CallToolAsync(JsonObject? parameters, CancellationToken cancellationToken)
    {
        var name = parameters?["name"]?.GetValue<string>();
        var arguments = parameters?["arguments"] as JsonObject ?? new JsonObject();
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new ArgumentException("Tool name is required");
        }

        return await _tools.CallAsync(name, arguments, cancellationToken).ConfigureAwait(false);
    }

}

public sealed record McpDispatchResult(JsonObject? Body, string? SessionId);
