namespace AiStand.ImapReadonlyMcp;

public sealed record MailboxInfo(string Name, int? MessageCount, int? UnreadCount);

public sealed record MessageSummary(
    uint Uid,
    string? Subject,
    string? From,
    string? To,
    DateTimeOffset? Date,
    long? Size,
    bool Seen);

public sealed record SearchMessagesRequest(
    string Mailbox,
    string? Subject,
    string? From,
    string? To,
    string? Text,
    DateTimeOffset? Since,
    DateTimeOffset? Before,
    bool UnreadOnly,
    int Page,
    int PageSize);

public sealed record SearchMessagesResult(IReadOnlyList<MessageSummary> Messages, int Page, int PageSize, bool HasMore);

public sealed record MessageDetail(
    MessageSummary Summary,
    string? TextBody,
    string? HtmlBody,
    bool BodyTruncated);

public sealed record AttachmentInfo(int Index, string FileName, string ContentType, long? Size);

public sealed record AttachmentContent(AttachmentInfo Metadata, string Base64Content);

public interface IImapReadService
{
    Task<IReadOnlyList<MailboxInfo>> ListMailboxesAsync(CancellationToken cancellationToken);

    Task<SearchMessagesResult> SearchMessagesAsync(SearchMessagesRequest request, CancellationToken cancellationToken);

    Task<MessageDetail> GetMessageAsync(string mailbox, uint uid, CancellationToken cancellationToken);

    Task<IReadOnlyList<AttachmentInfo>> ListAttachmentsAsync(string mailbox, uint uid, CancellationToken cancellationToken);

    Task<AttachmentContent> GetAttachmentAsync(string mailbox, uint uid, int index, CancellationToken cancellationToken);
}
