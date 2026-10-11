#!/usr/bin/env python3
"""The recurring jobs of the ai-stand hosts, as one container instead of systemd timers.

    controller.py run          the controller (ai01): runs the jobs named in CONTROLLER_JOBS
    controller.py receive      the certificate receiver (ai02): PUT /v1/certificate
    controller.py healthcheck  exit 0 while the process is alive and making progress

Jobs of `run` (each in its own thread, on its own interval, with a timeout):

    reconcile     readonly-mcp/reconcile.py: user attributes in Authentik -> MCP services, Telegram allowlist (5 min)
    model-access  docker/openwebui/model_access_snapshot.py: Open WebUI model access from the OIDC groups (5 min)
    certbot       certbot/renew.sh: renew the wildcard certificate and hand it to the other node (12 h)

The first two use the operator checkout of the repository, mounted read-only at its host path (the host timers they
replace ran the same files from the same place). The certbot scripts are baked into the image. A job whose input
file does not exist is skipped, never failed: a stand without MCP has nothing to reconcile.

Nothing here prints secrets: the jobs' own output is passed through, and they were written not to emit any.
"""
from __future__ import annotations

import hmac
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable

HEARTBEAT = Path(os.environ.get("CONTROLLER_HEARTBEAT", "/tmp/controller.heartbeat"))
HEARTBEAT_SECONDS = 15
HEALTHY_WITHIN = 90
OUTPUT_TAIL_BYTES = 64 * 1024
MAX_CERT_BODY = 8 * 1024 * 1024


def log(**event) -> None:
    print(json.dumps(event, sort_keys=True, separators=(",", ":")), flush=True)


# --- jobs --------------------------------------------------------------------------------------------------------------

class Job:
    def __init__(self, name: str, argv: list[str], interval: int, timeout: int, first_delay: int,
                 requires: list[str] | None = None, env: dict[str, str] | None = None):
        self.name, self.argv, self.interval, self.timeout = name, argv, interval, timeout
        self.first_delay, self.requires, self.env = first_delay, requires or [], env or {}


def seconds(env: dict[str, str], name: str, default: int, low: int = 1, high: int = 7 * 86400) -> int:
    raw = env.get(name, str(default)).strip()
    if not raw.isdigit() or not low <= int(raw) <= high:
        raise SystemExit(f"{name} must be an integer from {low} to {high}")
    return int(raw)


def storage_root(env: dict[str, str]) -> str:
    """The installation's storage root; compose passes it, so no path under it is spelled out here."""
    root = env.get("STORAGE_ROOT", "")
    if not root.startswith("/") or root.endswith("/") or ".." in root:
        raise SystemExit("STORAGE_ROOT must be the installation's absolute storage root")
    return root


def job_table(env: dict[str, str]) -> dict[str, Job]:
    storage = storage_root(env)
    repo = env.get("AI_STAND_REPO", "/home/setup/ai-stand")
    installation = env.get("AI_STAND_INSTALLATION", "")
    node = env.get("AI_STAND_NODE", "ai01")
    data = env.get("READONLY_MCP_DATA_ROOT", f"{storage}/readonly-mcp-data")
    reconciler_config = env.get("READONLY_MCP_RECONCILER_CONFIG", f"{data}/reconciler/reconciler.json")
    manifest = env.get("READONLY_MCP_MANIFEST", f"{data}/reconciler/manifest.json")
    identity_config = env.get("OPENWEBUI_MODEL_ACCESS_CONFIG", f"{storage}/ai-stand-data/identity/openwebui-model-access.json")
    scripts = env.get("CONTROLLER_SCRIPTS", "/opt/controller")
    python = sys.executable or "/usr/bin/python3"
    return {
        "reconcile": Job(
            "reconcile",
            [python, f"{repo}/readonly-mcp/reconcile.py", "--config", reconciler_config, "--manifest", manifest,
             "--apply-script", f"{repo}/apply.sh", "--installation", installation, "--node", node],
            interval=seconds(env, "CONTROLLER_RECONCILE_INTERVAL", 300), timeout=seconds(env, "CONTROLLER_RECONCILE_TIMEOUT", 1800),
            first_delay=seconds(env, "CONTROLLER_RECONCILE_DELAY", 120, low=0), requires=[reconciler_config]),
        "model-access": Job(
            "model-access", [python, f"{repo}/docker/openwebui/model_access_snapshot.py", "--apply"],
            interval=seconds(env, "CONTROLLER_MODEL_ACCESS_INTERVAL", 300), timeout=seconds(env, "CONTROLLER_MODEL_ACCESS_TIMEOUT", 240),
            first_delay=seconds(env, "CONTROLLER_MODEL_ACCESS_DELAY", 180, low=0), requires=[identity_config]),
        "certbot": Job(
            "certbot", ["bash", f"{scripts}/certbot/renew.sh"],
            interval=seconds(env, "CONTROLLER_CERTBOT_INTERVAL", 43200), timeout=seconds(env, "CONTROLLER_CERTBOT_TIMEOUT", 3600),
            first_delay=seconds(env, "CONTROLLER_CERTBOT_DELAY", 600, low=0)),
    }


def run_command(argv: list[str], timeout: int, env: dict[str, str]) -> tuple[int, str]:
    """Run argv in its own process group; on timeout kill the whole group. Returns (exit code, output tail)."""
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        code = process.returncode
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        code = 124
    return code, output[-OUTPUT_TAIL_BYTES:].decode("utf-8", "replace")


class Runner(threading.Thread):
    def __init__(self, job: Job, stop: threading.Event, environ: dict[str, str]):
        super().__init__(name=job.name, daemon=True)
        self.job, self.stop_event, self.environ = job, stop, environ
        self.last: dict = {}

    def run(self) -> None:
        if self.stop_event.wait(self.job.first_delay):
            return
        while True:
            self.once()
            if self.stop_event.wait(self.job.interval):
                return

    def once(self) -> None:
        missing = [path for path in self.job.requires if not os.path.exists(path)]
        if missing:
            self.last = {"job": self.job.name, "result": "skipped"}
            log(event="job-skipped", job=self.job.name, missing=missing)
            return
        started = time.monotonic()
        env = {**self.environ, **self.job.env}
        try:
            code, output = run_command(self.job.argv, self.job.timeout, env)
        except OSError as error:
            code, output = 127, f"cannot start: {type(error).__name__}"
        took = round(time.monotonic() - started, 1)
        for line in output.splitlines():
            print(f"[{self.job.name}] {line}", flush=True)
        self.last = {"job": self.job.name, "exit": code, "seconds": took, "at": int(time.time())}
        log(event="job" if code == 0 else "job-failed", job=self.job.name, exit=code, seconds=took)


def beat() -> None:
    HEARTBEAT.write_text(str(int(time.time())), encoding="ascii")


def healthy(now: float | None = None) -> bool:
    try:
        age = (time.time() if now is None else now) - HEARTBEAT.stat().st_mtime
    except OSError:
        return False
    return age <= HEALTHY_WITHIN


def run_controller(environ: dict[str, str]) -> int:
    table = job_table(environ)
    names = [name.strip() for name in environ.get("CONTROLLER_JOBS", "reconcile,model-access,certbot").split(",") if name.strip()]
    unknown = [name for name in names if name not in table]
    if unknown:
        print(f"unknown job(s): {', '.join(unknown)}", file=sys.stderr)
        return 2
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    runners = [Runner(table[name], stop, environ) for name in names]
    for runner in runners:
        runner.start()
    log(event="started", jobs=names)
    while not stop.is_set():
        beat()
        stop.wait(HEARTBEAT_SECONDS)
    log(event="stopping")
    for runner in runners:
        runner.join(timeout=20)
    return 0


# --- certificate receiver ----------------------------------------------------------------------------------------------

def make_receiver(environ: dict[str, str], host: str = "0.0.0.0", port: int = 8443) -> ThreadingHTTPServer:
    token_file = Path(environ.get("CERTBOT_RECEIVER_TOKEN_FILE", "/run/secrets/ai-stand-certbot-receiver-token"))
    script = environ.get("CERTBOT_RECEIVE_SCRIPT", "/opt/controller/certbot/receive-cert.sh")
    for name in ("CERT_DOMAIN", "CERTBOT_DATA"):
        if not environ.get(name):
            raise SystemExit(f"{name} is required")
    script_env = {**environ}
    busy = threading.Lock()

    def expected_token() -> str:
        try:
            return token_file.read_text(encoding="ascii").strip()
        except (OSError, UnicodeError):
            return ""

    class Handler(BaseHTTPRequestHandler):
        server_version = "ai-stand-cert-receiver"

        def log_message(self, format: str, *args) -> None:  # noqa: A002 - signature fixed by the base class
            log(event="request", client=self.client_address[0], line=self.requestline.split(" HTTP/")[0])

        def reply(self, status: int, text: str = "") -> None:
            body = text.encode("utf-8", "replace")
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            self.reply(200, "ok\n") if self.path == "/healthz" else self.reply(404, "not found\n")

        def do_PUT(self) -> None:
            if self.path != "/v1/certificate":
                return self.reply(404, "not found\n")
            token = expected_token()
            given = self.headers.get("Authorization", "")
            if not token or not hmac.compare_digest(given.encode(), f"Bearer {token}".encode()):
                return self.reply(403, "forbidden\n")
            length = self.headers.get("Content-Length", "")
            if not length.isdigit():
                return self.reply(411, "Content-Length is required\n")
            if int(length) > MAX_CERT_BODY:
                return self.reply(413, "too large\n")
            body = self.rfile.read(int(length))
            if not busy.acquire(blocking=False):
                return self.reply(409, "another certificate is being received\n")
            try:
                try:
                    result = subprocess.run(["bash", script], input=body, capture_output=True, env=script_env, timeout=300)
                except (OSError, subprocess.TimeoutExpired) as error:
                    return self.reply(500, f"receiver failed: {type(error).__name__}\n")
            finally:
                busy.release()
            text = (result.stdout + result.stderr).decode("utf-8", "replace")[-4000:]
            log(event="certificate", exit=result.returncode)
            self.reply(200 if result.returncode == 0 else 422, text)

    return ThreadingHTTPServer((host, port), Handler)


def heartbeat_forever() -> None:
    while True:
        beat()
        time.sleep(HEARTBEAT_SECONDS)


def run_receiver(environ: dict[str, str]) -> int:
    server = make_receiver(environ, port=int(environ.get("CERTBOT_RECEIVER_PORT", "8443")))
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    threading.Thread(target=heartbeat_forever, daemon=True).start()
    log(event="receiving", port=server.server_address[1])
    server.serve_forever()
    return 0


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    command = args[0] if args else "run"
    if command == "healthcheck":
        return 0 if healthy() else 1
    if command == "run":
        return run_controller(dict(os.environ))
    if command == "receive":
        return run_receiver(dict(os.environ))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
