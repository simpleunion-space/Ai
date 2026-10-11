#!/usr/bin/env python3
"""Pinned, resumable model artifacts. Never selects or loads inference models."""
import argparse
from contextlib import nullcontext
from concurrent.futures import ThreadPoolExecutor, as_completed
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

QUANT_TYPES = {"Q4_K_M": 15, "Q8_0": 7, "F16": 1, "BF16": 32}
SCALAR = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def read_metadata(path):
    """Read small GGUF metadata; skip tokenizer arrays and tensor bodies."""
    result = {}
    with Path(path).open("rb") as stream:
        file_size = os.fstat(stream.fileno()).st_size
        def number(fmt):
            size = struct.calcsize("<" + fmt)
            data = stream.read(size)
            if len(data) != size:
                raise ValueError("truncated GGUF metadata")
            return struct.unpack("<" + fmt, data)[0]

        def string(keep=True):
            length = number("Q")
            if length > 64 * 1024 * 1024:
                raise ValueError("oversized GGUF string")
            if keep:
                value = stream.read(length)
                if len(value) != length:
                    raise ValueError("truncated GGUF string")
                return value.decode("utf-8")
            skip(length)

        def skip(length):
            if stream.tell() + length > file_size:
                raise ValueError("truncated GGUF metadata")
            stream.seek(length, 1)

        def value(kind, keep):
            if kind in SCALAR:
                return number(SCALAR[kind])
            if kind == 8:
                return string(keep)
            if kind == 9:
                subtype, count = number("I"), number("Q")
                if count > 4_000_000 or subtype == 9:
                    raise ValueError("invalid GGUF array")
                if subtype in SCALAR:
                    skip(struct.calcsize("<" + SCALAR[subtype]) * count)
                else:
                    for _ in range(count):
                        value(subtype, False)
                return None
            raise ValueError("unknown GGUF metadata type")

        if stream.read(4) != b"GGUF" or number("I") not in (2, 3):
            raise ValueError("invalid GGUF header")
        number("Q")
        count = number("Q")
        if count > 100_000:
            raise ValueError("oversized GGUF metadata")
        for _ in range(count):
            key, kind = string(), number("I")
            keep = key in ("general.file_type", "general.architecture") or key.endswith(".embedding_length")
            item = value(kind, keep)
            if keep:
                result[key] = item
    return result


def validate_artifact(artifact):
    relative = Path(artifact["path"])
    if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 3:
        raise ValueError("unsafe artifact path")
    allowed = ("BF16",) if artifact.get("kind") == "projector" else ("Q4_K_M", "Q8_0")
    if artifact["quantization"] not in allowed:
        raise ValueError("unsupported catalog quantization")
    sha = artifact.get("sha256")
    if sha is not None and not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise ValueError("invalid artifact checksum")
    size = artifact.get("size")
    if size is not None and (type(size) is not int or size <= 0):
        raise ValueError("invalid artifact size")
    return relative


def reject_symlinks(path):
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError("symlink in artifact path")


def safe_path(root, relative):
    reject_symlinks(root)
    root = root.resolve()
    path = root / relative
    reject_symlinks(path)
    if not path.resolve().is_relative_to(root):
        raise ValueError("artifact escaped model root")
    return path


def artifact_directory(path):
    """Create only absent runtime-readable directories, independently of umask.

    Existing directories, private download chunks and administrative state are
    never recursively chowned/chmodded. A symlink or non-directory fails closed.
    """
    path = Path(path)
    reject_symlinks(path)
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    if not current.is_dir():
        raise ValueError("artifact parent is not a directory")
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o750)
        except FileExistsError:
            # A concurrent creator is not permission to alter its directory.
            reject_symlinks(directory)
            if not directory.is_dir():
                raise ValueError("artifact parent is not a directory") from None
            continue
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fchmod(descriptor, 0o750)
            os.fchown(descriptor, 10000, 20000)
        finally:
            os.close(descriptor)
    reject_symlinks(path)
    if not path.is_dir():
        raise ValueError("artifact parent is not a directory")


def verify_file(path, size, sha, quant):
    if not path.is_file() or size is None or sha is None:
        return False
    if path.stat().st_size != size or digest(path) != sha:
        return False
    if read_metadata(path).get("general.file_type") != QUANT_TYPES[quant]:
        raise ValueError("GGUF quantization disagrees with locked catalog")
    return True


def validate_download_source(source, path):
    url, size, sha = source["url"], source["size"], source["sha256"]
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or parsed.netloc != "huggingface.co" or parsed.query or parsed.fragment
            or not re.fullmatch(r"/[^/]+/[^/]+/resolve/[0-9a-f]{40}/[^/]+", parsed.path)
            or not re.fullmatch(r"[0-9a-f]{64}", sha)
            or type(size) is not int or size <= 0):
        raise ValueError("invalid immutable download source")
    if source.get("revision") and f"/resolve/{source['revision']}/" not in parsed.path:
        raise ValueError("download URL disagrees with pinned revision")
    if source.get("repo") and not parsed.path.startswith(f"/{source['repo']}/resolve/"):
        raise ValueError("download URL disagrees with pinned repository")
    if source.get("file") and parsed.path.rsplit("/", 1)[1] != source["file"]:
        raise ValueError("download URL disagrees with pinned file")
    reject_symlinks(path)
    return size, sha


def download(source, path, workers=8, chunk_bytes=128 * 1024**2):
    size, sha = validate_download_source(source, path)
    if type(workers) is not int or not 1 <= workers <= 16:
        raise ValueError("download workers must be in 1..16")
    if type(chunk_bytes) is not int or not 1 <= chunk_bytes <= 256 * 1024**2:
        raise ValueError("invalid download chunk size")
    if path.exists():
        if path.stat().st_size == size and digest(path) == sha:
            return
        raise ValueError("existing artifact differs from locked checksum; retained untouched")
    if workers == 1 or size <= chunk_bytes:
        return download_linear(source, path)
    return download_parallel(source, path, workers, chunk_bytes)


def download_linear(source, path):
    size, sha = validate_download_source(source, path)
    url = source["url"]
    artifact_directory(path.parent)
    if path.exists():
        if path.stat().st_size == size and digest(path) == sha:
            return
        raise ValueError("existing artifact differs from locked checksum; retained untouched")
    partial = path.with_name(path.name + ".partial")
    reject_symlinks(partial)
    for attempt in range(1, 7):
        offset = partial.stat().st_size if partial.exists() else 0
        if offset > size:
            raise ValueError("partial artifact exceeds locked size")
        if offset == size:
            break
        headers = {"User-Agent": "ai-stand-pinned-model-catalog/1", "Accept-Encoding": "identity"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
                if response.status not in (200, 206):
                    raise ValueError("unexpected download status")
                if offset and response.status != 206:
                    offset = 0
                expected_bytes = size
                if response.status == 206:
                    span = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
                    if not span:
                        raise ValueError("unexpected download range")
                    start, end, total = map(int, span.groups())
                    if start != offset or end < start or end >= size or total != size:
                        raise ValueError("unexpected download range")
                    expected_bytes = end - start + 1
                content_length = response.headers.get("Content-Length")
                if content_length is not None and (not content_length.isdecimal() or int(content_length) != expected_bytes):
                    raise ValueError("download content length disagrees with locked range")
                flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_APPEND if offset else os.O_TRUNC)
                received = 0
                with os.fdopen(os.open(partial, flags, 0o600), "wb") as stream:
                    for block in iter(lambda: response.read(8 * 1024 * 1024), b""):
                        received += len(block)
                        if received > expected_bytes:
                            raise ValueError("download exceeds locked range/size")
                        stream.write(block)
                    stream.flush()
                    os.fsync(stream.fileno())
                if received != expected_bytes:
                    raise OSError("incomplete download response")
            if partial.stat().st_size == size:
                break
        except (OSError, urllib.error.URLError):
            if attempt == 6:
                raise RuntimeError("pinned artifact download failed") from None
            time.sleep(min(attempt * 5, 30))
    if partial.stat().st_size != size or digest(partial) != sha:
        raise ValueError("download checksum/size mismatch; partial retained")
    partial.chmod(0o640)
    os.chown(partial, 10000, 20000)
    os.replace(partial, path)


class RangeContractError(ValueError):
    pass


def cache_paths(cache, index):
    part = safe_path(cache, Path(f"{index:08d}.part"))
    return part, safe_path(cache, Path(part.name + ".partial"))


def download_range(source, cache, index, start, end):
    """One bounded range; retry/continue only this managed segment's prefix."""
    size = source["size"]
    part, partial = cache_paths(cache, index)
    span_size = end - start + 1
    if part.exists():
        if part.stat().st_size != span_size:
            raise ValueError("cached range has an unexpected size; retained untouched")
        return span_size
    for attempt in range(1, 7):
        offset = partial.stat().st_size if partial.exists() else 0
        if offset > span_size:
            raise ValueError("partial range exceeds locked segment size")
        if offset == span_size:
            os.replace(partial, part)
            return span_size
        absolute_start = start + offset
        headers = {"User-Agent": "ai-stand-pinned-model-catalog/1", "Accept-Encoding": "identity",
                   "Range": f"bytes={absolute_start}-{end}"}
        try:
            request = urllib.request.Request(source["url"], headers=headers)
            with urllib.request.urlopen(request, timeout=120) as response:
                expected = f"bytes {absolute_start}-{end}/{size}"
                if response.status != 206 or response.headers.get("Content-Range") != expected:
                    raise RangeContractError("unexpected parallel download range")
                wanted = end - absolute_start + 1
                length = response.headers.get("Content-Length")
                if length is not None and (not length.isdecimal() or int(length) != wanted):
                    raise RangeContractError("parallel range content length mismatch")
                flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_APPEND
                received = 0
                with os.fdopen(os.open(partial, flags, 0o600), "wb") as stream:
                    for block in iter(lambda: response.read(8 * 1024**2), b""):
                        received += len(block)
                        if received > wanted:
                            raise RangeContractError("parallel response exceeds locked range")
                        stream.write(block)
                    stream.flush()
                    os.fsync(stream.fileno())
                if received != wanted:
                    raise OSError("incomplete parallel range")
            if partial.stat().st_size != span_size:
                raise ValueError("parallel range failed size verification")
            os.replace(partial, part)
            return span_size
        except (OSError, urllib.error.URLError, RangeContractError) as error:
            if isinstance(error, RangeContractError) and partial.exists() and partial.stat().st_size > offset:
                # Do not promote a full-looking prefix from a response that
                # violated its declared range. Only discard this attempt's
                # bytes in our own cache, never the user's linear prefix.
                with partial.open("r+b") as stream:
                    stream.truncate(offset)
            if attempt == 6:
                raise RuntimeError("pinned parallel range failed; cache retained") from None
            time.sleep(min(attempt * 2, 10))


def seed_range(prefix, partial, start, length):
    """Read-only old linear prefix; append only bytes absent in managed cache."""
    existing = partial.stat().st_size if partial.exists() else 0
    if existing >= length:
        return
    reject_symlinks(prefix)
    with prefix.open("rb") as source, os.fdopen(os.open(
            partial, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600), "wb") as output:
        source.seek(start + existing)
        remaining = length - existing
        while remaining:
            block = source.read(min(8 * 1024**2, remaining))
            if not block:
                raise ValueError("linear prefix changed while seeding cache")
            output.write(block)
            remaining -= len(block)
        output.flush()
        os.fsync(output.fileno())


def download_parallel(source, path, workers, chunk_bytes):
    size, sha = source["size"], source["sha256"]
    artifact_directory(path.parent)
    prefix = safe_path(path.parent, Path(path.name + ".partial"))
    prefix_size = prefix.stat().st_size if prefix.exists() else 0
    if prefix_size > size:
        raise ValueError("linear partial artifact exceeds locked size")
    cache = safe_path(path.parent, Path("." + path.name + ".download-parts"))
    cache.mkdir(mode=0o750, exist_ok=True)
    ranges = [(index, start, min(size - 1, start + chunk_bytes - 1))
              for index, start in enumerate(range(0, size, chunk_bytes))]
    names = {"manifest.json", "assembly.partial"}
    for index, _, _ in ranges:
        names.update((f"{index:08d}.part", f"{index:08d}.part.partial"))
    for entry in cache.iterdir():
        reject_symlinks(entry)
        if not entry.is_file() or entry.name not in names:
            raise ValueError("unknown file in managed download cache; retained untouched")
    manifest = cache / "manifest.json"
    expected_manifest = {"version": 1, "size": size, "sha256": sha, "chunkBytes": chunk_bytes}
    if manifest.exists():
        if manifest.stat().st_size > 1024 * 1024 or json.loads(manifest.read_text()) != expected_manifest:
            raise ValueError("download cache disagrees with immutable artifact")
    elif any(cache.iterdir()):
        raise ValueError("unmarked download cache is retained untouched")
    else:
        atomic_manifest(manifest, expected_manifest)

    # Segments and the assembly coexist until whole-file verification succeeds.
    missing_bytes = 0
    for index, start, end in ranges:
        part, partial = cache_paths(cache, index)
        amount = end - start + 1
        if part.exists():
            if part.stat().st_size != amount:
                raise ValueError("cached range has an unexpected size; retained untouched")
        else:
            saved = partial.stat().st_size if partial.exists() else 0
            if saved > amount:
                raise ValueError("partial range exceeds locked segment size")
            missing_bytes += amount - saved
    assembly = safe_path(cache, Path("assembly.partial"))
    existing_assembly = assembly.stat().st_size if assembly.exists() else 0
    if shutil.disk_usage(cache).free < missing_bytes + max(0, size - existing_assembly) + 16 * 1024**2:
        raise ValueError("insufficient segmented download/assembly space")

    pending, completed = [], 0
    for index, start, end in ranges:
        part, partial = cache_paths(cache, index)
        amount = end - start + 1
        if part.exists():
            completed += amount
            continue
        if prefix_size > start:
            seed_range(prefix, partial, start, min(amount, prefix_size - start))
        if partial.exists() and partial.stat().st_size == amount:
            os.replace(partial, part)
            completed += amount
        else:
            pending.append((index, start, end))
    print(f"MODEL_DOWNLOAD {path.name}: {completed}/{size} bytes cached", flush=True)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(download_range, source, cache, *span) for span in pending]
        try:
            for future in as_completed(futures):
                completed += future.result()
                print(f"MODEL_DOWNLOAD {path.name}: {completed}/{size} bytes", flush=True)
        except BaseException:
            for future in futures:
                future.cancel()
            raise

    with os.fdopen(os.open(assembly, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "wb") as output:
        for index, _, _ in ranges:
            part, _ = cache_paths(cache, index)
            with part.open("rb") as segment:
                shutil.copyfileobj(segment, output, length=8 * 1024**2)
        output.flush()
        os.fsync(output.fileno())
    if assembly.stat().st_size != size or digest(assembly) != sha:
        raise ValueError("parallel download checksum/size mismatch; prefix and cache retained")
    assembly.chmod(0o640)
    os.chown(assembly, 10000, 20000)
    # link is an atomic, no-overwrite publication within the same filesystem.
    try:
        os.link(assembly, path, follow_symlinks=False)
    except FileExistsError:
        reject_symlinks(path)
        if path.stat().st_size != size or digest(path) != sha:
            raise ValueError("existing artifact differs; retained untouched") from None
    for entry in cache.iterdir():
        reject_symlinks(entry)
        if not entry.is_file() or entry.name not in names:
            raise ValueError("unknown cache file retained after publication")
        entry.unlink()
    cache.rmdir()
    # The old linear .partial is intentionally left untouched for recovery.


def atomic_manifest(path, value):
    reject_symlinks(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=f".{path.name}.", suffix=".partial", delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.chmod(0o600)
    os.replace(temporary, path)


def quantizer_image(quantizer):
    image = quantizer["image"]
    labels = {}
    if not subprocess.run(["docker", "image", "inspect", image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        labels = json.loads(subprocess.check_output(
            ["docker", "image", "inspect", "--format", "{{json .Config.Labels}}", image], text=True)) or {}
    expected = {"org.opencontainers.image.revision": quantizer["commit"],
                "ai-stand.quantizer.archive-sha256": quantizer["archiveSha256"]}
    if any(labels.get(key) != value for key, value in expected.items()):
        subprocess.run(["docker", "build", "--tag", image,
                        "--build-arg", f"LLAMA_CPP_COMMIT={quantizer['commit']}",
                        "--build-arg", f"LLAMA_CPP_ARCHIVE_SHA256={quantizer['archiveSha256']}",
                        "--file", str(Path(__file__).with_name("Dockerfile.quantizer")), str(Path(__file__).parent)], check=True)
        labels = json.loads(subprocess.check_output(
            ["docker", "image", "inspect", "--format", "{{json .Config.Labels}}", image], text=True)) or {}
        if any(labels.get(key) != value for key, value in expected.items()):
            raise ValueError("quantizer image provenance disagrees with locked toolchain")
    image_id = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", image], text=True).strip()
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise ValueError("invalid quantizer image digest")
    return image, image_id


def generate(artifact, path, home, lock, output_manifest, download_workers=8):
    source = artifact["source"]
    quantizer = lock["quantizer"]
    if (source["quantizerCommit"] != quantizer["commit"]
            or not re.fullmatch(r"[0-9a-f]{40}", quantizer["commit"])
            or not re.fullmatch(r"[0-9a-f]{64}", quantizer["archiveSha256"])):
        raise ValueError("quantization source disagrees with locked toolchain")
    if artifact["quantization"] != "Q4_K_M":
        raise ValueError("quantizer only produces Q4_K_M")
    reject_symlinks(path)
    if output_manifest:
        reject_symlinks(output_manifest)
    staging = safe_path(home, Path("state/model-catalog-staging"))
    artifact_directory(staging)
    input_path = safe_path(staging, Path(source["input"]["file"]))
    if len(Path(source["input"]["file"]).parts) != 1:
        raise ValueError("unsafe quantization input filename")
    download(source["input"], input_path, workers=download_workers)
    if read_metadata(input_path).get("general.file_type") != QUANT_TYPES["F16"]:
        raise ValueError("quantization input is not official high-precision GGUF")
    output_path = safe_path(staging, Path(path.name))
    receipt = safe_path(staging, Path(path.name + ".receipt.json"))
    image, image_id = quantizer_image(quantizer)
    provenance = {"sourceSha256": source["input"]["sha256"], "quantizerCommit": source["quantizerCommit"],
                  "quantizerImageId": image_id}
    if output_path.exists():
        if receipt.exists():
            if receipt.stat().st_size > 1024 * 1024:
                raise ValueError("invalid quantizer completion receipt")
            recorded = json.loads(receipt.read_text())
            if any(recorded.get(key) != value for key, value in provenance.items()):
                raise ValueError("quantizer completion receipt disagrees with locked provenance")
            if not verify_file(output_path, recorded.get("size"), recorded.get("sha256"), "Q4_K_M"):
                raise ValueError("quantizer completion receipt failed checksum/size verification")
        elif not verify_file(output_path, artifact.get("size"), artifact.get("sha256"), "Q4_K_M"):
            # A failed/old run may leave a valid GGUF header and incomplete
            # tensors. Never bless that file with a newly computed checksum.
            raise ValueError("unreceipted quantizer output is unverified; retained untouched")
    else:
        fd, partial_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".partial", dir=staging)
        os.close(fd)
        partial_output = Path(partial_name)
        partial_output.chmod(0o640)
        os.chown(partial_output, 10000, 20000)
        subprocess.run([
            "docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--user", "10000:20000", "--tmpfs", "/tmp:rw,mode=1777",
            "--mount", f"type=bind,src={staging},dst=/work", image,
            "/work/" + input_path.name, "/work/" + partial_output.name, "Q4_K_M", "8",
        ], check=True)
        if read_metadata(partial_output).get("general.file_type") != QUANT_TYPES["Q4_K_M"]:
            raise ValueError("quantizer output is not Q4_K_M")
        completed = {**provenance, "sha256": digest(partial_output), "size": partial_output.stat().st_size}
        if artifact.get("sha256") is not None and completed["sha256"] != artifact["sha256"]:
            raise ValueError("generated artifact disagrees with pinned checksum")
        if artifact.get("size") is not None and completed["size"] != artifact["size"]:
            raise ValueError("generated artifact disagrees with pinned size")
        os.replace(partial_output, output_path)
        atomic_manifest(receipt, completed)
    if read_metadata(output_path).get("general.file_type") != QUANT_TYPES["Q4_K_M"]:
        raise ValueError("quantizer output is not Q4_K_M")
    generated = {"path": artifact["path"], "sha256": digest(output_path), "size": output_path.stat().st_size,
                 **provenance}
    if artifact.get("sha256") and generated["sha256"] != artifact["sha256"]:
        raise ValueError("generated artifact disagrees with pinned checksum")
    if artifact.get("size") is not None and generated["size"] != artifact["size"]:
        raise ValueError("generated artifact disagrees with pinned size")
    artifact_directory(path.parent)
    temporary = path.with_name(path.name + ".generated")
    if path.exists():
        if digest(path) != generated["sha256"]:
            raise ValueError("existing generated model differs; retained untouched")
    else:
        if temporary.is_symlink():
            raise ValueError("unsafe generated temporary artifact")
        shutil.copyfile(output_path, temporary)
        temporary.chmod(0o640)
        os.chown(temporary, 10000, 20000)
        os.replace(temporary, path)
    if output_manifest:
        atomic_manifest(output_manifest, generated)
    return generated


def catalog_lock(home, verify_only):
    lock_path = safe_path(home, Path("state/.model-catalog.lock"))
    if verify_only:
        return nullcontext()
    artifact_directory(lock_path.parent)
    return os.fdopen(os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600), "a")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", choices=("chat", "embedding"), required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, default=Path(__file__).with_name("catalog.lock.json"))
    parser.add_argument("--model")
    parser.add_argument("--quantization", choices=("Q4_K_M", "Q8_0"))
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--generated-manifest", type=Path)
    parser.add_argument("--download-workers", type=int, default=8)
    args = parser.parse_args()
    if not 1 <= args.download_workers <= 16:
        raise ValueError("download workers must be in 1..16")
    lock = json.loads(args.catalog.read_text())
    if lock.get("version") != 1:
        raise ValueError("unsupported catalog version")
    reject_symlinks(args.root)
    home = args.root.resolve()
    storage = os.environ.get("STORAGE_ROOT", "")
    if not storage.startswith("/") or storage.endswith("/") or ".." in storage:
        raise ValueError("STORAGE_ROOT must be the installation's absolute storage root")
    if not home.is_dir() or not str(home).startswith(str(Path(storage).resolve()) + "/llamacpp-data/"):
        raise ValueError("root must be an existing llama.cpp persistent home")
    models = home / "models"
    reject_symlinks(models)
    if args.verify_only:
        if not models.is_dir():
            raise ValueError("read-only verification requires an existing models directory")
    else:
        artifact_directory(models)
    selected = [item for item in lock["artifacts"] if item["role"] == args.role
                and (args.model is None or item["model"] == args.model)
                and (args.quantization is None or item["quantization"] == args.quantization)]
    # Auxiliary files are independently pinned and never counted as primary
    # Q4/Q8 weights. Projectors retain BF16 regardless of model quantization.
    selected += [item for item in lock.get("auxiliaryArtifacts", []) if item["role"] == args.role
                 and (args.model is None or item["model"] == args.model)]
    if not selected:
        raise ValueError("no locked artifacts match selection")
    # Verification reads immutable final files only. It must also work from a
    # read-only pre-maintenance probe mount without creating a lock/directory.
    with catalog_lock(home, args.verify_only) as held:
        if not args.verify_only:
            fcntl.flock(held, fcntl.LOCK_EX)
        for artifact in selected:
            path = safe_path(models, validate_artifact(artifact))
            if verify_file(path, artifact.get("size"), artifact.get("sha256"), artifact["quantization"]):
                print("VERIFIED " + artifact["path"], flush=True)
                continue
            if args.verify_only:
                raise ValueError("required locked artifact is missing/unverified: " + artifact["path"])
            required = artifact.get("size") or 2_000_000_000
            if shutil.disk_usage(home).free < required + 20 * 1024**3:
                raise ValueError("insufficient staging space")
            print("PREPARING " + artifact["path"], flush=True)
            if artifact["source"]["type"] == "huggingface":
                source = {**artifact["source"], "sha256": artifact["sha256"], "size": artifact["size"]}
                download(source, path, workers=args.download_workers)
            elif artifact["source"]["type"] == "quantized":
                generated = generate(artifact, path, home, lock, args.generated_manifest, download_workers=args.download_workers)
                if artifact.get("sha256") is None:
                    print("GENERATED " + json.dumps(generated), flush=True)
                    continue
            else:
                raise ValueError("unknown artifact source")
            if not verify_file(path, artifact["size"], artifact["sha256"], artifact["quantization"]):
                raise ValueError("prepared artifact failed verification")
            print("VERIFIED " + artifact["path"], flush=True)
    print("MODEL_CATALOG_COMPLETE", flush=True)


if __name__ == "__main__":
    main()

