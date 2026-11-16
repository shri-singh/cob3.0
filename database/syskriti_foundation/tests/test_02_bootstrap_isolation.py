"""Bootstrap, cross-tenant/org isolation, catalog vs tenant policy, fail-closed
context and sensitive-row visibility (master prompt tests 4, 5, 6, 7, 8)."""
from __future__ import annotations

import uuid

import psycopg2

from helpers import (ACTOR, INSTALLER_ROLE, PKG, PROVISIONER_LOGIN, RUNTIME_LOGIN, add_human, admin_org, admin_tenant,
                     digest, expect_error, issue_credential, make_grant, make_tenant, open_session, request)

ALL_TABLES_SQL = """select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname in ('cob3_tenant', 'cob3_identity') and c.relkind = 'r'
                       and c.relname not in ('foundation_installations', 'quota_counters', 'provisioning_jobs', 'provider_events')
                     order by 1"""


def test_bootstrap_example_runs_under_provisioner_without_disabling_security(h):
    conn = h.connect(PROVISIONER_LOGIN, autocommit=True)
    sql = (PKG / "BOOTSTRAP_EXAMPLE.sql").read_text(encoding="utf-8")
    conn.cursor().execute(sql)
    conn.cursor().execute(sql)  # rerun is a no-op
    assert any("already exists" in n for n in conn.notices)
    conn.close()
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    cur.execute("""select t.status, count(distinct o.organization_id), count(distinct b.tenant_role_binding_id),
                          count(distinct rb.role_binding_id), count(distinct u.principal_id), count(distinct p.permission_id),
                          count(distinct e.tenant_lifecycle_event_id)
                     from cob3_tenant.tenants t
                     join cob3_identity.organizations o on o.tenant_id = t.tenant_id
                     join cob3_identity.tenant_role_bindings b on b.tenant_id = t.tenant_id
                     join cob3_identity.role_bindings rb on rb.tenant_id = t.tenant_id
                     join cob3_identity.user_profiles u on u.tenant_id = t.tenant_id
                     join cob3_identity.permissions p on p.tenant_id = t.tenant_id
                     join cob3_tenant.tenant_lifecycle_events e on e.tenant_id = t.tenant_id
                    where t.tenant_code = 'example-tenant'
                    group by t.status""")
    status, orgs, tadmins, oadmins, humans, perms, events = cur.fetchone()
    assert (status, orgs, tadmins, oadmins, humans, events) == ("active", 1, 1, 1, 1, 2)
    assert perms == 20  # generic core templates only; no product permissions
    cur.execute("select count(*) from cob3_identity.permissions where tenant_id is null")
    assert cur.fetchone()[0] == 0
    owner.close()


def test_bootstrap_is_not_a_permanent_open_door(h):
    t = make_tenant(h)
    prov = h.connect(PROVISIONER_LOGIN)
    cur = prov.cursor()
    expect_error(cur, "select * from cob3_identity.bootstrap_tenant_administration(%s, 'org-x', 'X', 'admin2', 'A2', NULL, %s)",
                 (t.id, ACTOR), code="SKSTA")
    prov.rollback()
    prov.close()
    rt = h.conn(RUNTIME_LOGIN)
    expect_error(rt.cursor(), "select * from cob3_identity.bootstrap_tenant('x', 'x', NULL, 'r', 'o', 'o', 'a', 'a', NULL, gen_random_uuid())",
                 code="42501")
    rt.rollback()


def test_principal_requires_exactly_one_subtype_at_commit(h):
    t = make_tenant(h)
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    cur.execute("insert into cob3_identity.principals (tenant_id, principal_type, principal_code, display_name, created_by, updated_by)"
                " values (%s, 'human', 'orphan', 'Orphan', %s, %s)", (t.id, ACTOR, ACTOR))
    from helpers import expect_commit_error
    expect_commit_error(owner, "SKINV")
    # Wrong subtype for the principal type is rejected immediately.
    cur = owner.cursor()
    pid = uuid.uuid4()
    cur.execute("insert into cob3_identity.principals (tenant_id, principal_id, principal_type, principal_code, display_name, created_by, updated_by)"
                " values (%s, %s, 'service_account', 'svc-x', 'Svc', %s, %s)", (t.id, pid, ACTOR, ACTOR))
    expect_error(cur, "insert into cob3_identity.user_profiles (tenant_id, principal_id, created_by, updated_by) values (%s, %s, %s, %s)",
                 (t.id, pid, ACTOR, ACTOR), code="SKINV")
    owner.rollback()
    owner.close()


def test_cross_tenant_and_cross_organization_references_rejected(h):
    t1, t2 = make_tenant(h), make_tenant(h)
    with admin_tenant(t1) as cur:
        org_b = uuid.uuid4()
        cur.execute("insert into cob3_identity.organizations (tenant_id, organization_id, organization_code, name, created_by, updated_by)"
                    " values (%s, %s, 'org-b', 'Org B', %s, %s)", (t1.id, org_b, ACTOR, ACTOR))
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    # Membership of a tenant-2 principal in a tenant-1 organization.
    expect_error(cur, "insert into cob3_identity.organization_memberships (tenant_id, organization_id, principal_id, membership_type, created_by, updated_by)"
                      " values (%s, %s, %s, 'employee', %s, %s)", (t1.id, t1.org, t2.admin, ACTOR, ACTOR), code="23503")
    # Organization parent across tenants.
    expect_error(cur, "update cob3_identity.organizations set parent_organization_id = %s where tenant_id = %s and organization_id = %s",
                 (t2.org, t1.id, org_b), code="23503")
    # Team in org B, membership for a principal who is only a member of org A.
    team = uuid.uuid4()
    cur.execute("insert into cob3_identity.teams (tenant_id, team_id, organization_id, team_code, name, team_type, created_by, updated_by)"
                " values (%s, %s, %s, 'tb', 'Team B', 'project', %s, %s)", (t1.id, team, org_b, ACTOR, ACTOR))
    expect_error(cur, "insert into cob3_identity.team_memberships (tenant_id, organization_id, team_id, principal_id, created_by, updated_by)"
                      " values (%s, %s, %s, %s, %s, %s)", (t1.id, org_b, team, t1.admin, ACTOR, ACTOR), code="23503")
    # Role binding with org A scope inside org B.
    expect_error(cur, "insert into cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, team_id, grant_reason, created_by, updated_by)"
                      " select %s, %s, role_id, %s, %s, 'x', %s, %s from cob3_identity.roles where tenant_id = %s and role_code = 'audit_reader'",
                 (t1.id, org_b, t1.org_scope, team, ACTOR, ACTOR, t1.id), code="23503")
    # Usage attributed to another tenant's organization.
    expect_error(cur, "insert into cob3_tenant.usage_events (tenant_id, organization_id, feature_id, source_code, source_event_id, occurred_at, quantity, created_by, updated_by)"
                      " select %s, %s, feature_id, 'src', 'e1', now(), 1, %s, %s from cob3_tenant.features where feature_code = 'test.requests'",
                 (t1.id, t2.org, ACTOR, ACTOR), code="23503")
    owner.rollback()
    owner.close()
    # Runtime in tenant 1 context cannot see any tenant 2 rows.
    with admin_tenant(t1) as cur:
        cur.execute("select count(*) from cob3_identity.principals where tenant_id = %s", (t2.id,))
        assert cur.fetchone()[0] == 0
        cur.execute("select count(*) from cob3_tenant.subscriptions where tenant_id = %s", (t2.id,))
        assert cur.fetchone()[0] == 0


def test_platform_catalog_policy_is_distinct_from_tenant_owned_policy(h):
    t1, t2 = make_tenant(h), make_tenant(h)
    rt = h.conn(RUNTIME_LOGIN)
    with admin_tenant(t1, rt) as cur:
        cur.execute("select count(*) from cob3_tenant.plans where status = 'active'")
        assert cur.fetchone()[0] >= 2  # global catalog rows (tenant_id NULL) are readable when published/active
        cur.execute("select count(*) from cob3_tenant.plans where status <> 'active'")
        assert cur.fetchone()[0] == 0  # drafts/retired are not visible
        cur.execute("select count(*) from cob3_tenant.subscriptions")
        assert cur.fetchone()[0] == 1  # only own tenant's subscription
        expect_error(cur, "insert into cob3_tenant.plans (plan_code, name, created_by, updated_by) values ('evil', 'Evil', 'system:x', 'system:x')",
                     code="42501")
        expect_error(cur, "update cob3_tenant.subscriptions set status = 'paused'", code="42501")
        expect_error(cur, "insert into cob3_tenant.tenant_entitlement_overrides (tenant_id, feature_id, is_enabled, is_unlimited, reset_period, valid_from, valid_until, reason, created_by, updated_by)"
                          " select %s, feature_id, true, true, 'none', now(), now() + interval '1 year', 'self-award', 'system:x', 'system:x'"
                          " from cob3_tenant.features where feature_code = 'humans.max'", (t1.id,), code="42501")
    # An ordinary member (not a tenant controller) sees no tenant commercial rows.
    bob = add_human(t1, "bob", roles=("audit_reader",))
    s = open_session(h, t1, "sub-bob", t1.org)
    with request(rt, t1, bob, s) as cur:
        cur.execute("select count(*) from cob3_tenant.subscriptions")
        assert cur.fetchone()[0] == 0
        cur.execute("select count(*) from cob3_tenant.invoices")
        assert cur.fetchone()[0] == 0


def test_missing_or_spoofed_context_fails_closed_under_runtime_role(h):
    t = make_tenant(h)
    rt = h.conn(RUNTIME_LOGIN)
    cur = rt.cursor()
    cur.execute(ALL_TABLES_SQL)
    tables = [r[0] for r in cur.fetchall()]
    rt.commit()
    contexts = [
        ("no context", None, None, None, None),
        ("tenant+principal but no session/credential", t.id, t.org, t.admin, None),
        ("random session id", t.id, t.org, t.admin, uuid.uuid4()),
        ("session of another principal", t.id, t.org, uuid.uuid4(), t.admin_org_session),
        ("session with wrong tenant", uuid.uuid4(), t.org, t.admin, t.admin_org_session),
    ]
    for label, tid, org, principal, session in contexts:
        cur = rt.cursor()
        cur.execute("select cob3_identity.set_request_context(%s, %s, %s, %s, NULL)", (tid, org, principal, session))
        for table in tables:
            cur.execute(f"select count(*) from {table}")
            n = cur.fetchone()[0]
            if table.startswith("cob3_tenant.") and table.split(".")[1] in ("plans", "plan_versions", "features", "plan_entitlements", "plan_prices"):
                assert n == 0, f"{label}: catalog {table} visible without authenticated context"
            else:
                assert n == 0, f"{label}: {table} returned {n} rows"
        rt.rollback()
    # Malformed settings are treated as absent.
    cur = rt.cursor()
    cur.execute("select set_config('cob3.tenant_id', 'not-a-uuid', true), set_config('cob3.principal_id', '''; drop table x; --', true)")
    cur.execute("select cob3_identity.ctx_tenant_id(), cob3_identity.ctx_principal_id(), cob3_identity.ctx_auth_valid()")
    assert cur.fetchone() == (None, None, False)
    rt.rollback()
    # Revoked sessions stop working at the next request.
    with admin_org(t, rt) as cur:
        cur.execute("select count(*) from cob3_identity.organizations")
        assert cur.fetchone()[0] == 1
        cur.execute("select cob3_identity.revoke_session(%s)", (t.admin_org_session,))
    with admin_org(t, rt) as cur:
        cur.execute("select count(*) from cob3_identity.organizations")
        assert cur.fetchone()[0] == 0


def test_tenant_wide_sensitive_rows_not_exposed_to_every_member(h):
    t = make_tenant(h)
    rt = h.conn(RUNTIME_LOGIN)
    # Admin issues a personal token for themself.
    with admin_org(t, rt) as cur:
        gid, entries = make_grant(cur, t, t.admin, t.admin, "restricted_self", [("organization.read", False)])
        admin_cred, _, _ = issue_credential(cur, gid, "personal_api", entries)
    bob = add_human(t, "bob", roles=("audit_reader",))
    # Carol belongs only to another organization.
    with admin_tenant(t, rt) as cur:
        org_b = uuid.uuid4()
        cur.execute("insert into cob3_identity.organizations (tenant_id, organization_id, organization_code, name, created_by, updated_by)"
                    " values (%s, %s, 'org-b', 'Org B', %s, %s)", (t.id, org_b, ACTOR, ACTOR))
    # Tenant admin is not a member of org B: add scope + admin membership via owner for test setup.
    owner = h.connect(INSTALLER_ROLE)
    oc = owner.cursor()
    oc.execute("insert into cob3_identity.access_scopes (tenant_id, organization_id, scope_type, created_by, updated_by) values (%s, %s, 'organization', %s, %s)",
               (t.id, org_b, ACTOR, ACTOR))
    oc.execute("insert into cob3_identity.organization_memberships (tenant_id, organization_id, principal_id, membership_type, status, created_by, updated_by)"
               " values (%s, %s, %s, 'employee', 'active', %s, %s)", (t.id, org_b, t.admin, ACTOR, ACTOR))
    oc.execute("insert into cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, grant_reason, created_by, updated_by)"
               " select %s, %s, r.role_id, s.scope_id, %s, 'setup', %s, %s from cob3_identity.roles r, cob3_identity.access_scopes s"
               " where r.tenant_id = %s and r.role_code = 'organization_administrator' and s.organization_id = %s",
               (t.id, org_b, t.admin, ACTOR, ACTOR, t.id, org_b))
    owner.commit()
    owner.close()
    admin_b_session = open_session(h, t, "sub-admin", org_b)
    carol = add_human(t, "carol", roles=("audit_reader",), org=org_b, org_session=admin_b_session)
    bob_session = open_session(h, t, "sub-bob", t.org)
    with request(rt, t, bob, bob_session) as cur:
        cur.execute("select count(*) from cob3_identity.principal_credentials")
        assert cur.fetchone()[0] == 0  # cannot see the admin's credential
        cur.execute("select count(*) from cob3_identity.auth_sessions")
        assert cur.fetchone()[0] == 1  # only own session
        cur.execute("select principal_id from cob3_identity.principals")
        visible = {r[0] for r in cur.fetchall()}
        assert bob in visible and t.admin in visible and carol not in visible
        cur.execute("select count(*) from cob3_identity.tenant_role_bindings")
        assert cur.fetchone()[0] == 0
        cur.execute("select count(*) from cob3_identity.identity_providers")
        assert cur.fetchone()[0] == 1
        cur.execute("select count(*) from cob3_identity.external_identities")
        assert cur.fetchone()[0] == 1  # only own subject mapping
        expect_error(cur, "select secret_digest from cob3_identity.principal_credentials", code="42501")
        expect_error(cur, "select session_handle_digest from cob3_identity.auth_sessions", code="42501")
    with admin_org(t, rt) as cur:
        cur.execute("select count(*) from cob3_identity.principal_credentials where credential_id = %s", (admin_cred,))
        assert cur.fetchone()[0] == 1
