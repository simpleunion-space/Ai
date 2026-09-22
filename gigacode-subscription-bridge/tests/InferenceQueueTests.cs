using AiStand.GigacodeBridge;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace GigacodeBridge.Tests;

public sealed class InferenceQueueTests
{
    [Fact]
    public async Task EnforcesConfiguredTwoPlusTenCapacityAndAllowsCancelledWaiterToBeRemoved()
    {
        var values = new Dictionary<string, string?>
        {
            ["GIGACODE_MAX_CONCURRENT_REQUESTS"] = "2",
            ["GIGACODE_MAX_QUEUED_REQUESTS"] = "10",
        };
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(values).Build();
        var queue = new InferenceQueue(configuration);
        using var shutdown = new CancellationTokenSource();
        await queue.StartAsync(shutdown.Token);

        try
        {
            var bothStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var releaseActive = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var started = 0;
            Task<string> StartActive(string value) => queue.EnqueueAsync(async token =>
            {
                if (Interlocked.Increment(ref started) == 2)
                {
                    bothStarted.SetResult();
                }
                await releaseActive.Task.WaitAsync(token);
                return value;
            }, CancellationToken.None);
            var first = StartActive("first");
            var second = StartActive("second");
            await bothStarted.Task;

            using var queuedCancellation = new CancellationTokenSource();
            var queued = Enumerable.Range(0, 10)
                .Select(index => queue.EnqueueAsync(
                    _ => Task.FromResult($"queued-{index}"),
                    index == 0 ? queuedCancellation.Token : CancellationToken.None))
                .ToArray();
            await Assert.ThrowsAsync<QueueFullException>(() => queue.EnqueueAsync(_ => Task.FromResult("overflow"), CancellationToken.None));

            queuedCancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => queued[0]);
            releaseActive.SetResult();
            Assert.Equal("first", await first);
            Assert.Equal("second", await second);
            Assert.Equal(
                Enumerable.Range(1, 9).Select(index => $"queued-{index}"),
                await Task.WhenAll(queued.Skip(1)));

            await Task.Delay(50);
            Assert.Equal(0, queue.QueuedCount);
        }
        finally
        {
            shutdown.Cancel();
            await queue.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public void QueueOverflowMapsToOpenAi429()
    {
        var error = BridgeErrors.From(new QueueFullException());

        Assert.Equal(System.Net.HttpStatusCode.TooManyRequests, error.Status);
        Assert.Equal("rate_limit_error", error.Type);
    }
}
