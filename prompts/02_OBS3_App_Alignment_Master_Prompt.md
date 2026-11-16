# MASTER PROMPT 2 — Application alignment: discovery, architecture and plan

> Paste everything below this line into GitHub Copilot Chat (Agent mode) on the server that hosts the application
> code. Run it **after** Master Prompt 1 has reached at least GATE 2 (its `reports/APP_CONTRACT.md` and
> `reports/legacy_gap_report.md` must exist). This prompt produces an **architecture and an implementation plan**.
> Do not change application code in this run, except the planning documents listed in §8.

---

## 0. Your role and the outcome I want

You are the solution architect for the Observei application. The database is being rebuilt to the COB3 design
under the `obs3_` prefix (tenant, identity, settings, catalog, workspace, AI/agent state, connectors), and the live
telemetry schemas are getting additive scope columns. The application was built from modular components of
**OpenMetadata** (UI building blocks, forms, entity pages, possibly its Java/Python service patterns) and
**CopilotKit** (in-app AI copilot actions and readable context), plus our own backend.

Produce a plan that makes the application:

1. Work against the new database contract (new tables, routines, row-level security, error codes).
2. Offer complete front-end facilities for **tenant registration, organization registration and profile, team
   creation and membership, role creation with permission selection, role assignment, member invitation, domain
   verification, SSO/identity providers, service accounts and API credentials, approvals, audit, and settings** —
   with forms that match the new fields exactly.
3. Keep existing telemetry pages working, and move them to scoped data as soon as scope bindings are active.

You discover the code base yourself. Nothing below names a file; where you see *e.g.*, it is an example of what to
look for, not a claim that it exists.

---

## 1. Inputs to read first

| Input | Where | Use |
|---|---|---|
| `reports/APP_CONTRACT.md` | `db/obs3_platform_rebuild/` (from Prompt 1) | Tables, routines, permissions, error codes, settings registry. **Primary contract.** |
| `reports/REBUILD_REPORT.md`, `legacy_gap_report.md` | same | What changed, what was dropped, Alembic models now out of sync |
| COB3 design docs | COB3 repo (`$COB3_REPO`; ask me if not found) | `COP3_Identity_Consolidated_Schema_v1.md` §7 (roles/permissions), §8 (authorization service contract), §9.1 (DB vs app responsibilities); `COB3_Settings_Catalog_Workspace_Consolidated_Design_v1.md` §7 (settings resolver), §8 (media/URLs), §10 (permissions); `COB3_Tenant_Schema_Summary_v1.md` §11 (entitlements/quotas); `COB3_AI_Agent_State_Design_v1.md` §4 (AI authorization/execution) |
| Repo README + `docs/platform-foundation/SECURITY_AND_AUTHORIZATION.md` | COB3 repo | Request-context pattern, roles, error codes |
| The live database | read-only connection to `observei3` | Confirm columns/routines with `information_schema` and `pg_proc`; never trust a document over the catalog |

If `APP_CONTRACT.md` is missing, stop and tell me.

---

## 2. Rules for this run

1. **Plan only.** Read, search, run read-only commands, run existing tests if cheap. Do not edit application
   source, do not run migrations, do not change any database object, do not commit secrets.
2. **Evidence for every claim.** Every finding cites file path and line range (or DB object). Every planned change
   names the files it touches and why.
3. **The database decides authorization.** The app never re-implements permission logic as the source of truth.
   UI hiding of buttons is a convenience driven by an "effective permissions" API that calls
   `obs3_identity.evaluate_access`; the API still relies on RLS + routines.
4. **Reuse before you build.** Prefer existing OpenMetadata components (entity pages, tabs, tables, form builders,
   modals, permission-aware buttons, user/team pickers) and existing CopilotKit wiring. New components only where
   nothing fits; say which existing component each new screen is modeled on.
5. **No secrets in the browser.** API keys are shown once at creation and never retrievable; IdP client secrets and
   integration secrets go to the secret manager and are stored as `secret_reference` only.

---

## 3. Phase A — Discover the code base

Produce `docs/obs3-app-alignment/01_DISCOVERY.md` covering:

1. **Repositories and runtime topology.** Every repo/folder on this server that belongs to the app (UI, API,
   workers, Airflow DAGs, infra). Languages, frameworks and versions (`package.json`, `pyproject.toml`,
   `requirements*.txt`, `pom.xml`, Dockerfiles, compose/k8s manifests). How the UI talks to the API (REST,
   GraphQL, WebSocket), how CopilotKit's runtime endpoint is hosted, and which DB login each service uses.
2. **OpenMetadata reuse map.** Which OpenMetadata modules were copied or imported (UI component library, form
   utilities such as a field-generator / JSON-schema form, entity page layouts, permission providers, user/team/role
   pages, settings pages, API client generation). Whether they are vendored or a dependency, and how far they have
   been modified.
3. **CopilotKit usage.** Provider setup, runtime/backend endpoint, `useCopilotAction`/`useCopilotReadable` (or
   equivalents) inventory: each action, what it calls, what data it reads, and whether it checks permissions.
4. **Backend inventory.** Routers/controllers and their endpoints; request/response schemas (e.g. Pydantic/DTOs);
   service layer; DB access (ORM models, raw SQL, repositories); DB session lifecycle (per request? autocommit?
   pooled connections?); authentication middleware (IdP, JWT, sessions); background jobs.
5. **Alembic / migrations.** Revision history, models mapped to schemas now rebuilt, autogenerate settings
   (`include_schemas`, `include_object`), and what `alembic upgrade head` / `autogenerate` would do against the
   rebuilt database.
6. **Frontend inventory.** Routes/pages, navigation config, global state (store/context), API client layer, form
   library and validation, i18n, theme/branding, feature flags, existing admin pages (users, teams, roles,
   settings).
7. **Every reference to class A schemas/tables** (`obs3_tenant`, `obs3_identity`, `obs3_settings`,
   `obs3_catalog`, `obs3_workspace`, AI schemas, `obs3_connectors`, `llmobs_meta`) and to legacy table names from
   `OBS3_TO_COB3_MAPPING.md` (e.g. `users`, `teams`, `user_teams`, `org_customization`, `project`,
   `saved_artifact`, `agent`, `chat_message`). Classify each as read, write, or both.
8. **Telemetry access paths.** Every query against class B schemas, how it filters by tenant today (legacy numeric
   `tenant_id`?), and which views it uses.
9. **Tests and CI.** What exists, how long it runs, what would catch regressions.

---

## 4. Phase B — Impact analysis

Produce `docs/obs3-app-alignment/02_IMPACT_MATRIX.md`: one row per affected code unit.

| Column | Content |
|---|---|
| Unit | file / module / endpoint / page / Copilot action |
| Today | what it reads/writes (legacy table/columns) |
| New contract | target tables / routines / settings keys from `APP_CONTRACT.md` |
| Change type | rewrite, adapt, delete, new |
| Risk | what breaks if not changed (e.g. RLS returns zero rows, NOT NULL violation, dropped table) |
| Size | S / M / L |
| Depends on | other rows, DB gates (e.g. scope bindings active) |

Call out explicitly:
* Code that will **return empty results** under forced RLS because it never sets request context.
* Code that writes rows directly where a routine is mandatory (principals, memberships, credentials, grants,
  approvals, assets, projects, artifacts, revisions, tenants).
* Code that uses a single shared DB login with owner rights (must move to `obs3_runtime` / `obs3_worker`).
* Legacy concepts with no direct equivalent: project `visibility`, `is_personal`, artifact `is_default`,
  free-form `user_preferences` JSON, `memory_grant_policy`, `thread_share`, avatar URLs. Use the mapping doc.

---

## 5. Phase C — Target architecture

Produce `docs/obs3-app-alignment/03_ARCHITECTURE.md` with diagrams (Mermaid) and decisions. Cover at least:

### 5.1 Request context and DB access
* One explicit transaction per API request; first statement
  `SELECT obs3_identity.set_request_context(tenant, organization, principal, session, credential)`. Design the
  middleware / dependency / session wrapper that guarantees this, including connection-pool safety (context is
  transaction-local) and what happens for streaming responses and CopilotKit long-running calls.
* Login flow: trusted IdP verification in the API → `open_interactive_session` → session id in the app session.
  API keys → `verify_api_key` or `open_api_key_session`. Workers → `set_worker_context`.
* Organization switcher: a session with `organization_id = NULL` can only do tenant-control operations; how the UI
  picks and switches the active organization.
* DB logins: which service uses which group role; nobody runs as `obs3_owner`.

### 5.2 Error model
Map each custom SQLSTATE to an HTTP status, an API error code and a UI message pattern (`SKAUZ` → 403,
`SKCTX` → 401, `SKQTA`/`SKENT` → 402/409 with upgrade hint, `SKIMM`/`SKSTA`/`SKINV` → 409/422 with field mapping,
`SKIDM` → 409 idempotency, `SKADM` → 409 "last administrator", etc.). Optimistic concurrency: every edit form sends
`row_version`; a conflict shows "changed by someone else — reload".

### 5.3 Effective-permissions API
An endpoint that returns, for the current principal + organization (+ optional resource), the permission codes
that `evaluate_access` allows, cached per request, used by the UI to show/hide/disable actions and by CopilotKit to
decide which actions to register. It is a hint only; the write path is still enforced in the database.

### 5.4 Schema-driven forms
* **Settings forms are generated from `obs3_settings.setting_definitions`** (type, enum, min/max, length, pattern,
  maxItems, scope levels, lockability) and saved through the settings API; effective values come from
  `resolve_setting` with "inherited from tenant/org, locked" indicators.
* For entity forms (organization, team, role, invitation, service account, credential, identity provider, domain),
  define one form-schema source (JSON Schema or the OpenMetadata field-generator format already in the code base)
  derived from the DB contract, so client validation mirrors the DB CHECKs (code format, length, enums, https URLs,
  email shape). State how the schema stays in sync (generated from DB metadata vs hand-maintained with a contract
  test).

### 5.5 CopilotKit integration
* Each admin action available in the UI may also be a Copilot action, registered **only** when the effective
  permissions allow it, calling the **same API** (never direct DB), with human confirmation for every mutating
  action and an approval request (`request_action_approval`) where the permission requires it.
* Readable context limited to what the user can see; no secrets, no other tenants' data, no raw audit payloads.
* AI run state (threads, messages, runs) moves to the new `obs3_copilot` / `obs3_ai_runtime` tables: describe how
  the CopilotKit runtime persists threads/messages and which parts are worker-only per the AI design §4.

### 5.6 Alembic and models
Choose and justify: (a) re-baseline Alembic to the rebuilt schemas (new base revision, `alembic stamp`), or
(b) exclude DB-owned schemas from Alembic autogenerate and treat the SQL migrations as the source of truth with
read-only ORM models. Recommend one. Autogenerate must never try to recreate or drop DB-owned objects.

### 5.7 Telemetry pages
How telemetry queries move to the secured scoped views, how unresolved rows are excluded from customer views,
how pages behave before scope bindings are active (feature flag), and how legacy numeric tenant filters are
removed safely.

---

## 6. Phase D — Front-end feature design

Produce `docs/obs3-app-alignment/04_UI_FEATURES.md`. For **each** feature below give: route, entry point in
navigation, required permission(s), screens, form fields (DB column → field label → control → validation →
required/optional), API endpoints (method, path, request, response), the DB routine or table behind it, empty/error
states, and the existing OpenMetadata component it reuses. Add a low-fidelity wireframe (ASCII or Mermaid) per
screen.

| # | Feature | Notes the design must respect |
|---|---|---|
| 1 | **Tenant self-service registration** (public) | Writes `tenant_registration_requests`; email verification; provisioning worker calls `bootstrap_tenant`; first administrator from the verified IdP identity. Platform-operator review screen. |
| 2 | **Organization registration and profile** | `organizations` (code, name, legal name, description, parent, status, country, industry, size band, website); branding (`branding_profiles`, logo via `media_objects` upload → scan → ready); default timezone/locale via settings. Requires `tenant.manage_organizations` to create; org admins edit profile. Quota `organizations.max`. |
| 3 | **Organization domains** | Add domain, show DNS TXT instructions, verify, auto-join policy. |
| 4 | **Members and invitations** | Members list (membership status, teams, roles), invite by email with proposed teams/roles, resend/revoke, accept-invitation page, remove/suspend member. Quota `humans.max`. Last-administrator protection message. |
| 5 | **Teams** | Create/edit (code, name, description, `team_type`, parent), membership management (manual vs IdP-group-sourced, read-only for synced), external group → team mappings, team domains once Catalog is active. |
| 6 | **Roles and permissions** | Tenant role catalog (system roles read-only), create custom role (code, name, description, `role_class`), permission picker grouped by module/class with delegable/automation flags shown, `register_tenant_role` / `add_role_permission`. Requires `tenant.manage_roles`. |
| 7 | **Role assignments** | Assign roles to a principal or team at organization, domain, asset or project scope (`access_scopes` + `role_bindings`), tenant administrator assignment (`tenant_role_bindings`), validity window, effective-access viewer ("why can X do Y"). Requires `role.assign`. |
| 8 | **Identity providers / SSO** | `identity_providers` configuration (secret as reference), test connection, external identity linking, group sync status. Requires `tenant.manage_identity_providers`. |
| 9 | **Service accounts, automations, API credentials** | Create service account / automation, owner, issue credential with scoped grant (show secret once, store digest only), rotate, revoke, last used. |
| 10 | **Approvals inbox** | Pending `action_approvals` and grant authorizations; approve/deny with reason; requester cannot approve own request. |
| 11 | **Audit log** | Filterable `audit_events` viewer with `audit.read`; export. |
| 12 | **Settings** | Tenant, organization, team, personal levels; generated forms (§5.4); lock indicators; change history from `setting_change_events`; notification preferences and endpoints (email verification); integration configurations. |
| 13 | **Subscription and usage (read-only)** | Current plan/version, entitlements, quota usage vs limits, invoices list — for tenant admins; no payment capture in v1. |
| 14 | **Workspace sharing** | Project/artifact share dialog based on role bindings (`workspace_viewer/editor/owner`) instead of `visibility` flags; personal vs shared project. |
| 15 | **Connectors and scope bindings** | Connections list, sync status, and the scope-binding review screen (draft → approve → active, retire + new version) for platform/tenant admins. |
| 16 | **Onboarding wizard** | First-login flow for a new tenant admin: org profile → domains → invite members → create teams → assign roles → connect sources. Each step reuses the feature screens above. |

Also define: the organization switcher, the permission-aware navigation, and how forms show server-side field
errors mapped from DB constraint names.

---

## 7. Phase E — Implementation plan

Produce `docs/obs3-app-alignment/05_PLAN.md`:

1. **Milestones** in dependency order, e.g. M0 DB access layer + request context + error model → M1 authentication
   and session → M2 effective-permissions API + navigation → M3 organization/team/role/member features →
   M4 invitations, domains, SSO, credentials, approvals → M5 settings framework and branding → M6 workspace
   sharing and AI thread persistence → M7 telemetry scoped views → M8 onboarding wizard + Copilot actions →
   M9 hardening. Adjust to what discovery shows.
2. **Work items** per milestone: title, files to touch/create, acceptance criteria, tests to add, size, owner role
   (backend/frontend/full-stack), dependencies, and the DB gate it waits for.
3. **Testing strategy:** contract tests that fail when the DB catalog and the form schemas/DTOs drift; API tests
   for two tenants and two organizations (no cross-visibility); UI tests for each form's validation and
   server-error mapping; Copilot action tests that a user without permission never sees the action.
4. **Rollout:** feature flags per milestone, compatibility period for telemetry pages, data seeding for a demo
   tenant, rollback per milestone.
5. **Risks and open questions** for me, each with a recommended answer.

---

## 8. Deliverables of this run (only these files are written)

```
docs/obs3-app-alignment/
  01_DISCOVERY.md
  02_IMPACT_MATRIX.md
  03_ARCHITECTURE.md
  04_UI_FEATURES.md
  05_PLAN.md
  06_OPEN_QUESTIONS.md
```

Commit them on a new branch `plan/obs3-app-alignment` with one commit per phase. Then stop and give me a summary:
the five biggest risks, the milestone list with sizes, and the questions that block M0.

Start with Phase A now.
