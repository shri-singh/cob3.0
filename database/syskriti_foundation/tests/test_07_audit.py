"""Audit/event immutability (master prompt test 18) and audit content."""
from __future__ import annotations

import pytest

from helpers import INSTALLER_ROLE, RUNTIME_LOGIN, admin_org, expect_error, issue_credential, make_grant, make_tenant, request

APPEND_ONLY = ("cob3_identity.audit_events", "cob3_tenant.tenant_lifecycle_events", "cob3_tenant.usage_events",
               "cob3_identity.credential_permission_bindings")


def test_runtime_writers_cannot_update_delete_or_truncate_events(h):
    t = make_tenant(h)
    with admin_org(t) as cur:
        cur.execute("select cob3_identity.record_audit_event('test.event', 'organization', %s, 'success')", (t.org,))
        for table in APPEND_ONLY:
            expect_error(cur, f"update {table} set metadata = '{{}}'", code="42501")
            expect_error(cur, f"delete from {table}", code="42501")
            expect_error(cur, f"truncate {table}", code="42501")
        expect_error(cur, "insert into cob3_identity.audit_events (tenant_id, occurred_at, actor_identifier, action, target_type, outcome, created_by, updated_by)"
                          " values (%s, now(), 'x', 'forged', 'x', 'success', 'system:x', 'system:x')", (t.id,), code="42501")


@pytest.mark.parametrize("table", APPEND_ONLY)
def test_even_the_owner_cannot_rewrite_history(h, table):
    t = make_tenant(h)
    with admin_org(t) as cur:  # guarantee rows in every append-only table
        gid, entries = make_grant(cur, t, t.admin, t.admin, "restricted_self", [("organization.read", False)])
        issue_credential(cur, gid, "personal_api", entries)
        cur.execute("select cob3_tenant.record_usage_event('test.requests', 'gateway', 'evt-audit', now(), 1, %s)", (t.org,))
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    cur.execute(f"select count(*) from {table} where tenant_id = %s", (t.id,))
    assert cur.fetchone()[0] > 0
    expect_error(cur, f"update {table} set metadata = '{{\"x\": 1}}'", code="SKAPP")
    expect_error(cur, f"delete from {table}", code="SKAPP")
    expect_error(cur, f"truncate {table}", code="SKAPP")
    owner.rollback()
    owner.close()


def test_audit_records_actor_grantor_and_no_secrets(h):
    t = make_tenant(h)
    with admin_org(t) as cur:
        gid, entries = make_grant(cur, t, t.admin, t.admin, "restricted_self", [("organization.read", False)])
        cred, public_id, secret = issue_credential(cur, gid, "personal_api", entries)
        cur.execute("select action, actor_identifier, actor_principal_id, session_id, authorization_grant_id, details::text"
                    " from cob3_identity.audit_events where action = 'credential.issue' and target_id = %s", (cred,))
        action, actor, actor_pid, session, grant, details = cur.fetchone()
        assert actor == f"principal:{t.admin}" and actor_pid == t.admin and session == t.admin_org_session and grant == gid
        assert secret.hex() not in details and "secret" not in details.lower()
        # Denied requests with an unverified organization are still auditable.
        cur.execute("select cob3_identity.record_audit_event('access.denied', 'organization', %s, 'denied', 'rbac_denied',"
                    " '{}'::jsonb, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)", (t.org,))
        expect_error(cur, "select cob3_identity.record_audit_event('x', 'y', NULL, 'denied', NULL, '{\"password\": \"hunter2\"}'::jsonb)", code="23514")
    rt = h.conn(RUNTIME_LOGIN)
    with request(rt, t, t.admin, t.admin_org_session, org=t.org) as cur:
        cur.execute("select count(*) from cob3_identity.audit_events where outcome = 'denied'")
        assert cur.fetchone()[0] == 1
