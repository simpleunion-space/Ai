"""Tests for the Telegram user id attribute handling of reconcile.py.

    python -m unittest readonly-mcp/test_telegram_ids.py
"""
import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reconcile", HERE / "reconcile.py")
reconcile = importlib.util.module_from_spec(spec)
sys.modules["reconcile"] = reconcile  # dataclasses look the module up by name
spec.loader.exec_module(reconcile)


def user(value=..., **extra):
    attributes = dict(extra)
    if value is not ...:
        attributes[reconcile.TELEGRAM_ATTRIBUTE] = value
    return {"uuid": "00000000-0000-0000-0000-000000000001", "attributes": attributes}


class TelegramIdTests(unittest.TestCase):
    def test_plain_numbers_are_accepted(self):
        self.assertEqual(reconcile.telegram_user_id(user("6990181709")), ("6990181709", "active"))
        self.assertEqual(reconcile.telegram_user_id(user("  12345  ")), ("12345", "active"))
        self.assertEqual(reconcile.telegram_user_id(user(6990181709)), ("6990181709", "active"))

    def test_missing_values(self):
        self.assertEqual(reconcile.telegram_user_id(user()), (None, "missing"))
        self.assertEqual(reconcile.telegram_user_id(user("")), (None, "missing"))
        self.assertEqual(reconcile.telegram_user_id(user("   ")), (None, "missing"))
        self.assertEqual(reconcile.telegram_user_id(user(None)), (None, "missing"))
        self.assertEqual(reconcile.telegram_user_id({"uuid": "x"}), (None, "missing"))
        self.assertEqual(reconcile.telegram_user_id({"uuid": "x", "attributes": None}), (None, "missing"))

    def test_nothing_is_guessed(self):
        for bad in ("@username", "-1004424854981", "1234", "0123456", "12 345", "12345abc", "1e9999", "+6990181709",
                    "6990181709\n7", "9" * 16, True, 1.5, ["6990181709"], {"id": 1}):
            self.assertEqual(reconcile.telegram_user_id(user(bad)), (None, "invalid"), repr(bad))


class ApplyShellGuardTests(unittest.TestCase):
    """apply.sh refuses to push anything but a JSON array of 5-15 digit strings."""

    @staticmethod
    def pattern():
        text = (HERE.parent / "apply.sh").read_text(encoding="utf-8")
        match = re.search(r"local telegram_id_list='(.*?)'\n", text)
        assert match, "guard not found in apply.sh"
        return match.group(1)

    def accepts(self, value):
        # the very statement apply.sh uses: the pattern in a variable, unquoted on the right of =~
        script = f"telegram_id_list='{self.pattern()}'; v={value!r}; [[ \"$v\" =~ $telegram_id_list ]]"
        return subprocess.run(["bash", "-c", script], capture_output=True).returncode == 0

    def test_guard(self):
        for good in ('[]', '["12345"]', '["12345","6990181709"]'):
            self.assertTrue(self.accepts(good), good)
        for bad in ('', '[""]', '["1234"]', '[12345]', '["12345",]', '["12345" "6"]', '["12345"],', '["a2345"]', '["12345"]x',
                    '["1234567890123456"]', '{"a":1}'):
            self.assertFalse(self.accepts(bad), bad)


def owner(groups=..., **extra):
    attributes = dict(extra)
    if groups is not ...:
        attributes[reconcile.TELEGRAM_GROUPS_ATTRIBUTE] = groups
    return {"username": "akadmin", "is_active": True, "is_superuser": True, "attributes": attributes}


class TelegramGroupTests(unittest.TestCase):
    GROUP = "-1004424854981"

    def test_the_live_shape_is_accepted_and_normalised(self):
        value = {self.GROUP: {"requireMention": True, "topics": {"9": "claude", "5": "codex", "7": "main"}}}
        groups, state = reconcile.telegram_groups(owner(value))
        self.assertEqual(state, "active")
        self.assertEqual(groups, {self.GROUP: {"requireMention": True, "topics": {"5": "codex", "7": "main", "9": "claude"}}})

    def test_defaults_and_wildcard_topic(self):
        groups, state = reconcile.telegram_groups(owner({self.GROUP: {"topics": {"*": "main"}}}))
        self.assertEqual((state, groups), ("active", {self.GROUP: {"requireMention": True, "topics": {"*": "main"}}}))
        groups, state = reconcile.telegram_groups(owner({self.GROUP: {"requireMention": False}}))
        self.assertEqual((state, groups), ("active", {self.GROUP: {"requireMention": False}}))

    def test_json_text_is_the_same_as_an_object(self):
        text = '{"%s": {"topics": {"5": "codex"}}}' % self.GROUP
        self.assertEqual(reconcile.telegram_groups(owner(text)), reconcile.telegram_groups(owner(json_loads(text))))

    def test_empty_object_means_no_groups_but_missing_means_untouched(self):
        self.assertEqual(reconcile.telegram_groups(owner({})), ({}, "active"))
        self.assertEqual(reconcile.telegram_groups(owner("{}")), ({}, "active"))
        for missing in (owner(), owner(None), owner(""), owner("  "), None, {"attributes": None}):
            self.assertEqual(reconcile.telegram_groups(missing), (None, "missing"), repr(missing))

    def test_one_bad_entry_invalidates_everything(self):
        good = {self.GROUP: {"topics": {"5": "codex"}}}
        bad_values = [
            "not json", "[]", 5, True, ["-1004424854981"],
            {"1004424854981": {}},             # a group id is negative
            {"-12": {}},                       # too short
            {"@group": {}},
            {self.GROUP: "main"},
            {self.GROUP: {"requireMention": "yes"}},
            {self.GROUP: {"unknown": 1}},
            {self.GROUP: {"topics": []}},
            {self.GROUP: {"topics": {"0": "main"}}},
            {self.GROUP: {"topics": {"a": "main"}}},
            {self.GROUP: {"topics": {"5": "Main"}}},
            {self.GROUP: {"topics": {"5": "../x"}}},
            {self.GROUP: {"topics": {"5": 7}}},
            {**good, "-1004424854982": {"topics": {"5": "bad agent"}}},
        ]
        for bad in bad_values:
            self.assertEqual(reconcile.telegram_groups(owner(bad)), (None, "invalid"), repr(bad))

    def test_limits(self):
        many = {"-100%010d" % number: {} for number in range(reconcile.TELEGRAM_MAX_GROUPS + 1)}
        self.assertEqual(reconcile.telegram_groups(owner(many)), (None, "invalid"))
        topics = {str(number + 1): "main" for number in range(reconcile.TELEGRAM_MAX_TOPICS + 1)}
        self.assertEqual(reconcile.telegram_groups(owner({self.GROUP: {"topics": topics}})), (None, "invalid"))


def json_loads(text):
    import json
    return json.loads(text)


class TelegramOwnerLookupTests(unittest.TestCase):
    def authentik(self, users):
        instance = object.__new__(reconcile.Authentik)
        instance.settings = type("S", (), {"telegram_owner_username": "akadmin"})()
        instance._list = lambda path: users
        return instance

    def test_only_an_active_superuser_with_the_exact_name_qualifies(self):
        good = {"username": "akadmin", "is_active": True, "is_superuser": True}
        self.assertIs(self.authentik([good]).telegram_owner(), good)
        for bad in ({**good, "is_superuser": False}, {**good, "is_active": False}, {**good, "username": "akadmin2"},
                    {**good, "is_superuser": "true"}):
            self.assertIsNone(self.authentik([bad]).telegram_owner(), repr(bad))
        self.assertIsNone(self.authentik([]).telegram_owner())


class TelegramManifestTests(unittest.TestCase):
    def test_groups_are_left_out_unless_read_cleanly(self):
        self.assertEqual(reconcile.telegram_manifest(["12345"], "6990181709", None),
                         {"userIds": ["12345"], "ownerIds": ["6990181709"]})
        self.assertEqual(reconcile.telegram_manifest([], None, {}), {"userIds": [], "ownerIds": [], "groups": {}})
        self.assertEqual(reconcile.telegram_manifest(["12345"], "6990181709", {"-1004424854981": {"requireMention": True}}),
                         {"userIds": ["12345"], "ownerIds": ["6990181709"], "groups": {"-1004424854981": {"requireMention": True}}})


if __name__ == "__main__":
    unittest.main()
