# Legacy `obs3_*` → `cob3_*` mapping

Target: the `cob3_*` schemas installed by `migrations/001` (Tenant, Identity), `002` (Settings, Catalog,
Workspace) and `003` (AI and agent state). Sources: the `obs3_settings` and `obs3_workspace` ERDs, the
legacy tables named in `COB3_AI_Agent_State_Design_v1.md` §2, and the live telemetry schemas in
`Observei_Live_Telemetry_Additive_Architecture_v1.md`.

Two rules apply to everything below:

* **App-state schemas** (`obs3_identity`, `obs3_settings`, `obs3_workspace`, `obs3_memory`, `obs3_learning`, legacy
  copilot/agent tables) are **migrated into `cob3_*`** by a later backfill. The legacy tables are not dropped until the
  backfill is reconciled and writers have switched (design §12 step 11).
* **Live telemetry schemas** (`obs3_aiops`, `obs3_core`, `obs3_cx`, `obs3_incidents`, `obs3_log`, `obs3_ops`,
  `obs3_search`, `obs3_span`, `obs3_meta`) **stay where they are**. They get additive scope columns later. No fact
  is copied into `cob3_*`.

Column types below come from the ERD icons (text, uuid, json, timestamp). Confirm them with
`tools/obs3_inventory.sql` before writing backfill SQL.

## 0. Identity maps every backfill needs first

| Legacy value | Canonical target | How |
|---|---|---|
| `tenant_id` (text in the ERDs) | `cob3_tenant.tenants.tenant_id` (uuid) | Reviewed one-to-one map, kept in the migration evidence. Never cast or guess. |
| Organization (absent in legacy app tables) | `cob3_identity.organizations` | One verified org per tenant → copy explicitly. Several orgs → keep the data at tenant scope until a reviewed per-row assignment exists (Settings design §12.6). |
| `user_id`, `owner_user_id`, `changed_by`, `applied_by` | `cob3_identity.principals` (human) | Map through the trusted IdP subject (`external_identities`), never by email. Unknown users fail closed into quarantine. |
| `obs3_identity.users` | `principals` (human) + `user_profiles` + `principal_emails` + `external_identities` + `organization_memberships` | A legacy email becomes an **unverified** `principal_emails` row unless real verification evidence exists (`verification_source = 'migration_review'`). |
| `obs3_identity.teams` | `cob3_identity.teams` | Team code is stable and unique per organization. |
| `obs3_identity.user_teams` | `team_memberships` + `team_membership_sources` (`manual`) | IdP-group-sourced memberships go through `external_groups` / `group_team_mappings` instead. |

## 1. `obs3_settings` → `cob3_settings`

| Legacy table.column | Target | Notes |
|---|---|---|
| `org_customization` (key `tenant_id`) | `setting_scopes` (organization; tenant while unmapped) + `setting_values` | The legacy key is a tenant, so it cannot tell organizations apart. That is fixed by the org map in §0. |
| `org_customization.role_navigation` | `setting_values` → key `navigation.role_navigation` (object, lockable) | Presentation only. Never an authorization input. |
| `org_customization.updated_by/updated_at` | `setting_values.updated_by/updated_at` + one `setting_change_events` row | `updated_by` must become `principal:<uuid>` or `system:<name>`. |
| `org_appearance.custom_theme` | `branding_profiles.theme_tokens` | Allow-listed token names and scalar values only. CSS/JS-like values are rejected by trigger. |
| `org_appearance.custom_logo` | `media_objects` (re-scanned, status `ready`) → `branding_profiles.logo_media_id` | Bytes go to private object storage. Legacy URLs are reviewed before import, never blindly fetched. |
| `user_customization.customization` | `setting_values` at `principal` / `principal_org` scope, one row per registered key | Unknown JSON keys are quarantined, not stored as a free bag. |
| `user_preferences.preferences` | Registered keys (`ui.*`, `locale.*`, `display.*`, `navigation.*`) + `notification_preferences` for notification keys | Mandatory `security` notifications cannot be disabled below organization level. |

## 2. `obs3_workspace` → `cob3_catalog` + `cob3_workspace` + Identity

| Legacy table.column | Target | Notes |
|---|---|---|
| `project` | `cob3_catalog.assets` (type `workspace_project`, explicit) + `cob3_workspace.projects` + `asset_ownerships` | Create through `cob3_workspace.create_project` (or the same steps in one owner transaction). |
| `project.name / description` | `assets.name / description` | Catalog owns the title and description. |
| `project.owner_user_id` | `asset_ownerships` (owner, primary, human) + owner role binding (`workspace_owner`) | Ownership is accountability. Access comes from the role binding. |
| `project.is_personal` | `projects.project_kind` (`personal` + `personal_owner_principal_id` / `shared`) | At most one live personal project per member per organization. |
| `project.visibility / team_id` | Explicit Identity `role_bindings` on the project asset scope (team or principal) | No visibility flag in the new model. Org-wide "public" needs a reviewed sharing decision (design §12.8). |
| `project.icon / color` | `projects.icon_code / color` | |
| `project.default_agent_id` | `cob3_copilot.threads.default_agent_id` (per conversation), or project setting | An agent reference grants nothing. |
| `project.settings` | `setting_values` at `project` scope (registered keys only) | Unknown keys are quarantined. |
| `project.archived_at` | `assets.status = 'archived'` (metadata history in `asset_metadata_versions`) | |
| `project_member (principal_type, principal_id, role)` | `role_bindings` on the project asset scope (`include_workspace_artifacts = true`) with `workspace_viewer` / `workspace_editor` / `workspace_owner` | Exactly one of principal or team. Owner/Editor/Viewer are just role names; the permission bundles live in Identity. |
| `folder` | `cob3_workspace.folders` | `path` is dropped (derived from the tree). `owner_user_id` → `created_by` actor only. |
| `saved_artifact` | `assets` (type `saved_artifact`, explicit) + `artifacts` | Use `cob3_workspace.create_artifact`. |
| `saved_artifact.kind` | `artifacts.artifact_kind` | Values: dashboard, saved_query, report, document, visualization, notebook, prompt, workflow, external_link. |
| `saved_artifact.definition / version` | `artifact_revisions` (one immutable row per historical version) + `artifacts.current_revision_id` | Import one consistent history. `content_sha256` is computed on canonical JSON. |
| `saved_artifact.visibility` | Exact asset role bindings and/or `artifacts.inherit_project_access` | Private artifacts → `inherit_project_access = false`. |
| `saved_artifact.is_default` | Setting `workspace.default_artifact_id` (principal_org or project scope) | Not an artifact flag. |
| `saved_artifact.dataset_group` | `asset_relationships` (`depends_on` → dataset asset), or `assets.attributes` | Never an ACL. |
| `saved_artifact.source_thread_id` | `artifacts.source_thread_asset_id` (conversation asset) | Must be a registered `conversation` asset in the same organization. |
| `saved_artifact.source_run_id` | `artifacts.source_run_reference` (opaque provenance) | |
| `saved_artifact.last_viewed_at / view_count` | `recent_items` per principal / `interaction_daily` | Not stored on the artifact. |
| `saved_artifact_revision (version, definition, change_note)` | `artifact_revisions (revision_number, definition, change_note)` | Append-only. |
| `saved_artifact_revision.changed_by / changed_by_type` | `artifact_revisions.author_principal_id` + `created_by` actor | Resolve the legacy type (user/agent) to a principal. Unknown → quarantine. |
| `report_schedule (cron, timezone, format, enabled)` | `report_schedules (cron_expression, timezone, output_format, status)` | Needs an explicit `execution_principal_id` + `credential_id`. Migrate as `paused` until those are set. |
| `report_schedule.recipients` (JSON) | `report_recipients` (internal principals) + verified `notification_endpoints` | External-only recipients are rejected in v1. |
| `report_run (run_at, status, rows, error)` | `report_runs (scheduled_for, status, row_count, error_code)` | Needs `artifact_revision_id` and `data_access_manifest`. Historical runs without them stay in the legacy table. |
| `report_run.output_uri` | `file_objects` → `report_runs.output_file_id` | Signed or public URLs are never persisted. |
| `bookmark (target_type, target_id, url, label, position)` | `bookmarks (target_asset_id XOR external_url, label, position)` | Free-form targets must resolve to a real Catalog asset. Otherwise only an HTTPS URL is kept. |
| `recent_item (route, target_type, target_id, title, visit_count, first/last_visited_at)` | `recent_items (last_route, target_asset_id, visit_count, ...)` | `title` is not copied (it comes from Catalog at read time). Query strings are stripped from routes. |
| `ui_session (started_at, ended_at, app_version, device)` | `ui_sessions (..., device_context)` | Needs the matching interactive `auth_session_id`. Expired legacy sessions are simply not migrated. |
| `trajectory` | `interaction_journeys` | `learning_container_ids` becomes lineage/memory references in `003`, not a UUID array. |
| `usage_event (event_name, route, feature_key, target, properties)` | `interaction_events` | UI telemetry only, never billing. `client_event_id` gives retry safety. |
| `usage_daily (day, feature_key, events, active_seconds)` | `interaction_daily (day, feature_code, event_count, active_seconds)` | Rebuildable projection. |
| `tag (scope, owner_id, name, color, is_system)` | `cob3_catalog.tags (visibility, owner_principal_id, tag_code, name, color)` | `scope = personal` → `visibility = private`. |
| `tag_link (tag_id, target_type, target_id, applied_by, confidence)` | `cob3_catalog.asset_tags` | The target must be a registered asset. |

## 3. Legacy AI tables (`obs3_memory`, `obs3_learning`, copilot/agent, `llmobs_meta`) → AI schemas

| Legacy object | Target |
|---|---|
| `agent`, `agent_revision` | `cob3_agent.agents` + `agent_revisions` (+ sealed `agent_tool_bindings` / `agent_skill_bindings`) and a `releases` row per published revision |
| `model_registry` | `cob3_agent.model_deployments` (identity/config) + `cob3_llmobs.model_prices` (effective-dated). Scores → `cob3_learning.evaluation_results` |
| `tool.scopes`, agent capabilities JSON | `cob3_agent.tool_permission_requirements` (declared only; authority comes from Identity) |
| `learning_container` | `cob3_memory.containers` (+ Catalog asset `memory_container`) |
| Skill source ID arrays, `memory_source`, `ai_lineage_edge` | `cob3_ai_lineage.nodes` + `edges` (typed, backing-row validated) |
| `copilot.agent_run`, `tool_call`, `run_event`, `interrupt` | `cob3_ai_runtime.runs`, `tool_actions` / `tool_attempts`, `run_events`, `interrupts` |
| `learning.agent_checkpoint`, `agent_checkpoint_write` | `cob3_ai_runtime.checkpoints`, `checkpoint_writes` |
| `thread_lock`, `thread_state` | `cob3_copilot.branches.state_version` + fenced `run_attempts` |
| `thread_share` | Identity `role_bindings` on the conversation asset |
| `chat_message` | `cob3_copilot.messages` (role kept separate from `author_principal_id` and `run_id`) |
| `memory_grant_policy` | Retired. Identity scopes + container permissions + live source checks replace it. |
| `feedback.user_id`, `annotation.user_id` | `cob3_learning.feedback` / `annotations.author_principal_id` + `source_kind` |
| `training_dataset.pii_scrubbed` | `cob3_learning.dataset_versions` (`use_basis`, reviewer, `redaction_policy_version`, approval) |
| `llmobs_meta` policies | `cob3_llmobs.policy_versions` (immutable, environment-bound) |
| `connections.encrypted_secrets` | `cob3_settings.integration_configurations.secret_reference` (secret manager). Rotate on cutover. |
| `jobs.lease_id / lease_until` | `cob3_connectors.jobs` + `job_attempts` (fencing token) |
| `alert_rule`, `slo_definition` | Kept as they are, pending the separate incident/Ops redesign |

## 4. Live telemetry schemas (stay in `obs3_*`)

| Schema | Treatment | `cob3_*` link |
|---|---|---|
| `obs3_aiops` (`llm_gateway_call`, `v_llm_gateway_daily`) | Stays authoritative for imported gateway calls. Additive scope/connection columns only. | Correlated (never copied) to `cob3_llmobs.invocations` / `invocation_attempts` by verified IDs. Reports pick one accounting source. |
| `obs3_core` (`dim_application`, `dim_application_environment`) | Keep surrogate keys. Add canonical scope + `catalog_asset_id` where uniquely resolved. | `cob3_catalog.assets` (type `application`) |
| `obs3_cx` (`customer_survey`, scored views, MVs) | Add scope to base rows. MVs untouched; new reports query scoped base rows. | — |
| `obs3_incidents` (incident, event, entity, evidence, alarm, aliases, views) | Scope + provider ordering columns. Restricted evidence. | Catalog assets for governed applications/entities |
| `obs3_log` (`log_event` + detail, rollups, dims, views) | Scope + connection. Keep partition keys and full log keys. | — |
| `obs3_span` (`span_event`, `change_event`, rollups, dims, `service_alias`) | Scope + connection + resolver version on aliases. | — |
| `obs3_ops`, `obs3_meta` | Platform control plane. `alembic_version` stays untouched. No fabricated org. | — |
| `obs3_search` (family, outbox, dlq, offsets, watermarks, embedding cache, settings, `v_doc_*`) | Reuse. Additive projection/scope/lease fields. Product preferences stay in `cob3_settings`. | `v_doc_memory/chat/workspace` read `cob3_*` with their resource ACLs |

**Scope mapping table.** The telemetry design (§3.2) proposes one control table, `obs3_core.source_scope_binding`.
Following your decision to merge everything into `cob3_*`, it is implemented as **`cob3_connectors.source_scope_bindings`**:

* Same columns and rules as the design.
* An exclusion constraint prevents overlapping active ranges.
* Activation needs an approver.
* An active mapping is immutable; corrections retire it and add a new `mapping_version`.

Telemetry rows can later carry `scope_binding_id` with a scoped FK to it. Migrations 002/003 do **not** alter
any `obs3_*` table. Those ALTERs are per-object scripts written from the `tools/obs3_inventory.sql` output, as the
telemetry design §8 requires (short lock timeouts, nullable columns, bounded backfill, `NOT VALID` then `VALIDATE`).

## 5. Backfill order

1. Run `tools/obs3_inventory.sql` on `observei3` and keep the CSV exports.
2. Build the tenant, organization and principal maps (§0). Unresolved rows are quarantined.
3. Identity (users, teams, memberships, emails), then Settings (scopes, values, branding/media).
4. Catalog assets + Workspace projects, folders, artifacts and revisions, then bindings from members/visibility. Re-run
   `VERIFY_MODULES.sql` and compare row counts per tenant/org.
5. Personal pointers, UI telemetry (optional; can start empty), schedules (paused) and recipients.
6. AI: definitions (frozen manifests) → conversations/messages → memory as **candidates** → feedback/datasets.
7. Shadow-read and compare, switch writers per organization, then retire the legacy writers. Legacy tables are
   kept until reconciliation is signed off.
