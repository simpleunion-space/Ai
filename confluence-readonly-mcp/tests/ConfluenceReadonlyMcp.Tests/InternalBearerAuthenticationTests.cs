using AiStand.ConfluenceReadonlyMcp;
using Xunit;

namespace ConfluenceReadonlyMcp.Tests;

public sealed class InternalBearerAuthenticationTests
{
    [Fact]
    public void OnlyTheConfiguredBearerTokenIsAccepted()
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "backend-secret");
            var authentication = new InternalBearerAuthentication(path);

            Assert.True(authentication.IsAuthorized("Bearer backend-secret"));
            Assert.False(authentication.IsAuthorized(null));
            Assert.False(authentication.IsAuthorized("Basic backend-secret"));
            Assert.False(authentication.IsAuthorized("Bearer another-secret"));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
