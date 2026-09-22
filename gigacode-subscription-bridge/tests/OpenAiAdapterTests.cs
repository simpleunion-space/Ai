using System.Text;
using System.Text.Json.Nodes;
using AiStand.GigacodeBridge;
using Xunit;

namespace GigacodeBridge.Tests;

public sealed class OpenAiAdapterTests
{
    [Fact]
    public void ResponsesAdapterPreservesFunctionAndToolOutput()
    {
        var request = JsonNode.Parse("""
            {
              "input": [
                {"role":"user","content":[{"type":"input_text","text":"read a file"}]},
                {"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"README.md\"}"},
                {"type":"function_call_output","call_id":"call_1","output":"contents"}
              ],
              "tools":[{"type":"function","name":"read_file","description":"Read","parameters":{"type":"object"}}],
              "tool_choice":"auto"
            }
            """)!.AsObject();

        var chat = OpenAiAdapter.ToChatCompletion(request, "CodeChat");
        var messages = chat["messages"]!.AsArray();

        Assert.Equal("CodeChat", chat["model"]!.GetValue<string>());
        Assert.Equal("user", messages[0]!["role"]!.GetValue<string>());
        Assert.Equal("assistant", messages[1]!["role"]!.GetValue<string>());
        Assert.Equal("read_file", messages[1]!["tool_calls"]![0]!["function"]!["name"]!.GetValue<string>());
        Assert.Equal("tool", messages[2]!["role"]!.GetValue<string>());
        Assert.Equal("contents", messages[2]!["content"]!.GetValue<string>());
        Assert.Equal("function", chat["tools"]![0]!["type"]!.GetValue<string>());
    }

    [Fact]
    public void ResponsesAdapterIncludesRequiredOutputTextAnnotations()
    {
        var chat = JsonNode.Parse("""
            {"choices":[{"message":{"content":"OK"}}]}
            """)!.AsObject();

        var response = OpenAiAdapter.ToResponsesCompletion(chat, "gigacode/codechat");
        var annotations = response["output"]![0]!["content"]![0]!["annotations"]!.AsArray();

        Assert.Empty(annotations);
    }

    [Fact]
    public async Task StreamingResponsesAdapterEmitsNativeToolCallEvents()
    {
        var upstream = """
            data: {"choices":[{"delta":{"tool_calls":[{"id":"call_7","function":{"name":"pwd","arguments":"{}"}}]}}]}

            data: [DONE]

            """;
        await using var source = new MemoryStream(Encoding.UTF8.GetBytes(upstream));
        await using var destination = new MemoryStream();

        await OpenAiAdapter.WriteResponsesStreamAsync(source, destination, "gigacode/codechat", 10, CancellationToken.None);

        var output = Encoding.UTF8.GetString(destination.ToArray());
        Assert.Contains("response.output_item.added", output, StringComparison.Ordinal);
        Assert.Contains("response.function_call_arguments.delta", output, StringComparison.Ordinal);
        Assert.Contains("\"name\":\"pwd\"", output, StringComparison.Ordinal);
        Assert.Contains("response.completed", output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task StreamingResponsesAdapterAssignsDistinctOutputIndicesToMultipleToolCalls()
    {
        var upstream = """
            data: {"choices":[{"delta":{"content":"I will inspect both paths.","tool_calls":[{"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":\"README.md\"}"}},{"id":"call_2","function":{"name":"list_directory","arguments":"{\"path\":\"docker\"}"}}]}}]}

            data: [DONE]

            """;
        await using var source = new MemoryStream(Encoding.UTF8.GetBytes(upstream));
        await using var destination = new MemoryStream();

        await OpenAiAdapter.WriteResponsesStreamAsync(source, destination, "gigacode/codechat", 10, CancellationToken.None);

        var events = ParseSseEvents(destination);
        var addedIndices = events
            .Where(@event => @event["type"]?.GetValue<string>() == "response.output_item.added")
            .Select(@event => @event["output_index"]!.GetValue<int>())
            .ToArray();
        Assert.Equal(new[] { 0, 1, 2 }, addedIndices);

        var functionIndices = events
            .Where(@event => @event["type"]?.GetValue<string>()?.StartsWith("response.function_call_arguments.", StringComparison.Ordinal) == true)
            .Select(@event => @event["output_index"]!.GetValue<int>())
            .Distinct()
            .Order()
            .ToArray();
        Assert.Equal(new[] { 1, 2 }, functionIndices);

        var completedOutput = events
            .Single(@event => @event["type"]?.GetValue<string>() == "response.completed")["response"]!["output"]!
            .AsArray();
        Assert.Equal(new[] { "message", "function_call", "function_call" }, completedOutput
            .Select(item => item!["type"]!.GetValue<string>())
            .ToArray());
        Assert.Equal(new[] { "call_1", "call_2" }, completedOutput
            .Skip(1)
            .Select(item => item!["call_id"]!.GetValue<string>())
            .ToArray());
    }

    [Fact]
    public async Task StreamingResponsesAdapterCombinesGigaCodeToolCallFragmentsByIndex()
    {
        // GigaCode emits the call id/name first, then emits the argument
        // fragments with only the OpenAI streaming `index` field.
        var upstream = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_pwd","function":{"name":"run_shell","arguments":""}},{"index":1,"id":"call_ls","function":{"name":"run_shell","arguments":""}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"pwd\"}"}},{"index":1,"function":{"arguments":"{\"command\":\"ls -la\"}"}}]}}]}

            data: [DONE]

            """;
        await using var source = new MemoryStream(Encoding.UTF8.GetBytes(upstream));
        await using var destination = new MemoryStream();

        await OpenAiAdapter.WriteResponsesStreamAsync(source, destination, "gigacode/codechat", 10, CancellationToken.None);

        var events = ParseSseEvents(destination);
        var added = events
            .Where(@event => @event["type"]?.GetValue<string>() == "response.output_item.added")
            .ToArray();
        Assert.Equal(2, added.Length);
        Assert.Equal(new[] { "call_pwd", "call_ls" }, added
            .Select(@event => @event["item"]!["call_id"]!.GetValue<string>())
            .ToArray());
        Assert.All(added, @event => Assert.Equal("run_shell", @event["item"]!["name"]!.GetValue<string>()));

        var completedCalls = events
            .Single(@event => @event["type"]?.GetValue<string>() == "response.completed")["response"]!["output"]!
            .AsArray();
        Assert.Equal(2, completedCalls.Count);
        Assert.Equal("{\"command\":\"pwd\"}", completedCalls[0]!["arguments"]!.GetValue<string>());
        Assert.Equal("{\"command\":\"ls -la\"}", completedCalls[1]!["arguments"]!.GetValue<string>());
    }

    private static List<JsonObject> ParseSseEvents(Stream stream)
    {
        stream.Position = 0;
        return new StreamReader(stream, leaveOpen: true)
            .ReadToEnd()
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(line => line.StartsWith("data: ", StringComparison.Ordinal))
            .Select(line => JsonNode.Parse(line[6..])!.AsObject())
            .ToList();
    }
}
