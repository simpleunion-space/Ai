using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using AiStand.McpReadonly;

namespace JiraReadonlyMcp;

internal sealed class McpServer
{
    private const string ProtocolVersion = "2025-03-26";
    private static readonly Regex IssueKey = new("^[A-Z][A-Z0-9_]*-[1-9][0-9]*$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex AttachmentId = new("^[1-9][0-9]*$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private readonly JiraApiClient _jira;
    private readonly JiraOptions _options;

    public McpServer(JiraApiClient jira, JiraOptions options)
    {
        _jira = jira;
        _options = options;
    }

    public async Task<JsonObject?> HandleAsync(JsonElement request, CancellationToken cancellationToken)
    {
        if (request.ValueKind != JsonValueKind.Object)
        {
            return McpJson.Error(null, -32600, "Invalid JSON-RPC request");
        }

        var id = request.TryGetProperty("id", out var requestId) ? JsonNode.Parse(requestId.GetRawText()) : null;
        if (!request.TryGetProperty("jsonrpc", out var version) || version.GetString() != "2.0" ||
            !request.TryGetProperty("method", out var methodElement) || methodElement.ValueKind != JsonValueKind.String)
        {
            return McpJson.Error(id, -32600, "Invalid JSON-RPC request");
        }

        var method = methodElement.GetString()!;
        var parameters = request.TryGetProperty("params", out var paramsElement) && paramsElement.ValueKind == JsonValueKind.Object
            ? paramsElement
            : default;

        if (method.StartsWith("notifications/", StringComparison.Ordinal))
        {
            return null;
        }

        try
        {
            return method switch
            {
                "initialize" => McpJson.Result(id, Initialize(parameters)),
                "ping" => McpJson.Result(id, new JsonObject()),
                "tools/list" => McpJson.Result(id, new JsonObject { ["tools"] = Tools() }),
                "tools/call" => McpJson.Result(id, await CallToolAsync(parameters, cancellationToken).ConfigureAwait(false)),
                _ => McpJson.Error(id, -32601, "Method not found"),
            };
        }
        catch (ArgumentException exception)
        {
            return McpJson.Error(id, -32602, exception.Message);
        }
        catch (JiraApiException exception)
        {
            return McpJson.Result(id, ToolError(exception.Message, (int)exception.StatusCode));
        }
        catch (OperationCanceledException)
        {
            return McpJson.Result(id, ToolError("Read-only Jira request was cancelled or timed out", (int)HttpStatusCode.GatewayTimeout));
        }
        catch (Exception)
        {
            return McpJson.Result(id, ToolError("Read-only Jira backend failed", (int)HttpStatusCode.BadGateway));
        }
    }

    private static JsonObject Initialize(JsonElement parameters)
    {
        if (parameters.ValueKind == JsonValueKind.Object && parameters.TryGetProperty("protocolVersion", out var clientVersion) && clientVersion.ValueKind == JsonValueKind.String &&
            clientVersion.GetString() is not ProtocolVersion and not "2024-11-05")
        {
            throw new ArgumentException("Unsupported MCP protocol version");
        }

        return new JsonObject
        {
            ["protocolVersion"] = ProtocolVersion,
            ["capabilities"] = new JsonObject { ["tools"] = new JsonObject() },
            ["serverInfo"] = new JsonObject { ["name"] = "jira-readonly-mcp", ["version"] = "0.1.0" },
            ["instructions"] = "This server only reads Jira Data Center. It never performs Jira write operations.",
        };
    }

    private async Task<JsonObject> CallToolAsync(JsonElement parameters, CancellationToken cancellationToken)
    {
        if (parameters.ValueKind != JsonValueKind.Object || !parameters.TryGetProperty("name", out var nameElement) || nameElement.ValueKind != JsonValueKind.String)
        {
            throw new ArgumentException("tools/call requires a tool name");
        }

        var arguments = parameters.TryGetProperty("arguments", out var argumentsElement) && argumentsElement.ValueKind == JsonValueKind.Object
            ? argumentsElement
            : default;
        JsonNode data = nameElement.GetString() switch
        {
            "jira_search_issues" => await SearchIssuesAsync(arguments, cancellationToken).ConfigureAwait(false),
            "jira_get_issue" => await GetIssueAsync(arguments, cancellationToken).ConfigureAwait(false),
            "jira_list_comments" => await ListCommentsAsync(arguments, cancellationToken).ConfigureAwait(false),
            "jira_list_projects" => await ListProjectsAsync(arguments, cancellationToken).ConfigureAwait(false),
            "jira_get_attachment" => await GetAttachmentAsync(arguments, cancellationToken).ConfigureAwait(false),
            _ => throw new ArgumentException("Unknown read-only Jira tool"),
        };

        return new JsonObject
        {
            ["content"] = new JsonArray
            {
                new JsonObject { ["type"] = "text", ["text"] = data.ToJsonString(JsonSerializerOptions.Web) },
            },
            ["structuredContent"] = data,
        };
    }

    private Task<JsonNode> SearchIssuesAsync(JsonElement args, CancellationToken cancellationToken)
    {
        var jql = RequiredString(args, "jql", 4096);
        var startAt = BoundedInt(args, "start_at", 0, 0, int.MaxValue);
        var maxResults = BoundedInt(args, "max_results", _options.MaxResults, 1, _options.MaxResults);
        var path = $"rest/api/2/search?jql={Uri.EscapeDataString(jql)}&startAt={startAt}&maxResults={maxResults}&fields={Uri.EscapeDataString("summary,status,assignee,reporter,priority,issuetype,project,updated,created,description")}";
        return _jira.GetJsonAsync(path, cancellationToken);
    }

    private Task<JsonNode> GetIssueAsync(JsonElement args, CancellationToken cancellationToken)
    {
        var issueKey = RequiredIssueKey(args);
        return _jira.GetJsonAsync($"rest/api/2/issue/{Uri.EscapeDataString(issueKey)}?fields={Uri.EscapeDataString("summary,status,assignee,reporter,priority,issuetype,project,updated,created,description,attachment")}", cancellationToken);
    }

    private Task<JsonNode> ListCommentsAsync(JsonElement args, CancellationToken cancellationToken)
    {
        var issueKey = RequiredIssueKey(args);
        var startAt = BoundedInt(args, "start_at", 0, 0, int.MaxValue);
        var maxResults = BoundedInt(args, "max_results", _options.MaxResults, 1, _options.MaxResults);
        return _jira.GetJsonAsync($"rest/api/2/issue/{Uri.EscapeDataString(issueKey)}/comment?startAt={startAt}&maxResults={maxResults}", cancellationToken);
    }

    private Task<JsonNode> ListProjectsAsync(JsonElement args, CancellationToken cancellationToken)
    {
        var startAt = BoundedInt(args, "start_at", 0, 0, int.MaxValue);
        var maxResults = BoundedInt(args, "max_results", _options.MaxResults, 1, _options.MaxResults);
        return _jira.GetJsonAsync($"rest/api/2/project/search?startAt={startAt}&maxResults={maxResults}", cancellationToken);
    }

    private Task<JsonNode> GetAttachmentAsync(JsonElement args, CancellationToken cancellationToken)
    {
        var id = RequiredString(args, "attachment_id", 32);
        if (!AttachmentId.IsMatch(id))
        {
            throw new ArgumentException("attachment_id must be a positive numeric Jira attachment ID");
        }
        var includeContent = OptionalBoolean(args, "include_content", false);
        return _jira.GetAttachmentAsync(id, includeContent, cancellationToken);
    }

    private static JsonArray Tools() => new()
    {
        McpJson.Tool("jira_search_issues", "Search Jira issues using JQL. This is read-only.", new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["jql"] = StringSchema("JQL query", 4096),
                ["start_at"] = IntegerSchema("Zero-based result offset", 0),
                ["max_results"] = IntegerSchema("Number of results; limited by server policy", 1),
            },
            ["required"] = new JsonArray("jql"),
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("jira_get_issue", "Read one Jira issue and its metadata. This is read-only.", new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject { ["issue_key"] = StringSchema("Issue key, for example ABC-123", 128) },
            ["required"] = new JsonArray("issue_key"),
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("jira_list_comments", "Read comments of a Jira issue. This is read-only.", new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["issue_key"] = StringSchema("Issue key, for example ABC-123", 128),
                ["start_at"] = IntegerSchema("Zero-based comment offset", 0),
                ["max_results"] = IntegerSchema("Number of comments; limited by server policy", 1),
            },
            ["required"] = new JsonArray("issue_key"),
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("jira_list_projects", "List Jira projects visible to the configured account. This is read-only.", new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["start_at"] = IntegerSchema("Zero-based project offset", 0),
                ["max_results"] = IntegerSchema("Number of projects; limited by server policy", 1),
            },
            ["additionalProperties"] = false,
        }),
        McpJson.Tool("jira_get_attachment", "Read Jira attachment metadata, and optionally bounded attachment content encoded as base64. This is read-only.", new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["attachment_id"] = StringSchema("Numeric Jira attachment ID", 32),
                ["include_content"] = new JsonObject { ["type"] = "boolean", ["default"] = false },
            },
            ["required"] = new JsonArray("attachment_id"),
            ["additionalProperties"] = false,
        }),
    };

    private static JsonObject StringSchema(string description, int maxLength) => new()
    {
        ["type"] = "string",
        ["description"] = description,
        ["maxLength"] = maxLength,
    };

    private static JsonObject IntegerSchema(string description, int minimum) => new()
    {
        ["type"] = "integer",
        ["description"] = description,
        ["minimum"] = minimum,
    };

    private static JsonObject ToolError(string message, int status) => new()
    {
        ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = message } },
        ["isError"] = true,
        ["structuredContent"] = new JsonObject { ["status"] = status, ["message"] = message },
    };

    private static string RequiredIssueKey(JsonElement args)
    {
        var key = RequiredString(args, "issue_key", 128).ToUpperInvariant();
        if (!IssueKey.IsMatch(key))
        {
            throw new ArgumentException("issue_key is not a valid Jira issue key");
        }
        return key;
    }

    private static string RequiredString(JsonElement args, string name, int maximumLength)
    {
        if (args.ValueKind != JsonValueKind.Object || !args.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw new ArgumentException($"{name} is required");
        }
        var stringValue = value.GetString()?.Trim();
        if (string.IsNullOrEmpty(stringValue) || stringValue.Length > maximumLength)
        {
            throw new ArgumentException($"{name} must be a non-empty string of at most {maximumLength} characters");
        }
        return stringValue;
    }

    private static int BoundedInt(JsonElement args, string name, int defaultValue, int minimum, int maximum)
    {
        if (args.ValueKind != JsonValueKind.Object || !args.TryGetProperty(name, out var value))
        {
            return defaultValue;
        }
        if (!value.TryGetInt32(out var intValue) || intValue < minimum || intValue > maximum)
        {
            throw new ArgumentException($"{name} must be an integer from {minimum} to {maximum}");
        }
        return intValue;
    }

    private static bool OptionalBoolean(JsonElement args, string name, bool defaultValue)
    {
        if (args.ValueKind != JsonValueKind.Object || !args.TryGetProperty(name, out var value))
        {
            return defaultValue;
        }
        return value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : throw new ArgumentException($"{name} must be a boolean");
    }
}
