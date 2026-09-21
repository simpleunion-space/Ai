using System.Globalization;
using System.Security.Authentication;
using MailKit;
using MailKit.Net.Imap;
using MailKit.Search;
using MimeKit;

namespace AiStand.ImapReadonlyMcp;

public sealed class ImapReadService(
    ImapConnectionFactory connectionFactory,
    ImapOptions options,
    ILogger<ImapReadService> logger) : IImapReadService
{
    public async Task<IReadOnlyList<MailboxInfo>> ListMailboxesAsync(CancellationToken cancellationToken)
    {
        using var client = await connectionFactory.ConnectAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var folders = await client.GetFoldersAsync(client.PersonalNamespaces[0], StatusItems.Count | StatusItems.Unread, false, cancellationToken).ConfigureAwait(false);
            return folders
                .Where(IsAllowedMailbox)
                .Select(folder => new MailboxInfo(folder.FullName, folder.Count, folder.Unread))
                .OrderBy(folder => folder.Name, StringComparer.Ordinal)
                .ToArray();
        }
        catch (Exception exception) when (IsImapReadException(exception))
        {
            logger.LogWarning("IMAP mailbox listing failed: {Reason}", AiStand.McpReadonly.Redaction.Safe(exception.Message));
            throw new McpToolException("Unable to read configured IMAP account");
        }
        finally
        {
            await DisconnectQuietlyAsync(client).ConfigureAwait(false);
        }
    }

    public Task<SearchMessagesResult> SearchMessagesAsync(SearchMessagesRequest request, CancellationToken cancellationToken)
    {
        ValidateMailbox(request.Mailbox);
        if (request.Before is not null && request.Since is not null && request.Before <= request.Since)
        {
            throw new McpToolException("before must be later than since");
        }

        return UseFolderAsync(request.Mailbox, async (folder, token) =>
        {
            var query = BuildQuery(request);
            var matchingUids = await folder.SearchAsync(query, token).ConfigureAwait(false);
            var total = matchingUids.Count;
            var page = request.Page;
            var pageSize = request.PageSize;
            var pageOffset = (long)(page - 1) * pageSize;
            var exclusiveEnd = pageOffset >= total ? 0 : total - (int)pageOffset;
            var start = Math.Max(0, exclusiveEnd - pageSize);
            var selected = matchingUids.Skip(start).Take(exclusiveEnd - start).Reverse().ToArray();
            if (selected.Length == 0)
            {
                return new SearchMessagesResult([], page, pageSize, start > 0);
            }

            var summaries = await folder.FetchAsync(
                selected,
                MessageSummaryItems.Envelope | MessageSummaryItems.Flags | MessageSummaryItems.InternalDate | MessageSummaryItems.Size,
                token).ConfigureAwait(false);
            var indexed = summaries.ToDictionary(summary => summary.UniqueId.Id);
            var messages = selected
                .Where(uid => indexed.ContainsKey(uid.Id))
                .Select(uid => ToSummary(indexed[uid.Id]))
                .ToArray();
            return new SearchMessagesResult(messages, page, pageSize, start > 0);
        }, cancellationToken);
    }

    public Task<MessageDetail> GetMessageAsync(string mailbox, uint uid, CancellationToken cancellationToken)
    {
        ValidateMailbox(mailbox);
        return UseFolderAsync(mailbox, async (folder, token) =>
        {
            var summary = await FetchSingleSummaryAsync(folder, uid, token).ConfigureAwait(false);
            EnsureMessageWithinLimit(summary.Size);
            // MailKit's GetMessageAsync read path uses BODY.PEEK and this folder was
            // opened with FolderAccess.ReadOnly (IMAP EXAMINE), so it cannot set \Seen.
            var message = await folder.GetMessageAsync(new UniqueId(uid), token).ConfigureAwait(false);
            var (text, textTruncated) = TruncateUtf8(message.TextBody, options.MaxBodyBytes);
            var (html, htmlTruncated) = TruncateUtf8(message.HtmlBody, options.MaxBodyBytes);
            return new MessageDetail(ToSummary(summary), text, html, textTruncated || htmlTruncated);
        }, cancellationToken);
    }

    public Task<IReadOnlyList<AttachmentInfo>> ListAttachmentsAsync(string mailbox, uint uid, CancellationToken cancellationToken)
    {
        ValidateMailbox(mailbox);
        return UseFolderAsync<IReadOnlyList<AttachmentInfo>>(mailbox, async (folder, token) =>
        {
            var message = await GetBoundedMessageAsync(folder, uid, token).ConfigureAwait(false);
            return GetAttachments(message).Select((part, index) => ToAttachmentInfo(part, index)).ToArray();
        }, cancellationToken);
    }

    public Task<AttachmentContent> GetAttachmentAsync(string mailbox, uint uid, int index, CancellationToken cancellationToken)
    {
        ValidateMailbox(mailbox);
        if (index < 0 || index > 1000)
        {
            throw new McpToolException("attachmentIndex is invalid");
        }

        return UseFolderAsync(mailbox, async (folder, token) =>
        {
            var message = await GetBoundedMessageAsync(folder, uid, token).ConfigureAwait(false);
            var attachments = GetAttachments(message).ToArray();
            if (index >= attachments.Length)
            {
                throw new McpToolException("Attachment was not found");
            }

            var attachment = attachments[index];
            var declaredSize = attachment.ContentDisposition?.Size;
            if (declaredSize is > 0 && declaredSize > options.MaxAttachmentBytes)
            {
                throw new McpToolException("Attachment exceeds configured size limit");
            }

            await using var decoded = new MemoryStream();
            var content = attachment.Content ?? throw new McpToolException("Attachment content is unavailable");
            await content.DecodeToAsync(decoded, token).ConfigureAwait(false);
            if (decoded.Length > options.MaxAttachmentBytes)
            {
                throw new McpToolException("Attachment exceeds configured size limit");
            }

            return new AttachmentContent(ToAttachmentInfo(attachment, index), Convert.ToBase64String(decoded.ToArray()));
        }, cancellationToken);
    }

    private async Task<MimeMessage> GetBoundedMessageAsync(IMailFolder folder, uint uid, CancellationToken cancellationToken)
    {
        var summary = await FetchSingleSummaryAsync(folder, uid, cancellationToken).ConfigureAwait(false);
        EnsureMessageWithinLimit(summary.Size);
        return await folder.GetMessageAsync(new UniqueId(uid), cancellationToken).ConfigureAwait(false);
    }

    private async Task<IMessageSummary> FetchSingleSummaryAsync(IMailFolder folder, uint uid, CancellationToken cancellationToken)
    {
        var summaries = await folder.FetchAsync(
            [new UniqueId(uid)],
            MessageSummaryItems.Envelope | MessageSummaryItems.Flags | MessageSummaryItems.InternalDate | MessageSummaryItems.Size,
            cancellationToken).ConfigureAwait(false);
        return summaries.SingleOrDefault() ?? throw new McpToolException("Message was not found");
    }

    private async Task<T> UseFolderAsync<T>(string mailbox, Func<IMailFolder, CancellationToken, Task<T>> action, CancellationToken cancellationToken)
    {
        using var client = await connectionFactory.ConnectAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var folder = client.GetFolder(mailbox);
            // This is the only folder-open call in the module. ReadOnly maps to
            // IMAP EXAMINE and prevents every message-state mutation server-side.
            await folder.OpenAsync(FolderAccess.ReadOnly, cancellationToken).ConfigureAwait(false);
            return await action(folder, cancellationToken).ConfigureAwait(false);
        }
        catch (McpToolException)
        {
            throw;
        }
        catch (Exception exception) when (IsImapReadException(exception))
        {
            logger.LogWarning("IMAP read operation failed: {Reason}", AiStand.McpReadonly.Redaction.Safe(exception.Message));
            throw new McpToolException("Unable to read the requested IMAP data");
        }
        finally
        {
            await DisconnectQuietlyAsync(client).ConfigureAwait(false);
        }
    }

    private void ValidateMailbox(string mailbox)
    {
        InputValidation.EnsureMailboxSyntax(mailbox);
        if (!IsAllowedMailbox(mailbox))
        {
            throw new McpToolException("Mailbox is not allowed");
        }
    }

    private bool IsAllowedMailbox(IMailFolder folder) => IsAllowedMailbox(folder.FullName);

    private bool IsAllowedMailbox(string mailbox) => options.AllowedMailboxes.Count == 0 || options.AllowedMailboxes.Contains(mailbox);

    private void EnsureMessageWithinLimit(long? size)
    {
        if (size is > 0 && size > options.MaxMessageBytes)
        {
            throw new McpToolException("Message exceeds configured size limit");
        }
    }

    private static SearchQuery BuildQuery(SearchMessagesRequest request)
    {
        var query = SearchQuery.All;
        if (request.Subject is not null)
        {
            query = query.And(SearchQuery.SubjectContains(request.Subject));
        }
        if (request.From is not null)
        {
            query = query.And(SearchQuery.FromContains(request.From));
        }
        if (request.To is not null)
        {
            query = query.And(SearchQuery.ToContains(request.To));
        }
        if (request.Text is not null)
        {
            query = query.And(SearchQuery.BodyContains(request.Text));
        }
        if (request.Since is not null)
        {
            query = query.And(SearchQuery.DeliveredAfter(request.Since.Value.UtcDateTime));
        }
        if (request.Before is not null)
        {
            query = query.And(SearchQuery.DeliveredBefore(request.Before.Value.UtcDateTime));
        }
        if (request.UnreadOnly)
        {
            query = query.And(SearchQuery.NotSeen);
        }
        return query;
    }

    private static MessageSummary ToSummary(IMessageSummary summary)
    {
        var envelope = summary.Envelope;
        return new MessageSummary(
            summary.UniqueId.Id,
            TruncateHeader(envelope?.Subject),
            TruncateHeader(envelope?.From?.ToString()),
            TruncateHeader(envelope?.To?.ToString()),
            summary.InternalDate,
            summary.Size,
            summary.Flags?.HasFlag(MessageFlags.Seen) == true);
    }

    private static IEnumerable<MimePart> GetAttachments(MimeMessage message) => message.Attachments.OfType<MimePart>();

    private static AttachmentInfo ToAttachmentInfo(MimePart part, int index) => new(
        index,
        TruncateHeader(part.FileName) ?? $"attachment-{index.ToString(CultureInfo.InvariantCulture)}",
        part.ContentType.MimeType,
        part.ContentDisposition?.Size);

    private static string? TruncateHeader(string? value) => value is null ? null : value.Length <= 1024 ? value : value[..1024];

    private static (string? Value, bool Truncated) TruncateUtf8(string? value, int maxBytes)
    {
        if (value is null)
        {
            return (null, false);
        }
        if (System.Text.Encoding.UTF8.GetByteCount(value) <= maxBytes)
        {
            return (value, false);
        }

        var length = value.Length;
        while (length > 0 && System.Text.Encoding.UTF8.GetByteCount(value.AsSpan(0, length)) > maxBytes)
        {
            length--;
        }
        if (length > 0 && char.IsHighSurrogate(value[length - 1]))
        {
            length--;
        }
        return (value[..length], true);
    }

    private static async Task DisconnectQuietlyAsync(ImapClient client)
    {
        if (!client.IsConnected)
        {
            return;
        }
        try
        {
            await client.DisconnectAsync(true).ConfigureAwait(false);
        }
        catch
        {
            // The request result is already known; a failed IMAP LOGOUT must not
            // expose transport details or replace it.
        }
    }

    private static bool IsImapReadException(Exception exception) => exception is
        IOException or AuthenticationException or ServiceNotConnectedException or ServiceNotAuthenticatedException or
        FolderNotFoundException or MessageNotFoundException or CommandException or ProtocolException;
}
