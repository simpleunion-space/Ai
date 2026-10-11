"""Strict, single-file llama.cpp lifecycle; never downloads or selects models.

The native server stays loopback-only until a real inference and native GPU
proof pass. The public gate transports bytes without parsing or rewriting HTTP.
Docker liveness never performs generation or consumes an inference slot.
"""
import asyncio
import base64
from dataclasses import asdict, dataclass
import glob
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zlib

COMMIT = "d81235049384534c167caea52b85a694f6103d14"
ARCHIVE_SHA = "6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14"
TAG = "v0.6.0"
BUILD_FILE = Path("/opt/llamacpp-build.json")
BINARY = "/opt/llamacpp/bin/llama-server"
SCALAR = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


class RuntimeRejected(Exception):
    """Messages are image-owned diagnostics, never upstream response bodies."""


def fail(condition, message):
    if not condition:
        raise RuntimeRejected(message)


def integer(env, name, default, minimum=1, maximum=2**31-1):
    raw = env.get("LLAMACPP_" + name, str(default))
    fail(bool(re.fullmatch(r"[0-9]+", raw)), f"invalid {name}")
    number = int(raw)
    fail(minimum <= number <= maximum, f"invalid {name}")
    return number


def choice(env, name, default, values):
    raw = env.get("LLAMACPP_" + name, default)
    fail(raw in values, f"invalid {name}")
    return raw


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def canonical_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def no_symlinks(path):
    fail(not any(part.is_symlink() for part in (path, *path.parents)), "symlink in runtime path")


def model_file(root, relative):
    parts = PurePosixPath(relative)
    fail(bool(relative) and not parts.is_absolute() and ".." not in parts.parts
         and "\\" not in relative and parts.suffix.lower() == ".gguf", "unsafe GGUF path")
    no_symlinks(root)
    path = root / parts
    no_symlinks(path)
    fail(path.resolve().is_relative_to(root.resolve()) and path.is_file(), "GGUF file absent")
    return path.resolve()


def gguf_metadata(path):
    """Bounded parser: skip large tokenizer arrays, never load tensor payload."""
    result = {}
    with Path(path).open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size

        def number(fmt):
            data = stream.read(struct.calcsize("<" + fmt))
            fail(len(data) == struct.calcsize("<" + fmt), "truncated GGUF")
            return struct.unpack("<" + fmt, data)[0]

        def skip(length):
            fail(stream.tell() + length <= size, "truncated GGUF")
            stream.seek(length, 1)

        def string(keep=True):
            length = number("Q")
            fail(length <= 64 * 1024**2, "oversized GGUF metadata")
            if not keep:
                skip(length)
                return None
            raw = stream.read(length)
            fail(len(raw) == length, "truncated GGUF")
            return raw.decode("utf-8")

        def value(kind, keep):
            if kind in SCALAR:
                return number(SCALAR[kind])
            if kind == 8:
                return string(keep)
            if kind == 9:
                subtype, count = number("I"), number("Q")
                fail(subtype != 9 and count <= 4_000_000, "invalid GGUF array")
                if subtype in SCALAR:
                    skip(struct.calcsize("<" + SCALAR[subtype]) * count)
                else:
                    for _ in range(count):
                        value(subtype, False)
                return None
            raise RuntimeRejected("unsupported GGUF metadata type")

        fail(stream.read(4) == b"GGUF" and number("I") in (2, 3), "invalid GGUF header")
        number("Q")
        count = number("Q")
        fail(count <= 100_000, "oversized GGUF metadata")
        for _ in range(count):
            key, kind = string(), number("I")
            keep = key in ("general.file_type", "general.architecture") or key.endswith((".embedding_length", ".block_count"))
            item = value(kind, keep)
            if keep:
                result[key] = item
    return result


@dataclass(frozen=True)
class Config:
    role: str
    model_id: str
    model_path: str
    sha256: str
    projector_path: str
    projector_sha256: str
    models_dir: str
    state_dir: str
    context: int
    parallel: int
    batch: int
    ubatch: int
    port: int
    accelerator: str
    gfx: str
    require_gpu: bool
    gpu_layers: str
    flash_attention: str
    cache_k: str
    cache_v: str
    pooling: str
    dimensions: int
    catalog: str
    load_timeout: int
    request_timeout: int

    @classmethod
    def read(cls, env=None):
        env = os.environ if env is None else env
        role = choice(env, "ROLE", "chat", ("chat", "embedding"))
        accelerator = choice(env, "ACCELERATOR", "cpu", ("cpu", "amd", "nvidia"))
        required = integer(env, "REQUIRE_GPU", int(accelerator != "cpu"), 0, 1) == 1
        fail(required == (accelerator != "cpu"), "GPU accelerator requires GPU; CPU is only an explicit image")
        gpu_layers = choice(env, "GPU_LAYERS", "all" if required else "0", ("all", "0"))
        fail(gpu_layers == ("all" if required else "0"), "partial/automatic GPU offload forbidden")
        gfx = env.get("LLAMACPP_GFX", "")
        fail(bool(re.fullmatch(r"gfx[0-9]{4}", gfx)) if accelerator == "amd" else gfx == "", "invalid GFX")
        fail(not env.get("HSA_OVERRIDE_GFX_VERSION"), "GFX spoof forbidden")
        model_id = env.get("LLAMACPP_MODEL_ID", "")
        fail(bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,159}", model_id)), "invalid MODEL_ID")
        sha = env.get("LLAMACPP_MODEL_SHA256", "")
        fail(bool(re.fullmatch(r"[0-9a-f]{64}", sha)), "MODEL_SHA256 required")
        projector = env.get("LLAMACPP_PROJECTOR_PATH", "")
        projector_sha = env.get("LLAMACPP_PROJECTOR_SHA256", "")
        fail(bool(projector) == bool(projector_sha), "projector path/checksum pair required")
        if projector:
            fail(role == "chat" and bool(re.fullmatch(r"[0-9a-f]{64}", projector_sha)), "invalid projector")
        fail(not integer(env, "REQUIRE_PROJECTOR", 0, 0, 1) or bool(projector), "required projector absent")
        fail(choice(env, "REQUIRED_QUANT", "Q4_K_M", ("Q4_K_M",)) == "Q4_K_M", "only Q4_K_M allowed")
        context = integer(env, "CONTEXT_LENGTH", 8192, 32, 1048576)
        parallel = integer(env, "PARALLEL", 1, 1, 1)
        batch = integer(env, "BATCH_SIZE", 512, 1, context)
        ubatch = integer(env, "UBATCH_SIZE", 512, 1, batch)
        flash = choice(env, "FLASH_ATTN", "off" if role == "embedding" else "on", ("on", "off"))
        cache = ("f16", "bf16", "q8_0", "q4_0", "q4_1", "q5_0", "q5_1", "iq4_nl")
        pooling = choice(env, "POOLING", "last", ("last",))
        dimensions = integer(env, "EMBEDDING_DIMENSIONS", 4096 if role == "embedding" else 0, 0, 65536)
        fail(role != "embedding" or dimensions > 0, "embedding dimensions required")
        roots = [env.get("LLAMACPP_MODELS_DIR", "/models"), env.get("LLAMACPP_STATE_DIR", "/state")]
        fail(all(Path(p).is_absolute() for p in roots) and roots[0] != roots[1], "invalid runtime roots")
        catalog = env.get("LLAMACPP_MODEL_CATALOG_FINGERPRINT", "")
        fail(not catalog or bool(re.fullmatch(r"[0-9a-f]{64}", catalog)), "invalid catalog fingerprint")
        return cls(role, model_id, env.get("LLAMACPP_MODEL_PATH", ""), sha, projector, projector_sha,
                   *roots, context, parallel, batch, ubatch, integer(env, "PORT", 1234, 1024, 65534),
                   accelerator, gfx, required, gpu_layers, flash,
                   choice(env, "CACHE_TYPE_K", "f16", cache), choice(env, "CACHE_TYPE_V", "f16", cache),
                   pooling, dimensions, catalog, integer(env, "LOAD_WAIT_SECONDS", 3600, 1, 86400),
                   integer(env, "REQUEST_TIMEOUT", 86400, 1, 86400))

    @property
    def native_port(self):
        return self.port + 1

    @property
    def marker(self):
        return Path(self.state_dir) / "readiness.json"

    def fingerprint(self, build):
        return canonical_digest({"configuration": asdict(self), "build": build})


def validate_build(config):
    build = json.loads(BUILD_FILE.read_text())
    fail(build.get("commit") == COMMIT and build.get("archiveSha256") == ARCHIVE_SHA
         and build.get("nativeTag") == TAG,
         "native source provenance differs from pinned commit")
    fail(build.get("accelerator") == config.accelerator and build.get("gfx", "") == config.gfx,
         "native image accelerator/GFX mismatch")
    if config.accelerator == "amd":
        fail(build.get("rocmVersion") == "10.1", "pinned ROCm version required")
    return build


def validate_weights(config):
    path = model_file(Path(config.models_dir), config.model_path)
    fail(digest(path) == config.sha256, "model SHA-256 mismatch")
    metadata = gguf_metadata(path)
    fail(metadata.get("general.file_type") == 15, "model quantization is not Q4_K_M")
    if config.role == "embedding":
        architecture = metadata.get("general.architecture", "")
        fail(metadata.get(architecture + ".embedding_length") == config.dimensions, "GGUF embedding dimension mismatch")
    projector = None
    if config.projector_path:
        projector = model_file(Path(config.models_dir), config.projector_path)
        fail(digest(projector) == config.projector_sha256, "projector SHA-256 mismatch")
        fail(gguf_metadata(projector).get("general.file_type") == 32, "projector is not BF16")
    return path, projector


def verify_gpu_device(config):
    if config.accelerator == "cpu":
        return
    if config.accelerator == "amd":
        fail(os.access("/dev/kfd", os.R_OK | os.W_OK), "KFD absent or inaccessible")
        fail(any(os.access(p, os.R_OK | os.W_OK) for p in glob.glob("/dev/dri/renderD*")), "DRI render device inaccessible")
        targets = set()
        for name in glob.glob("/sys/class/kfd/kfd/topology/nodes/*/properties"):
            properties = dict(line.split(maxsplit=1) for line in Path(name).read_text().splitlines() if len(line.split()) == 2)
            raw = int(properties.get("gfx_target_version", "0"))
            if raw:
                targets.add(f"gfx{raw // 10000}{(raw // 100) % 100}{raw % 100}")
        fail(config.gfx in targets, "native host GFX does not match image")
    else:
        fail(any(os.access(p, os.R_OK | os.W_OK) for p in glob.glob("/dev/nvidia[0-9]*")), "NVIDIA device inaccessible")


def command(config, path, projector):
    argv = [BINARY, "--model", str(path), "--alias", config.model_id,
            "--host", "127.0.0.1", "--port", str(config.native_port),
            "--ctx-size", str(config.context), "--parallel", str(config.parallel),
            "--batch-size", str(config.batch), "--ubatch-size", str(config.ubatch),
            "--gpu-layers", config.gpu_layers, "--fit", "off", "--offline",
            "--no-webui", "--no-agent", "--no-ui-mcp-proxy", "--no-slots", "--no-context-shift",
            "--flash-attn", config.flash_attention, "--cache-type-k", config.cache_k,
            "--cache-type-v", config.cache_v, "--load-mode", "none", "--no-repack",
            "--timeout", str(config.request_timeout), "--log-verbosity", "4"]
    if config.role == "embedding":
        argv += ["--embedding", "--pooling", config.pooling, "--embd-normalize", "2"]
    else:
        argv += ["--jinja"]
    if projector:
        argv += ["--mmproj", str(projector)]
    return argv


def child_environment(config):
    # Upstream LLAMA_ARG_* variables can activate built-in tools, router/autoload,
    # remote models or silently override flags. Only our explicit argv controls it.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("LLAMA_ARG_") and k not in ("LLAMA_API_KEY", "HF_TOKEN", "HSA_OVERRIDE_GFX_VERSION")}
    env.update(HOME=config.state_dir, XDG_CACHE_HOME=config.state_dir + "/cache")
    return env


def start_ticks(pid):
    raw = Path(f"/proc/{pid}/stat").read_text()
    return raw.rsplit(")", 1)[1].split()[19]


def process_matches(marker):
    try:
        pid = int(marker["pid"])
        actual = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        actual = [p.decode() for p in actual if p]
        return (start_ticks(pid) == marker["startTicks"]
                and canonical_digest(actual) == marker["commandSha256"])
    except (OSError, ValueError, KeyError, IndexError):
        return False


def write_marker(config, build, state, **extra):
    value = {"schema": 1, "state": state, "identifier": config.model_id, "modelId": config.model_id,
             "role": config.role, "path": config.model_path, "sha256": config.sha256,
             "quant": "Q4_K_M", "quantization": "Q4_K_M", "contextLength": config.context,
             "parallel": config.parallel, "batchSize": config.batch, "ubatchSize": config.ubatch,
             "gpuLayers": config.gpu_layers, "cacheTypeK": config.cache_k, "cacheTypeV": config.cache_v,
             "flashAttention": config.flash_attention, "accelerator": config.accelerator, "gfx": config.gfx,
             "projectorPath": config.projector_path, "projectorSha256": config.projector_sha256,
             "pooling": config.pooling if config.role == "embedding" else "",
             "normalization": "l2" if config.role == "embedding" else "",
             "embeddingDimensions": config.dimensions, "nativeCommit": build["commit"],
             "nativeTag": build["nativeTag"],
             "sourceCommit": build["commit"], "sourceArchiveSha256": build["archiveSha256"],
             "rocmVersion": build.get("rocmVersion", ""), "catalogFingerprint": config.catalog,
             "configFingerprint": config.fingerprint(build), "updatedAt": int(time.time()),
             "supervisorPid": os.getpid(), "supervisorStartTicks": start_ticks(os.getpid()), **extra}
    no_symlinks(Path(config.state_dir))
    no_symlinks(config.marker)
    with tempfile.NamedTemporaryFile(mode="w", dir=config.state_dir, prefix=".readiness-", delete=False) as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
        temporary = stream.name
    os.replace(temporary, config.marker)
    return value


def request(config, endpoint, payload=None, timeout=15):
    body = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{config.native_port}{endpoint}", data=body,
                                 headers={"Content-Type": "application/json"})
    # No OS HTTP proxy must route the internal bootstrap probe off-container.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as response:
            fail(response.status == 200, "native bootstrap HTTP failed")
            raw = response.read(2 * 1024**2 + 1)
            fail(len(raw) <= 2 * 1024**2, "oversized bootstrap response")
            return json.loads(raw)
    except (OSError, ValueError) as error:
        raise RuntimeRejected("native bootstrap HTTP failed") from error


class NativeLog:
    """Capture only pre-public startup diagnostics; never log user payloads."""
    def __init__(self, process, config):
        self.lines = []
        self.bytes = 0
        self.public = threading.Event()
        self.failed = threading.Event()
        self.path = Path(config.state_dir) / "startup.log"
        no_symlinks(self.path)
        self.thread = threading.Thread(target=self.consume, args=(process,), daemon=True)
        self.thread.start()

    def consume(self, process):
        with self.path.open("w") as output:
            os.chmod(self.path, 0o600)
            for raw in iter(process.stdout.readline, b""):
                line = raw.decode("utf-8", errors="replace")[:4096]
                if any(term in line for term in ("GPU Hang", "GPU hang", "HIP error", "CUDA error", "HW Exception")):
                    self.failed.set()
                    # Fixed event only: upstream diagnostics can include user text.
                    print("[llamacpp] native GPU failure detected", file=sys.stderr, flush=True)
                if not self.public.is_set() and self.bytes < 2 * 1024**2:
                    self.lines.append(line)
                    self.bytes += len(raw)
                    output.write(line)
                    output.flush()

    def text(self):
        return "".join(self.lines)


def gpu_proof(config, pid, logs):
    if not config.require_gpu:
        return {"fullGpuOffload": False, "gpuLayersOffloaded": 0, "gpuLayersTotal": 0}
    text = logs.text()
    matches = re.findall(r"offloaded (\d+)/(\d+) layers to GPU", text)
    if not matches:
        maps = Path(f"/proc/{pid}/maps").read_text()
        library = "libggml-hip.so" if config.accelerator == "amd" else "libggml-cuda.so"
        fail(library in maps, "native GPU backend not mapped; CPU-only startup rejected")
    fail(bool(matches), "no native full GPU offload proof")
    offloaded, total = map(int, matches[-1])
    fail(total > 0 and offloaded == total, "partial/CPU GPU offload rejected")
    maps = Path(f"/proc/{pid}/maps").read_text()
    library = "libggml-hip.so" if config.accelerator == "amd" else "libggml-cuda.so"
    fail(library in maps, "native GPU backend not mapped")
    if config.accelerator == "amd":
        fail("libamdhip64.so" in maps, "ROCm userspace not mapped")
        devices = []
        for descriptor in glob.glob(f"/proc/{pid}/fd/*"):
            try:
                devices.append(os.readlink(descriptor))
            except OSError:
                pass
        fail(any(p == "/dev/kfd" for p in devices), "native process has no KFD descriptor")
    fail(not logs.failed.is_set(), "native GPU error during startup")
    return {"fullGpuOffload": True, "gpuLayersOffloaded": offloaded, "gpuLayersTotal": total}


def verify_loaded(config, path):
    models = request(config, "/v1/models").get("data", [])
    fail(len(models) == 1 and models[0].get("id") == config.model_id, "native model alias mismatch")
    props = request(config, "/props")
    fail(props.get("model_path") == str(path), "native loaded physical model differs")
    fail(props.get("total_slots") == config.parallel, "native parallelism differs")
    fail(props.get("default_generation_settings", {}).get("n_ctx") == config.context, "native context differs")
    if config.projector_path:
        fail(props.get("modalities", {}).get("vision") is True, "projector not active")


def inference_proof(config):
    if config.role == "embedding":
        value = request(config, "/v1/embeddings", {"model": config.model_id, "input": ["readonly GPU readiness probe"]}, 120)
        rows = value.get("data", [])
        fail(len(rows) == 1 and rows[0].get("index") == 0, "embedding readiness rows invalid")
        vector = rows[0].get("embedding", [])
        fail(len(vector) == config.dimensions and all(type(x) in (float, int) and math.isfinite(x) for x in vector),
             "embedding readiness dimensions/numbers invalid")
        fail(abs(math.sqrt(sum(x*x for x in vector)) - 1) < 1e-4, "embedding readiness normalization invalid")
        return {"realInference": True, "dimensions": len(vector), "normalization": "l2"}
    value = request(config, "/v1/chat/completions", {"model": config.model_id,
                    "messages": [{"role": "user", "content": "Reply exactly: OK. /no_think"}],
                    "temperature": 0, "max_tokens": 32, "stream": False}, 180)
    choices = value.get("choices", [])
    fail(bool(choices) and isinstance(choices[0].get("message"), dict), "chat readiness response invalid")
    fail(value.get("usage", {}).get("completion_tokens", 0) > 0, "chat readiness generated no tokens")
    proof = {"realInference": True, "dimensions": 0, "visionInference": False}
    if config.projector_path:
        # A deterministic 64x64 RGB image made only from standard-library code.
        # This is image-owned synthetic input, never a user's attachment.
        def chunk(kind, payload):
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
        raw = (b"\0" + bytes((255, 0, 0)) * 64) * 64
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        image = "data:image/png;base64," + base64.b64encode(png).decode()
        vision = request(config, "/v1/chat/completions", {"model": config.model_id,
                         "messages": [{"role": "user", "content": [
                             {"type": "text", "text": "Name this image's dominant color. /no_think"},
                             {"type": "image_url", "image_url": {"url": image}}]}],
                         "temperature": 0, "max_tokens": 32, "stream": False}, 180)
        fail(bool(vision.get("choices")) and vision.get("usage", {}).get("completion_tokens", 0) > 0,
             "vision readiness inference failed")
        proof["visionInference"] = True
    return proof


async def transfer(reader, writer):
    while True:
        data = await reader.read(65536)
        if not data:
            return
        writer.write(data)
        await writer.drain()


async def relay(reader, writer, native_port):
    upstream = None
    tasks = []
    try:
        upstream_reader, upstream = await asyncio.open_connection("127.0.0.1", native_port)
        tasks = [asyncio.create_task(transfer(reader, upstream)), asyncio.create_task(transfer(upstream_reader, writer))]
        # Client EOF means cancellation, not a long-lived abandoned native task.
        # No timeout/aggregation/SSE parsing is added to transparent byte transport.
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    except (OSError, asyncio.CancelledError):
        pass
    finally:
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        for stream in (writer, upstream):
            if stream is not None:
                stream.close()
                try:
                    await stream.wait_closed()
                except OSError:
                    pass


def drop_privileges():
    uid, gid = int(os.environ.get("IM_UID", "10000")), int(os.environ.get("IM_GID", "20000"))
    fail(uid == 10000 and gid == 20000, "runtime requires UID/GID 10000:20000")
    raw = os.environ.get("AI_SUPPLEMENTAL_GIDS", "")
    fail(not raw or bool(re.fullmatch(r"[1-9][0-9]*(?::[1-9][0-9]*)*", raw)), "invalid supplemental device groups")
    groups = sorted({gid, *(int(part) for part in raw.split(":") if part)})
    if os.geteuid() == 0:
        os.setgroups(groups)
        os.setgid(gid)
        os.setuid(uid)
    fail(os.geteuid() == uid and os.getegid() == gid and set(groups).issubset({os.getegid(), *os.getgroups()}),
         "runtime UID/GID/device groups mismatch")


def health(config, ready=False):
    build = validate_build(config)
    no_symlinks(config.marker)
    marker = json.loads(config.marker.read_text())
    fail(marker.get("configFingerprint") == config.fingerprint(build), "stale runtime marker")
    fail(marker.get("state") in ("validating", "loading", "ready"), "native process failed")
    supervisor = int(marker["supervisorPid"])
    fail(start_ticks(supervisor) == marker["supervisorStartTicks"], "stale supervisor process")
    if "pid" in marker:
        fail(process_matches(marker), "native process differs from startup proof")
    if ready:
        fail(marker.get("state") == "ready" and marker.get("proof", {}).get("realInference") is True,
             "native model inference not ready")
        if config.require_gpu:
            fail(marker["proof"].get("fullGpuOffload") is True, "GPU readiness absent")
        # Cheap HTTP health never uses a generation slot or repeats inference.
        fail(request(config, "/health", timeout=5).get("status") == "ok", "native HTTP unhealthy")
        with socket.create_connection(("127.0.0.1", config.port), timeout=3):
            pass


async def serve(config):
    build = validate_build(config)
    directory = Path(config.state_dir)
    no_symlinks(directory)
    fail(directory.is_dir() and os.access(directory, os.W_OK), "state directory not writable")
    write_marker(config, build, "validating")
    process = None
    gate = None
    logs = None
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for number in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(number, stop.set)
    try:
        path, projector = await asyncio.to_thread(validate_weights, config)
        verify_gpu_device(config)
        argv = command(config, path, projector)
        process = subprocess.Popen(argv, env=child_environment(config), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        process_fields = {"pid": process.pid, "startTicks": start_ticks(process.pid), "commandSha256": canonical_digest(argv)}
        logs = NativeLog(process, config)
        write_marker(config, build, "loading", **process_fields)
        deadline = time.monotonic() + config.load_timeout
        while not stop.is_set():
            fail(process.poll() is None and not logs.failed.is_set(), "native engine exited or GPU failed")
            fail(time.monotonic() < deadline, "native model load timeout")
            try:
                if (await asyncio.to_thread(request, config, "/health", timeout=2)).get("status") == "ok":
                    break
            except RuntimeRejected:
                pass
            await asyncio.sleep(1)
        if stop.is_set():
            return 0
        await asyncio.to_thread(verify_loaded, config, path)
        gpu = gpu_proof(config, process.pid, logs)
        proof = await asyncio.to_thread(inference_proof, config)
        proof.update(gpu)
        fail(process.poll() is None and not logs.failed.is_set(), "native process failed after inference")
        logs.public.set()
        gate = await asyncio.start_server(lambda reader, writer: relay(reader, writer, config.native_port), "0.0.0.0", config.port)
        write_marker(config, build, "ready", proof=proof, **process_fields)
        print("[llamacpp] native model ready; inference and exact runtime proved", file=sys.stderr, flush=True)
        while not stop.is_set():
            fail(process.poll() is None and not logs.failed.is_set(), "native engine exited or GPU failed")
            await asyncio.sleep(1)
        return 0
    except BaseException:
        # Gate withdrawal precedes any process shutdown/failure marker.
        if gate:
            gate.close()
            await gate.wait_closed()
            gate = None
        write_marker(config, build, "failed")
        raise
    finally:
        if gate:
            gate.close()
            await gate.wait_closed()
        if process and process.poll() is None:
            process.terminate()
            try:
                await asyncio.to_thread(process.wait, 30)
            except subprocess.TimeoutExpired:
                process.kill()
                await asyncio.to_thread(process.wait)
        if logs:
            logs.thread.join(timeout=5)
        if process and process.stdout:
            process.stdout.close()
        if stop.is_set():
            write_marker(config, build, "stopped")


def main():
    os.umask(0o077)
    mode = sys.argv[1] if len(sys.argv) > 1 else "serve"
    try:
        config = Config.read()
        if mode == "serve":
            drop_privileges()
            return asyncio.run(serve(config))
        fail(mode in ("health", "ready"), "unknown runtime operation")
        health(config, ready=mode == "ready")
        return 0
    except RuntimeRejected as error:
        # All RuntimeRejected strings are fixed, image-owned diagnostics.
        print(f"[llamacpp] {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, IndexError):
        # No args, headers, response body, credential or user payload can leak.
        print("[llamacpp] runtime validation or readiness failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
