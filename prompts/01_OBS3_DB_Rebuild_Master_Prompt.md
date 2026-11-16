# MASTER PROMPT 1 — OBS3 platform database rebuild (`observei3`)

> Paste everything below this line into GitHub Copilot Chat (Agent mode) on the server that can reach the
> `observei3` PostgreSQL database. Work phase by phase. Stop at every **GATE** and wait for my written approval.

---

## 0. Your role and the outcome I want

You are the database engineer for the Observei / Syskriti platform. The `observei3` database on this server holds
every schema under the **`obs3_` prefix**. A design and a tested SQL implementation exist in the **COB3 repository**,
where the same schemas are named `cob3_*` (my local mirror). Your job:

1. **Rebuild the application-state schemas** (tenant, identity, settings, catalog, workspace, AI/agent state,
   connectors) to the new COB3 design, **under the `obs3_` prefix**. These are dropped and recreated **empty**.
2. **Enhance the live telemetry schemas additively.** Add new columns, control tables, indexes and secured views.
   Fill new columns only with bounded **UPDATE/upsert** batches. **Every existing row is preserved.** Nothing is
   dropped, truncated, renamed or rewritten there.
3. Add a small **migration 004** for the gaps the frontend needs (self-service registration, invitations,
   organization domains, organization profile fields) and for any legacy column that has no home in the new design.
4. Leave a clean, repeatable, verified migration set plus an **app contract** document that the application team
   (Master Prompt 2) will build against.

Never improvise around a safety rule in this prompt. If reality differs from what is written here, stop and report.

---

## 1. Sources of truth (read these first, in this order)

The COB3 repository must be present on this server. Ask me for its path if you cannot find it; below it is `$COB3_REPO`.

| Priority | File | Use |
|---|---|---|
| 1 | `docs/platform-foundation/OBS3_TO_COB3_MAPPING.md` | Legacy → new mapping, telemetry treatment, backfill order |
| 2 | `docs/platform-foundation/MODULE_MIGRATIONS.md`, `IMPLEMENTATION_DECISIONS.md` | What 001/002/003 implement, deliberate deviations, roles |
| 3 | `Observei_Live_Telemetry_Additive_Architecture_v1.md` | **The contract for every telemetry change** (§3 scope, §4 columns, §5 per-schema, §8 sequence, §9 gates) |
| 4 | `COB3_Tenant_Schema_Summary_v1.md`, `COP3_Identity_Consolidated_Schema_v1.md` | Tenant (21 tables) and Identity (27 tables) dictionaries |
| 5 | `COB3_Settings_Catalog_Workspace_Consolidated_Design_v1.md` | Settings, Catalog, Workspace (+ Identity amendments §6) |
| 6 | `COB3_AI_Agent_State_Design_v1.md` | 66 AI/agent tables |
| 7 | `database/syskriti_foundation/src/`, `src_migrations/`, `build_*.py`, `VERIFY_*.sql`, `tools/obs3_inventory.sql`, `tests/` | **The implementation.** Generate from it; never retype DDL by hand |

If two sources disagree, the higher row wins, except that the SQL in `src*/` wins on exact column types and
constraints because it is tested (79 passing tests). Write every disagreement you find into the report.

---

## 2. Non-negotiable rules

1. **Target database is `observei3` only.** Print `current_database()`, `inet_server_addr()`, `inet_server_port()`
   and `version()` at the start of every script and abort if the database name differs.
2. **Prefix translation is mechanical.** The server's prefix is `obs3_`. Produce the server SQL from the repo with a
   deterministic translator (§5), not by editing SQL. No `cob3_` token may remain in generated server SQL.
3. **Class B schemas (telemetry) are additive only.** No `DROP`, `TRUNCATE`, `DELETE`, `RENAME`, type change,
   `VACUUM FULL`, `CLUSTER`, table-copy swap or partition drop. No `ADD COLUMN … DEFAULT <volatile>` and no
   `NOT NULL` on existing large tables in the same step. Existing PKs, `ON CONFLICT` targets, source timestamps and
   legacy `tenant_id` values are never changed. Row counts before and after must be identical.
4. **`obs3_meta.alembic_version` is untouched**, as are all framework-owned tables.
5. **No secrets in SQL, files or logs.** No passwords, API keys, tokens or connection strings with credentials.
   Login roles are created without passwords; authentication is configured outside SQL.
6. **Every DDL script is one atomic transaction** (or one `DO` block), except `CREATE INDEX CONCURRENTLY`, which runs
   alone. Set `lock_timeout = '3s'` and a bounded `statement_timeout` on every telemetry DDL; on timeout, retry with
   backoff and give up rather than queueing behind long transactions.
7. **Never guess scope.** Telemetry rows get a canonical tenant/organization only through an *approved*
   `obs3_connectors.source_scope_bindings` row. Unresolved rows stay in place with `scope_status = 'unresolved'`.
8. **Nothing destructive runs before GATE 2 approval**, and only after a verified backup.

---

## 3. Schema classification (verify against the live catalog — the catalog wins)

| Class | Schemas (server names) | Treatment |
|---|---|---|
| **A — rebuild empty** | `obs3_tenant`, `obs3_identity`, `obs3_settings`, `obs3_catalog`, `obs3_workspace`, `obs3_agent`, `obs3_ai_runtime`, `obs3_copilot`, `obs3_memory`, `obs3_learning`, `obs3_llmobs`, `obs3_ai_lineage`, `obs3_connectors` | Back up, drop, recreate from translated 001 → 002 → 003 → 004. Start empty. |
| **A′ — legacy app-state replaced by A** | `llmobs_meta` (→ `obs3_llmobs`), any legacy copilot/agent tables found elsewhere | Back up, then drop at GATE 2 only if no live writer uses them |
| **B — live telemetry, additive only** | `obs3_aiops`, `obs3_core`, `obs3_cx`, `obs3_incidents`, `obs3_log`, `obs3_span`, `obs3_ops`, `obs3_search` | Rules in §2.3 and Phase 6 |
| **C — framework / platform control** | `obs3_meta` (alembic), `public`, extensions | Do not touch, except creating `btree_gist` if absent |
| **D — unknown → STOP** | Anything else, e.g. **`obs3_spans`** (looks like a sibling of `obs3_span`), any `cob3_*` schema found on the server, any schema not listed | Report what it holds, who writes to it and what depends on it. Do nothing until I classify it. |

Class A is exactly the set the translated 001/002/003 preflights refuse to overwrite, plus `obs3_tenant`. If the
live database has an A schema with a name the repo does not create (or vice versa), stop and report.

---

## 4. Phase plan

Create a working folder in the application repository (or next to it if there is none):
`db/obs3_platform_rebuild/` with the layout in §7. Commit after every phase with a clear message.

### Phase 0 — Environment discovery (read-only)

1. Confirm `psql` connectivity, PostgreSQL ≥ 15, `btree_gist` available, and the connected role's attributes
   (`CREATEROLE`, `CREATEDB`, ownership of the class A schemas). The installer needs `CREATE` on the database and
   `CREATEROLE` (or pre-created group roles, see the repo README).
2. List all schemas with size, table count, row estimates and owner.
3. **Find every writer and reader of every class A / A′ / D schema.** Search the application repo(s), Airflow DAGs,
   cron jobs, ETL code and stored routines for the schema and table names (`grep -rn "obs3_identity\|obs3_connectors\|llmobs_meta\|…"`).
   Also query `pg_stat_user_tables` (`n_tup_ins/upd/del`, `last_autoanalyze`) and `pg_stat_activity` for live use.
   Pay special attention to `obs3_connectors` (job leases may be used by ingestion DAGs) and to `obs3_search`
   views `v_doc_memory`, `v_doc_chat_message`, `v_doc_workspace`, which read app-state tables.
4. Find the application's ORM / Alembic models for class A tables (the app uses Alembic; `obs3_meta.alembic_version`
   exists). Note their revision IDs. Dropping those tables desynchronizes Alembic; the app team handles re-baselining
   in Master Prompt 2, so record exactly which models are affected.

### Phase 1 — Inventory and backup (read-only + dump)

1. Run `$COB3_REPO/database/syskriti_foundation/tools/obs3_inventory.sql`. Save every result set as CSV under
   `inventory/`. It covers relkind, columns/types/defaults, constraints, indexes, partitions, view/MV definitions,
   dependencies, grants, RLS and triggers.
2. **Cross-schema dependency scan:** list every object **outside** class A/A′ that depends on a class A/A′ object
   (`pg_depend` / `pg_rewrite` for views and MVs, FKs, functions, triggers, sequences owned by columns). Save each
   dependent object's full definition (`pg_get_viewdef`, `pg_get_constraintdef`, `pg_get_functiondef`) to
   `inventory/dependents/`. These are the only objects a `DROP … CASCADE` would also remove.
3. Baseline for class B: exact `count(*)` per table (or per partition with bounded queries off-peak), table and index
   sizes, ingest/update rates, WAL/replica lag, long-running transactions, free disk, autovacuum health.
4. Backups (I will provide credentials through the environment; never write them to files):
   * `pg_dump -Fc` of the whole database → `backups/observei3_full_<UTC>.dump`
   * `pg_dump --schema-only` → `backups/observei3_schema_<UTC>.sql`
   * Per class A/A′ schema data dump → `backups/<schema>_<UTC>.dump`
   * Verify each dump with `pg_restore --list` and record sizes and SHA-256 checksums.
5. **Legacy column gap report** (input to migration 004): for every legacy class A/A′ table and column, record its
   target in the new design using `OBS3_TO_COB3_MAPPING.md`. Columns with **no target** go to
   `reports/legacy_gap_report.md` with: legacy table.column, type, non-null count, sample *shape* (never values),
   and a proposal: (a) drop as obsolete, (b) map to an existing new column/setting key, or (c) add to 004.

**GATE 1 — stop.** Send me: schema classification as found, writers/readers per class A/A′/D schema, dependent
objects that a drop would remove, Alembic models affected, class B baseline, backup proof, and the gap report.
Wait for approval and for my decision on every class D schema.

### Phase 2 — Build the `obs3_` SQL from the repository (no database changes)

1. Add `tools/prefix_translate.py` to the COB3 repo (or the working folder). It reads the built files
   `INSTALL_FOUNDATION.sql`, `migrations/002_*.sql`, `migrations/003_*.sql`, `VERIFY_FOUNDATION.sql`,
   `VERIFY_MODULES.sql`, `BOOTSTRAP_EXAMPLE.sql` and `seeds/*.sql`, and writes `obs3_` variants into `sql/`:
   * Replace the token `cob3_` → `obs3_` and the escaped LIKE form `cob3\_` → `obs3\_`. Role names follow the same
     prefix (`obs3_owner`, `obs3_runtime`, `obs3_provisioner`, `obs3_commercial_admin`, `obs3_worker`) unless I say
     otherwise at GATE 1.
   * **Fix logic that assumed "obs3_ = legacy".** After translation, new and legacy schemas share a prefix. Every
     `LIKE 'obs3\_%'` that means "legacy/telemetry" (e.g. `VERIFY_MODULES.sql` check 70, `tools/obs3_inventory.sql`,
     the 003 preflight HINT) must be replaced with an explicit list of class B schemas. List each such change.
   * Recompute and print SHA-256 of each output; the installer's rerun guard uses its own checksum.
   * Assert afterwards: zero `cob3` tokens (case-insensitive) outside comments; every schema/role name in the output
     is in the expected list; identical line counts to the inputs (translation must not add or remove lines).
2. Run `python build_installer.py --check` and `python build_migrations.py --check` in the repo first, so you
   translate exactly the tested build.
3. Write **migration 004** source as `src_migrations/004_obs3_platform_enhancements/NN_*.sql` in the repo, built by
   `build_migrations.py` like 002/003 (record component `platform_enhancements` 1.3.0 in
   `tenant.foundation_installations`), then translate it. Follow every convention the repo uses: mandatory columns
   (`tenant_id`, `organization_id` where org-owned, `created_at/by`, `updated_at/by`, `metadata`, `row_version`),
   composite tenant/org FKs with covering indexes, named CHECKs, trusted stamping triggers, state-machine triggers,
   append-only where historical, RLS **enabled and forced** with command-specific policies that call
   `identity.evaluate_access`, SECURITY DEFINER routines for privileged transitions, digests only (never raw tokens).
   Contents of 004:

   | Object | Purpose | Key columns / rules |
   |---|---|---|
   | `obs3_tenant.tenant_registration_requests` | Self-service sign-up queue consumed by the provisioning worker | requested `tenant_code`, `name`, `legal_name`, `home_region`, requester name/email, `email_verification_digest`, `status` (`submitted` → `email_verified` → `approved`/`rejected` → `provisioned`), `reviewed_by`, `provisioned_tenant_id`, `expires_at`. Platform-scoped (tenant NULL until provisioned). Only `obs3_provisioner` approves/provisions; anonymous API can only insert via a routine with rate-limit-friendly idempotency key. |
   | `obs3_identity.organization_invitations` | Invite a person by email into an organization with proposed teams and roles | `invitation_id`, `email`, `email_key`, `token_digest`, `invited_by_principal_id`, proposed `team_ids` and `role_ids` as child rows (not arrays), `status` (`pending`, `accepted`, `revoked`, `expired`), `expires_at`, `accepted_principal_id`. Routines `issue_organization_invitation`, `accept_organization_invitation` (creates membership + manual team membership + role bindings in one transaction, re-checking the inviter's authority at accept time), `revoke_organization_invitation`. Needs `organization.manage_members`; role proposals need `role.assign`. Respects `humans.max` quota. |
   | `obs3_identity.organization_domains` | Claimed email domains for SSO routing and optional auto-join | `domain_name` (normalized lowercase, IDNA in app), `verification_method` (`dns_txt`), `verification_token_digest`, `status` (`pending`, `verified`, `revoked`), `verified_at`, `auto_join_policy` (`off`, `request`, `auto_member`). UNIQUE verified domain per tenant. Auto-join never grants roles. |
   | `obs3_identity.organizations` (ALTER, nullable) | Registration profile fields for the onboarding form | `country_code char(2)`, `industry_code varchar(64)`, `size_band varchar(20)` (CHECK list), `website_url varchar(2048)` (https only). Timezone/locale stay in Settings; logo stays in `settings.branding_profiles`. |
   | Permissions + role templates | Make the new tables usable | `organization.invite_members`, `organization.manage_domains`, `tenant.review_registrations` (platform) — added through `module_permission_templates` / `provision_tenant_iam_seed` the same way 002/003 do, and bound to `organization_administrator`. |
   | Setting definitions | Registry rows the UI renders as forms | `organization.default_timezone`, `organization.default_locale`, `organization.invitation_ttl_hours` (min 1, max 720), `organization.allow_domain_auto_join` (lockable at tenant). |
   | Gap-report items I approved | Legacy columns that need a home | Only those marked (c) and approved at GATE 1. |

   Add pytest cases for 004 in `tests/test_12_platform_enhancements.py` following the style of `test_10`/`test_11`
   (isolation across two tenants, invitation accept re-checks authority, expired/revoked tokens refused, domain
   uniqueness, RLS denies without context).

### Phase 3 — Rehearsal on a scratch database

1. `CREATE DATABASE observei3_rehearsal` and restore **the schema-only dump plus class A data dumps** into it (no
   telemetry data needed; use small samples only if I approve).
2. Run the full Phase 4 sequence there end to end, then Phase 5 checks. Time each step.
3. If a disposable cluster is available (`COB3_TEST_DISPOSABLE_SERVER=1`), run the repo's `pytest tests` on the
   translated SQL by pointing the suite at the `obs3_` outputs; all 79 + new 004 tests must pass. If not available,
   say so in the report — never point tests at `observei3`.
4. Run 001 → 004 a second time on the rehearsal database: each must report a verified no-op.

**GATE 2 — stop.** Send me: the exact ordered list of statements Phase 4 will execute, the objects that will be
dropped (schema by schema, including every dependent object outside class A from Phase 1.2), rehearsal timings and
verify output, and the rollback plan (restore from the Phase 1 dumps). Wait for approval and a maintenance window.

### Phase 4 — Rebuild class A (destructive, inside the approved window)

1. Re-check that no session is connected to class A objects (`pg_stat_activity`, `pg_locks`); stop the app writers I
   name (I will do it, you verify).
2. `sql/40_drop_class_a.sql`: one transaction; `DROP SCHEMA <name>` for each approved schema. Use `CASCADE` only
   when the dependent-object list equals the one approved at GATE 2; otherwise abort. Save the drop log.
3. Run in order, each as one script, as the installer role: `sql/41_install_foundation.sql` (translated 001),
   `sql/42_settings_catalog_workspace.sql` (002), `sql/43_ai_agent_state.sql` (003),
   `sql/44_platform_enhancements.sql` (004). Expect the "installed/applied" notices.
4. Run translated `VERIFY_FOUNDATION.sql` (no FAIL/WARN) and `VERIFY_MODULES.sql` (all PASS/INFO), plus a 004
   verify section you add to `VERIFY_MODULES.sql`.
5. Recreate the dependent objects from Phase 1.2 **only** where they can be rewritten against the new tables with
   identical or safer semantics (for `obs3_search.v_doc_memory/chat_message/workspace`, read the new
   `obs3_memory` / `obs3_copilot` / `obs3_workspace` tables and preserve their resource ACL semantics, per telemetry
   design §5.8). Anything you cannot rewrite safely stays dropped and goes in the report.
6. Grants: create no login roles with passwords. Print the exact `GRANT obs3_runtime TO <app_login>;`,
   `GRANT obs3_worker TO <worker_login>;`, `GRANT obs3_provisioner TO <provisioning_login>;` statements for me to run,
   and confirm no runtime login holds `obs3_owner`, SUPERUSER or BYPASSRLS.

### Phase 5 — Bootstrap the first tenant, organization and connections

1. As `obs3_provisioner`, call `obs3_identity.bootstrap_tenant(...)` (see `BOOTSTRAP_EXAMPLE.sql` for the call
   shape) with values I provide: tenant code/name/region, first organization code/name, first administrator's IdP
   issuer + subject + email. Never invent these. Then backfill core permission templates
   (`seeds/core_permission_templates.sql`, translated). The Observei example seed is optional — ask me.
2. Register one `obs3_connectors.connections` row per real telemetry source (Elastic logs, Datadog spans/changes,
   Dynatrace incidents/problems, Portkey gateway, CX survey source, …) found in Phase 0. Secrets go to
   `obs3_settings.integration_configurations.secret_reference` as references only.
3. From the inventory, list every distinct legacy tenant key (numeric/text `tenant_id`) and stream in each class B
   table. Create **draft** `obs3_connectors.source_scope_bindings` rows (`status = 'draft'`) proposing
   connection + `legacy_tenant_key` + `stream_key` + `selector_key` → canonical tenant/org, with `valid_from` at the
   earliest event time observed. One proposal per deterministic selector; flag any ambiguous selector.

**GATE 3 — stop.** Send me the draft bindings as a table. I approve each one; activation needs
`approved_by_principal_id` and `approved_at`, set through the authorized path. Do not activate anything yourself.

### Phase 6 — Telemetry: additive columns (class B)

Generate **one script per object** from the inventory, under `sql/6x_telemetry/<schema>/<object>.sql`. For each
table, first map existing equivalents (telemetry design §4), then add only what is missing:

| Column | Type | Add when |
|---|---|---|
| `tenant_id` *or* `platform_tenant_id` | uuid | `platform_tenant_id` when a legacy numeric/text `tenant_id` exists (keep it untouched); `tenant_id` only when the table has none |
| `organization_id` *or* `platform_organization_id` | uuid | Same rule for an existing org field with another meaning |
| `scope_binding_id` | uuid | Scoped base facts and dimensions |
| `source_connection_id` | uuid | When `source_system` does not identify the provider account |
| `scope_status` | varchar(20) | `resolved`, `unresolved`, `conflict`; nullable, no table-rewriting default |
| `record_created_at`, `record_updated_at` | timestamptz | Only when existing `created_at`/`updated_at` mean source time |
| `created_by`, `updated_by` | varchar(160) | Writer identity (`system:<dag>`), nullable for history |
| `metadata` | jsonb | Only if missing; small extension object |
| `row_version` | bigint | Mutable rows only (incidents, aliases, outbox, cursors) |
| `catalog_asset_id` | uuid | `obs3_core.dim_application` and durable governed entities only |
| `source_updated_at`, `source_revision`, `is_deleted`, `observation_kind` | per design §4 | Only where the provider supplies the evidence |
| `ai_run_id` | uuid | Only on verified correlated rows; existing `run_id` stays an ingestion/DAG id |

Per-schema specifics come from telemetry design §5 (follow it table by table): `llm_gateway_call` request/attempt
identity and cost provenance; `dim_application`/`dim_application_environment` Catalog link; `obs3_cx` scope on base
rows only (materialized views are **not** altered — new reports query scoped base rows); `obs3_incidents` provider
update ordering and scoped aliases; `obs3_log` full log key incl. date; `obs3_span` resolver version on
`service_alias`; `obs3_ops` platform-scoped audit stays without fabricated org; `obs3_search` family/outbox/
offset/watermark/embedding-cache fields from §5.8.

Rules per script: inspect the column first (`IF NOT EXISTS` does not prove type or meaning), nullable only, no
default that rewrites the table, `lock_timeout` 3s, handle partition parents and leaves explicitly, explicit column
lists. Before running, list every writer (Airflow DAG `INSERT … ON CONFLICT`, `COPY`, pandas `to_sql`) that uses
positional columns and would break when a column is added — those writers must be fixed first (report them; the app
prompt covers app code, DAGs are listed for me).

Also confirm each table's complete PK and `ON CONFLICT` target. If two organizations could collide under the current
unique key, **do not** change keys now: write it in the report as a blocker for onboarding that source combination.

### Phase 7 — Bounded backfill (UPDATE/upsert only)

`sql/7x_backfill/` + a small resumable runner (Python or plpgsql procedure with `COMMIT` per batch):
* Only rows matching an **active** binding by event time and selector; only rows still `scope_status IS NULL` or
  `'unresolved'`; compare `row_version`/source revision so a concurrent DAG correction is never overwritten.
* Batches of indexed stable keys (per partition / key range), 5–50k rows, high-watermark table per range, pause when
  replica lag, WAL rate, disk or ingest latency exceed the Phase 1 baseline thresholds.
* Never touch source timestamps, legacy keys or payload columns. Never use `ctid` as a resume cursor.
* Rows with no matching binding are set to `unresolved` (or left NULL) — never assigned a default organization.

### Phase 8 — Indexes, constraints, secured views

1. `CREATE INDEX CONCURRENTLY` one statement per file, only for scoped read paths and FK columns you add (BRIN for
   append-correlated time scans, B-tree for selective scoped lookups). Partitioned tables: per-leaf concurrent build
   then attach. Check for and drop `INVALID` leftovers you created.
2. Scoped FKs/CHECKs as `NOT VALID` only after new writers comply, then `VALIDATE CONSTRAINT` in a bounded window.
3. Secured canonical views (e.g. `v_*_scoped`) that expose `tenant_id`/`organization_id` canonical UUIDs and
   `legacy_tenant_id` separately, filter `scope_status = 'resolved'`, and never re-aggregate percentiles or averages
   incorrectly (design §7). Legacy views stay as they are for trusted consumers.

### Phase 9 — Verification and handoff

1. Class B row counts equal the Phase 1 baseline (plus rows ingested since, with ingestion verified healthy).
2. Translated `VERIFY_FOUNDATION.sql` and `VERIFY_MODULES.sql` clean; 0 unindexed FKs; RLS forced on every class A
   table; runtime role sees nothing without `obs3_identity.set_request_context`.
3. Telemetry acceptance gates from design §9 that can be checked now; list the rest as pending with owner.
4. Write `reports/REBUILD_REPORT.md` and **`reports/APP_CONTRACT.md`** (consumed by Master Prompt 2):
   * every class A table with columns, PK, scope category (platform / tenant / organization), and the permission
     codes that read/write it;
   * every routine the app must call instead of raw INSERT/UPDATE (`set_request_context`, `set_worker_context`,
     `open_interactive_session`, `verify_api_key`, `bootstrap_tenant`, `create_service_account`, `create_automation`,
     `issue_principal_credential`, `register_tenant_role`, `add_role_permission`, `create_authorization_grant`,
     `request_action_approval`, `issue_/consume_email_verification`, `register_asset`, `create_project`,
     `create_artifact`, `commit_artifact_revision`, `resolve_setting`, and the new 004 routines) with signatures;
   * the custom SQLSTATE error codes (`SKAUZ`, `SKCTX`, `SKCAT`, `SKQTA`, `SKENT`, `SKIMM`, `SKSTA`, `SKINV`,
     `SKIDM`, `SKAPP`, `SKADM`, `SKISO`, `SKPRE`) and what the UI should show for each;
   * the setting definitions registry (keys, types, enums, bounds, lock rules) the UI renders as forms;
   * the telemetry columns added per table and the new secured views;
   * the Alembic models that no longer match the database.

---

## 5. Translator acceptance checks (Phase 2)

* Translation is idempotent and deterministic (same input → byte-identical output).
* Generated schemas = exactly the class A list; roles = exactly the five `obs3_*` group roles.
* No generated statement references a class B or C schema, except the explicit-list checks you rewrote and the
  documented dependent views in Phase 4.5.
* `migrations/001` translated is still a single atomic `DO` statement.

## 6. Stop conditions (report and wait, do not work around)

* A class D schema, or a class A schema with a live writer you were not told to stop.
* Any class B table whose real structure contradicts telemetry design §5 in a way that changes meaning.
* A drop would cascade to an object not approved at GATE 2.
* A lock wait or timeout on a class B table during business hours.
* Row-count mismatch on any class B table.
* Ambiguous scope selector, or a source ID collision between two organizations.
* Missing privilege (`CREATEROLE`, ownership) — print the exact statement a DBA must run.

## 7. Deliverable layout

```
db/obs3_platform_rebuild/
  README.md                      # how to run, in order, with expected notices
  inventory/                     # CSV exports, dependents/
  backups/                       # dump manifest + checksums only (dumps live on the backup volume)
  tools/prefix_translate.py
  sql/
    41_install_foundation.sql    42_settings_catalog_workspace.sql
    43_ai_agent_state.sql        44_platform_enhancements.sql
    40_drop_class_a.sql          45_bootstrap_tenant.sql (parameterized, no real values committed)
    6x_telemetry/<schema>/<object>.sql
    7x_backfill/                 8x_indexes/   8x_constraints/   8x_views/
    VERIFY_FOUNDATION.sql        VERIFY_MODULES.sql
  reports/
    GATE1_REPORT.md  GATE2_PLAN.md  GATE3_SCOPE_BINDINGS.md
    legacy_gap_report.md  REBUILD_REPORT.md  APP_CONTRACT.md
```

## 8. How to report at each gate

Short, factual, tables first: what you found, what you will run next, what could go wrong, what you need from me.
Quote exact object names and counts. No prose summaries of documents I already have.

Start with Phase 0 now.
