"""Identity invariants (master prompt tests 9, 10) plus last-admin protection."""
from __future__ import annotations

import threading
import time
import uuid

import psycopg2

from helpers import (ACTOR, INSTALLER_ROLE, RUNTIME_LOGIN, add_human, admin_org, admin_tenant, create_automation,
                     create_role, expect_commit_error, expect_error, issue_credential, make_grant, make_tenant,
                     wait_until_blocked)


def _new_org(cur, t, code, parent=None):
    oid = uuid.uuid4()
    cur.execute("insert into cob3_identity.organizations (tenant_id, organization_id, organization_code, name, parent_organization_id, created_by, updated_by)"
                " values (%s, %s, %s, %s, %s, %s, %s)", (t.id, oid, code, code, parent, ACTOR, ACTOR))
    return oid


def test_hierarchy_cycles_rejected(h):
    t = make_tenant(h)
    with admin_tenant(t) as cur:
        b = _new_org(cur, t, "org-b", parent=t.org)
        c = _new_org(cur, t, "org-c", parent=b)
        expect_error(cur, "update cob3_identity.organizations set parent_organization_id = %s where organization_id = %s", (c, t.org), code="SKINV")
        expect_error(cur, "update cob3_identity.organizations set parent_organization_id = organization_id where organization_id = %s", (b,), code="SKINV")
    with admin_org(t) as cur:
        t1, t2 = uuid.uuid4(), uuid.uuid4()
        for tid, code, parent in ((t1, "t1", None), (t2, "t2", t1)):
            cur.execute("insert into cob3_identity.teams (tenant_id, team_id, organization_id, team_code, name, team_type, parent_team_id, created_by, updated_by)"
                        " values (%s, %s, %s, %s, %s, 'project', %s, %s, %s)", (t.id, tid, t.org, code, code, parent, ACTOR, ACTOR))
        expect_error(cur, "update cob3_identity.teams set parent_team_id = %s where team_id = %s", (t2, t1), code="SKINV")


def test_concurrent_cycle_attempts_rejected(h, admin):
    t = make_tenant(h)
    with admin_tenant(t) as cur:
        x = _new_org(cur, t, "org-x")
        y = _new_org(cur, t, "org-y")
    results = {}

    def reparent(name, child, parent, hold):
        conn = h.connect(RUNTIME_LOGIN, application_name=f"cyc-{name}")
        cur = conn.cursor()
        try:
            cur.execute("select cob3_identity.set_request_context(%s, NULL, %s, %s, NULL)", (t.id, t.admin, t.admin_tenant_session))
            cur.execute("update cob3_identity.organizations set parent_organization_id = %s where organization_id = %s", (parent, child))
            if hold:
                time.sleep(1.0)
            conn.commit()
            results[name] = "ok"
        except psycopg2.Error as exc:
            conn.rollback()
            results[name] = exc.pgcode
        finally:
            conn.close()

    a = threading.Thread(target=reparent, args=("a", x, y, True))
    a.start()
    time.sleep(0.3)
    b = threading.Thread(target=reparent, args=("b", y, x, False))
    b.start()
    assert wait_until_blocked(admin, "cyc-b"), "second writer should wait on the hierarchy lock"
    a.join()
    b.join()
    assert sorted(results.values()) == ["SKINV", "ok"], results


def test_grant_shape_subtype_and_envelope_rules(h):
    t = make_tenant(h)
    bot = create_automation(t, "bot-1")
    human2 = add_human(t, "dana")
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    base = ("insert into cob3_identity.authorization_grants (tenant_id, organization_id, grantor_principal_id, grantee_principal_id,"
            " grant_type, valid_until, grant_reason, created_by, updated_by) values (%s, %s, %s, %s, %s, now() + interval '1 day', 'x', %s, %s)")
    expect_error(cur, base, (t.id, t.org, t.admin, human2, "restricted_self", ACTOR, ACTOR), code="23514")  # grantor<>grantee
    expect_error(cur, base, (t.id, t.org, bot, bot, "restricted_self", ACTOR, ACTOR), code="SKINV")       # automation self grant
    expect_error(cur, base, (t.id, t.org, bot, t.admin, "delegated", ACTOR, ACTOR), code="SKINV")         # automation as grantor
    expect_error(cur, base, (t.id, t.org, t.admin, human2, "delegated", ACTOR, ACTOR), code="SKINV")      # delegate to a human
    expect_error(cur, base.replace("grant_reason,", "grant_reason, status,").replace("'x',", "'x', 'active',"),
                 (t.id, t.org, t.admin, t.admin, "restricted_self", ACTOR, ACTOR), code="SKSTA")      # cannot insert active
    owner.rollback()

    create_role(t, "org_reader", ["organization.read", "team.read"])
    with admin_org(t) as rcur:
        gid, (e1,) = make_grant(rcur, t, t.admin, bot, "delegated", [("organization.read", False)])
        # IAM permission can never be placed in a delegated (automation) grant.
        rcur.execute("select cob3_identity.create_authorization_grant(%s, %s, 'restricted_self', now(), now() + interval '1 day', 'x')", (t.admin, t.admin))
        draft = rcur.fetchone()[0]
        g2, (e2,) = make_grant(rcur, t, t.admin, t.admin, "restricted_self", [("team.read", False)])
    # Envelope immutable after authorization.
    cur = owner.cursor()
    expect_error(cur, "insert into cob3_identity.authorization_grant_permissions (tenant_id, organization_id, authorization_grant_id, permission_id, scope_id, created_by, updated_by)"
                      " select %s, %s, %s, permission_id, %s, %s, %s from cob3_identity.permissions where tenant_id = %s and permission_code = 'team.read'",
                 (t.id, t.org, gid, t.org_scope, ACTOR, ACTOR, t.id), code="SKIMM")
    expect_error(cur, "update cob3_identity.authorization_grants set valid_until = valid_until + interval '30 days' where authorization_grant_id = %s", (gid,), code="SKIMM")
    expect_error(cur, "update cob3_identity.authorization_grants set grant_reason = 'widened' where authorization_grant_id = %s", (gid,), code="SKIMM")
    expect_error(cur, "delete from cob3_identity.authorization_grant_permissions where authorization_grant_id = %s", (gid,), code="SKIMM")
    # Delegated entries cannot carry IAM permissions.
    gx = uuid.uuid4()
    expect_error(cur, "insert into cob3_identity.authorization_grants (tenant_id, organization_id, authorization_grant_id, grantor_principal_id, grantee_principal_id,"
                      " grant_type, valid_until, grant_reason, created_by, updated_by) values (%s, %s, %s, %s, %s, 'delegated', now() + interval '1 day', 'x', %s, %s);"
                      " insert into cob3_identity.authorization_grant_permissions (tenant_id, organization_id, authorization_grant_id, permission_id, scope_id, created_by, updated_by)"
                      " select %s, %s, %s, permission_id, %s, %s, %s from cob3_identity.permissions where tenant_id = %s and permission_code = 'team.manage'",
                 (t.id, t.org, gx, t.admin, bot, ACTOR, ACTOR, t.id, t.org, gx, t.org_scope, ACTOR, ACTOR, t.id), code="SKINV")
    owner.rollback()
    # Empty envelope cannot be authorized.
    with admin_org(t) as rcur:
        expect_error(rcur, "select cob3_identity.authorize_authorization_grant(%s)", (draft,), code="SKINV")
    # Same-grant integrity for credentials and bindings.
    with admin_org(t) as rcur:
        cred, _, _ = issue_credential(rcur, g2, "personal_api", [e2])
        expect_error(rcur, "select cob3_identity.issue_principal_credential(%s, 'k', 'personal_api', %s, %s, 'sha256', 'api://cob3', now() + interval '1 hour', %s::uuid[])",
                     (g2, "pk_" + uuid.uuid4().hex[:16], psycopg2.Binary(b"x" * 32), [e1]), code="23503")
    cur = owner.cursor()
    fresh = uuid.uuid4()
    cur.execute("insert into cob3_identity.principal_credentials (tenant_id, organization_id, credential_id, principal_id, authorization_grant_id, credential_name, credential_usage,"
                " public_identifier, secret_digest, digest_algorithm, audience, expires_at, created_by, updated_by)"
                " values (%s, %s, %s, %s, %s, 'k', 'personal_api', 'pk_samegrant01', %s, 'sha256', 'api', now() + interval '1 hour', %s, %s)",
                (t.id, t.org, fresh, t.admin, g2, psycopg2.Binary(b"y" * 32), ACTOR, ACTOR))
    # Same transaction, but the entry belongs to ANOTHER grant: compound FK rejects it.
    expect_error(cur, "insert into cob3_identity.credential_permission_bindings (tenant_id, organization_id, credential_id, authorization_grant_id, authorization_grant_permission_id, created_by, updated_by)"
                      " values (%s, %s, %s, %s, %s, %s, %s)", (t.id, t.org, fresh, g2, e1, ACTOR, ACTOR), code="23503")
    expect_error(cur, "insert into cob3_identity.credential_permission_bindings (tenant_id, organization_id, credential_id, authorization_grant_id, authorization_grant_permission_id, created_by, updated_by)"
                      " values (%s, %s, %s, %s, %s, %s, %s)", (t.id, t.org, fresh, gid, e1, ACTOR, ACTOR), code="23503")
    expect_error(cur, "insert into cob3_identity.credential_permission_bindings (tenant_id, organization_id, credential_id, authorization_grant_id, authorization_grant_permission_id, created_by, updated_by)"
                      " values (%s, %s, %s, %s, %s, %s, %s)", (t.id, t.org, cred, g2, e2, ACTOR, ACTOR), code="SKIMM")  # later transaction
    expect_error(cur, "update cob3_identity.credential_permission_bindings set metadata = '{\"a\": 1}' where credential_id = %s", (cred,), code="SKAPP")
    # Credential principal must be the grantee; expiry within the grant; usage matches principal type.
    expect_error(cur, "insert into cob3_identity.principal_credentials (tenant_id, organization_id, principal_id, authorization_grant_id, credential_name, credential_usage,"
                      " public_identifier, secret_digest, digest_algorithm, audience, expires_at, created_by, updated_by)"
                      " values (%s, %s, %s, %s, 'k', 'personal_api', 'pk_aaaaaaaaaaaa', %s, 'sha256', 'api', now() + interval '1 hour', %s, %s)",
                 (t.id, t.org, t.admin, gid, psycopg2.Binary(b"x" * 32), ACTOR, ACTOR), code="23503")
    expect_error(cur, "insert into cob3_identity.principal_credentials (tenant_id, organization_id, principal_id, authorization_grant_id, credential_name, credential_usage,"
                      " public_identifier, secret_digest, digest_algorithm, audience, expires_at, created_by, updated_by)"
                      " values (%s, %s, %s, %s, 'k', 'personal_api', 'pk_bbbbbbbbbbbb', %s, 'sha256', 'api', now() + interval '400 days', %s, %s)",
                 (t.id, t.org, t.admin, g2, psycopg2.Binary(b"x" * 32), ACTOR, ACTOR), code="SKINV")
    expect_error(cur, "insert into cob3_identity.principal_credentials (tenant_id, organization_id, principal_id, authorization_grant_id, credential_name, credential_usage,"
                      " public_identifier, secret_digest, digest_algorithm, audience, expires_at, created_by, updated_by)"
                      " values (%s, %s, %s, %s, 'k', 'personal_api', 'pk_cccccccccccc', %s, 'sha256', 'api', now() + interval '1 hour', %s, %s)",
                 (t.id, t.org, bot, gid, psycopg2.Binary(b"x" * 32), ACTOR, ACTOR), code="SKINV")
    # Credential revocation is terminal.
    cur.execute("update cob3_identity.principal_credentials set status = 'revoked' where credential_id = %s", (cred,))
    expect_error(cur, "update cob3_identity.principal_credentials set status = 'active' where credential_id = %s", (cred,), code="SKSTA")
    owner.rollback()
    owner.close()


def test_creator_owner_and_membership_type_rules(h):
    t = make_tenant(h)
    bot = create_automation(t, "bot-owner-test")
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    pid = uuid.uuid4()
    cur.execute("insert into cob3_identity.principals (tenant_id, principal_id, principal_type, principal_code, display_name, created_by, updated_by)"
                " values (%s, %s, 'automation', 'bot-child', 'Child', %s, %s)", (t.id, pid, ACTOR, ACTOR))
    cur.execute("insert into cob3_identity.organization_memberships (tenant_id, organization_id, principal_id, membership_type, status, created_by, updated_by)"
                " values (%s, %s, %s, 'automation', 'active', %s, %s)", (t.id, t.org, pid, ACTOR, ACTOR))
    # An automation cannot create another automation (no recursion / self-provisioning).
    expect_error(cur, "insert into cob3_identity.automation_profiles (tenant_id, principal_id, organization_id, creator_principal_id, owner_principal_id, purpose,"
                      " automation_category, creation_method, created_by, updated_by) values (%s, %s, %s, %s, %s, 'x', 'agent', 'api', %s, %s)",
                 (t.id, pid, t.org, bot, t.admin, ACTOR, ACTOR), code="SKINV")
    # Owner must be human.
    expect_error(cur, "insert into cob3_identity.automation_profiles (tenant_id, principal_id, organization_id, creator_principal_id, owner_principal_id, purpose,"
                      " automation_category, creation_method, created_by, updated_by) values (%s, %s, %s, %s, %s, 'x', 'agent', 'api', %s, %s)",
                 (t.id, pid, t.org, t.admin, bot, ACTOR, ACTOR), code="SKINV")
    # Membership type must match principal type.
    expect_error(cur, "update cob3_identity.organization_memberships set membership_type = 'employee' where principal_id = %s", (pid,), code="SKINV")
    # principal_type is immutable.
    expect_error(cur, "update cob3_identity.principals set principal_type = 'human' where principal_id = %s", (bot,), code="SKIMM")
    owner.rollback()
    owner.close()


def test_last_active_human_tenant_administrator_is_protected(h):
    t = make_tenant(h)
    # Deferred check fires at commit.
    rt = h.conn(RUNTIME_LOGIN)
    cur = rt.cursor()
    cur.execute("select cob3_identity.set_request_context(%s, NULL, %s, %s, NULL)", (t.id, t.admin, t.admin_tenant_session))
    cur.execute("update cob3_identity.tenant_role_bindings set status = 'revoked' where principal_id = %s", (t.admin,))
    expect_commit_error(rt, "SKADM")
    # With a replacement administrator in the same transaction it succeeds.
    erin = add_human(t, "erin")
    cur = rt.cursor()
    cur.execute("select cob3_identity.set_request_context(%s, NULL, %s, %s, NULL)", (t.id, t.admin, t.admin_tenant_session))
    cur.execute("insert into cob3_identity.tenant_role_bindings (tenant_id, principal_id, role_id, grant_reason, created_by, updated_by)"
                " select %s, %s, role_id, 'handover', %s, %s from cob3_identity.roles where role_code = 'tenant_administrator'",
                (t.id, erin, ACTOR, ACTOR))
    cur.execute("update cob3_identity.tenant_role_bindings set status = 'revoked' where principal_id = %s", (t.admin,))
    rt.commit()
    # Automations can never receive tenant control-plane roles.
    bot = create_automation(t, "bot-tc")
    owner = h.connect(INSTALLER_ROLE)
    expect_error(owner.cursor(), "insert into cob3_identity.tenant_role_bindings (tenant_id, principal_id, role_id, grant_reason, created_by, updated_by)"
                                 " select %s, %s, role_id, 'x', %s, %s from cob3_identity.roles where tenant_id = %s and role_code = 'tenant_administrator'",
                 (t.id, bot, ACTOR, ACTOR, t.id), code="SKINV")
    owner.rollback()
    owner.close()
