#!/usr/bin/env python3
"""Rebase one narrow identity patch onto the exact, sealed OpenClaw release.

Both the standalone SQLite worker and the normal worker chunks contain this
logic. Patch all copies, then rebuild the upstream content-addressed archive;
never disable upstream's archive/worker integrity validation.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

VERSION = "2026.10.2"
ORIGINAL_BUNDLE = "f8f9701f36c625cb4d15680c187fab74b5e3c931c63cdf9b8b8c15f7664528d4"
ORIGINAL_ARCHIVE_SHA256 = "94bb6d51dcad390a8726a8c4a7ceda541be58d79b62806ee4e44bb600f23045a"
TARGET_HASHES = {
    "sqlite-store.worker.mjs": "deab935f33c5fb9076f6efe1e0b5fe3923a72cf808e604ccc3b013053d19db1a",
    "worker-chunk-DRViOBAV.mjs": "8800a2feb1fe8efd47596b1686fb831b5f237380d7844565e9fd576e2437f2fa",
}
HOST_TARGET_HASHES = {
    "http-auth-utils-BvQzAi7A.mjs": "75354ac4667bf5c747acf9dbc80bb60fd95fb6e5489398572bfcb2b6352a7ec0",
}


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise ValueError("Expected exactly one reviewed worker patch snippet")
    return source.replace(before, after, 1)


def display_patch(source: str, *, sqlite: bool) -> str:
    request, profile = ("Ot", "Dn") if sqlite else ("e", "n")
    writer = "setCanonicalUserProfileDisplayName" if sqlite else "aiStandSetDisplayName"
    shared_secret = "usesSharedSecretGatewayMethod"
    before = (
        f"return await prepareHttpProfile(`profileId`in {profile}?{profile}.profileId:{profile}.id,"
        f"{profile}.updatedAt,assertCurrent,{shared_secret}({request}.authResult.method)?void 0:{request}.cfg)"
    )
    # Ignore duplicate/array headers and never derive authorization identity
    # from this display-only value. The trusted ingress overwrites the header.
    header = f"{request}.req.headers[`x-ai-stand-display-name`]"
    label = (
        f"{request}.authResult.method===`trusted-proxy`&&"
        f"typeof {header}===`string`?{header}.trim():void 0"
    )
    # The canonical writer returns {profile}, not the older synchronous profile.
    after = (
        f"let aiStandProfileId=`profileId`in {profile}?{profile}.profileId:{profile}.id,"
        f"aiStandDisplayName={label};"
        f"if(aiStandDisplayName&&/^[A-Za-z0-9._@-]{{1,128}}$/.test(aiStandDisplayName)"
        f"&&{profile}.displayName!==aiStandDisplayName)"
        f"{profile}=(await {writer}(aiStandProfileId,aiStandDisplayName,{{assertCurrent}})).profile;"
        f"return await prepareHttpProfile(aiStandProfileId,{profile}.updatedAt,assertCurrent,"
        f"{shared_secret}({request}.authResult.method)?void 0:{request}.cfg)"
    )
    source = replace_once(source, before, after)
    if not sqlite:
        source = replace_once(
            source,
            'import{i as tt,n as nt,r as rt,t as it}from"./worker-chunk-8fF_aWIw.mjs";',
            'import{c as aiStandSetDisplayName,i as tt,n as nt,r as rt,t as it}from"./worker-chunk-8fF_aWIw.mjs";',
        )
    return source


def patch_sources(files: dict[str, bytes], *, enforce_hashes: bool = True) -> dict[str, bytes]:
    result = dict(files)
    for name, expected in TARGET_HASHES.items():
        if name not in files or (enforce_hashes and hashlib.sha256(files[name]).hexdigest() != expected):
            raise ValueError(f"Reviewed worker module hash mismatch: {name}")
    sqlite = display_patch(files["sqlite-store.worker.mjs"].decode(), sqlite=True)
    result["sqlite-store.worker.mjs"] = sqlite.encode()
    result["worker-chunk-DRViOBAV.mjs"] = display_patch(files["worker-chunk-DRViOBAV.mjs"].decode(), sqlite=False).encode()
    return result


def patch_host_sources(files: dict[str, bytes], *, enforce_hashes: bool = True) -> dict[str, bytes]:
    """Patch the Gateway host module that resolves the trusted-proxy user profile.

    The same display-name logic is patched in the sealed workers by
    patch_sources; this is its counterpart in the Gateway's own dist modules.
    """
    result = dict(files)
    for name, expected in HOST_TARGET_HASHES.items():
        if name not in files or (enforce_hashes and hashlib.sha256(files[name]).hexdigest() != expected):
            raise ValueError(f"Reviewed host module hash mismatch: {name}")
    name = "http-auth-utils-BvQzAi7A.mjs"
    source = files[name].decode()
    source = replace_once(
        source,
        'import { n as ensureCanonicalUserProfileForEmail, r as ensureCanonicalUserProfileForTailscaleIdentity, t as ensureCanonicalGatewayOwnerProfile } from "./user-profile-writes-BjylUIGD.mjs";',
        'import { n as ensureCanonicalUserProfileForEmail, r as ensureCanonicalUserProfileForTailscaleIdentity, s as setCanonicalUserProfileDisplayName, t as ensureCanonicalGatewayOwnerProfile } from "./user-profile-writes-BjylUIGD.mjs";',
    )
    source = replace_once(source, "\t\tconst profile = syncGitHubIdentity ?", "\t\tlet profile = syncGitHubIdentity ?")
    before = '\t\treturn await prepareHttpProfile("profileId" in profile ? profile.profileId : profile.id, profile.updatedAt, assertCurrent, usesSharedSecretGatewayMethod(params.authResult.method) ? void 0 : params.cfg);'
    after = (
        '\t\tconst aiStandProfileId = "profileId" in profile ? profile.profileId : profile.id;\n'
        '\t\tconst aiStandHeader = params.req.headers["x-ai-stand-display-name"];\n'
        '\t\tconst aiStandDisplayName = params.authResult.method === "trusted-proxy" && typeof aiStandHeader === "string" ? aiStandHeader.trim() : void 0;\n'
        '\t\tif (aiStandDisplayName && /^[A-Za-z0-9._@-]{1,128}$/.test(aiStandDisplayName) && profile.displayName !== aiStandDisplayName)\n'
        '\t\t\tprofile = (await setCanonicalUserProfileDisplayName(aiStandProfileId, aiStandDisplayName, { assertCurrent })).profile;\n'
        '\t\treturn await prepareHttpProfile(aiStandProfileId, profile.updatedAt, assertCurrent, usesSharedSecretGatewayMethod(params.authResult.method) ? void 0 : params.cfg);'
    )
    result[name] = replace_once(source, before, after).encode()
    return result


def read_bundle(path: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    total = 0
    with tarfile.open(path, "r:gz") as archive:
        for entry in archive:
            name = entry.name
            parts = PurePosixPath(name).parts
            if (not entry.isfile() or entry.mode != 0o700 or not parts or
                    any(part in ("", ".", "..") for part in parts) or
                    name.startswith("/") or "\\" in name or
                    str(PurePosixPath(name)) != name or name in files or
                    not re.fullmatch(r"[A-Za-z0-9_.-]+\.mjs", name)):
                raise ValueError("Unexpected worker artifact entry")
            total += entry.size
            if entry.size > 256 * 1024 * 1024 or total > 1024 * 1024 * 1024:
                raise ValueError("Worker artifact exceeds reviewed limits")
            reader = archive.extractfile(entry)
            assert reader is not None
            data = reader.read()
            if len(data) != entry.size:
                raise ValueError("Truncated worker artifact entry")
            files[name] = data
    if "worker.mjs" not in files:
        raise ValueError("Worker artifact entrypoint is missing")
    return files


def bundle_hash(files: dict[str, bytes]) -> str:
    digest = hashlib.sha256(b"openclaw-worker-bundle-v1\0")
    for name in sorted(files):
        data = files[name]
        digest.update(f"{name}\0{0o700:o}\0{len(data)}\0{hashlib.sha256(data).hexdigest()}\0".encode())
    return digest.hexdigest()


def write_bundle(path: Path, files: dict[str, bytes]) -> None:
    # Deterministic file metadata and gzip header; all original bytes/modes other
    # than the two reviewed modules remain identical.
    with path.open("xb") as destination:
        with gzip.GzipFile(fileobj=destination, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name in sorted(files):
                    entry = tarfile.TarInfo(name)
                    entry.mode, entry.size = 0o700, len(files[name])
                    archive.addfile(entry, io.BytesIO(files[name]))


def patch_package(root: Path) -> str:
    root = root.resolve(strict=True)
    if json.loads((root / "package.json").read_text())["version"] != VERSION:
        raise ValueError("Worker patch requires exactly OpenClaw 2026.10.2")
    host_files = {}
    for name in HOST_TARGET_HASHES:
        path = root / "dist" / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Reviewed host module is missing or unsafe: {name}")
        host_files[name] = path.read_bytes()
    # Validate every host fingerprint and exact snippet before modifying either
    # graph. A mixed install is rejected, not silently partially patched.
    patched_host = patch_host_sources(host_files)
    directory = root / "dist/worker-artifacts"
    archives = sorted(directory.glob("*.tar.gz"))
    original = directory / f"{ORIGINAL_BUNDLE}.tar.gz"
    if archives != [original] or original.is_symlink():
        raise ValueError("Expected exactly the reviewed original worker archive")
    if hashlib.sha256(original.read_bytes()).hexdigest() != ORIGINAL_ARCHIVE_SHA256:
        raise ValueError("Original worker archive checksum mismatch")
    files = read_bundle(original)
    if bundle_hash(files) != ORIGINAL_BUNDLE:
        raise ValueError("Original worker manifest hash mismatch")
    patched = patch_sources(files)
    digest = bundle_hash(patched)
    candidate = directory / f"{digest}.tar.gz"
    write_bundle(candidate, patched)
    if bundle_hash(read_bundle(candidate)) != digest:
        candidate.unlink()
        raise ValueError("Patched worker artifact validation failed")
    for name, data in patched_host.items():
        (root / "dist" / name).write_bytes(data)
    original.unlink()  # Replace only the exact image-owned, verified artifact.
    (root / "ai-stand-worker-patches.json").write_text(json.dumps({
        "version": VERSION,
        "originalBundle": ORIGINAL_BUNDLE,
        "bundle": digest,
        "patches": ["authentik-display-only-name"],
        "modules": {name: hashlib.sha256(patched[name]).hexdigest() for name in TARGET_HASHES},
        "hostModules": {name: hashlib.sha256(patched_host[name]).hexdigest() for name in HOST_TARGET_HASHES},
    }, sort_keys=True) + "\n")
    return digest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_root", type=Path)
    args = parser.parse_args()
    print(f"OPENCLAW_WORKER_PATCH_COMPLETE version={VERSION} bundle={patch_package(args.package_root)}")
