using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AiStand.GigacodeBridge;

internal static class OpenAiAdapter
{
    public static JsonObject ToChatCompletion(JsonObject responsesRequest, string upstreamModel)
    {
        var chat = new JsonObject { ["model"] = upstreamModel };
        CopyIfPresent(responsesRequest, chat, "stream", "temperature", "top_p", "seed", "metadata", "parallel_tool_calls", "tool_choice");
        if (responsesRequest["max_output_tokens"] is not null)
        {
            chat["max_tokens"] = responsesRequest["max_output_tokens"]!.DeepClone();
        }

        chat["messages"] = ToChatMessages(responsesRequest["input"]);
        if (responsesRequest["tools"] is JsonArray tools)
        {
            chat["tools"] = ToChatTools(tools);
        }

        return chat;
    }

    public static JsonObject ToResponsesCompletion(JsonObject chatCompletion, string modelAlias)
    {
        var choice = chatCompletion["choices"]?.AsArray().FirstOrDefault()?.AsObject();
        var message = choice?["message"]?.AsObject() ?? new JsonObject();
        var output = new JsonArray();
        var content = message["content"]?.GetValue<string>();
        if (!string.IsNullOrEmpty(content))
        {
            output.Add(new JsonObject
            {
                ["id"] = $"msg_{Guid.NewGuid():N}",
                ["type"] = "message",
                ["status"] = "completed",
                ["role"] = "assistant",
                ["content"] = new JsonArray(new JsonObject
                {
                    ["type"] = "output_text",
                    ["text"] = content,
                    // Agentgateway validates the OpenAI Responses schema
                    // strictly: output_text is incomplete without this
                    // field, even when the provider returned no citations.
                    ["annotations"] = new JsonArray(),
                }),
            });
        }

        if (message["tool_calls"] is JsonArray toolCalls)
        {
            foreach (var call in toolCalls.OfType<JsonObject>())
            {
                var function = call["function"]?.AsObject() ?? new JsonObject();
                var callId = call["id"]?.GetValue<string>() ?? $"call_{Guid.NewGuid():N}";
                output.Add(new JsonObject
                {
                    ["id"] = callId,
                    ["type"] = "function_call",
                    ["status"] = "completed",
                    ["call_id"] = callId,
                    ["name"] = function["name"]?.GetValue<string>() ?? string.Empty,
                    ["arguments"] = function["arguments"]?.GetValue<string>() ?? "{}",
                });
            }
        }

        var usage = chatCompletion["usage"]?.AsObject();
        return new JsonObject
        {
            ["id"] = $"resp_{Guid.NewGuid():N}",
            ["object"] = "response",
            ["created_at"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            ["status"] = "completed",
            ["model"] = modelAlias,
            ["output"] = output,
            ["usage"] = usage is null
                ? null
                : new JsonObject
                {
                    ["input_tokens"] = usage["prompt_tokens"]?.DeepClone() ?? 0,
                    ["output_tokens"] = usage["completion_tokens"]?.DeepClone() ?? 0,
                    ["total_tokens"] = usage["total_tokens"]?.DeepClone() ?? 0,
                },
        };
    }

    public static async Task WriteResponsesStreamAsync(
        Stream upstream,
        Stream destination,
        string modelAlias,
        int idleTimeoutSeconds,
        CancellationToken cancellationToken)
    {
        var responseId = $"resp_{Guid.NewGuid():N}";
        var createdAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        await WriteEventAsync(destination, "response.created", new JsonObject
        {
            ["type"] = "response",
            ["response"] = new JsonObject
            {
                ["id"] = responseId,
                ["object"] = "response",
                ["created_at"] = createdAt,
                ["status"] = "in_progress",
                ["model"] = modelAlias,
                ["output"] = new JsonArray(),
            },
        }, cancellationToken).ConfigureAwait(false);

        using var reader = new StreamReader(upstream, leaveOpen: false);
        string? line;
        var messageId = $"msg_{Guid.NewGuid():N}";
        TextOutputItemState? textItem = null;
        var textBuffer = new StringBuilder();
        // GigaCode follows the OpenAI streaming convention where the first
        // tool-call fragment carries the opaque id and function name, while
        // subsequent argument fragments carry only the numeric `index`.
        // Keeping both lookups prevents those fragments becoming separate
        // Responses output items (one empty call and one nameless call).
        var functionCallsById = new Dictionary<string, FunctionCallState>(StringComparer.Ordinal);
        var functionCallsByIndex = new Dictionary<int, FunctionCallState>();
        var outputItems = new List<OutputItemState>();
        var nextOutputIndex = 0;
        var completed = false;
        while ((line = await ReadLineWithIdleTimeoutAsync(reader, idleTimeoutSeconds, cancellationToken).ConfigureAwait(false)) is not null)
        {
            if (!line.StartsWith("data:", StringComparison.Ordinal))
            {
                continue;
            }

            var payload = line[5..].TrimStart();
            if (payload == "[DONE]")
            {
                completed = true;
                continue;
            }

            JsonObject? chunk;
            try
            {
                chunk = JsonNode.Parse(payload)?.AsObject();
            }
            catch (JsonException)
            {
                throw new GigacodeUpstreamException("GigaCode stream contains invalid JSON");
            }

            var delta = chunk?["choices"]?.AsArray().FirstOrDefault()?["delta"]?.AsObject();
            var textDelta = delta?["content"]?.GetValue<string>();
            if (!string.IsNullOrEmpty(textDelta))
            {
                if (textItem is null)
                {
                    textItem = new TextOutputItemState(messageId, nextOutputIndex++);
                    outputItems.Add(textItem);
                    await WriteEventAsync(destination, "response.output_item.added", new JsonObject
                    {
                        ["type"] = "response.output_item.added",
                        ["response_id"] = responseId,
                        ["output_index"] = textItem.OutputIndex,
                        ["item"] = new JsonObject
                        {
                            ["id"] = textItem.Id,
                            ["type"] = "message",
                            ["status"] = "in_progress",
                            ["role"] = "assistant",
                            ["content"] = new JsonArray(),
                        },
                    }, cancellationToken).ConfigureAwait(false);
                    await WriteEventAsync(destination, "response.content_part.added", new JsonObject
                    {
                        ["type"] = "response.content_part.added",
                        ["response_id"] = responseId,
                        ["item_id"] = textItem.Id,
                        ["output_index"] = textItem.OutputIndex,
                        ["content_index"] = 0,
                        ["part"] = new JsonObject
                        {
                            ["type"] = "output_text",
                            ["text"] = string.Empty,
                            ["annotations"] = new JsonArray(),
                        },
                    }, cancellationToken).ConfigureAwait(false);
                }

                textBuffer.Append(textDelta);
                await WriteEventAsync(destination, "response.output_text.delta", new JsonObject
                {
                    ["type"] = "response.output_text.delta",
                    ["response_id"] = responseId,
                    ["item_id"] = textItem.Id,
                    ["output_index"] = textItem.OutputIndex,
                    ["content_index"] = 0,
                    ["delta"] = textDelta,
                }, cancellationToken).ConfigureAwait(false);
            }

            if (delta?["tool_calls"] is JsonArray toolCalls)
            {
                foreach (var call in toolCalls.OfType<JsonObject>())
                {
                    var callId = call["id"]?.GetValue<string>();
                    var toolIndex = call["index"]?.GetValue<int>();
                    var function = call["function"]?.AsObject();
                    FunctionCallState? state = null;
                    if (!string.IsNullOrEmpty(callId))
                    {
                        functionCallsById.TryGetValue(callId, out state);
                    }

                    if (state is null && toolIndex is not null)
                    {
                        functionCallsByIndex.TryGetValue(toolIndex.Value, out state);
                    }

                    if (state is null)
                    {
                        var outputCallId = callId ?? $"call_{toolIndex ?? outputItems.Count}";
                        state = new FunctionCallState(
                            outputCallId,
                            function?["name"]?.GetValue<string>() ?? string.Empty,
                            nextOutputIndex++);
                        functionCallsById.Add(outputCallId, state);
                        if (toolIndex is not null)
                        {
                            functionCallsByIndex.Add(toolIndex.Value, state);
                        }

                        outputItems.Add(state);
                        await WriteEventAsync(destination, "response.output_item.added", new JsonObject
                        {
                            ["type"] = "response.output_item.added",
                            ["response_id"] = responseId,
                            ["output_index"] = state.OutputIndex,
                            ["item"] = new JsonObject
                            {
                                ["id"] = state.Id,
                                ["type"] = "function_call",
                                ["status"] = "in_progress",
                                ["call_id"] = state.Id,
                                ["name"] = state.Name,
                                ["arguments"] = string.Empty,
                            },
                        }, cancellationToken).ConfigureAwait(false);
                    }
                    else
                    {
                        if (!string.IsNullOrEmpty(callId))
                        {
                            functionCallsById.TryAdd(callId, state);
                        }

                        if (toolIndex is not null)
                        {
                            functionCallsByIndex.TryAdd(toolIndex.Value, state);
                        }
                    }

                    var arguments = function?["arguments"]?.GetValue<string>();
                    if (!string.IsNullOrEmpty(arguments))
                    {
                        state.Arguments.Append(arguments);
                        await WriteEventAsync(destination, "response.function_call_arguments.delta", new JsonObject
                        {
                            ["type"] = "response.function_call_arguments.delta",
                            ["response_id"] = responseId,
                            ["item_id"] = state.Id,
                            ["output_index"] = state.OutputIndex,
                            ["delta"] = arguments,
                        }, cancellationToken).ConfigureAwait(false);
                    }
                }
            }
        }

        if (!completed)
        {
            throw new GigacodeUpstreamException("GigaCode stream ended without [DONE]");
        }

        var completedOutput = new JsonArray();
        foreach (var outputItem in outputItems)
        {
            if (outputItem is TextOutputItemState completedTextItem)
            {
                var completeText = textBuffer.ToString();
                await WriteEventAsync(destination, "response.output_text.done", new JsonObject
                {
                    ["type"] = "response.output_text.done",
                    ["response_id"] = responseId,
                    ["item_id"] = completedTextItem.Id,
                    ["output_index"] = completedTextItem.OutputIndex,
                    ["content_index"] = 0,
                    ["text"] = completeText,
                }, cancellationToken).ConfigureAwait(false);
                await WriteEventAsync(destination, "response.content_part.done", new JsonObject
                {
                    ["type"] = "response.content_part.done",
                    ["response_id"] = responseId,
                    ["item_id"] = completedTextItem.Id,
                    ["output_index"] = completedTextItem.OutputIndex,
                    ["content_index"] = 0,
                    ["part"] = new JsonObject
                    {
                        ["type"] = "output_text",
                        ["text"] = completeText,
                        ["annotations"] = new JsonArray(),
                    },
                }, cancellationToken).ConfigureAwait(false);
                var completedText = new JsonObject
                {
                    ["id"] = completedTextItem.Id,
                    ["type"] = "message",
                    ["status"] = "completed",
                    ["role"] = "assistant",
                    ["content"] = new JsonArray(new JsonObject
                    {
                        ["type"] = "output_text",
                        ["text"] = completeText,
                        ["annotations"] = new JsonArray(),
                    }),
                };
                await WriteEventAsync(destination, "response.output_item.done", new JsonObject
                {
                    ["type"] = "response.output_item.done",
                    ["response_id"] = responseId,
                    ["output_index"] = completedTextItem.OutputIndex,
                    ["item"] = completedText,
                }, cancellationToken).ConfigureAwait(false);
                completedOutput.Add(completedText.DeepClone());
                continue;
            }

            var state = (FunctionCallState)outputItem;
            var completeArguments = state.Arguments.ToString();
            await WriteEventAsync(destination, "response.function_call_arguments.done", new JsonObject
            {
                ["type"] = "response.function_call_arguments.done",
                ["response_id"] = responseId,
                ["item_id"] = state.Id,
                ["output_index"] = state.OutputIndex,
                ["arguments"] = completeArguments,
            }, cancellationToken).ConfigureAwait(false);
            var functionItem = new JsonObject
            {
                ["id"] = state.Id,
                ["type"] = "function_call",
                ["status"] = "completed",
                ["call_id"] = state.Id,
                ["name"] = state.Name,
                ["arguments"] = completeArguments,
            };
            await WriteEventAsync(destination, "response.output_item.done", new JsonObject
            {
                ["type"] = "response.output_item.done",
                ["response_id"] = responseId,
                ["output_index"] = state.OutputIndex,
                ["item"] = functionItem,
            }, cancellationToken).ConfigureAwait(false);
            completedOutput.Add(functionItem.DeepClone());
        }

        await WriteEventAsync(destination, "response.completed", new JsonObject
        {
            ["type"] = "response.completed",
            ["response"] = new JsonObject
            {
                ["id"] = responseId,
                ["object"] = "response",
                ["created_at"] = createdAt,
                ["status"] = "completed",
                ["model"] = modelAlias,
                ["output"] = completedOutput,
            },
        }, cancellationToken).ConfigureAwait(false);
    }

    private abstract class OutputItemState(int outputIndex)
    {
        public int OutputIndex { get; } = outputIndex;
    }

    private sealed class TextOutputItemState(string id, int outputIndex) : OutputItemState(outputIndex)
    {
        public string Id { get; } = id;
    }

    private sealed class FunctionCallState(string id, string name, int outputIndex) : OutputItemState(outputIndex)
    {
        public string Id { get; } = id;
        public string Name { get; } = name;
        public StringBuilder Arguments { get; } = new();
    }

    private static async Task<string?> ReadLineWithIdleTimeoutAsync(
        StreamReader reader,
        int idleTimeoutSeconds,
        CancellationToken cancellationToken)
    {
        using var idleCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        idleCancellation.CancelAfter(TimeSpan.FromSeconds(idleTimeoutSeconds));
        try
        {
            return await reader.ReadLineAsync(idleCancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new GigacodeUpstreamException("GigaCode stream idle timeout", System.Net.HttpStatusCode.GatewayTimeout);
        }
    }

    private static JsonArray ToChatMessages(JsonNode? input)
    {
        var messages = new JsonArray();
        if (input is JsonValue value && value.TryGetValue<string>(out var text))
        {
            messages.Add(new JsonObject { ["role"] = "user", ["content"] = text });
            return messages;
        }

        if (input is not JsonArray items)
        {
            throw new GigacodeUpstreamException("Responses input must be a string or an array", System.Net.HttpStatusCode.BadRequest);
        }

        foreach (var item in items.OfType<JsonObject>())
        {
            if (item["type"]?.GetValue<string>() == "function_call_output")
            {
                messages.Add(new JsonObject
                {
                    ["role"] = "tool",
                    ["tool_call_id"] = item["call_id"]?.DeepClone(),
                    ["content"] = item["output"]?.DeepClone() ?? string.Empty,
                });
                continue;
            }

            if (item["type"]?.GetValue<string>() == "function_call")
            {
                var callId = item["call_id"]?.GetValue<string>()
                    ?? item["id"]?.GetValue<string>()
                    ?? $"call_{Guid.NewGuid():N}";
                messages.Add(new JsonObject
                {
                    ["role"] = "assistant",
                    ["content"] = string.Empty,
                    ["tool_calls"] = new JsonArray(new JsonObject
                    {
                        ["id"] = callId,
                        ["type"] = "function",
                        ["function"] = new JsonObject
                        {
                            ["name"] = item["name"]?.DeepClone() ?? string.Empty,
                            ["arguments"] = item["arguments"]?.DeepClone() ?? "{}",
                        },
                    }),
                });
                continue;
            }

            var role = item["role"]?.GetValue<string>() ?? "user";
            messages.Add(new JsonObject
            {
                ["role"] = role,
                ["content"] = ToChatContent(item["content"]),
            });
        }

        if (messages.Count == 0)
        {
            throw new GigacodeUpstreamException("Responses input cannot be empty", System.Net.HttpStatusCode.BadRequest);
        }

        return messages;
    }

    private static JsonNode ToChatContent(JsonNode? content)
    {
        if (content is not JsonArray parts)
        {
            return content?.DeepClone() ?? string.Empty;
        }

        var result = new JsonArray();
        foreach (var part in parts.OfType<JsonObject>())
        {
            var type = part["type"]?.GetValue<string>();
            switch (type)
            {
                case "input_text":
                case "output_text":
                    result.Add(new JsonObject { ["type"] = "text", ["text"] = part["text"]?.DeepClone() ?? string.Empty });
                    break;
                case "input_image":
                    result.Add(new JsonObject { ["type"] = "image_url", ["image_url"] = part["image_url"]?.DeepClone() ?? new JsonObject() });
                    break;
                default:
                    result.Add(part.DeepClone());
                    break;
            }
        }

        return result;
    }

    private static JsonArray ToChatTools(JsonArray tools)
    {
        var result = new JsonArray();
        foreach (var tool in tools.OfType<JsonObject>())
        {
            if (tool["type"]?.GetValue<string>() == "function" && tool["function"] is null)
            {
                result.Add(new JsonObject
                {
                    ["type"] = "function",
                    ["function"] = new JsonObject
                    {
                        ["name"] = tool["name"]?.DeepClone() ?? string.Empty,
                        ["description"] = tool["description"]?.DeepClone(),
                        ["parameters"] = tool["parameters"]?.DeepClone() ?? new JsonObject(),
                    },
                });
                continue;
            }

            result.Add(tool.DeepClone());
        }

        return result;
    }

    private static void CopyIfPresent(JsonObject source, JsonObject target, params string[] names)
    {
        foreach (var name in names)
        {
            if (source[name] is not null)
            {
                target[name] = source[name]!.DeepClone();
            }
        }
    }

    private static async Task WriteEventAsync(Stream destination, string name, JsonObject payload, CancellationToken cancellationToken)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes($"event: {name}\ndata: {payload.ToJsonString(JsonSerializerOptions.Web)}\n\n");
        await destination.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
    }
}
