using System.Text;
using AiStand.ImapReadonlyMcp;
using Microsoft.AspNetCore.Http;

namespace ImapReadonlyMcp.Tests;

public sealed class InternalBearerAuthenticatorTests : IDisposable
{
    private readonly string _temporaryDirectory = Path.Combine(Path.GetTempPath(), $"imap-readonly-mcp-{Guid.NewGuid():N}");

    [Fact]
    public void AuthorizesOnlyExactBearerValue()
    {
        Directory.CreateDirectory(_temporaryDirectory);
        var secretFile = Path.Combine(_temporaryDirectory, "internal-token");
        File.WriteAllText(secretFile, "expected-token\n", Encoding.UTF8);
        var authenticator = new InternalBearerAuthenticator(CreateOptions(secretFile));

        Assert.True(authenticator.IsAuthorized(CreateRequest("Bearer expected-token")));
        Assert.False(authenticator.IsAuthorized(CreateRequest("Bearer unexpected-token")));
        Assert.False(authenticator.IsAuthorized(CreateRequest("Basic expected-token")));
        Assert.False(authenticator.IsAuthorized(CreateRequest(null)));
    }

    [Fact]
    public void ConfigurationRequiresInternalBearerSecretPath()
    {
        Directory.CreateDirectory(_temporaryDirectory);
        var credentialFile = Path.Combine(_temporaryDirectory, "credential.json");
        File.WriteAllText(credentialFile, """{"username":"reader@example.test","password":"password"}""");
        var values = new Dictionary<string, string?>
        {
            ["IMAP_HOST"] = "mail.example.test",
            ["IMAP_CREDENTIAL_SECRET_FILE"] = credentialFile,
        };

        Assert.Throws<ConfigurationException>(() => ImapOptions.FromEnvironment(name => values.TryGetValue(name, out var value) ? value : null));
    }

    public void Dispose()
    {
        if (Directory.Exists(_temporaryDirectory))
        {
            Directory.Delete(_temporaryDirectory, true);
        }
    }

    private static HttpRequest CreateRequest(string? authorization)
    {
        var context = new DefaultHttpContext();
        if (authorization is not null)
        {
            context.Request.Headers.Authorization = authorization;
        }
        return context.Request;
    }

    private static ImapOptions CreateOptions(string tokenFile) => new(
        "mail.example.test", 993, ImapTlsMode.Implicit, ImapAuthenticationMode.Basic,
        new ImapCredentialSecret("reader", "password", null, null, null, null, null, null), tokenFile, null,
        new HashSet<string>(StringComparer.Ordinal) { "INBOX" }, 10, 1024, 4096, 1024, 60);
}
