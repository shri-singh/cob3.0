# Validation report

**Date:** 8 November 2026 · **Foundation:** 1.0.0 · **Installer checksum:**
`7b55051fba245f0f8aaaad5003bc23a567a9cbc906b8e095d5d16f4724101439`

## Environment actually used

| Item | Version / detail |
|---|---|
| PostgreSQL | 18.1 (x86_64-windows, msvc) — a **disposable** cluster created with `initdb` in a temporary directory, port 55432, localhost only, trust auth. The machine's existing PostgreSQL on port 5432 was **not** touched. |
| btree_gist | 1.8 |
| Python / psycopg2 / pytest | 3.10.6 / 2.9.11 / 8.4.2 |
| Installer identity | Non-superuser login `t_installer` with `LOGIN CREATEROLE`, owner of the target database (managed-service-like path) |
| Runtime identities | Logins that are members of exactly one of `cob3_runtime`, `cob3_provisioner`, `cob3_commercial_admin` — RLS was exercised under these non-owner roles, never as superuser |

## Commands

```bash
python database/syskriti_foundation/build_installer.py --check
COB3_TEST_DISPOSABLE_SERVER=1 COB3_TEST_ADMIN_DSN="host=localhost port=55432 user=pgsuper dbname=postgres" \
    python -m pytest database/syskriti_foundation/tests -q
COB3_TEST_DISPOSABLE_SERVER=1 python database/syskriti_foundation/tools/schema_coverage.py
psql -f INSTALL_FOUNDATION.sql ; psql -f VERIFY_FOUNDATION.sql      # manual runs on throwaway databases
```

## Results

* `build_installer.py --check`: **OK** (installer and `migrations/001` match `src/`).
* pytest: **52 passed, 0 failed, 0 skipped** (≈55–62 s). Each run creates its own databases and drops them.
* Schema coverage generator: **807/807** specified columns exact across 48 tables.
* `VERIFY_FOUNDATION.sql` after install: no FAIL/WARN; `catalog integration = PENDING`. A deliberate
  negative check (granting `cob3_owner` to a runtime login) was reported as FAIL, then reverted.
* Installer rerun: verified no-op; a tampered installer (different checksum) failed with `SKPRE` and
  changed nothing.

### Master-prompt test mapping

| # | Requirement | Test(s) | Result |
|---|---|---|---|
| 1 | Fresh install creates 48 tables + support objects | t01 `test_install_creates_all_48…` | pass |
| 2 | Columns, nullability, keys, constraints, reference scopes | t01 column coverage (both schemas), FK index/NOT VALID test | pass |
| 3 | Second install verified no-op / early failure, data preserved | t01 rerun tests | pass |
| 4 | Bootstrap commits without broken references | t02 bootstrap example, subtype test | pass |
| 5 | Cross-tenant / cross-org references rejected | t02 cross-tenant test | pass |
| 6 | Global catalog policy distinct from tenant data policy | t02 catalog policy test | pass |
| 7 | Missing/incorrect context fails closed under runtime role | t02 fail-closed test (all tables, 5 bad contexts, malformed GUCs, revoked session) | pass |
| 8 | Tenant-wide sensitive rows not exposed | t02 sensitive rows test (digest columns `42501`) | pass |
| 9 | Hierarchy cycles incl. concurrent attempts | t03 (two sessions; second verified blocked on the lock) | pass |
| 10 | Grantor/grantee/subtype, same-grant credential refs, immutable envelopes | t03 grant/credential tests | pass |
| 11 | Personal token cannot exceed subset; empty subset denies | t04 | pass |
| 12 | Removing grantor/grantee authority, disabling membership, revoking grant/credential blocks next request | t04 (2 tests) | pass |
| 13 | Role expansion ≠ grant expansion; automation cannot self-mint/administer IAM | t04 (2 tests) | pass |
| 14 | Approval exact payload, single use, concurrency | t05 (3 tests; concurrent consumer verified blocked) | pass |
| 15 | Domain/asset fail closed; organization scope works | t04 catalog test; t08 template | pass |
| 16 | Published catalog and issued invoice immutable | t06 (2 tests) | pass |
| 17 | Overlaps, usage idempotency, correction limits, quota races | t06 (overlaps, usage, 20-thread counter race, allocation race, gauge race) | pass |
| 18 | Audit/event records not updatable/deletable/truncatable | t07 (runtime `42501`; owner `SKAPP` on 4 tables) | pass |
| 19 | Installer/migration/schema-coverage drift checks | t01 drift + checksum test; t09 VERIFY/seeds | pass |

## Not validated (stated precisely)

* **PostgreSQL 15, 16, 17** were not executed. The minimum of 15 is based on feature analysis
  (`UNIQUE NULLS NOT DISTINCT`, role semantics); PG15-specific branches (role membership checks) are
  untested.
* **DBeaver and pgAdmin GUIs** were not driven. The installer was executed through `psql -f` and as a
  single statement through psycopg2. It is one `DO` block with blank lines converted to `--` so editors
  that split on blank lines cannot break it, but GUI execution itself is unverified.
* **Managed services (RDS/Azure/Cloud SQL):** only simulated with a non-superuser CREATEROLE login; the
  pre-provisioned-roles path (no CREATEROLE) was exercised implicitly on reinstall into new databases
  (roles already existed) but not with a login lacking CREATEROLE.
* **Backend services** (Python/FastAPI), federated token verification, payment/provider integration and
  API-key secret handling were not built in this delivery.
* **Performance/load:** not measured. RLS predicates call SECURITY DEFINER functions (once per statement
  where possible, per row for directory/grant visibility); large-tenant performance needs profiling.
* Routines without dedicated tests: `claim_provisioning_job`, `record_provider_event`,
  provider-subscription-reference uniqueness, subscription change lifecycle, team membership sources and
  group mappings in authorization, permission/role "immutable after use" guards, credential-based grant
  authorization (provisioning service path).
* This is **not** a production-readiness claim: production use additionally requires the backend
  controls listed in `SECURITY_AND_AUTHORIZATION.md`, operational backup/restore drills, and the gaps
  above closed.
