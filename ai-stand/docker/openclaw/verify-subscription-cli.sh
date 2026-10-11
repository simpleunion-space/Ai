#!/bin/sh
# No CLI session or inference is started; these probes expose versions only.
set -eu
codex_bin=/opt/openclaw/subscription-cli/codex/0.162.1/vendor/x86_64-unknown-linux-musl/bin/codex
claude_bin=/opt/openclaw/subscription-cli/claude/2.1.296/claude
[ "${OPENCLAW_CODEX_APP_SERVER_BIN:-}" = "$codex_bin" ] || {
    printf '%s\n' '[openclaw] configured Codex runtime is not the pinned image artifact' >&2
    exit 1
}
[ "$(command -v claude)" = /usr/local/bin/claude ] \
    && [ "$(readlink -f /usr/local/bin/claude)" = "$claude_bin" ] || {
    printf '%s\n' '[openclaw] Claude command would select an unpinned runtime' >&2
    exit 1
}
for cli_bin in "$codex_bin" "${codex_bin%/*}/codex-code-mode-host" "$claude_bin"; do
    [ -f "$cli_bin" ] && [ ! -L "$cli_bin" ] \
        && [ "$(stat -c '%u:%g:%a' "$cli_bin")" = 0:0:755 ] || {
        printf '%s\n' '[openclaw] native CLI ownership or mode is unsafe' >&2
        exit 1
    }
done
printf '%s\n' \
    '628e35487d888a28f0427fc37501da529dd3d81fcbad7a2c3421c1e8670d92e1  /opt/openclaw/subscription-cli/codex/0.162.1/vendor/x86_64-unknown-linux-musl/bin/codex' \
    'ec71830690a7c0024916ee0c99fbdc635bc6e747ff665ea4f03a8389bbcb6b30  /opt/openclaw/subscription-cli/codex/0.162.1/vendor/x86_64-unknown-linux-musl/bin/codex-code-mode-host' \
    '24972e3bc859fab2b46ed4c1e51f7d6130f06d3bd550811a114640de3370d0de  /opt/openclaw/subscription-cli/claude/2.1.296/claude' \
    | sha256sum --check --status
[ "$("$codex_bin" --version)" = 'codex-cli 0.162.1' ] || {
    printf '%s\n' '[openclaw] native Codex version mismatch' >&2; exit 1
}
[ "$("$claude_bin" --version)" = '2.1.296 (Claude Code)' ] || {
    printf '%s\n' '[openclaw] native Claude version mismatch' >&2; exit 1
}
[ "${DISABLE_AUTOUPDATER:-}" = 1 ] || {
    printf '%s\n' '[openclaw] native Claude updater must be disabled' >&2; exit 1
}
printf '%s\n' '[openclaw] Verified immutable native CLI versions: Codex 0.162.1; Claude 2.1.296'
