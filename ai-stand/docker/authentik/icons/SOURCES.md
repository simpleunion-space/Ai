# Verified upstream icon sources

Assets are served only from the local Authentik icon path. Their sources are
recorded here so a refresh is explicit and can be verified before an icon is
replaced.

| Local file | Official source | SHA-256 of fetched upstream asset |
| --- | --- | --- |
| `agentgateway.svg` (also used by the Agentgateway MCP OAuth contract) | `https://github.com/agentgateway/agentgateway` official project artwork | `f10b16d30516f12bd4538dd70c9c4d95b54cbd57546774e7e394a9bfbd704aec` |
| `openclaw.png` | `https://raw.githubusercontent.com/openclaw/openclaw/2a6251bafbbdcf79f67453c6b52d31b9093aaeff/docs/assets/openclaw-hero-dark.png` (official "Molty" mascot hero art; pixel-identical to the `-light` variant within the mascot's own bounding box) | `6f9ab876d21dfc80b4a8e683bee32edcaa96691f5eafce9cbbe679bc17a73830` |
| `coder.svg` | `https://raw.githubusercontent.com/coder/coder/d1b0722034b782a449774878d3cccd24a967ea34/site/static/icon/coder.svg` | `73c8ae0b9ffb112b30d5bdabe96c8f47de1cfe7e7e26034c5d425cf8a6c4c654` |
| `gitea.svg` | `https://raw.githubusercontent.com/go-gitea/gitea/main/public/assets/img/logo.svg` (official Gitea source asset) | `ab8b24d9c8863b8961221e3a64e349d7bc8d7a1f2d10ea5b96049ad1740efdba` |

`openclaw.png` is Molty (OpenClaw's own mascot) isolated from the upstream
hero image's "OpenClaw" wordmark and soft background glow onto a transparent
512x512 canvas. The previous `openclaw.svg` (`docs/assets/pixel-lobster.svg`)
was a decorative "pixel lobster terminal theme" doc asset, not the project's
actual mark - OpenClaw's own README confirms Molty as its mascot. The listed
checksum is that of the fetched upstream hero PNG; the local file is a
cropped, padded and upscaled derivative of it, not a byte-for-byte copy.
