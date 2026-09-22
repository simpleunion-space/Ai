#!/usr/bin/env python3
"""MetaMCP tenant identity control plane.

This is intentionally narrower than a MetaMCP administration client.  It
performs one of two fail-closed operations against the *pinned* central
MetaMCP PostgreSQL schema:

* ``migrate-email-owners`` establishes the one-time relation from an existing
  email-owned MetaMCP user to immutable Authentik ``(issuer, sub)``;
* ``reconcile`` requires that relation to exist and writes a non-secret
  descriptor for isolated per-user tenant runtimes.

All inventory values are transported into PostgreSQL through ``COPY`` to a
temporary table.  They are never interpolated into SQL, environment variables
or command-line arguments.  Database credentials remain in the already
mounted Docker Secret inside the PostgreSQL task.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

from tenant_manifest import TenantManifestError, atomic_write_json, load_inventory
from tenant_runtime import TenantDescriptorError, TenantIdentity, descriptor_for


EXPECTED_IMAGE = "ghcr.io/metatool-ai/metamcp:2.4.22"
SAFE_STACK_NAME = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
CONTAINER_ID = re.compile(r"^[0-9a-f]{12,64}$")
SCHEMA_COLUMNS = {
    ("users", "id"),
    ("users", "email"),
    ("accounts", "user_id"),
    ("accounts", "account_id"),
    ("accounts", "provider_id"),
}


class ProvisionError(RuntimeError):
    """A control-plane error that must not emit a partial tenant manifest."""


def fail(message: str) -> ProvisionError:
    return ProvisionError(f"MetaMCP tenant provisioning refused: {message}")


def copy_escape(values: list[str]) -> str:
    """Encode values for PostgreSQL COPY text format without SQL interpolation."""
    def escape(value: str) -> str:
        return (
            value.replace("\\", "\\\\")
            .replace("\t", "\\t")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
        )

    return "\t".join(escape(value) for value in values) + "\n"


class Postgres:
    def __init__(self, stack_name: str) -> None:
        if not SAFE_STACK_NAME.fullmatch(stack_name):
            raise fail("stack name is unsafe")
        result = subprocess.run(
            [
                "docker", "ps", "--filter",
                f"label=com.docker.swarm.service.name={stack_name}_metamcp-postgres",
                "--format", "{{.ID}}",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        identifiers = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if result.returncode or len(identifiers) != 1 or not CONTAINER_ID.fullmatch(identifiers[0]):
            raise fail("exactly one local MetaMCP PostgreSQL task is required")
        self.container_id = identifiers[0]

    def sql(self, script: str) -> str:
        # The shell fragment is constant.  It reads the password only inside
        # the already running database task and receives SQL solely on stdin.
        command = (
            "set -eu\n"
            "export PGPASSWORD=\"$(cat /run/secrets/ai-stand-metamcp-postgres-password)\"\n"
            "exec psql --no-psqlrc --quiet --tuples-only --no-align "
            "--set ON_ERROR_STOP=1 -U metamcp -d metamcp\n"
        )
        result = subprocess.run(
            ["docker", "exec", "-i", self.container_id, "sh", "-ec", command],
            input=script,
            check=False,
            stdout=subprocess.PIPE,
            # psql can echo a failed COPY record.  Treat its diagnostics as
            # sensitive and only expose the generic error below.
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if result.returncode:
            raise fail("pinned database transaction failed")
        return result.stdout

    def assert_schema(self) -> None:
        values = ",".join(f"('{table}','{column}')" for table, column in sorted(SCHEMA_COLUMNS))
        output = self.sql(
            "SELECT count(*) FROM information_schema.columns "
            "WHERE table_schema = 'public' AND (table_name, column_name) IN ("
            + values
            + ");\n"
        ).strip()
        if output != str(len(SCHEMA_COLUMNS)):
            raise fail("MetaMCP schema does not match the pinned identity contract")


def transaction_script(users: list[dict[str, str]], migrate: bool) -> str:
    """Make one serializable all-or-nothing mapping transaction for all users."""
    copy_rows = "".join(
        copy_escape([
            user["issuer"],
            user["subject"],
            user["legacyEmail"],
            user["slug"],
            user["backendKeySecret"],
        ])
        for user in users
    )
    mode = "true" if migrate else "false"
    return f"""BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
CREATE TABLE IF NOT EXISTS ai_stand_metamcp_tenant_identities (
  issuer text NOT NULL,
  subject uuid NOT NULL,
  metamcp_user_id text NOT NULL,
  legacy_email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (issuer, subject),
  UNIQUE (metamcp_user_id)
);
LOCK TABLE ai_stand_metamcp_tenant_identities IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE _ai_stand_tenant_request (
  issuer text NOT NULL,
  subject uuid NOT NULL,
  legacy_email text NOT NULL,
  slug text NOT NULL,
  backend_key_secret text NOT NULL
) ON COMMIT DROP;
COPY _ai_stand_tenant_request (issuer, subject, legacy_email, slug, backend_key_secret) FROM STDIN WITH (FORMAT text);
{copy_rows}\\.
DO $ai_stand$
DECLARE
  request record;
  mapped_user_id text;
  candidate_count integer;
  candidate_user_id text;
BEGIN
  FOR request IN SELECT * FROM _ai_stand_tenant_request ORDER BY issuer, subject LOOP
    SELECT metamcp_user_id INTO mapped_user_id
      FROM ai_stand_metamcp_tenant_identities
      WHERE issuer = request.issuer AND subject = request.subject;
    IF FOUND THEN
      IF (SELECT count(*) FROM users WHERE id::text = mapped_user_id) <> 1 THEN
        RAISE EXCEPTION 'mapped MetaMCP user no longer exists';
      END IF;
      CONTINUE;
    END IF;
    IF NOT {mode} THEN
      RAISE EXCEPTION 'missing immutable issuer/sub ownership mapping';
    END IF;
    SELECT count(*), min(id::text) INTO candidate_count, candidate_user_id
      FROM users WHERE lower(email) = lower(request.legacy_email);
    IF candidate_count <> 1 THEN
      RAISE EXCEPTION 'legacy email ownership is absent or ambiguous';
    END IF;
    IF EXISTS (
      SELECT 1 FROM ai_stand_metamcp_tenant_identities
      WHERE metamcp_user_id = candidate_user_id
        AND (issuer <> request.issuer OR subject <> request.subject)
    ) THEN
      RAISE EXCEPTION 'MetaMCP user already belongs to a different immutable identity';
    END IF;
    INSERT INTO ai_stand_metamcp_tenant_identities
      (issuer, subject, metamcp_user_id, legacy_email)
    VALUES (request.issuer, request.subject, candidate_user_id, request.legacy_email);
  END LOOP;
END $ai_stand$;
SELECT request.issuer || E'\\t' || request.subject::text || E'\\t' || request.slug || E'\\t' || map.metamcp_user_id || E'\\t' || request.backend_key_secret
  FROM _ai_stand_tenant_request AS request
  JOIN ai_stand_metamcp_tenant_identities AS map
    ON map.issuer = request.issuer AND map.subject = request.subject
  ORDER BY request.issuer, request.subject;
COMMIT;
"""


def mappings_from_rows(rows: str) -> list[dict[str, str]]:
    mappings: list[dict[str, str]] = []
    for line in rows.splitlines():
        fields = line.split("\t")
        if len(fields) != 5 or any(not field for field in fields):
            raise fail("database returned an invalid ownership mapping")
        issuer, subject, slug, metamcp_user_id, backend_key_secret = fields
        mappings.append({
            "issuer": issuer,
            "subject": subject,
            "slug": slug,
            "metamcpUserId": metamcp_user_id,
            "backendKeySecret": backend_key_secret,
        })
    return mappings


def build_runtime_manifest(mappings: list[dict[str, str]]) -> dict:
    tenants = []
    seen_ids: set[str] = set()
    for mapping in mappings:
        try:
            tenant = descriptor_for(TenantIdentity(
                issuer=mapping["issuer"],
                subject=mapping["subject"],
                slug=mapping["slug"],
                metamcp_user_id=mapping["metamcpUserId"],
                backend_key_secret=mapping["backendKeySecret"],
            ))
        except TenantDescriptorError as exc:
            raise fail(str(exc)) from exc
        if tenant["tenantId"] in seen_ids:
            raise fail("descriptor has a colliding tenant ID")
        seen_ids.add(tenant["tenantId"])
        tenants.append(tenant)
    return {
        "version": 1,
        "schemaContract": "metamcp-2.4.22-identity-v1",
        "tenants": tenants,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migrate-email-owners", action="store_true", help="perform the explicit one-time email-to-(issuer,sub) migration")
    parser.add_argument("--inventory", type=Path, required=True, help="non-secret identity inventory")
    parser.add_argument("--stack-name", required=True)
    parser.add_argument("--metamcp-image", required=True)
    parser.add_argument("--output", type=Path, help="write the fail-closed isolated tenant runtime descriptor")
    args = parser.parse_args()

    if args.metamcp_image != EXPECTED_IMAGE:
        raise fail(f"expected pinned MetaMCP image {EXPECTED_IMAGE}")
    if args.migrate_email_owners and args.output:
        raise fail("migration does not emit a runtime descriptor; run reconcile separately after review")
    if not args.migrate_email_owners and not args.output:
        raise fail("reconcile requires --output")

    users = load_inventory(args.inventory)
    database = Postgres(args.stack_name)
    database.assert_schema()
    mappings = mappings_from_rows(database.sql(transaction_script(users, args.migrate_email_owners)))
    if len(mappings) != len(users):
        raise fail("database did not return one mapping per requested identity")
    if args.output:
        atomic_write_json(args.output, build_runtime_manifest(mappings))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ProvisionError, TenantManifestError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
