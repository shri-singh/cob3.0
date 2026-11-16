"""Test helpers for the Syskriti foundation SQL package.

Tests run ONLY against a disposable PostgreSQL server explicitly opted in with
COB3_TEST_DISPOSABLE_SERVER=1. Each test session creates (and drops) its own
database; it never touches an existing application database.
"""
from __future__ import annotations

import contextlib
import os
import pathlib
import time
import uuid
from dataclasses import dataclass, field

import psycopg2
import psycopg2.extras

psycopg2.extras.register_uuid()

PKG = pathlib.Path(__file__).resolve().parents[1]
REPO = PKG.parents[1]
ADMIN_DSN = os.environ.get("COB3_TEST_ADMIN_DSN", "host=localhost port=55432 user=pgsuper dbname=postgres")
ACTOR = "system:test"

INSTALLER_ROLE = "t_installer"
RUNTIME_LOGIN = "t_runtime"
PROVISIONER_LOGIN = "t_provisioner"
COMMERCIAL_LOGIN = "t_commercial"
WORKER_LOGIN = "t_worker"

# Ordered upgrade migrations applied by the `hm` fixture (after the installer).
MODULE_MIGRATIONS = tuple(os.environ.get("COB3_TEST_MODULES", "002_settings_catalog_workspace.sql,003_ai_agent_state.sql").split(","))

DEFAULT_LIMITS = {
    "organizations.max": 100,
    "humans.max": 100,
    "service_accounts.max": 100,
    "automations.max": 100,
    "api_credentials.max": 100,
    "automation.enabled": True,
    "sso.enabled": True,
    "test.requests": 1000,
}


def dsn_for(dbname: str, user: str) -> str:
    parts = dict(p.split("=", 1) for p in ADMIN_DSN.split())
    parts["dbname"] = dbname
    parts["user"] = user
    return " ".join(f"{k}={v}" for k, v in parts.items())


def unique(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:10]}"


def digest() -> psycopg2.Binary:
    return psycopg2.Binary(os.urandom(32))


def expect_error(cur, sql, params=None, code=None):
    """Execute inside a savepoint and require a database error (optionally a SQLSTATE)."""
    cur.execute("SAVEPOINT expect_error")
    try:
        cur.execute(sql, params)
    except psycopg2.Error as exc:
        cur.execute("ROLLBACK TO SAVEPOINT expect_error")
        if code is not None:
            assert exc.pgcode == code, f"expected SQLSTATE {code}, got {exc.pgcode}: {exc.pgerror}"
        return exc
    cur.execute("RELEASE SAVEPOINT expect_error")
    raise AssertionError(f"expected an error ({code}) but statement succeeded: {sql}")


def expect_commit_error(conn, code=None):
    try:
        conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        if code is not None:
            assert exc.pgcode == code, f"expected SQLSTATE {code} at commit, got {exc.pgcode}: {exc.pgerror}"
        return exc
    raise AssertionError(f"expected commit to fail with {code}")


class Harness:
    def __init__(self, dbname: str):
        self.dbname = dbname
        self._conns: list = []
        self._cache: dict = {}

    def connect(self, user: str, autocommit: bool = False, application_name: str | None = None):
        """Fresh connection (caller closes it; used for concurrency)."""
        dsn = dsn_for(self.dbname, user)
        if application_name:
            dsn += f" application_name={application_name}"
        conn = psycopg2.connect(dsn)
        conn.autocommit = autocommit
        self._conns.append(conn)
        return conn

    def conn(self, user: str):
        """Cached, reusable connection for sequential test steps."""
        cached = self._cache.get(user)
        if cached is None or cached.closed:
            cached = self.connect(user)
            self._cache[user] = cached
        else:
            cached.rollback()
        return cached

    def close(self):
        for conn in self._conns:
            with contextlib.suppress(Exception):
                conn.close()
        self._conns.clear()


@dataclass
class Tenant:
    h: Harness
    id: uuid.UUID
    code: str
    org: uuid.UUID
    admin: uuid.UUID
    idp: uuid.UUID
    org_scope: uuid.UUID = None
    admin_org_session: uuid.UUID = None
    admin_tenant_session: uuid.UUID = None
    plan_version: uuid.UUID = None
    plan_price: uuid.UUID = None
    subscription: uuid.UUID = None
    extra: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Commercial setup (platform commercial authority)
# ---------------------------------------------------------------------------
def ensure_test_counter_feature(h: Harness):
    conn = h.connect(COMMERCIAL_LOGIN)
    cur = conn.cursor()
    cur.execute("select cob3_identity.set_system_context(%s)", (ACTOR,))
    cur.execute("select 1 from cob3_tenant.features where feature_code = 'test.requests'")
    if cur.fetchone() is None:
        cur.execute(
            "insert into cob3_tenant.features (feature_code, name, value_type, unit_code, measurement_kind, created_by, updated_by)"
            " values ('test.requests', 'Test requests', 'quota', 'request', 'counter', %s, %s)", (ACTOR, ACTOR))
    conn.commit()
    conn.close()


def create_published_plan(h: Harness, limits: dict):
    conn = h.connect(COMMERCIAL_LOGIN)
    cur = conn.cursor()
    cur.execute("select cob3_identity.set_system_context(%s)", (ACTOR,))
    code = unique("plan")
    cur.execute("insert into cob3_tenant.plans (plan_code, name, created_by, updated_by) values (%s, %s, %s, %s) returning plan_id",
                (code, code, ACTOR, ACTOR))
    plan = cur.fetchone()[0]
    cur.execute("update cob3_tenant.plans set status = 'active' where plan_id = %s", (plan,))
    cur.execute("insert into cob3_tenant.plan_versions (plan_id, version_number, effective_from, created_by, updated_by)"
                " values (%s, 1, now() - interval '365 days', %s, %s) returning plan_version_id", (plan, ACTOR, ACTOR))
    pv = cur.fetchone()[0]
    for feature_code, value in limits.items():
        cur.execute("select feature_id, value_type, measurement_kind from cob3_tenant.features where feature_code = %s", (feature_code,))
        row = cur.fetchone()
        if row is None:
            continue
        fid, vtype, kind = row
        if vtype == "boolean":
            args = (bool(value), None, False, "none")
        elif value is None:
            args = (True, None, True, "none" if kind == "gauge" else "calendar_month")
        else:
            args = (True, value, False, "none" if kind == "gauge" else "calendar_month")
        cur.execute("insert into cob3_tenant.plan_entitlements (plan_version_id, feature_id, is_enabled, limit_value, is_unlimited, reset_period, created_by, updated_by)"
                    " values (%s, %s, %s, %s, %s, %s, %s, %s)", (pv, fid, *args, ACTOR, ACTOR))
    cur.execute("update cob3_tenant.plan_versions set status = 'published' where plan_version_id = %s", (pv,))
    cur.execute("insert into cob3_tenant.plan_prices (plan_version_id, price_code, currency_code, billing_interval, base_amount_minor, effective_from, created_by, updated_by)"
                " values (%s, %s, 'USD', 'month', 1000, now() - interval '365 days', %s, %s) returning plan_price_id",
                (pv, unique("price"), ACTOR, ACTOR))
    price = cur.fetchone()[0]
    cur.execute("update cob3_tenant.plan_prices set status = 'published' where plan_price_id = %s", (price,))
    conn.commit()
    conn.close()
    return pv, price


def subscribe(h: Harness, tenant_id, pv, price):
    conn = h.connect(COMMERCIAL_LOGIN)
    cur = conn.cursor()
    cur.execute("select cob3_identity.set_system_context(%s)", (ACTOR,))
    cur.execute("insert into cob3_tenant.billing_accounts (tenant_id, legal_name, billing_email, billing_address, country_code, created_by, updated_by)"
                " values (%s, 'Example Ltd', 'billing@example.invalid', '{\"line1\": \"1 Example Street\"}', 'US', %s, %s) returning billing_account_id",
                (tenant_id, ACTOR, ACTOR))
    ba = cur.fetchone()[0]
    cur.execute("insert into cob3_tenant.subscriptions (tenant_id, billing_account_id, status, created_by, updated_by)"
                " values (%s, %s, 'active', %s, %s) returning subscription_id", (tenant_id, ba, ACTOR, ACTOR))
    sub = cur.fetchone()[0]
    cur.execute("insert into cob3_tenant.subscription_periods (tenant_id, subscription_id, billing_period_key, segment_number, plan_version_id,"
                " plan_price_id, period_start, period_end, currency_code, contract_amount_minor, status, created_by, updated_by)"
                " values (%s, %s, 'cycle-1', 1, %s, %s, now() - interval '1 day', now() + interval '30 days', 'USD', 1000, 'active', %s, %s)",
                (tenant_id, sub, pv, price, ACTOR, ACTOR))
    conn.commit()
    conn.close()
    return sub, ba


# ---------------------------------------------------------------------------
# Tenant/identity setup
# ---------------------------------------------------------------------------
def open_session(h: Harness, t: Tenant, subject: str, org):
    conn = h.connect(RUNTIME_LOGIN)
    cur = conn.cursor()
    cur.execute("select session_id, principal_id from cob3_identity.open_interactive_session(%s, %s, %s, %s, %s, NULL, 'api://cob3',"
                " now(), now() + interval '2 hours')", (t.id, t.idp, subject, org, digest()))
    session_id, _principal = cur.fetchone()
    conn.commit()
    conn.close()
    return session_id


def make_tenant(h: Harness, limits: dict | None = None, activate: bool = True, subscribe_plan: bool = True) -> Tenant:
    lim = dict(DEFAULT_LIMITS)
    lim.update(limits or {})
    prov = h.connect(PROVISIONER_LOGIN)
    cur = prov.cursor()
    code = unique("t")
    cur.execute("select tenant_id, organization_id, admin_principal_id from cob3_identity.bootstrap_tenant("
                "%s, %s, NULL, 'test-region', 'org-a', 'Org A', 'admin', 'Admin', 'admin@example.invalid', %s, false, %s)",
                (code, "Tenant " + code, uuid.uuid4(), ACTOR))
    tid, org, admin = cur.fetchone()
    cur.execute("select cob3_identity.bootstrap_identity_provider(%s, 'test-oidc', 'Test IdP', 'oidc', %s, 'settings://idp/test', %s)",
                (tid, f"https://idp.{code}.invalid/", ACTOR))
    idp = cur.fetchone()[0]
    cur.execute("select cob3_identity.bootstrap_link_external_identity(%s, %s, %s, 'sub-admin', %s)", (tid, admin, idp, ACTOR))
    prov.commit()
    t = Tenant(h=h, id=tid, code=code, org=org, admin=admin, idp=idp)
    if subscribe_plan:
        t.plan_version, t.plan_price = create_published_plan(h, lim)
        t.subscription, _ = subscribe(h, tid, t.plan_version, t.plan_price)
    if activate:
        cur.execute("select cob3_tenant.transition_tenant_status(%s, 'active', 'test activation', %s, %s)", (tid, uuid.uuid4(), ACTOR))
        prov.commit()
        t.admin_org_session = open_session(h, t, "sub-admin", org)
        t.admin_tenant_session = open_session(h, t, "sub-admin", None)
        with request(h.conn(RUNTIME_LOGIN), t, t.admin, t.admin_org_session) as c:
            c.execute("select scope_id from cob3_identity.access_scopes where scope_type = 'organization' and organization_id = %s", (org,))
            t.org_scope = c.fetchone()[0]
    prov.close()
    return t


@contextlib.contextmanager
def request(conn, t: Tenant, principal, session=None, credential=None, org="default"):
    """One authenticated 'request' = one transaction with transaction-local context."""
    cur = conn.cursor()
    org_id = t.org if org == "default" else org
    cur.execute("select cob3_identity.set_request_context(%s, %s, %s, %s, %s)", (t.id, org_id, principal, session, credential))
    try:
        yield cur
        conn.commit()
    except BaseException:
        conn.rollback()
        raise


def admin_org(t: Tenant, conn=None):
    return request(conn or t.h.conn(RUNTIME_LOGIN), t, t.admin, t.admin_org_session)


def admin_tenant(t: Tenant, conn=None):
    return request(conn or t.h.conn(RUNTIME_LOGIN), t, t.admin, t.admin_tenant_session, org=None)


def add_human(t: Tenant, code: str, roles=(), org=None, org_session=None):
    """Create a human member through the runtime (RLS + triggers) and link a federated subject."""
    org = org or t.org
    session = org_session or t.admin_org_session
    pid = uuid.uuid4()
    with request(t.h.conn(RUNTIME_LOGIN), t, t.admin, session, org=org) as cur:
        cur.execute("insert into cob3_identity.principals (tenant_id, principal_id, principal_type, principal_code, display_name, created_by, updated_by)"
                    " values (%s, %s, 'human', %s, %s, %s, %s)", (t.id, pid, code, code, ACTOR, ACTOR))
        cur.execute("insert into cob3_identity.organization_memberships (tenant_id, organization_id, principal_id, membership_type, status, created_by, updated_by)"
                    " values (%s, %s, %s, 'employee', 'active', %s, %s)", (t.id, org, pid, ACTOR, ACTOR))
        cur.execute("insert into cob3_identity.user_profiles (tenant_id, principal_id, email, created_by, updated_by) values (%s, %s, %s, %s, %s)",
                    (t.id, pid, f"{code}@example.invalid", ACTOR, ACTOR))
        for role in roles:
            bind_role(cur, t, pid, role, org)
    prov = t.h.connect(PROVISIONER_LOGIN)
    prov.cursor().execute("select cob3_identity.bootstrap_link_external_identity(%s, %s, %s, %s, %s)", (t.id, pid, t.idp, "sub-" + code, ACTOR))
    prov.commit()
    prov.close()
    return pid


def bind_role(cur, t: Tenant, principal, role_code: str, org=None, team=None):
    org = org or t.org
    cur.execute("select scope_id from cob3_identity.access_scopes where organization_id = %s and scope_type = 'organization'", (org,))
    scope = cur.fetchone()[0]
    cur.execute("insert into cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, team_id, grant_reason, created_by, updated_by)"
                " select %s, %s, r.role_id, %s, %s, %s, 'test', %s, %s from cob3_identity.roles r where r.role_code = %s",
                (t.id, org, scope, principal if team is None else None, team, ACTOR, ACTOR, role_code))
    assert cur.rowcount == 1, f"role {role_code} not found"


def create_role(t: Tenant, code: str, perms, role_class="organization"):
    with admin_tenant(t) as cur:
        rid = uuid.uuid4()
        cur.execute("insert into cob3_identity.roles (tenant_id, role_id, role_code, name, role_class, created_by, updated_by)"
                    " values (%s, %s, %s, %s, %s, %s, %s)", (t.id, rid, code, code, role_class, ACTOR, ACTOR))
        for p in perms:
            cur.execute("insert into cob3_identity.role_permissions (tenant_id, role_id, permission_id, created_by, updated_by)"
                        " select %s, %s, permission_id, %s, %s from cob3_identity.permissions where permission_code = %s",
                        (t.id, rid, ACTOR, ACTOR, p))
            assert cur.rowcount == 1, p
    return rid


def create_automation(t: Tenant, code: str, roles=()):
    with admin_org(t) as cur:
        cur.execute("select cob3_identity.create_automation(%s, %s, %s, 'test automation', 'agent', 'portal', NULL)",
                    (code, code, t.admin))
        auto = cur.fetchone()[0]
        for role in roles:
            bind_role(cur, t, auto, role)
    return auto


def make_grant(cur, t: Tenant, grantor, grantee, grant_type, entries, hours=24):
    """entries: list of (permission_code, requires_approval). Returns (grant_id, [entry ids])."""
    cur.execute("select cob3_identity.create_authorization_grant(%s, %s, %s, now(), now() + make_interval(hours => %s), 'test grant')",
                (grantor, grantee, grant_type, hours))
    gid = cur.fetchone()[0]
    ids = []
    for perm, approval in entries:
        cur.execute("select cob3_identity.add_authorization_grant_permission(%s, %s, %s, %s)", (gid, perm, t.org_scope, approval))
        ids.append(cur.fetchone()[0])
    cur.execute("select cob3_identity.authorize_authorization_grant(%s)", (gid,))
    return gid, ids


def issue_credential(cur, gid, usage, entry_ids, hours=12):
    public_id = "pk_" + uuid.uuid4().hex[:20]
    secret = os.urandom(32)
    cur.execute("select cob3_identity.issue_principal_credential(%s, 'test key', %s, %s, %s, 'sha256', 'api://cob3',"
                " now() + make_interval(hours => %s), %s::uuid[])",
                (gid, usage, public_id, psycopg2.Binary(secret), hours, list(entry_ids)))
    return cur.fetchone()[0], public_id, secret


def evaluate(conn, t: Tenant, principal, permission, session=None, credential=None, target_type="organization", target_id=None, org="default"):
    org_id = t.org if org == "default" else org
    cur = conn.cursor()
    cur.execute("select allowed, reason_code, requires_approval, matched_grant_permission_id from cob3_identity.evaluate_access("
                "%s, %s, %s, %s, %s, %s, %s, %s, now(), NULL)",
                (t.id, org_id, principal, session, credential, permission, target_type, target_id or org_id))
    row = cur.fetchone()
    conn.commit()
    return {"allowed": row[0], "reason": row[1], "requires_approval": row[2], "entry": row[3]}


def wait_until_blocked(admin_conn, application_name: str, timeout: float = 10.0):
    """Wait until a backend with the given application_name is waiting on a lock."""
    cur = admin_conn.cursor()
    deadline = time.time() + timeout
    while time.time() < deadline:
        cur.execute("select count(*) from pg_stat_activity where application_name = %s and wait_event_type = 'Lock'", (application_name,))
        if cur.fetchone()[0] > 0:
            return True
        time.sleep(0.05)
    return False
