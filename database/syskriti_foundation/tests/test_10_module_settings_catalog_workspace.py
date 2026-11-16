"""Migration 002: Settings, Catalog, Workspace and Identity amendments.

Runs in the separate `hm` database (foundation 001 + ordered migrations) under
the real non-owner runtime/worker roles. Behaviour, not just object presence.
"""
from __future__ import annotations

import json

import psycopg2
import pytest

from helpers import (ACTOR, INSTALLER_ROLE, PKG, RUNTIME_LOGIN, WORKER_LOGIN, admin_org, dsn_for, expect_error, make_tenant,
                     request, unique)
from module_helpers import as_user, bind_asset_role, member, sha

M002 = PKG / "migrations" / "002_settings_catalog_workspace.sql"


@pytest.fixture(scope="module")
def t(hm):
    return make_tenant(hm)



def new_project(cur, name, kind="shared"):
    cur.execute("select cob3_workspace.create_project(%s, %s, %s)", (unique("prj"), name, kind))
    pid = cur.fetchone()[0]
    cur.execute("select asset_id from cob3_workspace.projects where project_id = %s", (pid,))
    return pid, cur.fetchone()[0]


def new_artifact(cur, project_id, inherit=True):
    doc = {"panels": []}
    cur.execute("select cob3_workspace.create_artifact(%s, 'dashboard', %s, 'Dash', %s, 1, %s, NULL, NULL, %s)",
                (project_id, unique("art"), json.dumps(doc), sha(json.dumps(doc)), inherit))
    aid = cur.fetchone()[0]
    cur.execute("select asset_id from cob3_workspace.artifacts where artifact_id = %s", (aid,))
    return aid, cur.fetchone()[0]


# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
def test_components_recorded_and_rerun_is_noop(hm, module_notices):
    assert any("Migration 002" in n and "applied" in n for n in module_notices)
    conn = psycopg2.connect(dsn_for(hm.dbname, INSTALLER_ROLE))
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("select component, version from cob3_tenant.foundation_installations order by installed_at")
    comps = dict(cur.fetchall())
    assert comps["settings_catalog_workspace"] == "1.1.0" and comps["catalog_integration"] == "1.1.0"
    cur.execute(M002.read_text(encoding="utf-8"))
    assert any("Verified no-op" in n for n in conn.notices)
    conn.close()


def test_every_module_table_has_forced_rls_and_stamping(hm):
    conn = psycopg2.connect(dsn_for(hm.dbname, INSTALLER_ROLE))
    cur = conn.cursor()
    cur.execute("""
        select c.oid::regclass::text, c.relrowsecurity and c.relforcerowsecurity,
               exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'trg_90_stamp_row'),
               exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'trg_00_block_truncate'),
               exists (select 1 from pg_policies p where p.schemaname = n.nspname and p.tablename = c.relname and 'cob3_owner' = any (p.roles))
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where c.relkind = 'r' and (n.nspname in ('cob3_settings', 'cob3_catalog', 'cob3_workspace')
               or (n.nspname, c.relname) in (('cob3_identity', 'principal_emails'), ('cob3_identity', 'email_verification_challenges')))""")
    rows = cur.fetchall()
    assert len(rows) == 39
    bad = [r for r in rows if not all(r[1:])]
    assert not bad, bad
    conn.close()


# ---------------------------------------------------------------------------
# Identity amendments: email master, projection, verification
# ---------------------------------------------------------------------------
def test_email_projection_and_verification(t):
    pid, sess = member(t, unique("em"))
    with as_user(t, pid, sess) as cur:
        cur.execute("select email from cob3_identity.user_profiles where principal_id = %s", (pid,))
        assert cur.fetchone()[0] is None, "legacy profile email must not be shown as verified contact data"
        cur.execute("select principal_email_id, verified_at from cob3_identity.principal_emails where principal_id = %s", (pid,))
        email_id, verified = cur.fetchone()
        assert verified is None
        expect_error(cur, "update cob3_identity.user_profiles set email = 'x@example.invalid' where principal_id = %s", (pid,), "42501")
        expect_error(cur, "update cob3_identity.principal_emails set is_primary = true where principal_email_id = %s", (email_id,), "23514")
        cur.execute("select cob3_identity.issue_email_verification(%s, %s, now() + interval '1 hour')", (email_id, sha("right-token")))
    with as_user(t, pid, sess) as cur:
        cur.execute("select cob3_identity.consume_email_verification(%s, %s)", (email_id, sha("wrong-token")))
        assert cur.fetchone()[0] is False
    # Challenges are routine-only: the runtime has no table privilege at all.
    with as_user(t, pid, sess) as cur:
        expect_error(cur, "select 1 from cob3_identity.email_verification_challenges", None, "42501")
    with as_user(t, pid, sess) as cur:
        cur.execute("select cob3_identity.consume_email_verification(%s, %s)", (email_id, sha("right-token")))
        assert cur.fetchone()[0] is True
        cur.execute("update cob3_identity.principal_emails set is_primary = true where principal_email_id = %s", (email_id,))
        cur.execute("select p.email, e.email_address from cob3_identity.user_profiles p"
                    " join cob3_identity.principal_emails e on e.tenant_id = p.tenant_id and e.principal_id = p.principal_id"
                    " where p.principal_id = %s", (pid,))
        proj, addr = cur.fetchone()
        assert proj == addr


def test_cannot_register_email_for_another_user(t):
    a, sa = member(t, unique("ea"))
    b, _ = member(t, unique("eb"))
    with as_user(t, a, sa) as cur:
        expect_error(cur, "insert into cob3_identity.principal_emails (tenant_id, principal_id, email_address, email_key, label,"
                          " created_by, updated_by) values (%s, %s, 'z@example.invalid', 'z@example.invalid', 'work', %s, %s)",
                     (t.id, b, ACTOR, ACTOR), "42501")


# ---------------------------------------------------------------------------
# Settings: typed values, precedence, locks
# ---------------------------------------------------------------------------
def test_settings_precedence_and_locks(t):
    pid, sess = member(t, unique("st"))
    with as_user(t, pid, sess) as cur:
        cur.execute("select cob3_settings.ensure_scope('principal')")
        pscope = cur.fetchone()[0]
        cur.execute("insert into cob3_settings.setting_values (tenant_id, setting_scope_id, setting_definition_id, value, created_by, updated_by)"
                    " select %s, %s, d.setting_definition_id, '\"dark\"', %s, %s from cob3_settings.setting_definitions d"
                    " where d.setting_key = 'ui.theme'", (t.id, pscope, ACTOR, ACTOR))
        expect_error(cur, "insert into cob3_settings.setting_values (tenant_id, setting_scope_id, setting_definition_id, value, created_by, updated_by)"
                          " select %s, %s, d.setting_definition_id, '\"purple\"', %s, %s from cob3_settings.setting_definitions d"
                          " where d.setting_key = 'ui.density'", (t.id, pscope, ACTOR, ACTOR), "SKINV")
        # A member cannot lock or write organization settings.
        cur.execute("select cob3_settings.ensure_scope('organization')")
        oscope = cur.fetchone()[0]
        expect_error(cur, "insert into cob3_settings.setting_values (tenant_id, organization_id, setting_scope_id, setting_definition_id, value,"
                          " is_locked, change_reason, created_by, updated_by) select %s, %s, %s, d.setting_definition_id, '\"light\"', true,"
                          " 'policy', %s, %s from cob3_settings.setting_definitions d where d.setting_key = 'ui.theme'",
                     (t.id, t.org, oscope, ACTOR, ACTOR), "42501")
        cur.execute("select value, winning_scope_type, locked_at_scope from cob3_settings.resolve_setting('ui.theme')")
        assert cur.fetchone() == ("dark", "principal", None)
    with admin_org(t) as cur:
        cur.execute("insert into cob3_settings.setting_values (tenant_id, organization_id, setting_scope_id, setting_definition_id, value,"
                    " is_locked, change_reason, created_by, updated_by) select %s, %s, %s, d.setting_definition_id, '\"light\"', true,"
                    " 'brand policy', %s, %s from cob3_settings.setting_definitions d where d.setting_key = 'ui.theme'",
                    (t.id, t.org, oscope, ACTOR, ACTOR))
        cur.execute("select count(*) from cob3_settings.setting_change_events where setting_scope_id = %s and operation = 'lock'", (oscope,))
        assert cur.fetchone()[0] == 1
    with as_user(t, pid, sess) as cur:
        cur.execute("select value, winning_scope_type, locked_at_scope from cob3_settings.resolve_setting('ui.theme')")
        assert cur.fetchone() == ("light", "organization", "organization")
        # Default with no override anywhere.
        cur.execute("select value, winning_scope_type from cob3_settings.resolve_setting('display.page_size')")
        assert cur.fetchone() == (50, "default")


def test_personal_settings_invisible_to_others(t):
    a, sa = member(t, unique("pa"))
    b, sb = member(t, unique("pb"))
    with as_user(t, a, sa) as cur:
        cur.execute("select cob3_settings.ensure_scope('principal')")
        scope = cur.fetchone()[0]
    with as_user(t, b, sb) as cur:
        cur.execute("select count(*) from cob3_settings.setting_scopes where setting_scope_id = %s", (scope,))
        assert cur.fetchone()[0] == 0


# ---------------------------------------------------------------------------
# Catalog + Workspace: explicit access, inheritance, revisions
# ---------------------------------------------------------------------------
def test_private_project_and_inheritance(t):
    owner, so = member(t, unique("ow"))
    viewer, sv = member(t, unique("vw"))
    with as_user(t, owner, so) as cur:
        project, passet = new_project(cur, "Team analytics")
        inheriting, inh_asset = new_artifact(cur, project, inherit=True)
        private, priv_asset = new_artifact(cur, project, inherit=False)
        cur.execute("select count(*) from cob3_catalog.assets where asset_id in (%s, %s, %s)", (passet, inh_asset, priv_asset))
        assert cur.fetchone()[0] == 3
    # Organization membership alone opens nothing.
    with as_user(t, viewer, sv) as cur:
        cur.execute("select count(*) from cob3_workspace.projects where project_id = %s", (project,))
        assert cur.fetchone()[0] == 0
        cur.execute("select count(*) from cob3_catalog.assets where asset_id = %s", (passet,))
        assert cur.fetchone()[0] == 0
    # Organization-wide containment grant does NOT open explicit resources (6.3).
    with admin_org(t) as cur:
        cur.execute("insert into cob3_identity.access_scopes (tenant_id, organization_id, scope_type, include_contained_assets,"
                    " created_by, updated_by) values (%s, %s, 'organization', true, %s, %s) on conflict do nothing", (t.id, t.org, ACTOR, ACTOR))
        cur.execute("select scope_id from cob3_identity.access_scopes where scope_type = 'organization' and include_contained_assets")
        wide = cur.fetchone()[0]
        cur.execute("insert into cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, grant_reason,"
                    " created_by, updated_by) select %s, %s, role_id, %s, %s, 'wide', %s, %s from cob3_identity.roles"
                    " where role_code = 'workspace_viewer'", (t.id, t.org, wide, viewer, ACTOR, ACTOR))
    with as_user(t, viewer, sv) as cur:
        cur.execute("select count(*) from cob3_workspace.artifacts where artifact_id = %s", (inheriting,))
        assert cur.fetchone()[0] == 0
    # Project scope with include_workspace_artifacts opens the project and inheriting artifacts only (6.4).
    with admin_org(t) as cur:
        bind_asset_role(cur, t, viewer, "workspace_viewer", passet, include_artifacts=True)
    with as_user(t, viewer, sv) as cur:
        cur.execute("select count(*) from cob3_workspace.projects where project_id = %s", (project,))
        assert cur.fetchone()[0] == 1
        cur.execute("select artifact_id from cob3_workspace.artifacts where project_id = %s", (project,))
        assert {r[0] for r in cur.fetchall()} == {inheriting}
        cur.execute("select count(*) from cob3_workspace.artifact_revisions where artifact_id = %s", (private,))
        assert cur.fetchone()[0] == 0
        # Viewer cannot commit content.
        expect_error(cur, "select cob3_workspace.commit_artifact_revision(%s, 1, 'inline', '{}'::jsonb, NULL, NULL, 1, %s)",
                     (inheriting, sha("x")), "SKAUZ")


def test_revision_head_is_optimistic_and_sequential(t):
    owner, so = member(t, unique("rv"))
    with as_user(t, owner, so) as cur:
        project, _ = new_project(cur, "Revisions")
        art, _ = new_artifact(cur, project)
        cur.execute("select row_version from cob3_workspace.artifacts where artifact_id = %s", (art,))
        head = cur.fetchone()[0]
        cur.execute("select cob3_workspace.commit_artifact_revision(%s, %s, 'inline', '{\"v\":2}'::jsonb, NULL, NULL, 1, %s)",
                    (art, head, sha("v2")))
        expect_error(cur, "select cob3_workspace.commit_artifact_revision(%s, %s, 'inline', '{\"v\":3}'::jsonb, NULL, NULL, 1, %s)",
                     (art, head, sha("v3")), "SKINV")
        cur.execute("select max(revision_number) from cob3_workspace.artifact_revisions where artifact_id = %s", (art,))
        assert cur.fetchone()[0] == 2
        expect_error(cur, "update cob3_workspace.artifact_revisions set change_note = 'x' where artifact_id = %s", (art,), "42501")


def test_admin_is_not_implicitly_a_workspace_user(t):
    with admin_org(t) as cur:
        expect_error(cur, "select cob3_workspace.create_project(%s, 'Admin', 'shared')", (unique("prj"),), "SKAUZ")


def test_one_personal_project_and_human_owner(t):
    owner, so = member(t, unique("pp"))
    with as_user(t, owner, so) as cur:
        new_project(cur, "Mine", kind="personal")
        expect_error(cur, "select cob3_workspace.create_project(%s, 'Mine again', 'personal')", (unique("prj"),), "SKINV")


def test_folder_cycles_and_cross_project_parents_rejected(t):
    owner, so = member(t, unique("fd"))
    with as_user(t, owner, so) as cur:
        p1, _ = new_project(cur, "P1")
        p2, _ = new_project(cur, "P2")
        cur.execute("insert into cob3_workspace.folders (tenant_id, organization_id, project_id, name, created_by, updated_by)"
                    " values (%s, %s, %s, 'a', %s, %s) returning folder_id", (t.id, t.org, p1, ACTOR, ACTOR))
        fa = cur.fetchone()[0]
        cur.execute("insert into cob3_workspace.folders (tenant_id, organization_id, project_id, parent_folder_id, name, created_by, updated_by)"
                    " values (%s, %s, %s, %s, 'b', %s, %s) returning folder_id", (t.id, t.org, p1, fa, ACTOR, ACTOR))
        fb = cur.fetchone()[0]
        expect_error(cur, "update cob3_workspace.folders set parent_folder_id = %s where folder_id = %s", (fb, fa), "SKINV")
        expect_error(cur, "insert into cob3_workspace.folders (tenant_id, organization_id, project_id, parent_folder_id, name, created_by, updated_by)"
                          " values (%s, %s, %s, %s, 'c', %s, %s)", (t.id, t.org, p2, fa, ACTOR, ACTOR), "23503")


def test_explicit_mode_enforced_and_classification_change_needs_authority(t):
    owner, so = member(t, unique("cl"))
    with as_user(t, owner, so) as cur:
        _, passet = new_project(cur, "Explicit")
        expect_error(cur, "update cob3_catalog.assets set authorization_mode = 'governed' where asset_id = %s", (passet,), "SKINV")
        cur.execute("select count(*) from cob3_catalog.asset_metadata_versions where asset_id = %s", (passet,))
        assert cur.fetchone()[0] >= 1


def test_other_tenant_sees_nothing(t, hm):
    other = make_tenant(hm)
    owner, so = member(t, unique("iso"))
    with as_user(t, owner, so) as cur:
        new_project(cur, "Isolated")
    with request(hm.conn(RUNTIME_LOGIN), other, other.admin, other.admin_org_session) as cur:
        cur.execute("select count(*) from cob3_workspace.projects")
        assert cur.fetchone()[0] == 0
        cur.execute("select count(*) from cob3_catalog.assets")
        assert cur.fetchone()[0] == 0
        cur.execute("select count(*) from cob3_settings.setting_scopes")
        assert cur.fetchone()[0] == 0


def test_no_context_sees_nothing(hm, t):
    conn = hm.conn(RUNTIME_LOGIN)
    cur = conn.cursor()
    for table in ("cob3_catalog.assets", "cob3_workspace.projects", "cob3_settings.setting_values", "cob3_identity.principal_emails"):
        cur.execute(f"select count(*) from {table}")
        assert cur.fetchone()[0] == 0, table
    conn.rollback()


def test_worker_scope_is_tenant_and_org_bound(t, hm):
    owner, so = member(t, unique("wk"))
    with as_user(t, owner, so) as cur:
        new_project(cur, "Worker visible")
    conn = hm.connect(WORKER_LOGIN)
    cur = conn.cursor()
    cur.execute("select count(*) from cob3_workspace.projects")
    assert cur.fetchone()[0] == 0, "no worker scope -> nothing"
    cur.execute("select cob3_identity.set_worker_context(%s, %s, 'system:test-worker')", (t.id, t.org))
    cur.execute("select count(*) from cob3_workspace.projects")
    assert cur.fetchone()[0] >= 1
    cur.execute("select count(*) from cob3_workspace.projects where tenant_id <> %s", (t.id,))
    assert cur.fetchone()[0] == 0
    expect_error(cur, "insert into cob3_workspace.projects (tenant_id, organization_id, asset_id, project_kind, created_by, updated_by)"
                      " values (%s, %s, gen_random_uuid(), 'shared', 'system:x', 'system:x')", (t.id, t.org), "42501")
    conn.rollback()
    conn.close()
