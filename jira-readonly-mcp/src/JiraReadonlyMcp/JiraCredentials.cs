using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace JiraReadonlyMcp;

internal sealed class JiraCredentials
{
    public string? Username { get; init; }
    public string? Password { get; init; }
    public string? Token { get; init; }
    public string? ClientId { get; init; }
    public string? ClientSecret { get; init; }
    public string? RefreshToken { get; init; }

    public static JiraCredentials Load(JiraOptions options)
    {
        var content = File.ReadAllText(options.CredentialSecretFile, Encoding.UTF8);
        using var document = JsonDocument.Parse(content);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidOperationException("JIRA credential secret must be a JSON object");
        }

        string? Read(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()?.Trim()
            : null;

        var credentials = new JiraCredentials
        {
            Username = Read("username"),
            Password = Read("password"),
            // Vault's fixed record contract intentionally calls this field
            // `pat`.  Keep the legacy `token` spelling as a migration-only
            // fallback so an existing installation can rotate its secret
            // without an outage; a renderer created by ai-stand only emits
            // the documented `pat` shape.
            Token = Read("pat") ?? Read("token"),
            ClientId = Read("client_id"),
            ClientSecret = Read("client_secret"),
            RefreshToken = Read("refresh_token"),
        };
        credentials.Validate(options.AuthMode);
        return credentials;
    }

    public void Validate(JiraAuthMode mode)
    {
        static bool Missing(string? value) => string.IsNullOrWhiteSpace(value);
        var valid = mode switch
        {
            JiraAuthMode.Basic => !Missing(Username) && !Missing(Password),
            JiraAuthMode.Pat => !Missing(Token),
            JiraAuthMode.OAuthClientCredentials => !Missing(ClientId) && !Missing(ClientSecret),
            JiraAuthMode.OAuthRefreshToken => !Missing(ClientId) && !Missing(ClientSecret) && !Missing(RefreshToken),
            _ => false,
        };
        if (!valid)
        {
            throw new InvalidOperationException($"JIRA credential secret does not contain required fields for {mode}");
        }
    }

    public AuthenticationHeaderValue BasicHeader() => new(
        "Basic",
        Convert.ToBase64String(Encoding.UTF8.GetBytes($"{Username}:{Password}")));
}
