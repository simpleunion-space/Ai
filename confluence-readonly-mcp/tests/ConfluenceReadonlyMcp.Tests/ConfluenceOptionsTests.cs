using AiStand.ConfluenceReadonlyMcp;
using Xunit;

namespace ConfluenceReadonlyMcp.Tests;

public sealed class ConfluenceOptionsTests
{
    [Fact]
    public void ConfigurationRejectsPlainHttpBaseUrl()
    {
        var values = RequiredBasicValues();
        values["CONFLUENCE_BASE_URL"] = "http://confluence.example.test";

        var error = Assert.Throws<InvalidOperationException>(() => Create(values));

        Assert.Contains("HTTPS", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ConfigurationRejectsOAuthTokenUrlWithCredentials()
    {
        var values = new Dictionary<string, string?>
        {
            ["CONFLUENCE_BASE_URL"] = "https://confluence.example.test/wiki",
            ["CONFLUENCE_AUTH_MODE"] = "oauth2_client_credentials",
            ["CONFLUENCE_OAUTH_TOKEN_URL"] = "https://user:password@auth.example.test/token",
            ["CONFLUENCE_OAUTH_CLIENT_ID_FILE"] = "client-id",
            ["CONFLUENCE_OAUTH_CLIENT_SECRET_FILE"] = "client-secret",
            ["MCP_INTERNAL_TOKEN_FILE"] = "backend-token",
        };

        var error = Assert.Throws<InvalidOperationException>(() => Create(values));

        Assert.Contains("HTTPS", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ConfigurationAddsTrailingSlashToContextPath()
    {
        var options = Create(RequiredBasicValues());

        Assert.Equal("https://confluence.example.test/wiki/", options.BaseUri.AbsoluteUri);
        Assert.Equal(25, options.MaxPageSize);
        Assert.Equal(100, options.MaxResults);
    }

    [Fact]
    public void RendererCredentialJsonSupportsPlannedOAuthModeWithoutLegacyFiles()
    {
        var values = new Dictionary<string, string?>
        {
            ["CONFLUENCE_BASE_URL"] = "https://confluence.example.test/wiki",
            ["CONFLUENCE_AUTH_MODE"] = "oauth-client-credentials",
            ["CONFLUENCE_CREDENTIAL_SECRET_FILE"] = "credential-json",
            ["MCP_INTERNAL_TOKEN_FILE"] = "backend-token",
        };
        const string credentialJson = """
            {"client_id":"client","client_secret":"secret","token_url":"https://auth.example.test/oauth/token","scope":"read:confluence"}
            """;

        var options = ConfluenceOptions.From(
            name => values.TryGetValue(name, out var value) ? value : null,
            path => path == "credential-json" ? credentialJson : "internal-token");

        Assert.Equal(ConfluenceAuthMode.OAuth2ClientCredentials, options.AuthMode);
        Assert.Equal("https://auth.example.test/oauth/token", options.OAuthTokenUri!.AbsoluteUri);
        Assert.Equal("client", options.ResolveOAuthClientId());
        Assert.Equal("secret", options.ResolveOAuthClientSecret());
        Assert.Equal("read:confluence", options.OAuthScope);
        Assert.Null(options.OAuthClientIdFile);
        Assert.Null(options.OAuthClientSecretFile);
    }

    private static ConfluenceOptions Create(Dictionary<string, string?> values) => ConfluenceOptions.From(
        name => values.TryGetValue(name, out var value) ? value : null,
        _ => "non-empty-test-secret");

    private static Dictionary<string, string?> RequiredBasicValues() => new()
    {
        ["CONFLUENCE_BASE_URL"] = "https://confluence.example.test/wiki",
        ["CONFLUENCE_AUTH_MODE"] = "basic",
        ["CONFLUENCE_USERNAME_FILE"] = "username",
        ["CONFLUENCE_PASSWORD_FILE"] = "password",
        ["MCP_INTERNAL_TOKEN_FILE"] = "backend-token",
    };
}
