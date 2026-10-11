"""Tests for how reconcile.py writes its per-user status without undoing other people's edits.

    python -m unittest readonly-mcp/test_status_write.py        (Linux only: reconcile.py imports fcntl)
"""
import importlib.util
import sys
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reconcile", HERE / "reconcile.py")
reconcile = importlib.util.module_from_spec(spec)
sys.modules["reconcile"] = reconcile  # dataclasses look the module up by name
spec.loader.exec_module(reconcile)


def stamp(age_seconds=0):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - age_seconds))


def status(state="active", checked_at=None):
    return {"credentialSource": "authentik-user-attributes", "checkedAt": checked_at or stamp(),
            "services": {"jira": {"state": state}}, "telegram": {"state": "missing"}}


class FakeAuthentik(reconcile.Authentik):
    """Authentik client whose API is a dictionary: GET returns the *current* stored user, PATCH replaces its attributes."""

    def __init__(self, stored):
        self.stored = stored
        self.calls = []

    def _api(self, path, method="GET", payload=None):
        self.calls.append(method)
        if method == "PATCH":
            self.stored["attributes"] = payload["attributes"]
        return self.stored


class WriteStatusTests(unittest.TestCase):
    def test_an_edit_saved_during_the_run_survives(self):
        snapshot = {"pk": 7, "attributes": {"ai_stand_telegram_user_id": "11111"}}          # taken at the start of the run
        stored = {"pk": 7, "attributes": {"ai_stand_telegram_user_id": "11111",              # what the person saved since
                                          "ai_stand_git_ssh_public_key": "ssh-ed25519 AAAA"}}
        client = FakeAuthentik(stored)
        client.write_status(snapshot, status())
        self.assertEqual(stored["attributes"]["ai_stand_git_ssh_public_key"], "ssh-ed25519 AAAA")
        self.assertEqual(stored["attributes"]["ai_stand_telegram_user_id"], "11111")
        self.assertIn("ai_stand_mcp", stored["attributes"])

    def test_a_removed_value_stays_removed(self):
        snapshot = {"pk": 7, "attributes": {"ai_stand_telegram_user_id": "11111"}}
        stored = {"pk": 7, "attributes": {}}                                                 # the person cleared it meanwhile
        FakeAuthentik(stored).write_status(snapshot, status())
        self.assertNotIn("ai_stand_telegram_user_id", stored["attributes"])

    def test_an_unchanged_recent_status_is_not_written(self):
        stored = {"pk": 7, "attributes": {"ai_stand_mcp": status(checked_at=stamp(60))}}
        client = FakeAuthentik(stored)
        client.write_status({"pk": 7, "attributes": {}}, status())
        self.assertEqual(client.calls, ["GET"])

    def test_a_changed_status_is_written(self):
        stored = {"pk": 7, "attributes": {"ai_stand_mcp": status("needs_credentials", stamp(60))}}
        client = FakeAuthentik(stored)
        client.write_status({"pk": 7, "attributes": {}}, status("active"))
        self.assertEqual(client.calls, ["GET", "PATCH"])
        self.assertEqual(stored["attributes"]["ai_stand_mcp"]["services"]["jira"]["state"], "active")

    def test_an_old_timestamp_is_refreshed(self):
        stored = {"pk": 7, "attributes": {"ai_stand_mcp": status(checked_at=stamp(2 * 3600))}}
        client = FakeAuthentik(stored)
        client.write_status({"pk": 7, "attributes": {}}, status())
        self.assertEqual(client.calls, ["GET", "PATCH"])

    def test_missing_attributes_are_tolerated(self):
        stored = {"pk": 7, "attributes": None}
        FakeAuthentik(stored).write_status({"pk": 7}, status())
        self.assertIn("ai_stand_mcp", stored["attributes"])

    def test_a_user_without_a_key_is_refused(self):
        with self.assertRaises(reconcile.ReconcileError):
            FakeAuthentik({}).write_status({"attributes": {}}, status())


class StatusUnchangedTests(unittest.TestCase):
    def test_edge_cases(self):
        self.assertFalse(reconcile.status_unchanged(None, status()))
        self.assertFalse(reconcile.status_unchanged("text", status()))
        self.assertFalse(reconcile.status_unchanged({"services": {}}, status()))                 # no timestamp
        self.assertFalse(reconcile.status_unchanged(status(checked_at="garbage"), status()))
        self.assertFalse(reconcile.status_unchanged(status(checked_at=stamp(-3600)), status()))  # timestamp in the future
        self.assertTrue(reconcile.status_unchanged(status(checked_at=stamp(10)), status()))


if __name__ == "__main__":
    unittest.main()
