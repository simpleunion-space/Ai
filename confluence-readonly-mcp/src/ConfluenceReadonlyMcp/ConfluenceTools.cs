using System.Text.Json;
using System.Text.Json.Nodes;
using AiStand.McpReadonly;

namespace AiStand.ConfluenceReadonlyMcp;

public sealed class ConfluenceTools
{
    private readonly ConfluenceClient _client;
    private readonly ConfluenceOptions _options;
    private readonly ILogger<ConfluenceTools> _logger;

    public ConfluenceTools(ConfluenceClient client, ConfluenceOptions options, ILogger<ConfluenceTools> logger)
    {
        _client = client;
        _options = options;
        _logger = logger;
    }

    public static JsonArray Definitions => new()
    {
        McpJson.Tool("confluence_search_content", "Search Confluence content with CQL. Results are limited by the server's read-only pagination policy.", new JsonObject
        {
            ["type"] = "object",
            ["additionalProperties"] = false,
            ["required"] = new JsonArray("cql"),
            ["properties"] = new JsonObject
            {
                ["cql"] = new JsonObject { ["type"] = "string", ["maxLength"] = 4096 },
                ["start"] = new JsonObject { ["type"] = "integer", ["minimum"] = 0 },
                ["limit"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1 },
            },
        }),
        McpJson.Tool("confluence_get_content", "Read one Confluence content item. The server chooses a fixed safe set of returned fields.", ContentIdSchema()),
        McpJson.Tool("confluence_list_comments", "List comments for one Confluence content item.", PaginatedContentIdSchema()),
        McpJson.Tool("confluence_list_attachments", "List attachments for one Confluence content item.", PaginatedContentIdSchema()),
        McpJson.Tool("confluence_get_attachment", "Read one attachment by its Confluence attachment content ID. The attachment size is server-limited.", ContentIdSchema()),
    };

    public async Task<JsonObject> CallAsync(string toolName, JsonObject arguments, CancellationToken cancellationToken)
    {
        try
        {
            JsonNode result = toolName switch
            {
                "confluence_search_content" => await _client.SearchContentAsync(
                    RequiredString(arguments, "cql"),
                    OptionalInt(arguments, "start", 0),
                    OptionalInt(arguments, "limit", _options.MaxPageSize),
                    cancellationToken).ConfigureAwait(false),
                "confluence_get_content" => await _client.GetContentAsync(RequiredString(arguments, "content_id"), cancellationToken).ConfigureAwait(false),
                "confluence_list_comments" => await _client.ListCommentsAsync(
                    RequiredString(arguments, "content_id"),
                    OptionalInt(arguments, "start", 0),
                    OptionalInt(arguments, "limit", _options.MaxPageSize),
                    cancellationToken).ConfigureAwait(false),
                "confluence_list_attachments" => await _client.ListAttachmentsAsync(
                    RequiredString(arguments, "content_id"),
                    OptionalInt(arguments, "start", 0),
                    OptionalInt(arguments, "limit", _options.MaxPageSize),
                    cancellationToken).ConfigureAwait(false),
                "confluence_get_attachment" => AttachmentResult(await _client.GetAttachmentAsync(RequiredString(arguments, "content_id"), cancellationToken).ConfigureAwait(false)),
                _ => throw new ArgumentException("Unknown tool"),
            };

            ConfluenceLog.ToolCompleted(_logger, toolName);
            return ToolResult(result);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            ConfluenceLog.ToolCancelled(_logger, toolName);
            return ErrorResult("The request was cancelled");
        }
        catch (ArgumentException)
        {
            ConfluenceLog.ToolInvalidInput(_logger, toolName);
            return ErrorResult("Invalid tool input");
        }
        catch (ConfluenceClientException exception)
        {
            ConfluenceLog.ToolUpstreamFailure(_logger, toolName, exception.StatusCode is null ? "unavailable" : ((int)exception.StatusCode).ToString(System.Globalization.CultureInfo.InvariantCulture));
            return ErrorResult(Redaction.Safe(exception.Message));
        }
        catch (Exception)
        {
            ConfluenceLog.ToolFailure(_logger, toolName);
            return ErrorResult("Confluence request failed");
        }
    }

    private static JsonObject ContentIdSchema() => new()
    {
        ["type"] = "object",
        ["additionalProperties"] = false,
        ["required"] = new JsonArray("content_id"),
        ["properties"] = new JsonObject
        {
            ["content_id"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 128 },
        },
    };

    private static JsonObject PaginatedContentIdSchema() => new()
    {
        ["type"] = "object",
        ["additionalProperties"] = false,
        ["required"] = new JsonArray("content_id"),
        ["properties"] = new JsonObject
        {
            ["content_id"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 128 },
            ["start"] = new JsonObject { ["type"] = "integer", ["minimum"] = 0 },
            ["limit"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1 },
        },
    };

    private static string RequiredString(JsonObject arguments, string name) => arguments[name]?.GetValue<string>() is { Length: > 0 } value
        ? value
        : throw new ArgumentException($"{name} is required");

    private static int OptionalInt(JsonObject arguments, string name, int defaultValue) => arguments[name] is null
        ? defaultValue
        : arguments[name]!.GetValue<int>();

    private static JsonObject ToolResult(JsonNode value) => new()
    {
        ["content"] = new JsonArray(new JsonObject
        {
            ["type"] = "text",
            ["text"] = value.ToJsonString(new JsonSerializerOptions { WriteIndented = false }),
        }),
    };

    private static JsonObject AttachmentResult(ConfluenceAttachment attachment) => new()
    {
        ["content"] = new JsonArray(new JsonObject
        {
            ["type"] = "resource",
            ["resource"] = new JsonObject
            {
                ["uri"] = "confluence://attachment",
                ["mimeType"] = attachment.ContentType,
                ["blob"] = Convert.ToBase64String(attachment.Bytes),
            },
        }),
    };

    private static JsonObject ErrorResult(string text) => McpJson.Text(text, isError: true);
}

internal static partial class ConfluenceLog
{
    [LoggerMessage(Level = LogLevel.Information, Message = "Confluence MCP tool {ToolName} completed")]
    public static partial void ToolCompleted(ILogger logger, string toolName);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Confluence MCP tool {ToolName} was cancelled")]
    public static partial void ToolCancelled(ILogger logger, string toolName);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Confluence MCP tool {ToolName} received invalid input")]
    public static partial void ToolInvalidInput(ILogger logger, string toolName);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Confluence MCP tool {ToolName} failed with upstream status {StatusCode}")]
    public static partial void ToolUpstreamFailure(ILogger logger, string toolName, string statusCode);

    [LoggerMessage(Level = LogLevel.Error, Message = "Confluence MCP tool {ToolName} failed")]
    public static partial void ToolFailure(ILogger logger, string toolName);
}
