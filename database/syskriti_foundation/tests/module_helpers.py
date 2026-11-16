"""Shared helpers for the ordered-migration (002/003) test modules."""
from __future__ import annotations

import hashlib
import os

import psycopg2

from helpers import ACTOR, RUNTIME_LOGIN, WORKER_LOGIN, add_human, open_session, request


def sha(text: str) -> psycopg2.Binary:
    return psycopg2.Binary(hashlib.sha256(text.encode()).digest())


def sha_hex(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def member(t, code, roles=("organization_member",)):
    """Human member bound to the given org-scope roles, with an interactive org session."""
    pid = add_human(t, code, roles=roles)
    return pid, open_session(t.h, t, "sub-" + code, t.org)


def as_user(t, pid, session, org="default"):
    return request(t.h.conn(RUNTIME_LOGIN), t, pid, session, org=org)


def bind_asset_role(cur, t, principal, role_code, asset_id, include_artifacts=False):
    """Exact-asset role binding (explicit sharing), run as an administrator with role.assign."""
    cur.execute("select scope_id from cob3_identity.access_scopes where scope_type = 'asset' and asset_id = %s"
                " and include_workspace_artifacts = %s", (asset_id, include_artifacts))
    row = cur.fetchone()
    if row is None:
        cur.execute("insert into cob3_identity.access_scopes (tenant_id, organization_id, scope_type, asset_id,"
                    " include_workspace_artifacts, created_by, updated_by) values (%s, %s, 'asset', %s, %s, %s, %s) returning scope_id",
                    (t.id, t.org, asset_id, include_artifacts, ACTOR, ACTOR))
        row = cur.fetchone()
    cur.execute("insert into cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, grant_reason,"
                " created_by, updated_by) select %s, %s, r.role_id, %s, %s, 'test share', %s, %s from cob3_identity.roles r"
                " where r.role_code = %s", (t.id, t.org, row[0], principal, ACTOR, ACTOR, role_code))
    assert cur.rowcount == 1


def worker(t, actor="system:test-worker"):
    """Fresh worker connection entered into the tenant/organization worker scope."""
    conn = t.h.connect(WORKER_LOGIN)
    cur = conn.cursor()
    cur.execute("select cob3_identity.set_worker_context(%s, %s, %s)", (t.id, t.org, actor))
    return conn, cur


def ready_file(t, wcur, uploader, label):
    """Worker-registered scanned file; returns (file_object_id, sha hex, size)."""
    digest = hashlib.sha256(label.encode()).digest()
    wcur.execute("insert into cob3_workspace.file_objects (tenant_id, organization_id, uploaded_by_principal_id, storage_provider,"
                 " storage_container, object_key, filename, mime_type, size_bytes, sha256, status, created_by, updated_by)"
                 " values (%s, %s, %s, 's3', 'private', %s, 'x.json', 'application/json', %s, %s, 'ready', 'system:t', 'system:t')"
                 " returning file_object_id",
                 (t.id, t.org, uploader, "obj/" + os.urandom(8).hex(), len(label), psycopg2.Binary(digest)))
    return wcur.fetchone()[0], digest.hex(), len(label)
