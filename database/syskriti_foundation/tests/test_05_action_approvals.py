"""Sensitive action approvals (master prompt test 14), including concurrency."""
from __future__ import annotations

import hashlib
import threading
import time
import uuid

import psycopg2

from helpers import (RUNTIME_LOGIN, admin_org, create_automation, create_role, evaluate, expect_error, issue_credential,
                     make_grant, make_tenant, request, wait_until_blocked)


def _setup(h):
    t = make_tenant(h)
    create_role(t, "org_reader", ["organization.read"])
    bot = create_automation(t, "bot-approvals", roles=("org_reader",))
    with admin_org(t) as cur:
        gid, (entry,) = make_grant(cur, t, t.admin, bot, "delegated", [("organization.read", True)])
        cred, _, _ = issue_credential(cur, gid, "automation", [entry])
    return t, bot, gid, entry, cred


def _digest(*parts) -> bytes:
    return hashlib.sha256("|".join(str(p) for p in parts).encode()).digest()


def _request(rt, t, bot, cred, entry, req_id, digest):
    with request(rt, t, bot, None, cred) as cur:
        cur.execute("select cob3_identity.request_action_approval(%s, %s, 'organization', %s, %s, now() + interval '1 hour')",
                    (entry, req_id, t.org, psycopg2.Binary(digest)))
        return cur.fetchone()[0]


def test_approval_binds_exact_payload_and_is_single_use(h):
    t, bot, gid, entry, cred = _setup(h)
    rt = h.conn(RUNTIME_LOGIN)
    d = evaluate(rt, t, bot, "organization.read", credential=cred)
    assert d["allowed"] and d["requires_approval"]
    req = uuid.uuid4()
    good = _digest("rename-org", t.org, "new-name", bot, gid, req)
    approval = _request(rt, t, bot, cred, entry, req, good)
    # The requester cannot approve; automations have no interactive session at all.
    with request(rt, t, bot, None, cred) as cur:
        expect_error(cur, "select cob3_identity.decide_action_approval(%s, true)", (approval,), code="SKAUZ")
        expect_error(cur, "select cob3_identity.consume_action_approval(%s, %s)", (req, psycopg2.Binary(good)), code="SKAUZ")  # still pending
    with admin_org(t, rt) as cur:
        cur.execute("select cob3_identity.decide_action_approval(%s, true)", (approval,))
    with request(rt, t, bot, None, cred) as cur:
        tampered = _digest("rename-org", t.org, "other-name", bot, gid, req)
        expect_error(cur, "select cob3_identity.consume_action_approval(%s, %s)", (req, psycopg2.Binary(tampered)), code="SKAUZ")
        cur.execute("select cob3_identity.consume_action_approval(%s, %s)", (req, psycopg2.Binary(good)))
        assert cur.fetchone()[0] == approval
    with request(rt, t, bot, None, cred) as cur:
        expect_error(cur, "select cob3_identity.consume_action_approval(%s, %s)", (req, psycopg2.Binary(good)), code="SKAUZ")  # replay
    # The same request id cannot be reused for a new approval.
    with request(rt, t, bot, None, cred) as cur:
        expect_error(cur, "select cob3_identity.request_action_approval(%s, %s, 'organization', %s, %s, now() + interval '1 hour')",
                     (entry, req, t.org, psycopg2.Binary(good)), code="23505")
    # Approved rows are frozen apart from lifecycle columns.
    owner = h.connect("t_installer")
    expect_error(owner.cursor(), "update cob3_identity.action_approvals set target_id = gen_random_uuid() where action_approval_id = %s",
                 (approval,), code="SKIMM")
    owner.rollback()
    owner.close()


def test_approval_consumption_revalidates_requester_access(h):
    t, bot, gid, entry, cred = _setup(h)
    rt = h.conn(RUNTIME_LOGIN)
    req = uuid.uuid4()
    d = _digest("x", req)
    approval = _request(rt, t, bot, cred, entry, req, d)
    with admin_org(t, rt) as cur:
        cur.execute("select cob3_identity.decide_action_approval(%s, true)", (approval,))
        cur.execute("update cob3_identity.role_bindings set status = 'revoked' where principal_id = %s", (bot,))
    with request(rt, t, bot, None, cred) as cur:
        expect_error(cur, "select cob3_identity.consume_action_approval(%s, %s)", (req, psycopg2.Binary(d)), code="SKAUZ")
    with admin_org(t, rt) as cur:
        cur.execute("select status from cob3_identity.action_approvals where action_approval_id = %s", (approval,))
        assert cur.fetchone()[0] == "approved"  # failed consumption rolled back


def test_concurrent_consumption_succeeds_exactly_once(h, admin):
    t, bot, gid, entry, cred = _setup(h)
    rt = h.conn(RUNTIME_LOGIN)
    req = uuid.uuid4()
    d = _digest("delete-team", req)
    approval = _request(rt, t, bot, cred, entry, req, d)
    with admin_org(t, rt) as cur:
        cur.execute("select cob3_identity.decide_action_approval(%s, true)", (approval,))
    results = {}

    def consume(name, hold):
        conn = h.connect(RUNTIME_LOGIN, application_name=f"consume-{name}")
        cur = conn.cursor()
        try:
            cur.execute("select cob3_identity.set_request_context(%s, %s, %s, NULL, %s)", (t.id, t.org, bot, cred))
            cur.execute("select cob3_identity.consume_action_approval(%s, %s)", (req, psycopg2.Binary(d)))
            if hold:
                time.sleep(1.0)
            conn.commit()
            results[name] = "ok"
        except psycopg2.Error as exc:
            conn.rollback()
            results[name] = exc.pgcode
        finally:
            conn.close()

    first = threading.Thread(target=consume, args=("a", True))
    first.start()
    time.sleep(0.3)
    second = threading.Thread(target=consume, args=("b", False))
    second.start()
    assert wait_until_blocked(admin, "consume-b"), "second consumer should block on the approval row"
    first.join()
    second.join()
    assert sorted(results.values()) == ["SKAUZ", "ok"], results
