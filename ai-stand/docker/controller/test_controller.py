"""Tests for controller.py: the job scheduler, the certificate receiver and the health check.

    python -m unittest docker/controller/test_controller.py       (POSIX only: process groups, bash)
"""
import http.client
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

spec = importlib.util.spec_from_file_location("controller", Path(__file__).resolve().with_name("controller.py"))
controller = importlib.util.module_from_spec(spec)
sys.modules["controller"] = controller
spec.loader.exec_module(controller)

TOKEN = "receiver-token-0123456789abcdef"


class JobTableTests(unittest.TestCase):
    ROOT = {"STORAGE_ROOT": "/srv/stand"}

    def test_default_jobs_and_arguments(self):
        table = controller.job_table({**self.ROOT, "AI_STAND_REPO": "/r", "AI_STAND_INSTALLATION": "inst", "AI_STAND_NODE": "ai01"})
        self.assertEqual(set(table), {"reconcile", "model-access", "certbot"})
        reconcile = table["reconcile"]
        self.assertIn("/r/readonly-mcp/reconcile.py", reconcile.argv)
        self.assertIn("/r/apply.sh", reconcile.argv)
        self.assertEqual(reconcile.argv[reconcile.argv.index("--installation") + 1], "inst")
        self.assertEqual((reconcile.interval, table["model-access"].interval, table["certbot"].interval), (300, 300, 43200))

    def test_the_inputs_of_the_jobs_follow_the_storage_root(self):
        table = controller.job_table(self.ROOT)
        reconcile = table["reconcile"]
        self.assertEqual(reconcile.argv[reconcile.argv.index("--config") + 1], "/srv/stand/readonly-mcp-data/reconciler/reconciler.json")
        self.assertEqual(reconcile.argv[reconcile.argv.index("--manifest") + 1], "/srv/stand/readonly-mcp-data/reconciler/manifest.json")
        self.assertEqual(reconcile.requires, ["/srv/stand/readonly-mcp-data/reconciler/reconciler.json"])
        self.assertEqual(table["model-access"].requires, ["/srv/stand/ai-stand-data/identity/openwebui-model-access.json"])

    def test_the_storage_root_is_required_and_checked(self):
        for env in ({}, {"STORAGE_ROOT": ""}, {"STORAGE_ROOT": "relative"}, {"STORAGE_ROOT": "/srv/stand/"}, {"STORAGE_ROOT": "/a/../b"}):
            with self.subTest(env), self.assertRaises(SystemExit):
                controller.job_table(env)

    def test_interval_overrides_are_validated(self):
        with self.assertRaises(SystemExit):
            controller.job_table({**self.ROOT, "CONTROLLER_RECONCILE_INTERVAL": "abc"})
        with self.assertRaises(SystemExit):
            controller.job_table({**self.ROOT, "CONTROLLER_RECONCILE_INTERVAL": "0"})
        self.assertEqual(controller.job_table({**self.ROOT, "CONTROLLER_RECONCILE_INTERVAL": "60"})["reconcile"].interval, 60)


class RunnerTests(unittest.TestCase):
    def run_once(self, job):
        runner = controller.Runner(job, threading.Event(), dict(os.environ))
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            runner.once()
        return runner, buffer.getvalue()

    def test_a_successful_job_is_logged_with_its_output(self):
        runner, out = self.run_once(controller.Job("ok", ["sh", "-c", "echo hello; echo there"], 60, 10, 0))
        self.assertEqual(runner.last["exit"], 0)
        self.assertIn("[ok] hello", out)
        self.assertIn('"event":"job"', out)

    def test_a_failing_job_is_reported_as_failed(self):
        runner, out = self.run_once(controller.Job("bad", ["sh", "-c", "echo boom; exit 3"], 60, 10, 0))
        self.assertEqual(runner.last["exit"], 3)
        self.assertIn('"event":"job-failed"', out)

    def test_a_job_without_its_input_is_skipped_not_failed(self):
        runner, out = self.run_once(controller.Job("skip", ["false"], 60, 10, 0, requires=["/nonexistent/config.json"]))
        self.assertEqual(runner.last["result"], "skipped")
        self.assertIn('"event":"job-skipped"', out)
        self.assertNotIn("job-failed", out)

    def test_a_missing_program_is_a_failure_not_a_crash(self):
        runner, out = self.run_once(controller.Job("nope", ["/nonexistent/program"], 60, 10, 0))
        self.assertEqual(runner.last["exit"], 127)

    def test_a_timeout_kills_the_whole_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "child-survived"
            # the shell starts a background child that would write the marker after the timeout
            script = f"(sleep 3; touch {marker}) & sleep 30"
            started = time.monotonic()
            runner, out = self.run_once(controller.Job("slow", ["sh", "-c", script], 60, 1, 0))
            self.assertLess(time.monotonic() - started, 10)
            self.assertEqual(runner.last["exit"], 124)
            time.sleep(3.5)
            self.assertFalse(marker.exists(), "the background child must have been killed with the group")

    def test_the_job_environment_reaches_the_command(self):
        env = dict(os.environ, SOME_SETTING="from-compose")
        runner = controller.Runner(controller.Job("env", ["sh", "-c", "echo $SOME_SETTING"], 60, 10, 0), threading.Event(), env)
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            runner.once()
        self.assertIn("[env] from-compose", buffer.getvalue())

    def test_the_thread_runs_repeatedly_and_stops_promptly(self):
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "count"
            job = controller.Job("tick", ["sh", "-c", f"echo x >> {counter}"], interval=1, timeout=10, first_delay=0)
            stop = threading.Event()
            runner = controller.Runner(job, stop, dict(os.environ))
            with redirect_stdout(io.StringIO()):
                runner.start()
                time.sleep(2.6)
                stop.set()
                runner.join(timeout=5)
            self.assertFalse(runner.is_alive())
            self.assertGreaterEqual(len(counter.read_text().split()), 3)


class HealthTests(unittest.TestCase):
    def test_heartbeat_age(self):
        with tempfile.TemporaryDirectory() as directory:
            original = controller.HEARTBEAT
            controller.HEARTBEAT = Path(directory) / "beat"
            try:
                self.assertFalse(controller.healthy())
                controller.beat()
                now = controller.HEARTBEAT.stat().st_mtime
                self.assertTrue(controller.healthy(now=now + 30))
                self.assertFalse(controller.healthy(now=now + 200))
            finally:
                controller.HEARTBEAT = original

    def test_unknown_job_names_are_refused(self):
        self.assertEqual(controller.run_controller({"STORAGE_ROOT": "/srv/stand", "CONTROLLER_JOBS": "reconcile,bogus"}), 2)


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        (self.dir / "token").write_text(TOKEN + "\n")
        self.script = self.dir / "receive.sh"
        self.received = self.dir / "received.bin"
        self.write_script(f"cat > {self.received}; echo received $(wc -c < {self.received}) bytes for $CERT_DOMAIN; exit 0")
        self.env = {**os.environ, "CERT_DOMAIN": "test.example", "CERTBOT_DATA": str(self.dir),
                    "CERTBOT_RECEIVER_TOKEN_FILE": str(self.dir / "token"), "CERTBOT_RECEIVE_SCRIPT": str(self.script)}
        self.server = controller.make_receiver(self.env, host="127.0.0.1", port=0)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def write_script(self, body):
        self.script.write_text("#!/usr/bin/env bash\n" + body + "\n")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR)

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=20)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read().decode()
        connection.close()
        return response.status, data

    def put(self, body=b"tar-bytes", token=TOKEN, path="/v1/certificate"):
        headers = {"Authorization": f"Bearer {token}"} if token is not None else {}
        return self.request("PUT", path, body=body, headers=headers)

    def test_a_valid_upload_reaches_the_script(self):
        status, text = self.put(b"0123456789")
        self.assertEqual(status, 200)
        self.assertIn("received 10 bytes for test.example", text)
        self.assertEqual(self.received.read_bytes(), b"0123456789")

    def test_a_failing_script_is_a_422_with_its_message(self):
        self.write_script("cat > /dev/null; echo 'certificate has less than 30 days of validity' >&2; exit 1")
        status, text = self.put()
        self.assertEqual(status, 422)
        self.assertIn("less than 30 days", text)

    def test_wrong_missing_or_malformed_tokens_are_refused_before_the_script_runs(self):
        for token in ("wrong", "", None):
            status, _ = self.put(token=token)
            self.assertEqual(status, 403, repr(token))
        status, _ = self.request("PUT", "/v1/certificate", body=b"x", headers={"Authorization": TOKEN})   # no Bearer scheme
        self.assertEqual(status, 403)
        self.assertFalse(self.received.exists())

    def test_an_unreadable_token_file_refuses_everything(self):
        (self.dir / "token").unlink()
        self.assertEqual(self.put()[0], 403)

    def test_other_paths_and_methods(self):
        self.assertEqual(self.put(path="/other")[0], 404)
        self.assertEqual(self.request("GET", "/healthz")[0], 200)
        self.assertEqual(self.request("GET", "/v1/certificate")[0], 404)
        self.assertEqual(self.request("POST", "/v1/certificate", body=b"x")[0], 501)

    def test_oversized_and_unsized_bodies_are_refused(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=20)
        connection.putrequest("PUT", "/v1/certificate")
        connection.putheader("Authorization", f"Bearer {TOKEN}")
        connection.putheader("Content-Length", str(controller.MAX_CERT_BODY + 1))
        connection.endheaders()
        self.assertEqual(connection.getresponse().status, 413)
        connection.close()
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=20)
        connection.putrequest("PUT", "/v1/certificate")
        connection.putheader("Authorization", f"Bearer {TOKEN}")
        connection.endheaders()
        self.assertEqual(connection.getresponse().status, 411)
        connection.close()

    def test_two_uploads_never_run_at_once(self):
        gate = self.dir / "gate"
        self.write_script(f"cat > /dev/null; touch {self.dir}/running; while [ ! -e {gate} ]; do sleep 0.1; done; exit 0")
        first = {}
        thread = threading.Thread(target=lambda: first.update(result=self.put()))
        thread.start()
        deadline = time.monotonic() + 10
        while not (self.dir / "running").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        status, _ = self.put()
        self.assertEqual(status, 409)
        gate.touch()
        thread.join(timeout=10)
        self.assertEqual(first["result"][0], 200)

    def test_missing_configuration_is_refused_at_start(self):
        with self.assertRaises(SystemExit):
            controller.make_receiver({"CERTBOT_DATA": "/x"}, port=0)


if __name__ == "__main__":
    unittest.main()
