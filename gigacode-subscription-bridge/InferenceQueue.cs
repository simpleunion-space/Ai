using System.Threading.Channels;

namespace AiStand.GigacodeBridge;

internal sealed class QueueFullException : Exception
{
    public QueueFullException() : base("The GigaCode inference queue is full") { }
}

internal sealed class InferenceQueue : BackgroundService
{
    private readonly Channel<WorkItem> _requests;
    private readonly int _parallelism;
    private int _queued;

    public InferenceQueue(IConfiguration configuration)
    {
        _parallelism = PositiveInteger(configuration, "GIGACODE_MAX_CONCURRENT_REQUESTS", 2);
        var capacity = PositiveInteger(configuration, "GIGACODE_MAX_QUEUED_REQUESTS", 10);
        _requests = Channel.CreateBounded<WorkItem>(new BoundedChannelOptions(capacity)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = false,
            SingleWriter = false,
        });
    }

    public int QueuedCount => Volatile.Read(ref _queued);

    public async Task<T> EnqueueAsync<T>(Func<CancellationToken, Task<T>> operation, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var item = new WorkItem(
            async token => await operation(token).ConfigureAwait(false),
            completion,
            cancellationToken);

        Interlocked.Increment(ref _queued);
        if (!_requests.Writer.TryWrite(item))
        {
            Interlocked.Decrement(ref _queued);
            throw new QueueFullException();
        }

        using var registration = cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
        var result = await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        return (T)result!;
    }

    protected override Task ExecuteAsync(CancellationToken stoppingToken) =>
        Task.WhenAll(Enumerable.Range(0, _parallelism).Select(_ => WorkerAsync(stoppingToken)));

    private async Task WorkerAsync(CancellationToken stoppingToken)
    {
        await foreach (var item in _requests.Reader.ReadAllAsync(stoppingToken).ConfigureAwait(false))
        {
            Interlocked.Decrement(ref _queued);
            if (item.Completion.Task.IsCompleted)
            {
                continue;
            }

            try
            {
                var result = await item.Operation(item.RequestAborted).ConfigureAwait(false);
                item.Completion.TrySetResult(result);
            }
            catch (OperationCanceledException) when (item.RequestAborted.IsCancellationRequested)
            {
                item.Completion.TrySetCanceled(item.RequestAborted);
            }
            catch (Exception exception)
            {
                item.Completion.TrySetException(exception);
            }
        }
    }

    private static int PositiveInteger(IConfiguration configuration, string name, int defaultValue)
    {
        var raw = configuration[name] ?? defaultValue.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return int.TryParse(raw, out var value) && value > 0
            ? value
            : throw new InvalidOperationException($"{name} must be a positive integer");
    }

    private sealed record WorkItem(
        Func<CancellationToken, Task<object?>> Operation,
        TaskCompletionSource<object?> Completion,
        CancellationToken RequestAborted);
}
