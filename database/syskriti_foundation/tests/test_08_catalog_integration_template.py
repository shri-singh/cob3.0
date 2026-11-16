"""Future Catalog integration template (master prompt section 7.6).

Runs in its OWN throwaway database: the template permanently enables
domain/asset operations, so it must not touch the shared session database.
The cob3_catalog schema created here is a TEST FIXTURE that follows
future_integrations/catalog_integration_contract.md; the foundation installer
never creates Catalog objects.
"""
from __future__ import annotations

import uuid

import psycopg2
import pytest

from helpers import (ACTOR, INSTALLER_ROLE, PKG, RUNTIME_LOGIN, Harness, admin_org, admin_tenant, add_human, create_role,
                     dsn_for, evaluate, expect_error, make_tenant, open_session, request)

TEMPLATE = PKG / "future_integrations" / "catalog_integration.sql.template"

CATALOG_FIXTURE = """
CREATE SCHEMA cob3_catalog;
CREATE TABLE cob3_catalog.domains (
    tenant_id uuid NOT NULL, organization_id uuid NOT NULL, domain_id uuid NOT NULL DEFAULT gen_random_uuid(),
    status varchar(20) NOT NULL DEFAULT 'active',
    UNIQUE (tenant_id, organization_id, domain_id),
    FOREIGN KEY (tenant_id, organization_id) REFERENCES cob3_identity.organizations (tenant_id, organization_id));
CREATE TABLE cob3_catalog.assets (
    tenant_id uuid NOT NULL, organization_id uuid NOT NULL, asset_id uuid NOT NULL DEFAULT gen_random_uuid(),
    resource_type varchar(64) NOT NULL, primary_domain_id uuid NULL, status varchar(20) NOT NULL DEFAULT 'active',
    UNIQUE (tenant_id, organization_id, asset_id),
    FOREIGN KEY (tenant_id, organization_id, primary_domain_id) REFERENCES cob3_catalog.domains (tenant_id, organization_id, domain_id));
GRANT USAGE ON SCHEMA cob3_catalog TO cob3_owner;
GRANT SELECT, REFERENCES ON cob3_catalog.domains, cob3_catalog.assets TO cob3_owner;
"""


@pytest.fixture()
def h2(admin):
    dbname = "cob3_cat_" + uuid.uuid4().hex[:8]
    cur = admin.cursor()
    cur.execute(f'CREATE DATABASE "{dbname}" OWNER "{INSTALLER_ROLE}"')
    inst = psycopg2.connect(dsn_for(dbname, INSTALLER_ROLE))
    inst.autocommit = True
    inst.cursor().execute((PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8"))
    inst.close()
    harness = Harness(dbname)
    yield harness
    harness.close()
    cur.execute("select pg_terminate_backend(pid) from pg_stat_activity where datname = %s and pid <> pg_backend_pid()", (dbname,))
    cur.execute(f'DROP DATABASE IF EXISTS "{dbname}"')


def test_catalog_template_verifies_first_then_enables_resolver(h2):
    owner = h2.connect(INSTALLER_ROLE, autocommit=True)
    template = TEMPLATE.read_text(encoding="utf-8")
    with pytest.raises(psycopg2.Error) as exc:
        owner.cursor().execute(template)
    assert exc.value.pgcode == "SKCAT"
    cur = owner.cursor()
    cur.execute("select count(*) from cob3_tenant.foundation_installations where component = 'catalog_integration'")
    assert cur.fetchone()[0] == 0

    # Contract-shaped Catalog appears (test fixture), then the template runs.
    cur.execute(CATALOG_FIXTURE)
    cur.execute(template)
    cur.execute("select cob3_identity.catalog_integration_installed()")
    assert cur.fetchone()[0] is True
    cur.execute("""select conname, convalidated from pg_constraint
                    where conname in ('access_scopes_domain_fk', 'access_scopes_asset_fk', 'team_domains_domain_fk') order by 1""")
    assert cur.fetchall() == [("access_scopes_asset_fk", True), ("access_scopes_domain_fk", True), ("team_domains_domain_fk", True)]
    owner.notices.clear()
    cur.execute(template)  # rerun is a no-op
    assert any("already installed" in n for n in owner.notices)

    # Domain/asset operations now validate against real Catalog rows.
    t = make_tenant(h2)
    cur.execute("insert into cob3_catalog.domains (tenant_id, organization_id) values (%s, %s) returning domain_id", (t.id, t.org))
    domain = cur.fetchone()[0]
    cur.execute("insert into cob3_catalog.assets (tenant_id, organization_id, resource_type, primary_domain_id) values (%s, %s, 'domain', %s) returning asset_id",
                (t.id, t.org, domain))
    create_role(t, "domain_reader", ["domain.read"])
    erin = add_human(t, "erin")
    rt = h2.conn(RUNTIME_LOGIN)
    with admin_org(t, rt) as c:
        expect_error(c, "insert into cob3_identity.access_scopes (tenant_id, organization_id, scope_type, domain_id, created_by, updated_by)"
                        " values (%s, %s, 'domain', gen_random_uuid(), %s, %s)", (t.id, t.org, ACTOR, ACTOR), code="SKCAT")
        scope = uuid.uuid4()
        c.execute("insert into cob3_identity.access_scopes (tenant_id, scope_id, organization_id, scope_type, domain_id, created_by, updated_by)"
                  " values (%s, %s, %s, 'domain', %s, %s, %s)", (t.id, scope, t.org, domain, ACTOR, ACTOR))
        c.execute("insert into cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, grant_reason, created_by, updated_by)"
                  " select %s, %s, role_id, %s, %s, 'domain access', %s, %s from cob3_identity.roles where role_code = 'domain_reader'",
                  (t.id, t.org, scope, erin, ACTOR, ACTOR))
        team = uuid.uuid4()
        c.execute("insert into cob3_identity.teams (tenant_id, team_id, organization_id, team_code, name, team_type, created_by, updated_by)"
                  " values (%s, %s, %s, 'ops', 'Ops', 'functional', %s, %s)", (t.id, team, t.org, ACTOR, ACTOR))
        c.execute("insert into cob3_identity.team_domains (tenant_id, organization_id, team_id, domain_id, responsibility_type, created_by, updated_by)"
                  " values (%s, %s, %s, %s, 'owner', %s, %s)", (t.id, t.org, team, domain, ACTOR, ACTOR))
    s = open_session(h2, t, "sub-erin", t.org)
    assert evaluate(rt, t, erin, "domain.read", session=s, target_type="domain", target_id=domain)["allowed"]
    assert not evaluate(rt, t, erin, "domain.read", session=s, target_type="domain", target_id=uuid.uuid4())["allowed"]
    assert not evaluate(rt, t, erin, "organization.read", session=s)["allowed"]  # domain role grants nothing org-wide
