using AiStand.McpReadonly;
using Xunit;

namespace McpReadonly.Common.Tests;

public sealed class ReadOnlyMcpOptionsTests
{
    [Fact]
    public void RejectsUnencryptedUpstream()
    {
        var options = new ReadOnlyMcpOptions { BaseUri = new Uri("http://example.test") };
        Assert.Throws<InvalidOperationException>(() => options.Validate());
    }

    [Fact]
    public void ClampsRequestedPageSize()
    {
        var options = new ReadOnlyMcpOptions { BaseUri = new Uri("https://example.test"), MaximumPageSize = 50 };
        Assert.Equal(50, options.ClampPageSize(500));
    }
}
