#!/usr/bin/env python3
"""Offline contract tests for neutral read-only MCP route rendering."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("render-profile.py")
SPEC = importlib.util.spec_from_file_location("readonly_mcp_render_profile", MODULE_PATH)
assert SPEC and SPEC.loader
renderer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = renderer
SPEC.loader.exec_module(renderer)


USER = {
    "subject": "01234567-89ab-cdef-0123-456789abcdef",
    "slug": "u-a23d006bb020a81dfd1afa1",
    "services": {
        "jira": {
            "credentialSecret": "ai-stand-mcp-jira-u-a23d006bb020a81dfd1afa1-credentials-v1",
            "internalTokenSecret": "ai-stand-mcp-jira-u-a23d006bb020a81dfd1afa1-internal-v1",
            "secretVersion": 1,
        },
    },
    "metamcp": None,
}


class RenderPathContractTests(unittest.TestCase):
    def test_generic_path_prefix_is_rendered_consistently(self) -> None:
        rendered = renderer.render_agentgateway(
            "# READONLY_MCP_ROUTES_RENDER\n",
            [USER],
            "https://agentgateway.example.invalid",
            "https://authentik.example.invalid/application/o/mcp/",
            "agentgateway-mcp",
            "https://openwebui.example.invalid",
            "/mcp/work",
        )
        self.assertIn("pathPrefix: /mcp/work/jira-readonly-mcp", rendered)
        self.assertIn(
            "resource: https://agentgateway.example.invalid/mcp/work/jira-readonly-mcp",
            rendered,
        )
        # OAuth resource metadata is stable before any subject has stored
        # credentials for a particular MCP type.
        self.assertIn("/mcp/work/confluence-readonly-mcp", rendered)
        self.assertIn('require: "\'ai-users\' in jwt.groups"', rendered)
        self.assertIn(
            'allow: "jwt.sub == \\\"01234567-89ab-cdef-0123-456789abcdef\\\" && mcp.tool.target == \\\"jira-u-a23d006bb020a81dfd1afa1\\\""',
            rendered,
        )
        self.assertNotIn("&& (", rendered)

    def test_openclaw_overlay_receives_the_same_prefix(self) -> None:
        rendered = renderer.render_compose(
            [USER],
            {"jira": "jira:test", "confluence": "confluence:test", "imap": "imap:test"},
            "https://agentgateway.example.invalid",
            {
                "jiraBaseUrl": "https://jira.example.invalid",
                "confluenceBaseUrl": "https://confluence.example.invalid",
                "imapHost": "imap.example.invalid",
                "imapPort": 993,
                "imapTlsMode": "implicit",
            },
            "/mcp/work",
        )
        self.assertIn("ai-mcp-backend:", rendered)
        self.assertIn("name: ai-stand_ai-mcp-backend", rendered)
        self.assertNotIn("ai-network:", rendered)

    def test_gigacode_route_is_bound_to_the_owner_subject(self) -> None:
        user = {**USER, "services": {
            "gigacode": {
                "deviceIdSecret": "ai-stand-gigacode-u-a23d006bb020a81dfd1afa1-device-v1",
                "internalTokenSecret": "ai-stand-gigacode-u-a23d006bb020a81dfd1afa1-internal-v1",
                "secretVersion": 1,
            },
        }}
        rendered = renderer.render_agentgateway(
            "# READONLY_MCP_ROUTES_RENDER\n",
            [user],
            "https://agentgateway.example.invalid",
            "https://authentik.example.invalid/application/o/mcp/",
            "agentgateway-mcp",
            "https://openwebui.example.invalid",
            "/mcp/work",
        )
        self.assertIn("pathPrefix: /_internal/gigacode/u-a23d006bb020a81dfd1afa1/chat/completions", rendered)
        self.assertIn("pathPrefix: /_internal/gigacode/u-a23d006bb020a81dfd1afa1/responses", rendered)
        self.assertIn('jwt.sub == \\"01234567-89ab-cdef-0123-456789abcdef\\"', rendered)
        self.assertIn("file: /run/secrets/ai-stand-gigacode-u-a23d006bb020a81dfd1afa1-internal-v1", rendered)
        self.assertIn("full: /v1/chat/completions", rendered)
        self.assertIn("full: /v1/responses", rendered)

        compose = renderer.render_compose(
            [user],
            {
                "jira": "jira:test",
                "confluence": "confluence:test",
                "imap": "imap:test",
                "gigacode": "gigacode:test",
            },
            "https://agentgateway.example.invalid",
            {
                "jiraBaseUrl": "https://jira.example.invalid",
                "confluenceBaseUrl": "https://confluence.example.invalid",
                "imapHost": "imap.example.invalid",
                "imapPort": 993,
                "imapTlsMode": "implicit",
            },
            "/mcp/work",
        )
        self.assertIn("gigacode-subscription-bridge-u-a23d006bb020a81dfd1afa1:", compose)
        self.assertIn("ai-models-backend:", compose)

    def test_empty_manifest_keeps_all_oauth_routes_and_denies_dispatch(self) -> None:
        rendered = renderer.render_agentgateway(
            "# READONLY_MCP_ROUTES_RENDER\n",
            [],
            "https://agentgateway.example.invalid",
            "https://authentik.example.invalid/application/o/mcp/",
            "agentgateway-mcp",
            "https://openwebui.example.invalid",
            "/mcp/work",
        )
        for kind in ("jira", "confluence", "imap", "personal"):
            self.assertIn(f"name: readonly-{kind}", rendered)
        self.assertEqual(rendered.count('allow: "false"'), 4)
        self.assertEqual(rendered.count("          targets: []"), 4)

    def test_only_safe_generic_prefixes_are_accepted(self) -> None:
        self.assertTrue(renderer.MCP_PATH_PREFIX.fullmatch("/mcp/work"))
        self.assertFalse(renderer.MCP_PATH_PREFIX.fullmatch("/mcp/work/extra"))
        self.assertFalse(renderer.MCP_PATH_PREFIX.fullmatch("https://invalid.example"))


if __name__ == "__main__":
    unittest.main()
