"""Tests for the template-variable handling of publisher.py (no Coder, no Docker).

    python -m unittest docker/coder-templates/test_publisher_variables.py
"""
import importlib.util
import sys
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("coder_template_publisher", Path(__file__).resolve().with_name("publisher.py"))
publisher = importlib.util.module_from_spec(spec)
sys.modules["coder_template_publisher"] = publisher
spec.loader.exec_module(publisher)


class TemplateVariableTests(unittest.TestCase):
    def test_parsing_is_stable_and_sorted(self):
        self.assertEqual(publisher.template_variables(None), [])
        self.assertEqual(publisher.template_variables([]), [])
        self.assertEqual(
            publisher.template_variables(["b=2", "ssh_keys_root=/srv/keys/users", "a="]),
            [{"name": "a", "value": ""}, {"name": "b", "value": "2"}, {"name": "ssh_keys_root", "value": "/srv/keys/users"}])
        # Only the first "=" separates; a value may contain more.
        self.assertEqual(publisher.template_variables(["x=a=b"]), [{"name": "x", "value": "a=b"}])

    def test_rejections(self):
        for bad in (["novalue"], ["Bad=1"], ["1a=1"], ["a=1", "a=2"], ["a=" + "x" * 1025], ["a=line\nbreak"], ["a=nul\x00"], ["=v"]):
            with self.subTest(bad), self.assertRaises(publisher.PublisherError):
                publisher.template_variables(bad)

    def test_the_marker_follows_the_variables(self):
        base = "0" * 64
        self.assertEqual(publisher.source_digest(base, []), base)
        one = publisher.source_digest(base, publisher.template_variables(["ssh_keys_root=/a"]))
        again = publisher.source_digest(base, publisher.template_variables(["ssh_keys_root=/a"]))
        other = publisher.source_digest(base, publisher.template_variables(["ssh_keys_root=/b"]))
        self.assertEqual(one, again)
        self.assertNotEqual(one, base)
        self.assertNotEqual(one, other)


if __name__ == "__main__":
    unittest.main()
