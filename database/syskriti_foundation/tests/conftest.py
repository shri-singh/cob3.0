"""Session fixtures: a throwaway database with the standalone installer applied.

Safety: requires COB3_TEST_DISPOSABLE_SERVER=1 and a superuser DSN for a
disposable server in COB3_TEST_ADMIN_DSN. The suite creates its own database
(cob3_test_<random>) and drops it at the end; it never modifies any other DB.
"""
from __future__ import annotations

import os
import uuid

import psycopg2
import pytest

from helpers import (ADMIN_DSN, COMMERCIAL_LOGIN, INSTALLER_ROLE, MODULE_MIGRATIONS, PKG, PROVISIONER_LOGIN, RUNTIME_LOGIN,
                     WORKER_LOGIN, Harness, dsn_for, ensure_test_counter_feature)


@pytest.fixture(scope="session")
def admin():
    if os.environ.get("COB3_TEST_DISPOSABLE_SERVER") != "1":
        pytest.skip("Set COB3_TEST_DISPOSABLE_SERVER=1 and COB3_TEST_ADMIN_DSN (superuser DSN of a DISPOSABLE server).")
    conn = psycopg2.connect(ADMIN_DSN)
    conn.autocommit = True
    yield conn
    conn.close()


def _ensure_login(cur, name: str, extra: str = ""):
    cur.execute("select 1 from pg_roles where rolname = %s", (name,))
    if cur.fetchone() is None:
        cur.execute(f'CREATE ROLE "{name}" LOGIN {extra}')


@pytest.fixture(scope="session")
def install_notices():
    return []


@pytest.fixture(scope="session")
def h(admin, install_notices):
    cur = admin.cursor()
    dbname = "cob3_test_" + uuid.uuid4().hex[:8]
    # Realistic least-privilege installer: LOGIN CREATEROLE, owns the database, not superuser.
    _ensure_login(cur, INSTALLER_ROLE, "CREATEROLE")
    cur.execute(f'CREATE DATABASE "{dbname}" OWNER "{INSTALLER_ROLE}"')
    inst = psycopg2.connect(dsn_for(dbname, INSTALLER_ROLE))
    inst.autocommit = True
    inst.cursor().execute((PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8"))
    install_notices.extend(inst.notices)
    inst.close()
    for login, group in ((RUNTIME_LOGIN, "cob3_runtime"), (PROVISIONER_LOGIN, "cob3_provisioner"),
                         (COMMERCIAL_LOGIN, "cob3_commercial_admin")):
        _ensure_login(cur, login)
        cur.execute(f'GRANT {group} TO "{login}"')
    harness = Harness(dbname)
    ensure_test_counter_feature(harness)
    yield harness
    harness.close()
    cur.execute("select pg_terminate_backend(pid) from pg_stat_activity where datname = %s and pid <> pg_backend_pid()", (dbname,))
    if os.environ.get("COB3_TEST_KEEP_DB") != "1":
        cur.execute(f'DROP DATABASE IF EXISTS "{dbname}"')


@pytest.fixture(scope="session")
def module_notices():
    return []


@pytest.fixture(scope="session")
def hm(admin, module_notices):
    """Separate database with foundation 001 plus ordered migrations 002/003 applied
    as the same least-privilege installer role (they must not touch the shared DB)."""
    cur = admin.cursor()
    dbname = "cob3_mod_" + uuid.uuid4().hex[:8]
    _ensure_login(cur, INSTALLER_ROLE, "CREATEROLE")
    cur.execute(f'CREATE DATABASE "{dbname}" OWNER "{INSTALLER_ROLE}"')
    inst = psycopg2.connect(dsn_for(dbname, INSTALLER_ROLE))
    inst.autocommit = True
    inst.cursor().execute((PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8"))
    for name in MODULE_MIGRATIONS:
        inst.cursor().execute((PKG / "migrations" / name).read_text(encoding="utf-8"))
    module_notices.extend(inst.notices)
    inst.close()
    for login, group in ((RUNTIME_LOGIN, "cob3_runtime"), (PROVISIONER_LOGIN, "cob3_provisioner"),
                         (COMMERCIAL_LOGIN, "cob3_commercial_admin"), (WORKER_LOGIN, "cob3_worker")):
        _ensure_login(cur, login)
        cur.execute(f'GRANT {group} TO "{login}"')
    harness = Harness(dbname)
    ensure_test_counter_feature(harness)
    yield harness
    harness.close()
    cur.execute("select pg_terminate_backend(pid) from pg_stat_activity where datname = %s and pid <> pg_backend_pid()", (dbname,))
    if os.environ.get("COB3_TEST_KEEP_DB") != "1":
        cur.execute(f'DROP DATABASE IF EXISTS "{dbname}"')
