using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiStand.McpReadonly;

namespace AiStand.ImapReadonlyMcp;

public static class McpToolCatalog
{
    public static IReadOnlyList<string> Names { get; } =
    [
        "imap_list_mailboxes",
        "imap_search_messages",
        "imap_get_message",
        "imap_list_attachments",
        "imap_get_attachment",
    ];

    public static JsonArray CreateToolList() =>
    [
        McpJson.Tool("imap_list_mailboxes", "List mailboxes available to the configured IMAP account.", new JsonObject
        {
            ["type"] = "object",
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("imap_search_messages", "Search one IMAP mailbox with bounded, read-only filters.", new JsonObject
        {
            ["type"] = "object",
            ["required"] = new JsonArray("mailbox"),
            ["properties"] = new JsonObject
            {
                ["mailbox"] = StringSchema("Mailbox name"),
                ["subject"] = StringSchema("Subject substring"),
                ["from"] = StringSchema("Sender substring"),
                ["to"] = StringSchema("Recipient substring"),
                ["text"] = StringSchema("Body substring"),
                ["since"] = StringSchema("Inclusive ISO-8601 timestamp"),
                ["before"] = StringSchema("Exclusive ISO-8601 timestamp"),
                ["unreadOnly"] = new JsonObject { ["type"] = "boolean" },
                ["page"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1 },
                ["pageSize"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1 },
            },
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("imap_get_message", "Read bounded metadata and body for a message UID without changing its state.", new JsonObject
        {
            ["type"] = "object",
            ["required"] = new JsonArray("mailbox", "uid"),
            ["properties"] = new JsonObject
            {
                ["mailbox"] = StringSchema("Mailbox name"),
                ["uid"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1 },
            },
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("imap_list_attachments", "List attachments for a bounded message UID.", new JsonObject
        {
            ["type"] = "object",
            ["required"] = new JsonArray("mailbox", "uid"),
            ["properties"] = new JsonObject
            {
                ["mailbox"] = StringSchema("Mailbox name"),
                ["uid"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1 },
            },
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("imap_get_attachment", "Read one bounded attachment by its zero-based attachment index.", new JsonObject
        {
            ["type"] = "object",
            ["required"] = new JsonArray("mailbox", "uid", "attachmentIndex"),
            ["properties"] = new JsonObject
            {
                ["mailbox"] = StringSchema("Mailbox name"),
                ["uid"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1 },
                ["attachmentIndex"] = new JsonObject { ["type"] = "integer", ["minimum"] = 0 },
            },
            ["additionalProperties"] = false,
        }),
    ];

    private static JsonObject StringSchema(string description) => new()
    {
        ["type"] = "string",
        ["description"] = description,
        ["maxLength"] = 512,
    };
}

public sealed class McpToolDispatcher(IImapReadService imap, ImapOptions options)
{
    public async Task<JsonNode> InvokeAsync(string name, JsonObject arguments, CancellationToken cancellationToken)
    {
        EnsureArgumentsForTool(name, arguments);
        return name switch
        {
            "imap_list_mailboxes" => JsonSerializer.SerializeToNode(await imap.ListMailboxesAsync(cancellationToken).ConfigureAwait(false))!,
            "imap_search_messages" => JsonSerializer.SerializeToNode(await imap.SearchMessagesAsync(ParseSearch(arguments), cancellationToken).ConfigureAwait(false))!,
            "imap_get_message" => JsonSerializer.SerializeToNode(await imap.GetMessageAsync(ReadMailbox(arguments), ReadUid(arguments), cancellationToken).ConfigureAwait(false))!,
            "imap_list_attachments" => JsonSerializer.SerializeToNode(await imap.ListAttachmentsAsync(ReadMailbox(arguments), ReadUid(arguments), cancellationToken).ConfigureAwait(false))!,
            "imap_get_attachment" => JsonSerializer.SerializeToNode(await imap.GetAttachmentAsync(ReadMailbox(arguments), ReadUid(arguments), ReadBoundedInt(arguments, "attachmentIndex", 0, 1000), cancellationToken).ConfigureAwait(false))!,
            _ => throw new McpToolException("Unknown MCP tool"),
        };
    }

    private static void EnsureArgumentsForTool(string name, JsonObject arguments)
    {
        switch (name)
        {
            case "imap_list_mailboxes":
                EnsureOnlyKnownProperties(arguments);
                break;
            case "imap_search_messages":
                EnsureOnlyKnownProperties(arguments, "mailbox", "subject", "from", "to", "text", "since", "before", "unreadOnly", "page", "pageSize");
                break;
            case "imap_get_message":
            case "imap_list_attachments":
                EnsureOnlyKnownProperties(arguments, "mailbox", "uid");
                break;
            case "imap_get_attachment":
                EnsureOnlyKnownProperties(arguments, "mailbox", "uid", "attachmentIndex");
                break;
        }
    }

    private SearchMessagesRequest ParseSearch(JsonObject arguments)
    {
        var mailbox = ReadMailbox(arguments);
        var subject = ReadOptionalText(arguments, "subject");
        var from = ReadOptionalText(arguments, "from");
        var to = ReadOptionalText(arguments, "to");
        var text = ReadOptionalText(arguments, "text");
        var since = ReadOptionalTimestamp(arguments, "since");
        var before = ReadOptionalTimestamp(arguments, "before");
        var unreadOnly = ReadOptionalBoolean(arguments, "unreadOnly") ?? false;
        var page = ReadOptionalBoundedInt(arguments, "page", 1, int.MaxValue) ?? 1;
        var pageSize = ReadOptionalBoundedInt(arguments, "pageSize", 1, options.MaxPageSize) ?? options.MaxPageSize;
        return new SearchMessagesRequest(mailbox, subject, from, to, text, since, before, unreadOnly, page, pageSize);
    }

    private static string ReadMailbox(JsonObject arguments)
    {
        var mailbox = ReadRequiredString(arguments, "mailbox", 255);
        InputValidation.EnsureMailboxSyntax(mailbox);
        return mailbox;
    }

    private static uint ReadUid(JsonObject arguments) => InputValidation.PositiveUid(ReadRequiredLong(arguments, "uid"));

    private static int ReadBoundedInt(JsonObject arguments, string name, int minimum, int maximum) =>
        InputValidation.BoundedInteger(ReadRequiredLong(arguments, name), name, minimum, maximum);

    private static string? ReadOptionalText(JsonObject arguments, string name)
    {
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            return null;
        }
        try
        {
            return InputValidation.BoundedText(node.GetValue<string>(), name);
        }
        catch (InvalidOperationException)
        {
            throw new McpToolException($"{name} must be a string");
        }
    }

    private static DateTimeOffset? ReadOptionalTimestamp(JsonObject arguments, string name)
    {
        var value = ReadOptionalText(arguments, name);
        if (value is null)
        {
            return null;
        }
        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var timestamp)
            ? timestamp
            : throw new McpToolException($"{name} must be an ISO-8601 timestamp");
    }

    private static bool? ReadOptionalBoolean(JsonObject arguments, string name)
    {
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            return null;
        }
        try
        {
            return node.GetValue<bool>();
        }
        catch (InvalidOperationException)
        {
            throw new McpToolException($"{name} must be a boolean");
        }
    }

    private static int? ReadOptionalBoundedInt(JsonObject arguments, string name, int minimum, int maximum)
    {
        if (!arguments.ContainsKey(name))
        {
            return null;
        }
        return ReadBoundedInt(arguments, name, minimum, maximum);
    }

    private static long ReadRequiredLong(JsonObject arguments, string name)
    {
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            throw new McpToolException($"{name} is required");
        }
        try
        {
            return node.GetValue<long>();
        }
        catch (InvalidOperationException)
        {
            throw new McpToolException($"{name} must be an integer");
        }
    }

    private static string ReadRequiredString(JsonObject arguments, string name, int maximum)
    {
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            throw new McpToolException($"{name} is required");
        }
        try
        {
            return InputValidation.BoundedText(node.GetValue<string>(), name, maximum);
        }
        catch (InvalidOperationException)
        {
            throw new McpToolException($"{name} must be a string");
        }
    }

    private static void EnsureOnlyKnownProperties(JsonObject arguments, params string[] names)
    {
        var allowed = new HashSet<string>(names, StringComparer.Ordinal);
        if (arguments.Any(property => !allowed.Contains(property.Key)))
        {
            throw new McpToolException("Unexpected tool argument");
        }
    }
}

public static class McpEndpoint
{
    private const string JsonRpcVersion = "2.0";

    public static async Task HandleAsync(HttpContext context, McpToolDispatcher dispatcher, ILoggerFactory loggerFactory)
    {
        if (!AcceptsJson(context.Request))
        {
            context.Response.StatusCode = StatusCodes.Status406NotAcceptable;
            return;
        }

        JsonObject request;
        try
        {
            request = (await JsonNode.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted).ConfigureAwait(false))?.AsObject()
                ?? throw new JsonException();
        }
        catch (JsonException)
        {
            await WriteAsync(context.Response, Error(null, -32700, "Parse error"), context.RequestAborted).ConfigureAwait(false);
            return;
        }

        var id = request["id"]?.DeepClone();
        var method = request["method"]?.GetValue<string>();
        if (request["jsonrpc"]?.GetValue<string>() != JsonRpcVersion || string.IsNullOrWhiteSpace(method))
        {
            await WriteAsync(context.Response, Error(id, -32600, "Invalid Request"), context.RequestAborted).ConfigureAwait(false);
            return;
        }

        if (id is null && method == "notifications/initialized")
        {
            context.Response.StatusCode = StatusCodes.Status202Accepted;
            return;
        }
        if (id is null)
        {
            context.Response.StatusCode = StatusCodes.Status202Accepted;
            return;
        }

        try
        {
            var response = method switch
            {
                "initialize" => Result(id, new JsonObject
                {
                    ["protocolVersion"] = "2025-03-26",
                    ["capabilities"] = new JsonObject
                    {
                        ["tools"] = new JsonObject { ["listChanged"] = false },
                    },
                    ["serverInfo"] = new JsonObject { ["name"] = "imap-readonly-mcp", ["version"] = "1.0.0" },
                    ["instructions"] = "This server only reads the configured IMAP account. It never changes mail state.",
                }),
                "ping" => Result(id, new JsonObject()),
                "tools/list" => Result(id, new JsonObject { ["tools"] = McpToolCatalog.CreateToolList() }),
                "tools/call" => await CallToolAsync(id, request["params"]?.AsObject(), dispatcher, context.RequestAborted).ConfigureAwait(false),
                _ => Error(id, -32601, "Method not found"),
            };
            await WriteAsync(context.Response, response, context.RequestAborted).ConfigureAwait(false);
        }
        catch (McpToolException exception)
        {
            var logger = loggerFactory.CreateLogger("McpEndpoint");
            logger.LogInformation("MCP tool request {RequestId} failed safely: {Reason}", SafeLog.RequestId(), Redaction.Safe(exception.Message));
            await WriteAsync(context.Response, ToolError(id, exception.Message), context.RequestAborted).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            loggerFactory.CreateLogger("McpEndpoint").LogInformation("MCP client cancelled request");
        }
        catch (Exception exception)
        {
            loggerFactory.CreateLogger("McpEndpoint").LogError("MCP request failed unexpectedly: {Reason}", Redaction.Safe(exception.Message));
            await WriteAsync(context.Response, Error(id, -32603, "Internal error"), context.RequestAborted).ConfigureAwait(false);
        }
    }

    private static async Task<JsonObject> CallToolAsync(JsonNode id, JsonObject? parameters, McpToolDispatcher dispatcher, CancellationToken cancellationToken)
    {
        var name = parameters?["name"]?.GetValue<string>();
        var arguments = parameters?["arguments"]?.AsObject() ?? new JsonObject();
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new McpToolException("Tool name is required");
        }
        if (!McpToolCatalog.Names.Contains(name, StringComparer.Ordinal))
        {
            throw new McpToolException("Unknown MCP tool");
        }

        var output = await dispatcher.InvokeAsync(name, arguments, cancellationToken).ConfigureAwait(false);
        return Result(id, new JsonObject
        {
            ["content"] = new JsonArray(new JsonObject
            {
                ["type"] = "text",
                ["text"] = output.ToJsonString(new JsonSerializerOptions(JsonSerializerDefaults.Web)),
            }),
            ["structuredContent"] = output,
        });
    }

    private static bool AcceptsJson(HttpRequest request)
    {
        var accept = request.Headers.Accept.ToString();
        return string.IsNullOrWhiteSpace(accept) || accept.Contains("application/json", StringComparison.OrdinalIgnoreCase) ||
            accept.Contains("text/event-stream", StringComparison.OrdinalIgnoreCase) || accept.Contains("*/*", StringComparison.Ordinal);
    }

    private static JsonObject Result(JsonNode id, JsonNode result) => McpJson.Result(id, result);

    private static JsonObject ToolError(JsonNode id, string message) => McpJson.Result(id, McpJson.Text(message, true));

    private static JsonObject Error(JsonNode? id, int code, string message) => McpJson.Error(id, code, message);

    private static async Task WriteAsync(HttpResponse response, JsonObject payload, CancellationToken cancellationToken)
    {
        response.StatusCode = StatusCodes.Status200OK;
        response.ContentType = "application/json; charset=utf-8";
        await response.WriteAsync(payload.ToJsonString(new JsonSerializerOptions(JsonSerializerDefaults.Web)), cancellationToken).ConfigureAwait(false);
    }
}
