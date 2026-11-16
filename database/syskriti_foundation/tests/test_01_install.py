"""Install, rerun, coverage and drift checks (master prompt tests 1, 2, 3, 7-role, 19)."""
from __future__ import annotations

import re
import subprocess
import sys

import psycopg2
import pytest

from helpers import INSTALLER_ROLE, PKG, RUNTIME_LOGIN, dsn_for, expect_error
from spec_parser import parse_identity_spec, parse_tenant_spec

SUPPORT_TABLES = {("cob3_tenant", "foundation_installations"), ("cob3_tenant", "quota_counters")}


def db_columns(cur, schema: str) -> dict:
    cur.execute("""
        select c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull
          from pg_attribute a
          join pg_class c on c.oid = a.attrelid
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = %s and c.relkind = 'r' and a.attnum > 0 and not a.attisdropped""", (schema,))
    out: dict = {}
    for rel, col, typ, nn in cur.fetchall():
        out.setdefault(rel, {})[col] = (typ, nn)
    return out


@pytest.fixture()
def owner(h):
    conn = h.connect(INSTALLER_ROLE)
    yield conn
    conn.close()


def test_install_creates_all_48_logical_tables_and_support_tables(owner):
    cur = owner.cursor()
    cur.execute("""select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname in ('cob3_tenant', 'cob3_identity') and c.relkind = 'r'""")
    found = set(cur.fetchall())
    identity = {("cob3_identity", t) for t in parse_identity_spec()}
    tenant = {("cob3_tenant", t) for t in parse_tenant_spec()}
    assert len(identity) == 27 and len(tenant) == 21
    assert found == identity | tenant | SUPPORT_TABLES
    cur.execute("""select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname in ('cob3_tenant', 'cob3_identity') and c.relkind = 'r'
                      and c.relrowsecurity and c.relforcerowsecurity""")
    assert cur.fetchone()[0] == 50
    cur.execute("select nspname from pg_namespace where nspname like 'cob3%' or nspname like 'cop3%' order by 1")
    assert [r[0] for r in cur.fetchall()] == ["cob3_identity", "cob3_tenant"]


@pytest.mark.parametrize("schema,parser", [("cob3_identity", parse_identity_spec), ("cob3_tenant", parse_tenant_spec)])
def test_every_specified_column_type_and_nullability(owner, schema, parser):
    spec = parser()
    actual = db_columns(owner.cursor(), schema)
    problems = []
    for table, cols in spec.items():
        got = actual.get(table)
        if got is None:
            problems.append(f"missing table {schema}.{table}")
            continue
        for col, (typ, nn) in cols.items():
            if col not in got:
                problems.append(f"{table}.{col} missing")
            elif got[col] != (typ, nn):
                problems.append(f"{table}.{col}: spec {typ} {'NOT NULL' if nn else 'NULL'} vs db {got[col]}")
        for extra in set(got) - set(cols):
            problems.append(f"{table}.{extra} not in specification")
    assert not problems, "\n".join(problems)


def test_rerun_is_verified_noop_and_preserves_data(h, owner):
    cur = owner.cursor()
    cur.execute("select count(*), max(installed_at) from cob3_tenant.foundation_installations")
    before = cur.fetchone()
    cur.execute("select count(*) from cob3_tenant.tenants")
    tenants_before = cur.fetchone()[0]
    owner.commit()
    owner.notices.clear()
    owner.autocommit = True
    owner.cursor().execute((PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8"))
    assert any("Verified no-op" in n for n in owner.notices)
    owner.autocommit = False
    cur = owner.cursor()
    cur.execute("select count(*), max(installed_at) from cob3_tenant.foundation_installations")
    assert cur.fetchone() == before
    cur.execute("select count(*) from cob3_tenant.tenants")
    assert cur.fetchone()[0] == tenants_before


def test_rerun_of_different_installer_fails_early_without_changes(owner):
    text = (PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8")
    checksum = re.search(r"Checksum \(sha256\): ([0-9a-f]{64})", text).group(1)
    tampered = text.replace(checksum, "0" * 64)
    cur = owner.cursor()
    cur.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname like 'cob3_%'")
    funcs_before = cur.fetchone()[0]
    owner.commit()
    with pytest.raises(psycopg2.Error) as exc:
        owner.cursor().execute(tampered)
    owner.rollback()
    assert exc.value.pgcode == "SKPRE"
    cur = owner.cursor()
    cur.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname like 'cob3_%'")
    assert cur.fetchone()[0] == funcs_before


def test_runtime_roles_are_not_privileged(owner):
    cur = owner.cursor()
    cur.execute("""select rolname, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolcanlogin
                     from pg_roles where rolname like 'cob3\\_%' order by 1""")
    rows = {r[0]: r[1:] for r in cur.fetchall()}
    # cob3_worker is created by ordered migration 002 (roles are cluster-wide); it must be unprivileged too.
    assert set(rows) - {"cob3_worker"} == {"cob3_owner", "cob3_runtime", "cob3_provisioner", "cob3_commercial_admin"}
    for name, attrs in rows.items():
        assert attrs == (False, False, False, False, False), (name, attrs)
    cur.execute("select pg_has_role(%s, 'cob3_owner', 'MEMBER')", (RUNTIME_LOGIN,))
    assert cur.fetchone()[0] is False
    cur.execute("""select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname like 'cob3\\_%' and pg_get_userbyid(c.relowner) <> 'cob3_owner'""")
    assert cur.fetchone()[0] == 0


def test_no_function_executable_by_public_and_definers_pin_search_path(owner):
    cur = owner.cursor()
    cur.execute("""select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname like 'cob3\\_%' and has_function_privilege('public', p.oid, 'EXECUTE')""")
    assert cur.fetchone()[0] == 0
    cur.execute("""select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname like 'cob3\\_%'
                      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%%')""")
    assert cur.fetchall() == []


def test_secret_digest_columns_not_granted_to_runtime(owner):
    cur = owner.cursor()
    for table, column in (("principal_credentials", "secret_digest"), ("auth_sessions", "session_handle_digest"),
                          ("auth_sessions", "refresh_token_digest")):
        cur.execute("select has_column_privilege('cob3_runtime', %s, %s, 'SELECT')", (f"cob3_identity.{table}", column))
        assert cur.fetchone()[0] is False, (table, column)


def test_every_foreign_key_has_covering_index_and_no_unvalidated_constraints(owner):
    cur = owner.cursor()
    cur.execute("""
        select c.conrelid::regclass::text, c.conname
          from pg_constraint c join pg_namespace n on n.oid = c.connamespace
         where n.nspname like 'cob3\\_%' and c.contype = 'f'
           and not exists (
               select 1 from pg_index i
                where i.indrelid = c.conrelid
                  and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey
                  and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] <@ c.conkey)""")
    assert cur.fetchall() == []
    cur.execute("""select conname from pg_constraint c join pg_namespace n on n.oid = c.connamespace
                    where n.nspname like 'cob3\\_%' and not c.convalidated""")
    assert cur.fetchall() == []


def test_installed_checksum_matches_file_and_build_has_no_drift(owner):
    text = (PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8")
    checksum = re.search(r"Checksum \(sha256\): ([0-9a-f]{64})", text).group(1)
    cur = owner.cursor()
    cur.execute("select script_checksum from cob3_tenant.foundation_installations where component = 'foundation'")
    assert cur.fetchone()[0] == checksum
    result = subprocess.run([sys.executable, str(PKG / "build_installer.py"), "--check"], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (PKG / "INSTALL_FOUNDATION.sql").read_bytes() == (PKG / "migrations" / "001_initial_foundation.sql").read_bytes()


def test_installer_is_plain_sql_without_client_commands_or_placeholders():
    text = (PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8")
    assert not re.search(r"^\s*\\", text, re.M), "psql backslash command found"
    assert "${" not in text and "{{" not in text and "@@" not in text
    for forbidden in (r"CREATE\s+DATABASE", r"DROP\s+SCHEMA", r"DROP\s+TABLE", r"TRUNCATE\s", r"DELETE\s+FROM"):
        assert not re.search(r"^\s*" + forbidden, text, re.M | re.I), forbidden
