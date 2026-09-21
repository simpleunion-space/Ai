using AiStand.ImapReadonlyMcp;

namespace ImapReadonlyMcp.Tests;

public sealed class ConfigurationTests : IDisposable
{
    private readonly string _temporaryDirectory = Path.Combine(Path.GetTempPath(), $"imap-readonly-options-{Guid.NewGuid():N}");

    [Fact]
    public void ReadsTlsOnlyBasicConfigurationFromOneCredentialSecret()
    {
        var options = ImapOptions.FromEnvironment(CreateEnvironment("basic", """{"username":"reader@example.test","password":"not-logged"}""", new Dictionary<string, string?>
        {
            ["IMAP_ALLOWED_MAILBOXES"] = "INBOX,Archive",
            ["IMAP_MAX_RESULTS"] = "25",
        }));

        Assert.Equal("mail.example.test", options.Host);
        Assert.Equal(ImapTlsMode.Implicit, options.TlsMode);
        Assert.Equal(ImapAuthenticationMode.Basic, options.AuthenticationMode);
        Assert.Equal("reader@example.test", options.Credentials.Username);
        Assert.Contains("INBOX", options.AllowedMailboxes);
        Assert.Equal(25, options.MaxPageSize);
    }

    [Theory]
    [InlineData("none")]
    [InlineData("plain")]
    [InlineData("opportunistic")]
    public void RejectsNonTlsModes(string tlsMode)
    {
        var environment = CreateEnvironment("basic", """{"username":"reader","password":"secret"}""", new Dictionary<string, string?> { ["IMAP_TLS_MODE"] = tlsMode });

        Assert.Throws<ConfigurationException>(() => ImapOptions.FromEnvironment(environment));
    }

    [Fact]
    public void RejectsUrlAsImapHost()
    {
        var environment = CreateEnvironment("basic", """{"username":"reader","password":"secret"}""", new Dictionary<string, string?> { ["IMAP_HOST"] = "imap://mail.example.test/path" });

        Assert.Throws<ConfigurationException>(() => ImapOptions.FromEnvironment(environment));
    }

    [Fact]
    public void SupportsOAuthClientCredentialsFromOneCredentialSecret()
    {
        var options = ImapOptions.FromEnvironment(CreateEnvironment("oauth-client-credentials", """
        {"username":"reader@example.test","token_url":"https://login.example.test/token","client_id":"imap-service","client_secret":"not-logged","scope":"imap.read"}
        """));

        Assert.Equal(ImapAuthenticationMode.OAuthClientCredentials, options.AuthenticationMode);
        Assert.Equal("https", options.OAuth!.TokenEndpoint.Scheme);
        Assert.Equal("imap.read", options.OAuth.Scope);
    }

    [Fact]
    public void SupportsPreissuedOAuthTokenFromCredentialSecret()
    {
        var options = ImapOptions.FromEnvironment(CreateEnvironment("oauth-client-credentials", """{"username":"reader@example.test","token":"preissued-access-token"}"""));

        Assert.Equal(ImapAuthenticationMode.OAuthClientCredentials, options.AuthenticationMode);
        Assert.Equal("preissued-access-token", options.Credentials.AccessToken);
        Assert.Null(options.OAuth);
    }

    [Fact]
    public void SupportsOAuthRefreshTokenStateWithRendererKeyName()
    {
        var options = ImapOptions.FromEnvironment(CreateEnvironment("oauth-refresh-token", """
        {"username":"reader@example.test","token_url":"https://login.example.test/token","client_id":"imap-service","client_secret":"not-logged","refresh_token":"initial-token"}
        """, new Dictionary<string, string?>
        {
            ["IMAP_TOKEN_STATE_DIR"] = _temporaryDirectory,
            ["IMAP_TOKEN_STATE_KEY_FILE"] = "/run/secrets/state-key",
        }));

        Assert.Equal(ImapAuthenticationMode.OAuthRefreshToken, options.AuthenticationMode);
        Assert.Equal("/run/secrets/state-key", options.OAuth!.TokenStateKeyFile);
        Assert.Equal("initial-token", options.OAuth.InitialRefreshToken);
    }

    [Fact]
    public void SupportsLegacyTokenStateKeyAlias()
    {
        var options = ImapOptions.FromEnvironment(CreateEnvironment("oauth-refresh-token", """
        {"username":"reader@example.test","token_url":"https://login.example.test/token","client_id":"imap-service","client_secret":"not-logged","refresh_token":"initial-token"}
        """, new Dictionary<string, string?>
        {
            ["IMAP_TOKEN_STATE_DIR"] = _temporaryDirectory,
            ["IMAP_TOKEN_PROTECTION_KEY_FILE"] = "/run/secrets/legacy-state-key",
        }));

        Assert.Equal("/run/secrets/legacy-state-key", options.OAuth!.TokenStateKeyFile);
    }

    [Fact]
    public void RejectsUnexpectedCredentialJsonProperty()
    {
        var environment = CreateEnvironment("basic", """{"username":"reader","password":"secret","host":"attacker.example"}""");

        Assert.Throws<ConfigurationException>(() => ImapOptions.FromEnvironment(environment));
    }

    public void Dispose()
    {
        if (Directory.Exists(_temporaryDirectory))
        {
            Directory.Delete(_temporaryDirectory, true);
        }
    }

    private Func<string, string?> CreateEnvironment(string authMode, string credentialJson, IReadOnlyDictionary<string, string?>? overrides = null)
    {
        Directory.CreateDirectory(_temporaryDirectory);
        var credentialFile = Path.Combine(_temporaryDirectory, $"credential-{Guid.NewGuid():N}.json");
        File.WriteAllText(credentialFile, credentialJson);
        var values = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["IMAP_HOST"] = "mail.example.test",
            ["IMAP_AUTH_MODE"] = authMode,
            ["IMAP_CREDENTIAL_SECRET_FILE"] = credentialFile,
            ["MCP_INTERNAL_TOKEN_FILE"] = "/run/secrets/mcp-internal-token",
        };
        if (overrides is not null)
        {
            foreach (var pair in overrides)
            {
                values[pair.Key] = pair.Value;
            }
        }
        return name => values.TryGetValue(name, out var value) ? value : null;
    }
}
