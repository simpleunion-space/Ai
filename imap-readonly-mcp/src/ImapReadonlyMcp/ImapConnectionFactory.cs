using System.Net;
using System.Security.Authentication;
using MailKit;
using MailKit.Net.Imap;
using MailKit.Security;

namespace AiStand.ImapReadonlyMcp;

public sealed class ImapConnectionFactory(
    ImapOptions options,
    IImapCredentialProvider credentials,
    ILogger<ImapConnectionFactory> logger)
{
    public async Task<ImapClient> ConnectAsync(CancellationToken cancellationToken)
    {
        var client = new ImapClient
        {
            Timeout = checked(options.RequestTimeoutSeconds * 1000),
            ServerCertificateValidationCallback = static (_, _, _, errors) => errors == System.Net.Security.SslPolicyErrors.None,
        };
        try
        {
            var secureSocketOptions = options.TlsMode == ImapTlsMode.Implicit
                ? SecureSocketOptions.SslOnConnect
                : SecureSocketOptions.StartTls;
            await client.ConnectAsync(options.Host, options.Port, secureSocketOptions, cancellationToken).ConfigureAwait(false);
            if (!client.IsSecure)
            {
                throw new McpToolException("IMAP server did not establish TLS");
            }

            var credential = await credentials.GetCredentialAsync(cancellationToken).ConfigureAwait(false);
            var sasl = credential.CreateSaslMechanism();
            if (sasl is not null)
            {
                await client.AuthenticateAsync(sasl, cancellationToken).ConfigureAwait(false);
            }
            else
            {
                await client.AuthenticateAsync(new NetworkCredential(options.Credentials.Username, credential.Password), cancellationToken).ConfigureAwait(false);
            }

            return client;
        }
        catch (McpToolException)
        {
            client.Dispose();
            throw;
        }
        catch (Exception exception) when (exception is IOException or System.Security.Authentication.AuthenticationException or MailKit.Security.AuthenticationException or ServiceNotConnectedException or ServiceNotAuthenticatedException or ProtocolException)
        {
            client.Dispose();
            logger.LogWarning("IMAP connection or authentication failed: {Reason}", AiStand.McpReadonly.Redaction.Safe(exception.Message));
            throw new McpToolException("IMAP service is unavailable or rejected the configured account");
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }
}
