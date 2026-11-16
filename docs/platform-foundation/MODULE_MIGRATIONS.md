# Ordered migrations 002 and 003

| Migration | Component / version | Implements | Adds |
|---|---|---|---|
| `001_initial_foundation.sql` | `foundation` 1.0.0 | Tenant + Identity specs | `cob3_tenant` (21+2), `cob3_identity` (27) |
| `002_settings_catalog_workspace.sql` | `settings_catalog_workspace` 1.1.0 (+ `catalog_integration`) | `COB3_Settings_Catalog_Workspace_Consolidated_Design_v1.md` | `cob3_settings` (11), `cob3_catalog` (10), `cob3_workspace` (16), Identity `principal_emails` + `email_verification_challenges`, Identity amendments §6 |
| `003_ai_agent_state.sql` | `ai_agent_state` 1.2.0 | `COB3_AI_Agent_State_Design_v1.md` (66 tables) + telemetry design §3.2 | `cob3_agent` (14), `cob3_ai_runtime` (14), `cob3_copilot` (7), `cob3_memory` (6), `cob3_learning` (8), `cob3_llmobs` (10), `cob3_ai_lineage` (2), `cob3_connectors` (6) |

Total after 003: **156 tables** across 13 `cob3_*` schemas, 628 foreign keys (all indexed), and RLS enabled **and
forced** on every table. Legacy and live `obs3_*` schemas are **not touched**. See `OBS3_TO_COB3_MAPPING.md`.

## Running on the local `observei3` database

001 is already applied and `cob3_*` holds no data, so:

1. Connect to `observei3` as **the same role that ran 001** (it holds `cob3_owner` and `CREATEROLE`).
2. Execute `migrations/002_settings_catalog_workspace.sql` as one script (DBeaver: Alt+X). It is a single `DO`
   statement: everything is applied, or nothing is. Expected notice: `Migration 002 ... applied`.
3. Execute `migrations/003_ai_agent_state.sql` the same way. Expected notice: `... 67 AI tables installed`.
4. Run `VERIFY_MODULES.sql` (every row PASS/INFO) and `VERIFY_FOUNDATION.sql` (no FAIL/WARN).
5. Run `tools/obs3_inventory.sql` and keep the exports. They are the evidence the legacy backfill needs.

Re-running a migration that is already recorded is a verified no-op. If a different version is recorded, the run
stops before changing anything. 002 refuses to run if `cob3_settings`, `cob3_catalog` or `cob3_workspace` already
exist, and 003 does the same for its eight schemas. Neither one creates, alters or drops anything in `obs3_*`.

If the migration role lacks `CREATEROLE`, a DBA first runs `CREATE ROLE cob3_worker NOLOGIN NOINHERIT;`.

## Roles

| Role | New | Use |
|---|---|---|
| `cob3_runtime` | — | API requests via `cob3_identity.set_request_context`. Every module row is filtered by a live Identity decision. |
| `cob3_worker` | 002 | Trusted background workers: report scheduler, scanners, AI runtime, connectors, projectors. Must call `cob3_identity.set_worker_context(tenant, org, 'system:<name>')` per transaction and only sees and writes that tenant/organization. Without that call it sees nothing. NOLOGIN, no BYPASSRLS. Grant it to worker login roles. |
| `cob3_provisioner` | — | `provision_tenant_iam_seed` now also seeds the module permissions and roles. |

## Authorization model as implemented

* **Real Catalog resolver** (replaces the fail-closed guards, same signatures).
  * `governed` assets follow organization/domain containment.
  * `explicit` assets (every Workspace and AI type) open **only** through an exact asset scope, or through a
    Workspace project scope with `include_workspace_artifacts` covering an inheriting artifact. An org-wide
    `ai_user` or `workspace_viewer` binding opens nothing private.
  * Exact team bindings on explicit assets need no domain responsibility (design §6.5).
* **Creation is atomic.** `cob3_catalog.register_asset`, `cob3_workspace.create_project` and `create_artifact` insert
  the asset, the module row, the primary ownership and the creator's owner-role binding in one transaction.
  * An automation creating on behalf of a human records ownership only; it never grants rights.
  * Deferred constraint triggers reject an active asset without a primary owner or its module row, and an active
    artifact without a committed revision.
* **Revisions.** `commit_artifact_revision` advances the head optimistically (stale `row_version` → `SKINV`). Revision
  numbers are gapless under a row lock.
* **Settings.**
  * Typed registry with a database-side validator (type, enum, min/max, length, pattern, maxItems).
  * Explicit precedence via `cob3_settings.resolve_setting`; tenant/org locks win; one selected team only.
  * Every change is written to `setting_change_events`.
  * `effective_automation_policy` composes AND/MIN/OR and denies when no tenant policy is active.
* **Email.** `principal_emails` is the only writable master. `user_profiles.email` is a projection of the primary
  verified address, and legacy profile emails become unverified rows. `issue_/consume_email_verification` store only
  digests and count failed attempts.
* **AI.**
  * Agent, prompt and skill pointers can reference only published versions.
  * Revision bindings are sealed in the creating transaction.
  * Runs pin a published revision (unpublished only for `evaluation` runs), use a self-owned execution context and
    need `ai.agent.invoke`.
  * Terminal runs are frozen. Attempts carry monotonic fencing tokens; events and messages have gapless sequences.
  * Tool actions must use a tool bound to the run's agent revision, and need an Identity approval when required.
  * Assistant, tool and system messages come from workers only.
  * Lineage nodes must have a backing row of an allowlisted kind; derivation edges cannot form cycles.
  * Unknown token usage stays NULL, and cache/reasoning subsets are bounded by their totals.
  * Prices cannot overlap (exclusion constraint), and zero content retention forbids capture.

## Deliberate decisions and deviations from the design documents

| Topic | Decision | Reason |
|---|---|---|
| Schema names | `cob3_*` only. Nothing created in `obs3_*`. | Your decision to merge everything into `cob3_*`, and the docs' "no duplicate masters" rule |
| Telemetry mapping table | `cob3_connectors.source_scope_bindings` instead of `obs3_core.source_scope_binding` | Keeps live telemetry schemas untouched; it maps connector connections, so it sits with them |
| `asset_types` | Added release-owned columns `subtype_table`, `read/write/create_permission_code`, `owner_role_code`; `owning_module` also accepts `ai` | Data-driven module wiring, with no security decisions in `metadata` |
| AI asset type codes | `ai_dataset` and `connector_connection` (not `dataset` / `connection`) | `dataset` is already the governed Catalog data-asset type |
| `integration_configurations.adapter_type` | Adds `model_provider`, `tool_endpoint`, `telemetry_exporter`, `connector`, `training_provider` | The AI design references Settings configs for these adapters |
| Extra permissions | `settings.manage_tenant` (tenant control); AI: `ai.prompt.*`, `ai.skill.*`, `ai.tool.edit`, `ai.memory.manage`, `ai.application.manage`, `ai.model.manage`, `ai.review.manage`, `ai.retention.manage`, `ai.lineage.read` | Every table needs a concrete permission. The doc's list is called "suggested". |
| Generic Catalog permissions | Resource type `asset` (`catalog.read/manage`, `asset.share`, `ai.release.approve`) matches any asset type | One permission covers all asset types |
| New roles | `organization_member`, `workspace_viewer/editor/owner`, `report_operator`, `ai_user`, `ai_builder`, `ai_resource_owner`, `ai_reviewer`, `ai_administrator` | Org admins are **not** implicitly Workspace or AI users, and builders cannot approve their own releases |
| `user_profiles.avatar_uri` | Must be NULL (CHECK) | The design moves avatars to `avatar_media_id`; a legacy value blocks 002 until reviewed |
| `report_recipients.recipient_principal_id` | NOT NULL in v1 (CHECK) | Design §9: internal recipients only |
| Self-service settings | Fixed authenticated capability (interactive human, own scope) | Design §10 chooses this |
| Scan verdicts | Only a worker or system context may set media/files to `ready`/`rejected` | Uploads start quarantined |
| `foundation` verify | `VERIFY_FOUNDATION.sql` ignores the two Identity tables added by 002; `VERIFY_MODULES.sql` covers 002/003 | Keeps the 1.0.0 shape check exact |

## Not implemented here (next steps)

* **Backfill** from legacy `obs3_*` app tables. It needs the inventory output and the tenant/org/principal maps
  (`OBS3_TO_COB3_MAPPING.md` §0, §5).
* **Per-object additive ALTERs** on live telemetry tables (telemetry design §8). They need the inventory output and
  must run off-peak with lock timeouts.
* **Backend service routines** for AI run orchestration beyond the database contract. RLS lets the API create a
  self-owned context, run, user message and outbox row; workers do the rest.
* **Full JSON-Schema validation**, IDNA email normalization, cron/DST evaluation and webhook SSRF checks stay in
  application code. The database enforces shape, ownership and invariants.
* **Performance.** RLS predicates evaluate live Identity decisions per row. That is correct but costly for large
  listings, so list endpoints should batch authorization (design §13).

## Validation (disposable PostgreSQL 18.1 cluster)

* `python build_installer.py --check` and `python build_migrations.py --check`: no drift.
* 001 → 002 → 003 install as the non-superuser `CREATEROLE` installer. Re-runs are verified no-ops.
* `VERIFY_FOUNDATION.sql`: no FAIL/WARN. `VERIFY_MODULES.sql`: all PASS/INFO. 0 unindexed foreign keys.
* `pytest tests`: **79 passed**, made up of 52 foundation tests, 15 migration-002 tests and 12 migration-003 tests.
  Two foundation tests were corrected:
  * `test_06` hard-coded a usage timestamp of 2026-11-08, which is now outside the subscription period it creates.
  * `test_01` now accepts the migration-created `cob3_worker` role in the cluster-wide role check, while still
    requiring it to be unprivileged.
