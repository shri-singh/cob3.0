# Syskriti foundation database (Tenant + Identity)

Reusable PostgreSQL foundation for Syskriti SaaS products: schemas **`cob3_tenant`**
(21 tables) and **`cob3_identity`** (27 tables), plus 2 documented support tables.
The installer itself does not create Catalog/Settings/Workspace or AI schemas; those are added by the
ordered migrations `002` (Settings, Catalog, Workspace) and `003` (AI and agent state) described below.

| File | Purpose |
|---|---|
| `INSTALL_FOUNDATION.sql` | **The master script.** Standalone, single atomic statement. Fresh install into an existing database. |
| `VERIFY_FOUNDATION.sql` | Read-only PASS/FAIL/WARN/PENDING report. Safe at any time. |
| `BOOTSTRAP_EXAMPLE.sql` | NONPRODUCTION example: one synthetic tenant, organization and administrator. |
| `seeds/core_permission_templates.sql` | Backfill generic core IAM templates to existing tenants after an upgrade. |
| `seeds/optional_observei_examples.sql` | OPTIONAL product example (Observei). Never run by the installer. |
| `future_integrations/` | Catalog contract + separately invoked integration template (not installed). |
| `migrations/001_initial_foundation.sql` | First migration; byte-identical to the installer for v1.0.0. |
| `migrations/002_settings_catalog_workspace.sql` | Ordered migration: `cob3_settings`, `cob3_catalog`, `cob3_workspace`, Identity amendments, real Catalog resolver, role `cob3_worker`. |
| `migrations/003_ai_agent_state.sql` | Ordered migration: 8 AI schemas (66 design tables + `cob3_connectors.source_scope_bindings`). |
| `VERIFY_MODULES.sql` | Read-only PASS/FAIL/PENDING report for migrations 002/003. |
| `src/NN_*.sql` + `build_installer.py` | Single source of truth and deterministic build (`--check` = drift check). |
| `src_migrations/NNN_*/NN_*.sql` + `build_migrations.py` | Source and deterministic build of migrations 002/003 (`--check` = drift check). |
| `tests/` | pytest suite run against a disposable server (79 tests: 52 foundation + 27 for 002/003). |
| `tools/schema_coverage.py` | Regenerates `docs/platform-foundation/SCHEMA_COVERAGE_APPENDIX.md`. |
| `tools/obs3_inventory.sql` | Read-only catalog export of legacy/live `obs3_*` schemas (evidence for backfill and additive telemetry changes). |

Migrations 002/003, the legacy `obs3_*` mapping and the design deviations are documented in
`docs/platform-foundation/MODULE_MIGRATIONS.md` and `docs/platform-foundation/OBS3_TO_COB3_MAPPING.md`.

Design and security documentation: `docs/platform-foundation/`.

## Prerequisites

* PostgreSQL **15 or later** (tested on 18.1; 15–17 were not executed, see the validation report).
* Extension **`btree_gist`** available (contrib). It is created in schema `public` if absent; a trusted
  extension needs only CREATE on the database, otherwise ask a DBA to run `CREATE EXTENSION btree_gist;`.
* An **existing** target database. Create it separately if needed, for example:
  `CREATE DATABASE myproduct OWNER my_migrator;` (not part of the installer, which is transactional).
* The database must **not** contain schemas `cob3_tenant` or `cob3_identity` (unless the same version is
  already installed, in which case the installer is a verified no-op). Other schemas are untouched.

### Connection privileges for the installer

Connect as a migration role that:

1. has `CREATE` on the database (the database owner is simplest), and
2. either has `CREATEROLE`, or the DBA pre-created the four group roles and granted `cob3_owner` to it:

```sql
-- only when the installer may not create roles (no passwords; NOLOGIN group roles)
CREATE ROLE cob3_owner            NOLOGIN NOINHERIT;
CREATE ROLE cob3_runtime          NOLOGIN NOINHERIT;
CREATE ROLE cob3_provisioner      NOLOGIN NOINHERIT;
CREATE ROLE cob3_commercial_admin NOLOGIN NOINHERIT;
GRANT cob3_owner TO my_migrator;
```

Superuser is **not** required (tests install as a non-superuser `CREATEROLE` login).
Preflight checks all of this **before** changing anything.

## Execution order (DBeaver / pgAdmin / psql)

1. **`INSTALL_FOUNDATION.sql`** — open it and execute the whole file
   (DBeaver: *Execute SQL Script* Alt+X, or select all and Ctrl+Enter; pgAdmin: Query Tool → Execute;
   psql: `\i INSTALL_FOUNDATION.sql` or `psql -f`). It is one `DO` block, so it either installs
   everything or nothing. Expect the notice
   `Syskriti foundation 1.0.0 installed in database …`.
2. **`VERIFY_FOUNDATION.sql`** — expect no `FAIL`/`WARN` rows and `catalog integration = PENDING`.
3. Create login roles for applications (see *Runtime setup*).
4. Optional, disposable databases only: **`BOOTSTRAP_EXAMPLE.sql`** (needs `SET ROLE cob3_provisioner`).
5. Optional product seeds (`seeds/`), only for the product that wants them.
6. Ordered module migrations, as the same installer role: **`migrations/002_settings_catalog_workspace.sql`**, then
   **`migrations/003_ai_agent_state.sql`** (each one atomic `DO` statement; re-runs are verified no-ops), then
   **`VERIFY_MODULES.sql`**. They never touch `obs3_*` schemas.

Re-running the installer: same version and checksum → notice *Verified no-op: nothing was changed*;
anything else → error `SKPRE` before any change. The installer never drops, truncates or
overwrites existing objects.

## What the installer creates

* Schemas `cob3_tenant`, `cob3_identity` owned by `cob3_owner`.
* 48 logical tables with every specified column, type and nullability (807/807), 50 primary keys,
  128 tenant/organization-qualified foreign keys (all indexed), named CHECK constraints, partial unique
  indexes and 3 `btree_gist` exclusion constraints (no overlapping contract segments, approved overrides
  or active allocations).
* Support tables `cob3_tenant.foundation_installations` (version record) and `cob3_tenant.quota_counters`
  (transactional hard-quota counters).
* Triggers: trusted stamping (`created_*` immutable, `updated_*`, `row_version`), immutable scope ids,
  state machines, frozen published/issued/authorized records, append-only events, TRUNCATE guards,
  cross-row validation, hierarchy-cycle prevention, quota/allocation enforcement, deferred subtype and
  lifecycle checks, last-administrator protection.
* Row-level security **enabled and forced** on all 50 tables with command-specific policies per role.
* SECURITY DEFINER routines for bootstrap, provisioning, grants, credentials, sessions, approvals,
  audit, usage and entitlement resolution; `evaluate_access` for live authorization decisions.
* Seven core platform feature definitions used by identity quota enforcement
  (`organizations.max`, `humans.max`, `service_accounts.max`, `automations.max`,
  `api_credentials.max`, `automation.enabled`, `sso.enabled`).
* Infrastructure outside the schemas: roles `cob3_owner`, `cob3_runtime`, `cob3_provisioner`,
  `cob3_commercial_admin` (NOLOGIN, no passwords) and extension `btree_gist` if absent.

**Not created:** Catalog (`cob3_catalog`) or Settings (`cob3_settings`) schemas, plans, prices,
tenants, users, login roles, passwords, tokens, product (Observei) permissions or features, a payment
or SSO integration, a backend or UI.

## Runtime setup and backend configuration

```sql
CREATE ROLE myproduct_api LOGIN;            -- set authentication outside SQL (no passwords in scripts)
GRANT cob3_runtime TO myproduct_api;        -- customer-facing backend
CREATE ROLE myproduct_provisioning LOGIN;   GRANT cob3_provisioner TO myproduct_provisioning;
CREATE ROLE myproduct_billing LOGIN;        GRANT cob3_commercial_admin TO myproduct_billing;
```

Never grant `cob3_owner` (or SUPERUSER/BYPASSRLS) to a runtime login; `VERIFY_FOUNDATION.sql` flags it.
On a shared PostgreSQL cluster, role names are cluster-wide: use one cluster per product, or revoke
`CONNECT` on each product database from `PUBLIC` and grant it per login.

Every runtime request runs in **one explicit transaction**:

```sql
BEGIN;
SELECT cob3_identity.set_request_context(:tenant_id, :organization_id, :principal_id, :session_id, :credential_id);
-- queries / routine calls for this request
COMMIT;   -- context is transaction-local and disappears here
```

* Interactive human: after the trusted authentication adapter has verified the IdP assertion, call
  `cob3_identity.open_interactive_session(...)` once and pass the returned `session_id` per request.
  A session with `organization_id = NULL` authorizes tenant-control operations only.
* API key: `cob3_identity.verify_api_key(tenant, public_identifier, digest, audience)` returns the
  principal/credential to put in the context (or `open_api_key_session` for a bounded session).
* Without a valid session or credential in the context, the runtime role sees **nothing**.
* `cob3_identity.evaluate_access(...)` returns `allowed`, `reason_code` and `requires_approval`.
* Platform workers call `cob3_identity.set_system_context('system:<name>')`.

Error codes are custom SQLSTATEs: `SKAUZ` denied, `SKCTX` no/invalid context, `SKCAT` Catalog not
installed, `SKQTA` quota, `SKENT` not entitled, `SKIMM` immutable, `SKSTA` invalid state change,
`SKINV` invariant, `SKIDM` idempotency conflict, `SKAPP` append-only, `SKADM` last administrator,
`SKISO` unsafe isolation level (REPEATABLE READ refused for quota/allocation writes), `SKPRE` preflight.

## Known limitations (external integrations)

* Federated login: the database cannot verify OIDC/SAML tokens. A trusted adapter must verify
  signature/issuer/audience/nonce before `open_interactive_session`. No fake SSO verifier is provided.
* API keys: the backend generates high-entropy secrets and supplies digests (e.g. HMAC-SHA-256 with a
  server pepper); raw secrets are never stored. Digest comparison inside SQL is not constant-time.
* Payments/provider events: `record_provider_event` stores authenticated, tenant-resolved events only;
  webhook authentication and the platform ingress queue for unresolved events are out of scope.
* Settings-dependent policy (maximum grant lifetime, group-sync freshness, org automation policy) must be
  enforced by the backend with explicit secure defaults until `cob3_settings` exists.
* Catalog: domain/asset scopes, team-domain responsibility and any non-organization resource
  authorization fail closed (`SKCAT`/deny) until `future_integrations/` is applied.

## Backup, upgrade and recovery

* Take a backup (`pg_dump -Fc`) before installing into a database that holds other data.
* An installation error rolls back completely (single statement); fix the reported cause and rerun.
  Error `CONTEXT … line N` refers to the DO block: file line = N + the offset printed in the header.
* Upgrades are **ordered migrations** (`migrations/002_…`) that alter existing objects and insert a new
  `foundation_installations` row; never rerun a newer fresh installer over an old installation.
* Removing a test installation (disposable databases only): drop the database. There is no automatic
  destructive reset script by design.

## Rebuilding and testing

```bash
python build_installer.py            # rebuild INSTALL_FOUNDATION.sql + migrations/001 from src/
python build_installer.py --check    # drift check (CI): exit 1 if outputs differ from src/
python build_migrations.py           # rebuild migrations/002 and 003 from src_migrations/
python build_migrations.py --check   # drift check for the ordered migrations
pip install -r tests/requirements.txt
COB3_TEST_DISPOSABLE_SERVER=1 COB3_TEST_ADMIN_DSN="host=localhost port=55432 user=pgsuper dbname=postgres" \
    python -m pytest tests -q        # creates and drops its own databases on a DISPOSABLE server only
```
