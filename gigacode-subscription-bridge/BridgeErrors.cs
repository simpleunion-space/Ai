using System.Net;

namespace AiStand.GigacodeBridge;

internal static class BridgeErrors
{
    public static (HttpStatusCode Status, string Message, string Type) From(Exception exception) => exception switch
    {
        QueueFullException => (HttpStatusCode.TooManyRequests, "GigaCode inference queue is full", "rate_limit_error"),
        GigacodeUpstreamException upstream => (upstream.StatusCode, upstream.Message, "api_error"),
        OperationCanceledException => (HttpStatusCode.GatewayTimeout, "GigaCode request timed out", "api_error"),
        _ => (HttpStatusCode.BadGateway, "GigaCode upstream request failed", "api_error"),
    };
}
