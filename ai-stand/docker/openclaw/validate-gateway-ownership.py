#!/usr/bin/env python3
"""Validate Gateway storage without changing ownership or following symlinks.

Only OpenClaw's two image-managed npm generation namespaces may be root-owned.
All other persistent state must remain owned by the unprivileged Gateway user.
"""

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


GENERATION_NAME = re.compile(
    r"openclaw-(?P<package>codex|memory-lancedb)-[0-9a-f]{8,64}"
    r"__openclaw-generation__g-[0-9a-f]{8,64}\Z"
)
# Exact initial project names emitted by the pinned 2026.10.2 native
# installer. Upgrades use the generation namespace above; an arbitrary
# suffix-free npm project is not an ownership exception.
INITIAL_PROJECT_NAMES = {
    "openclaw-codex-8902d781d4": "codex",
    "openclaw-memory-lancedb-6a4d78c41e": "memory-lancedb",
}
GENERATION_PARENT = (".openclaw", "npm", "projects")
OPENCLAW_PEER = "/usr/local/lib/node_modules/openclaw"


class OwnershipConflict(RuntimeError):
    pass


def generation_root(relative):
    """Return a fixed managed project boundary, never an arbitrary npm path."""
    parts = relative.parts
    if (len(parts) >= 4 and parts[:3] == GENERATION_PARENT
            and (GENERATION_NAME.fullmatch(parts[3]) or parts[3] in INITIAL_PROJECT_NAMES)):
        return PurePosixPath(*parts[:4])
    return None


def validate_link(relative, project, target):
    if target.startswith("/"):
        matched = GENERATION_NAME.fullmatch(project.name)
        package = matched.group("package") if matched else INITIAL_PROJECT_NAMES[project.name]
        # OpenClaw's native managed-plugin installer may establish the peer
        # at the project root or directly inside its own scoped package.
        # Neither location permits peers under arbitrary dependency packages.
        peer_paths = (
            project / "node_modules" / "openclaw",
            project / "node_modules" / "@openclaw" / package / "node_modules" / "openclaw",
        )
        if relative in peer_paths and target == OPENCLAW_PEER:
            return
        raise OwnershipConflict(f"Unexpected absolute managed plugin link: {relative}")
    # Resolve lexical components only: the host cannot resolve the peer's
    # image-only absolute path, and resolving filesystem links would escape
    # the no-follow validation boundary.
    parts = list(relative.parent.parts)
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise OwnershipConflict(f"Escaping managed plugin link: {relative}")
            parts.pop()
        else:
            parts.append(part)
    if tuple(parts[:len(project.parts)]) != project.parts:
        raise OwnershipConflict(f"Escaping managed plugin link: {relative}")


def validate_entry(relative, metadata, expected, managed_owner=None, link_target=None):
    owner = (metadata.st_uid, metadata.st_gid)
    project = generation_root(relative)
    is_project_root = project == relative
    if is_project_root and not stat.S_ISDIR(metadata.st_mode):
        raise OwnershipConflict(f"Managed plugin generation is not a directory: {relative}")
    if is_project_root:
        managed_owner = owner
    if managed_owner == (0, 0) and project is not None:
        if owner != (0, 0):
            raise OwnershipConflict(f"Mutable ownership inside managed plugin: {relative}")
        if stat.S_ISLNK(metadata.st_mode):
            validate_link(relative, project, link_target or "")
        elif stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode):
            if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID):
                raise OwnershipConflict(f"Writable managed plugin payload: {relative}")
            if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
                raise OwnershipConflict(f"Hard-linked managed plugin payload: {relative}")
        else:
            raise OwnershipConflict(f"Unexpected managed plugin file type: {relative}")
    elif owner != expected:
        raise OwnershipConflict(
            f"Unexpected Gateway ownership at {relative}: {owner[0]}:{owner[1]}; "
            f"expected {expected[0]}:{expected[1]}"
        )
    return managed_owner


def validate_tree(root, uid, gid):
    root = Path(root)
    if not root.is_absolute() or ".." in root.parts:
        raise OwnershipConflict("Gateway path must be absolute and contain no traversal")
    if os.path.realpath(root) != os.path.abspath(root):
        raise OwnershipConflict("Gateway path or one of its ancestors is a symlink")
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode):
        raise OwnershipConflict("Gateway path is not a directory")
    expected = (uid, gid)
    validate_entry(PurePosixPath("."), metadata, expected)
    device = metadata.st_dev
    def visit(directory_fd, relative_parent, managed_owner):
        # Directory descriptors and O_NOFOLLOW prevent a changed descendant
        # from turning a no-follow scan into traversal outside Gateway data.
        with os.scandir(directory_fd) as entries:
            for entry in entries:
                relative = relative_parent / entry.name
                metadata = entry.stat(follow_symlinks=False)
                if metadata.st_dev != device:
                    raise OwnershipConflict(f"Unexpected nested Gateway filesystem: {relative}")
                link_target = (os.readlink(entry.name, dir_fd=directory_fd)
                               if stat.S_ISLNK(metadata.st_mode) else None)
                child_owner = validate_entry(
                    relative, metadata, expected, managed_owner, link_target
                )
                if stat.S_ISDIR(metadata.st_mode):
                    child_fd = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                       dir_fd=directory_fd)
                    try:
                        opened = os.fstat(child_fd)
                        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                            raise OwnershipConflict(f"Gateway directory changed during scan: {relative}")
                        visit(child_fd, relative, child_owner)
                    finally:
                        os.close(child_fd)

    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(root_fd)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise OwnershipConflict("Gateway root changed during scan")
        visit(root_fd, PurePosixPath("."), None)
    finally:
        os.close(root_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gateway-root", required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    args = parser.parse_args()
    if args.uid <= 0 or args.gid <= 0:
        parser.error("Gateway UID/GID must be positive and non-root")
    try:
        validate_tree(args.gateway_root, args.uid, args.gid)
    except (OwnershipConflict, OSError) as error:
        print(f"OpenClaw Gateway ownership validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
