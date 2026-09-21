using System.Text.Json.Nodes;

namespace AiStand.McpReadonly;

/// <summary>Small dependency-free helpers for MCP JSON-RPC responses.</summary>
public static class McpJson
{
    public static JsonObject Result(JsonNode? id, JsonNode result) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id?.DeepClone(),
        ["result"] = result,
    };

    public static JsonObject Error(JsonNode? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id?.DeepClone(),
        ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
    };

    public static JsonObject Text(string value, bool isError = false) => new()
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = value }),
        ["isError"] = isError,
    };

    public static JsonObject Tool(string name, string description, JsonObject inputSchema) => new()
    {
        ["name"] = name,
        ["description"] = description,
        ["inputSchema"] = inputSchema,
    };
}
