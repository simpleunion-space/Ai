#!/usr/bin/env python3
"""Convert the old reconciler's non-secret personal record into v1 tenant input.

The adapter exists only during the deliberate email-owner migration.  It does
not create a tenant, choose an endpoint or grant access; those decisions are
made by the immutable ``(issuer, sub)`` mapping helper.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from tenant_manifest import atomic_write_json, validate_inventory


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy-inventory", type=Path, required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    raw = json.loads(args.legacy_inventory.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("version") != 1 or not isinstance(raw.get("users"), list):
        raise SystemExit("legacy personal inventory is invalid")
    users = []
    for entry in raw["users"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("metamcp"), dict):
            raise SystemExit("legacy personal inventory has an invalid user entry")
        personal = entry["metamcp"]
        users.append({
            "issuer": args.issuer,
            "subject": entry.get("subject"),
            "slug": entry.get("slug"),
            "legacyEmail": personal.get("userEmail"),
            "metamcp": {"backendKeySecret": personal.get("backendKeySecret")},
        })
    payload = {"version": 1, "users": users}
    # Validate before writing so a malformed legacy source cannot become a
    # new authority for the migration step.
    validate_inventory(payload)
    atomic_write_json(args.output, payload)


if __name__ == "__main__":
    main()
