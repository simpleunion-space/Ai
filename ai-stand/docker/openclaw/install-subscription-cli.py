#!/usr/bin/env python3
"""Install reviewed, image-owned native CLI artifacts, never user credentials."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path("/opt/openclaw/subscription-cli")
OPENCLAW_VERSION = "2026.10.2"
OPENCLAW_INTEGRITY = "sha512-FuLLF+WI12ypwQ0r+pcKDcmB+kXus5N4QClaKEnaAn6GN4I1AitkOhwv0GFl2rVKpvuUBDQWIfglHNy6Trv/EQ=="
ARTIFACTS = {
    "codex": {
        "version": "0.162.1",
        "package_version": "0.162.1-linux-x64",
        "url": "https://registry.npmjs.org/@openai/codex/-/codex-0.162.1-linux-x64.tgz",
        "integrity": "sha512-cjK2mdHIfEepZ1lQ1MX3aTQC+8ncIsvnacl/6vI2dIIcfP8/MrhTQ2+qRlkXFNDzJSj1d36quIszP+3/4CUJWQ==",
        "binary": "vendor/x86_64-unknown-linux-musl/bin/codex",
        "sha256": "628e35487d888a28f0427fc37501da529dd3d81fcbad7a2c3421c1e8670d92e1",
        "companions": {
            "vendor/x86_64-unknown-linux-musl/bin/codex-code-mode-host": "ec71830690a7c0024916ee0c99fbdc635bc6e747ff665ea4f03a8389bbcb6b30",
        },
    },
    "claude": {
        "version": "2.1.296",
        "package_version": "2.1.296",
        "url": "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.296.tgz",
        "integrity": "sha512-+m01urgelnI+VJxPaKPEK0wixgq42uZ8PeCaUk5tX/8YoDBvSmC/REVQG2jQfJAr8dxunpjJ600FvLrcj1WWTw==",
        "binary": "claude",
        "sha256": "24972e3bc859fab2b46ed4c1e51f7d6130f06d3bd550811a114640de3370d0de",
        "companions": {},
    },
}


def file_hash(path: Path, algorithm: str = "sha256") -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as source:
        while block := source.read(4 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def verify_archive(path: Path, integrity: str) -> None:
    actual = "sha512-" + base64.b64encode(bytes.fromhex(file_hash(path, "sha512"))).decode()
    if actual != integrity:
        raise ValueError("Native CLI package integrity mismatch")


def verify_openclaw(path: Path) -> None:
    verify_archive(path, OPENCLAW_INTEGRITY)
    with tarfile.open(path, "r:gz") as archive:
        metadata = json.load(archive.extractfile("package/package.json"))
    if metadata["version"] != OPENCLAW_VERSION:
        raise ValueError("OpenClaw package version mismatch")


def safe_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = archive.getmembers()
    seen: set[str] = set()
    total = 0
    for member in members:
        parts = PurePosixPath(member.name).parts
        if (not parts or parts[0] != "package" or len(parts) < 2 or
                any(part in ("", ".", "..") for part in parts) or
                str(PurePosixPath(member.name)) != member.name or
                "\\" in member.name or member.name in seen or
                not (member.isfile() or member.isdir()) or
                member.mode & 0o7000):
            raise ValueError("Unexpected native CLI archive entry")
        seen.add(member.name)
        total += member.size
        if member.size > 512 * 1024 * 1024 or total > 1024 * 1024 * 1024:
            raise ValueError("Native CLI artifact exceeds reviewed size limits")
    return members


def extract_artifact(archive_path: Path, destination: Path, spec: dict) -> None:
    verify_archive(archive_path, spec["integrity"])
    if destination.is_symlink() or destination.exists():
        raise ValueError("Native CLI installation destination must be new")
    with tarfile.open(archive_path, "r:gz") as archive:
        members = safe_members(archive)
        package_entry = next((m for m in members if m.name == "package/package.json" and m.isfile()), None)
        if package_entry is None:
            raise ValueError("Native CLI package metadata is missing")
        metadata = json.load(archive.extractfile(package_entry))
        if metadata["version"] != spec["package_version"]:
            raise ValueError("Native CLI package version mismatch")
        destination.mkdir(parents=True, mode=0o755)
        # Do not trust tar extraction, symlinks, uid/gid or permissions. Retain
        # all vendor assets/licenses, normalize only image-owned file modes.
        for member in members:
            relative = PurePosixPath(member.name).relative_to("package")
            target = destination.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            if member.isdir():
                target.mkdir(exist_ok=True, mode=0o755)
            else:
                source = archive.extractfile(member)
                assert source is not None
                with target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
    verify_installed(destination, spec)


def verify_installed(destination: Path, spec: dict) -> None:
    for relative, expected in {spec["binary"]: spec["sha256"], **spec["companions"]}.items():
        path = destination / relative
        if path.is_symlink() or not path.is_file() or file_hash(path) != expected:
            raise ValueError("Native CLI binary checksum mismatch")
    with (destination / spec["binary"]).open("rb") as source:
        header = source.read(20)
    if header[:5] != b"\x7fELF\x02" or header[18:20] != b"\x3e\x00":
        raise ValueError("Native CLI artifact is not the reviewed Linux x86_64 executable")


def install(root: Path, cache: Path | None = None) -> None:
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "AMD64"):
        raise ValueError("Pinned subscription CLI artifacts require Linux x86_64")
    root = root.absolute()
    # This root is in the immutable image, never HOME or OPENCLAW_STATE_DIR.
    if root.is_symlink() or (root.exists() and any(root.iterdir())):
        raise ValueError("Subscription CLI image root must be new or empty")
    root.mkdir(parents=True, exist_ok=True, mode=0o755)
    with tempfile.TemporaryDirectory(prefix="ai-stand-cli-") as task_temp:
        for name, spec in ARTIFACTS.items():
            filename = spec["url"].rsplit("/", 1)[-1]
            archive = cache / filename if cache else Path(task_temp) / filename
            if not cache:
                with urllib.request.urlopen(spec["url"], timeout=120) as response, archive.open("xb") as output:
                    downloaded = 0
                    while block := response.read(4 * 1024 * 1024):
                        downloaded += len(block)
                        if downloaded > 256 * 1024 * 1024:
                            raise ValueError("Native CLI download exceeds reviewed size limits")
                        output.write(block)
            destination = root / name / spec["version"]
            extract_artifact(archive, destination, spec)
            version = subprocess.run([str(destination / spec["binary"]), "--version"],
                                     check=True, text=True, capture_output=True, timeout=30).stdout.strip()
            if spec["version"] not in version.split():
                raise ValueError("Installed native CLI reported an unexpected version")
    (root / "artifacts.json").write_text(json.dumps(ARTIFACTS, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--verify-openclaw", type=Path)
    args = parser.parse_args()
    if args.verify_openclaw:
        verify_openclaw(args.verify_openclaw)
        print(f"OPENCLAW_PACKAGE_VERIFIED version={OPENCLAW_VERSION}")
        raise SystemExit(0)
    install(args.root, args.cache)
    print("SUBSCRIPTION_CLI_INSTALL_COMPLETE codex=0.162.1 claude=2.1.296")
