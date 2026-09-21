using System.Security.Cryptography;
using AiStand.ImapReadonlyMcp;

namespace ImapReadonlyMcp.Tests;

public sealed class TokenStateStoreTests : IDisposable
{
    private readonly string _temporaryDirectory = Path.Combine(Path.GetTempPath(), $"imap-readonly-mcp-token-{Guid.NewGuid():N}");

    [Fact]
    public void PersistsRotatedRefreshTokenEncryptedAndReadsItAfterRestart()
    {
        Directory.CreateDirectory(_temporaryDirectory);
        var keyFile = WriteFile(Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)));
        var options = new OAuthOptions(new Uri("https://login.example.test/token"), "client", "secret", null, ImapAuthenticationMode.OAuthRefreshToken, "initial-refresh-token", _temporaryDirectory, keyFile);
        var first = new TokenStateStore(options);

        Assert.Equal("initial-refresh-token", first.ReadRefreshToken());
        first.WriteRotatedRefreshToken("rotated-refresh-token");

        var stateFile = Path.Combine(_temporaryDirectory, "imap-oauth-refresh.v1");
        Assert.DoesNotContain("rotated-refresh-token", File.ReadAllText(stateFile));
        Assert.Equal("rotated-refresh-token", new TokenStateStore(options).ReadRefreshToken());
    }

    public void Dispose()
    {
        if (Directory.Exists(_temporaryDirectory))
        {
            Directory.Delete(_temporaryDirectory, true);
        }
    }

    private string WriteFile(string value)
    {
        var file = Path.Combine(_temporaryDirectory, $"{Guid.NewGuid():N}.secret");
        File.WriteAllText(file, value);
        return file;
    }
}
