"""Authorization behavior (master prompt tests 11, 12, 13, 15)."""
from __future__ import annotations

import uuid

import psycopg2
import pytest

from helpers import (ACTOR, RUNTIME_LOGIN, add_human, admin_org, admin_tenant, bind_role, create_automation, create_role,
                     digest, evaluate, expect_error, issue_credential, make_grant, make_tenant, open_session, request)


@pytest.fixture()
def world(h):
    """Tenant with a custom org_reader role, an automation with a delegated
    grant + credential, and the admin's personal token."""
    t = make_tenant(h)
    create_role(t, "org_reader", ["organization.read"])
    bot = create_automation(t, unique_code("bot"), roles=("org_reader",))
    with admin_org(t) as cur:
        dgrant, (d_org_read,) = make_grant(cur, t, t.admin, bot, "delegated", [("organization.read", False)])
        bot_cred, _, _ = issue_credential(cur, dgrant, "automation", [d_org_read])
        pgrant, (p_org_read, p_team_read, p_team_manage) = make_grant(
            cur, t, t.admin, t.admin, "restricted_self",
            [("organization.read", False), ("team.read", False), ("team.manage", False)])
        narrow_cred, _, _ = issue_credential(cur, pgrant, "personal_api", [p_org_read])
        empty_cred, _, _ = issue_credential(cur, pgrant, "personal_api", [])
        full_cred, _, _ = issue_credential(cur, pgrant, "personal_api", [p_org_read, p_team_read, p_team_manage])
    return dict(t=t, bot=bot, dgrant=dgrant, bot_cred=bot_cred, pgrant=pgrant, narrow=narrow_cred, empty=empty_cred, full=full_cred)


def unique_code(prefix):
    return f"{prefix}-{uuid.uuid4().hex[:8]}"


def test_interactive_rbac_and_tenant_control_separation(h, world):
    t = world["t"]
    rt = h.conn(RUNTIME_LOGIN)
    assert evaluate(rt, t, t.admin, "organization.read", session=t.admin_org_session)["allowed"]
    # Tenant control permission needs the tenant role binding, not org roles.
    assert evaluate(rt, t, t.admin, "tenant.manage_roles", session=t.admin_tenant_session, org=None)["allowed"]
    bob = add_human(t, "bob", roles=("organization_administrator",))
    bob_s = open_session(h, t, "sub-bob", t.org)
    r = evaluate(rt, t, bob, "tenant.manage_roles", session=bob_s)
    assert r == {**r, "allowed": False, "reason": "tenant_rbac_denied"}
    # Tenant control does not imply organization data access: a tenant admin
    # without an org role binding gets nothing in that organization.
    with admin_tenant(t) as cur:
        org_b = uuid.uuid4()
        cur.execute("insert into cob3_identity.organizations (tenant_id, organization_id, organization_code, name, created_by, updated_by)"
                    " values (%s, %s, 'org-b', 'Org B', %s, %s)", (t.id, org_b, ACTOR, ACTOR))
    r = evaluate(rt, t, t.admin, "organization.read", session=t.admin_tenant_session, org=org_b)
    assert not r["allowed"]
    # A client-supplied principal id is not proof of authority.
    r = evaluate(rt, t, bob, "organization.read", session=t.admin_org_session)
    assert r["reason"] == "session_principal_mismatch"


def test_personal_token_cannot_exceed_subset_and_empty_subset_denies(h, world):
    t, rt = world["t"], h.conn(RUNTIME_LOGIN)
    assert evaluate(rt, t, t.admin, "organization.read", credential=world["narrow"])["allowed"]
    r = evaluate(rt, t, t.admin, "team.read", credential=world["narrow"])
    assert (r["allowed"], r["reason"]) == (False, "credential_subset_denied")
    r = evaluate(rt, t, t.admin, "organization.read", credential=world["empty"])
    assert (r["allowed"], r["reason"]) == (False, "credential_subset_denied")
    # Grant ceiling: the owner's other roles never leak into the token.
    r = evaluate(rt, t, t.admin, "audit.read", credential=world["full"])
    assert (r["allowed"], r["reason"]) == (False, "no_matching_grant_entry")
    # IAM mutation through a personal token is refused even if inside the grant.
    r = evaluate(rt, t, t.admin, "team.manage", credential=world["full"])
    assert (r["allowed"], r["reason"]) == (False, "iam_requires_interactive_or_provisioning")
    # API key cannot be promoted into the interactive session.
    r = evaluate(rt, t, t.admin, "organization.read", session=t.admin_org_session, credential=world["full"])
    assert r["reason"] == "credential_not_permitted_in_interactive_session"
    # RLS through a credential context is bounded the same way.
    with request(rt, t, t.admin, None, world["narrow"]) as cur:
        cur.execute("select count(*) from cob3_identity.organizations")
        assert cur.fetchone()[0] == 1
        expect_error(cur, "insert into cob3_identity.teams (tenant_id, organization_id, team_code, name, team_type, created_by, updated_by)"
                          " values (%s, %s, 'x', 'x', 'project', 'system:x', 'system:x')", (t.id, t.org), code="42501")


def test_delegated_automation_needs_grantor_and_grantee_and_revocation_is_immediate(h, world):
    t, rt, bot, cred = world["t"], h.conn(RUNTIME_LOGIN), world["bot"], world["bot_cred"]
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["allowed"]
    # Grantee loses live permission -> denied.
    with admin_org(t) as cur:
        cur.execute("update cob3_identity.role_bindings set status = 'revoked' where principal_id = %s", (bot,))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["reason"] == "grantee_rbac_denied"
    with admin_org(t) as cur:
        bind_role(cur, t, bot, "org_reader")
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["allowed"]
    # Membership suspension -> denied.
    with admin_org(t) as cur:
        cur.execute("update cob3_identity.organization_memberships set status = 'suspended' where principal_id = %s", (bot,))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["reason"] == "membership_not_effective"
    with admin_org(t) as cur:
        cur.execute("update cob3_identity.organization_memberships set status = 'active' where principal_id = %s", (bot,))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["allowed"]
    # Grant suspension -> denied; resume -> allowed.
    with admin_org(t) as cur:
        cur.execute("select cob3_identity.set_authorization_grant_status(%s, 'suspended', 'test')", (world["dgrant"],))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["reason"] == "grant_not_effective"
    with admin_org(t) as cur:
        cur.execute("select cob3_identity.set_authorization_grant_status(%s, 'active', 'test')", (world["dgrant"],))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["allowed"]
    # Grantor loses authority (admin revokes own org admin binding) -> denied.
    with admin_org(t) as cur:
        cur.execute("update cob3_identity.role_bindings set status = 'revoked' where principal_id = %s", (t.admin,))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["reason"] == "grantor_rbac_denied"


def test_revoked_credential_disabled_principal_and_revoked_grant_block_next_request(h, world):
    t, rt, bot, cred = world["t"], h.conn(RUNTIME_LOGIN), world["bot"], world["bot_cred"]
    with admin_org(t) as cur:
        cur.execute("update cob3_identity.principals set status = 'suspended' where principal_id = %s", (bot,))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["reason"] == "principal_not_eligible"
    with admin_org(t) as cur:
        cur.execute("update cob3_identity.principals set status = 'active' where principal_id = %s", (bot,))
        cur.execute("select cob3_identity.revoke_principal_credential(%s, 'rotation')", (cred,))
    assert evaluate(rt, t, bot, "organization.read", credential=cred)["reason"] == "credential_invalid"
    # Revoking the personal grant kills all of its credentials.
    assert evaluate(rt, t, t.admin, "organization.read", credential=world["narrow"])["allowed"]
    with admin_org(t) as cur:
        cur.execute("select cob3_identity.set_authorization_grant_status(%s, 'revoked', 'compromised')", (world["pgrant"],))
    assert not evaluate(rt, t, t.admin, "organization.read", credential=world["narrow"])["allowed"]
    with admin_org(t) as cur:
        cur.execute("select count(*) from cob3_identity.principal_credentials where authorization_grant_id = %s and status = 'active'", (world["pgrant"],))
        assert cur.fetchone()[0] == 0


def test_role_expansion_does_not_expand_grants(h, world):
    t, rt, bot, cred = world["t"], h.conn(RUNTIME_LOGIN), world["bot"], world["bot_cred"]
    with admin_tenant(t) as cur:
        cur.execute("insert into cob3_identity.role_permissions (tenant_id, role_id, permission_id, created_by, updated_by)"
                    " select %s, r.role_id, p.permission_id, %s, %s from cob3_identity.roles r, cob3_identity.permissions p"
                    " where r.role_code = 'org_reader' and p.permission_code = 'team.read'", (t.id, ACTOR, ACTOR))
    r = evaluate(rt, t, bot, "team.read", credential=cred)
    assert (r["allowed"], r["reason"]) == (False, "no_matching_grant_entry")


def test_automation_cannot_self_mint_or_administer_iam(h, world):
    t, rt, bot, cred = world["t"], h.conn(RUNTIME_LOGIN), world["bot"], world["bot_cred"]
    with request(rt, t, bot, None, cred) as cur:
        expect_error(cur, "select cob3_identity.create_automation('bot-child', 'c', %s, 'x', 'agent', 'provisioning', NULL)", (t.admin,), code="SKAUZ")
        expect_error(cur, "select cob3_identity.issue_principal_credential(%s, 'k', 'automation', 'pk_selfmint0001', %s, 'sha256', 'api://cob3', now() + interval '1 hour', %s::uuid[])",
                     (world["dgrant"], digest(), []), code="SKAUZ")
        expect_error(cur, "select cob3_identity.create_authorization_grant(%s, %s, 'delegated', now(), now() + interval '1 hour', 'x')", (bot, bot), code="SKAUZ")
        expect_error(cur, "insert into cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, grant_reason, created_by, updated_by)"
                          " select %s, %s, role_id, %s, %s, 'x', 'system:x', 'system:x' from cob3_identity.roles where role_code = 'organization_administrator'",
                     (t.id, t.org, t.org_scope, bot), code="42501")
    # An automation-usage token held by a HUMAN carries the same restrictions.
    with admin_org(t) as cur:
        g, (e_read, e_manage) = make_grant(cur, t, t.admin, t.admin, "restricted_self", [("organization.read", False), ("team.manage", False)])
        human_auto_cred, _, _ = issue_credential(cur, g, "automation", [e_read, e_manage])
    assert evaluate(rt, t, t.admin, "organization.read", credential=human_auto_cred)["allowed"]
    assert evaluate(rt, t, t.admin, "team.manage", credential=human_auto_cred)["reason"] == "automation_restricted"
    # Automation principals cannot get interactive sessions.
    prov = h.connect("t_provisioner")
    prov.cursor().execute("select cob3_identity.bootstrap_link_external_identity(%s, %s, %s, 'sub-bot', %s)", (t.id, bot, t.idp, ACTOR))
    prov.commit()
    prov.close()
    cur = rt.cursor()
    expect_error(cur, "select * from cob3_identity.open_interactive_session(%s, %s, 'sub-bot', %s, %s, NULL, 'api://cob3', now(), now() + interval '1 hour')",
                 (t.id, t.idp, t.org, digest()), code="SKAUZ")
    rt.rollback()


def test_api_key_verification_and_session_exchange_preserve_bounds(h, world):
    t, rt = world["t"], h.conn(RUNTIME_LOGIN)
    with admin_org(t) as cur:
        g, (e1,) = make_grant(cur, t, t.admin, t.admin, "restricted_self", [("organization.read", False)], hours=2)
        cred, public_id, secret = issue_credential(cur, g, "personal_api", [e1], hours=1)
    cur = rt.cursor()
    cur.execute("select principal_id, credential_id from cob3_identity.verify_api_key(%s, %s, %s, 'api://cob3')", (t.id, public_id, psycopg2.Binary(secret)))
    assert cur.fetchone() == (t.admin, cred)
    cur.execute("select count(*) from cob3_identity.verify_api_key(%s, %s, %s, 'api://cob3')", (t.id, public_id, psycopg2.Binary(b"z" * 32)))
    assert cur.fetchone()[0] == 0
    cur.execute("select count(*) from cob3_identity.verify_api_key(%s, %s, %s, 'api://other')", (t.id, public_id, psycopg2.Binary(secret)))
    assert cur.fetchone()[0] == 0
    cur.execute("select cob3_identity.open_api_key_session(%s, %s, %s, 'api://cob3', %s, now() + interval '30 days')",
                (t.id, public_id, psycopg2.Binary(secret), digest()))
    session = cur.fetchone()[0]
    rt.commit()
    with admin_org(t) as cur:
        cur.execute("select s.session_kind, s.expires_at <= c.expires_at, s.audience = c.audience from cob3_identity.auth_sessions s"
                    " join cob3_identity.principal_credentials c on c.credential_id = s.credential_id where s.session_id = %s", (session,))
        assert cur.fetchone() == ("noninteractive", True, True)
    assert evaluate(rt, t, t.admin, "organization.read", session=session)["allowed"]
    r = evaluate(rt, t, t.admin, "team.read", session=session)
    assert r["allowed"] is False
    r = evaluate(rt, t, t.admin, "tenant.manage_roles", session=session, org=None)
    assert r["allowed"] is False


def test_catalog_references_fail_closed_while_org_scope_works(h, world):
    t, rt = world["t"], h.conn(RUNTIME_LOGIN)
    with admin_org(t) as cur:
        expect_error(cur, "insert into cob3_identity.access_scopes (tenant_id, organization_id, scope_type, domain_id, created_by, updated_by)"
                          " values (%s, %s, 'domain', gen_random_uuid(), 'system:x', 'system:x')", (t.id, t.org), code="SKCAT")
        expect_error(cur, "insert into cob3_identity.access_scopes (tenant_id, organization_id, scope_type, asset_id, created_by, updated_by)"
                          " values (%s, %s, 'asset', gen_random_uuid(), 'system:x', 'system:x')", (t.id, t.org), code="SKCAT")
        team = uuid.uuid4()
        cur.execute("insert into cob3_identity.teams (tenant_id, team_id, organization_id, team_code, name, team_type, created_by, updated_by)"
                    " values (%s, %s, %s, 'ops', 'Ops', 'functional', 'system:x', 'system:x')", (t.id, team, t.org))
        expect_error(cur, "insert into cob3_identity.team_domains (tenant_id, organization_id, team_id, domain_id, responsibility_type, created_by, updated_by)"
                          " values (%s, %s, %s, gen_random_uuid(), 'owner', 'system:x', 'system:x')", (t.id, t.org, team), code="SKCAT")
        cur.execute("select cob3_identity.catalog_integration_installed()")
        assert cur.fetchone()[0] is False
    # Resource-dependent authorization denies an unknown resource even with a UUID.
    r = evaluate(rt, t, t.admin, "domain.read", session=t.admin_org_session, target_type="domain", target_id=uuid.uuid4())
    assert r["allowed"] is False
    # Organization-scoped operations work now.
    assert evaluate(rt, t, t.admin, "team.manage", session=t.admin_org_session)["allowed"]
    assert evaluate(rt, t, t.admin, "organization.read", session=t.admin_org_session)["allowed"]
