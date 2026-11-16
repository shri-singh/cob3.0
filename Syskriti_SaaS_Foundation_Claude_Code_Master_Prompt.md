# Syskriti Reusable SaaS Foundation — Claude Code Master Prompt

**Purpose:** implement the reusable Tenant and Identity backend/database foundation from the two accompanying schema specifications.  
**Prepared:** 8 November 2026

## How to use

Place these three files in your VS Code project, preferably under `docs/platform-foundation/`:

1. `COB3_Tenant_Schema_Summary_v1.md`
2. `COP3_Identity_Consolidated_Schema_v1.md`
3. This master prompt.

Paste everything between **BEGIN MASTER PROMPT** and **END MASTER PROMPT** into Claude Code, or ask Claude Code to read this file and execute that section. Paths in this prompt are proposed repository paths; adapt to the actual checkout after inspection.

---

## BEGIN MASTER PROMPT

You are the principal backend architect and PostgreSQL engineer implementing a reusable SaaS platform foundation for **Syskriti**. Work directly in this VS Code repository. Read the source specifications and existing project instructions before editing. Implement the requested deliverables; do not stop at an architecture explanation, a plan, or pseudocode.

### 1. Business and architectural perspective

Syskriti will build multiple SaaS products. Observei/Opsi is one product using this foundation, not the identity of the foundation itself.

We want a reusable backend package and versioned PostgreSQL schema implementation that future Syskriti products can adopt with the same installation scripts, migration history, core entity model, security rules and provisioning workflow. Product-specific permissions, feature codes and plan seeds may differ, while core identity and tenancy behavior remains consistent.

The eventual platform has four logical modules:

- **Tenant:** customer accounts, commercial plans, subscriptions, purchased capabilities, quota allocation, usage and billing records.
- **Identity:** organizations, principals, teams, permissions, roles, scoped bindings, credentials, delegation and identity audit.
- **Catalog:** product domains and governed resources/assets; implemented later.
- **Settings:** configurations and preferences; implemented later.

**Implement only Tenant and Identity now.** Do not build a frontend, Observability ingestion pipeline, dashboards, a real payment integration, a complete identity-provider login integration, Catalog or Settings.

Reuse across products initially means **the same package and SQL installed into separate product databases/deployments**. Do not silently turn this into one shared cross-product identity database or add cross-product SSO, product subscriptions, cross-tenant federation or a product_id to every table. Document those as separate future architecture choices.

Avoid hardcoding Observei, Opsi, Dynatrace, Elasticsearch, CopilotKit or a particular cloud into generic core tables/services. Product-specific seed examples must be separated and explicitly optional.

### 2. Authoritative design inputs

Locate and read these files completely, including constraints and enforcement sections:

- `COB3_Tenant_Schema_Summary_v1.md`
- `COP3_Identity_Consolidated_Schema_v1.md`

Search the repository by filename if their folders differ. If a source file is missing, tell me which file is missing; do not invent its contents. Continue independent repository discovery while identifying the missing dependency.

The specifications describe **21 Tenant tables and 27 Identity tables**. Preserve all 48 logical tables and all documented columns/semantics. They are design inputs, not executable migrations. Resolve implementation gaps explicitly instead of assuming every prose constraint is already SQL-safe.

This master prompt takes precedence for implementation scope, consistent naming, staged Catalog integration and deliverables. Preserve source files unchanged. Write reconciled decisions into a separate implementation document.

Naming reconciliation:

- The files use inconsistent `COP3`/`COB3` prefixes.
- For a fresh implementation, normalize to **`cob3_tenant` and `cob3_identity`** throughout tables, FKs, routines, policies, models, tests and documentation.
- Later module contracts use `cob3_catalog` and `cob3_settings`; do not create those schemas now.
- If the existing repository/database already depends on `cop3_*`, preserve its working objects, document the mapping and prepare an explicit non-destructive migration strategy. Do not silently rename live schemas.
- Use a single source for schema-name constants in backend code/generation. Delivered SQL must contain resolved identifiers and execute directly, not contain unresolved template variables.

### 3. Start with discovery and reconciliation

Inspect repository instructions, backend stack, package manager, ORM, migration conventions, PostgreSQL version configuration and existing tests. Check git status and preserve unrelated work.

Use the existing backend stack where appropriate. For an empty repository, default to a modular Python/FastAPI/SQLAlchemy structure with PostgreSQL, using compatible versions established during setup. Pin dependencies and document the versions actually tested.

Write a concise design-reconciliation note covering:

- Source-to-final schema/table mapping.
- Platform-wide catalog rows versus tenant-owned and organization-owned rows.
- Tenant/Identity circular references and bootstrap ordering.
- Composite tenant/org foreign keys and parent UNIQUE constraints needed by child references.
- UUID key differences between the two source documents; do not normalize away required isolation guarantees.
- Which invariants use CHECK/FK/UNIQUE, triggers, authorized routines or backend services.
- Which future Catalog-dependent operations remain disabled.
- PostgreSQL minimum version and any required extensions/privileges.

Make reasonable reversible implementation choices and proceed. Ask only when an unresolved choice risks existing data, changes the business model, or requires unavailable credentials. Do not repeatedly ask whether to begin the already requested implementation.

### 4. Core identity behavior to preserve

Principal types:

- `human`
- `service_account`
- `automation`

A token is a credential, never a fourth principal type. A simple personal/service token uses its existing owner principal; a separately accountable agent/assistant uses an automation principal.

Preserve:

- Tenant -> multiple organizations.
- Principal -> memberships in multiple organizations within a tenant.
- Team -> exactly one organization, with explicit responsibilities in multiple domains when Catalog is integrated.
- Roles -> explicit atomic permissions.
- Role bindings -> recipient plus organization/domain/asset scope.
- Tenant control-plane authority separate from organization data access.
- Human profile, service profile and automation profile subtype integrity.
- Human/service creation of automations; no automation self-provisioning or recursive delegation in this version.
- Creator, accountable owner and delegating authority are distinct concepts.

Token/noninteractive authorization must evaluate:

**live grantor permissions AND live grantee permissions AND approved grant capability AND credential subset, where present**, plus lifecycle, organization, scope, audience, expiry, approval and credential-usage checks.

Restricted-self grants have grantor=grantee. Delegated grants have a human/service grantor and automation grantee. Empty grant/credential capability sets deny access. Team assignments or later role expansion cannot bypass the immutable approved grant ceiling.

Interactive human sessions follow current RBAC; API-key authentication must not become an unrestricted interactive session. A requested principal/tenant/org ID from a client is not proof of authority. Preserve federated authentication integration interfaces without implementing a fake SSO verifier.

Automation-use credentials attached to humans/services must not bypass the automation IAM restrictions. Privileged IAM endpoints require the documented interactive or separately authorized provisioning path. Do not assume a descriptive usage label can identify every script that holds a personal token.

Implement reusable, testable authorization/entitlement services for this boundary. Do not implement JWT/OIDC cryptography from scratch. If no existing trusted authentication adapter is available, fail closed for unauthenticated production calls and keep any fixture authentication test-only.

### 5. Tenant commercial behavior to preserve

- One tenant master; organization master remains in Identity.
- Platform catalog tables explicitly have tenant_id=NULL and organization_id=NULL; this is not a row-security wildcard.
- Versioned plans, features, entitlements and published prices.
- One live base subscription per tenant in this version.
- Explicit effective contract segments; prevent overlapping periods.
- Immutable published/issued terms and transaction snapshots.
- Tenant overrides approved by platform commercial authority, not by customer tenant administrators.
- Feature availability is separate from identity permission.
- Finite tenant quotas and explicit organization allocation semantics.
- Gauge limits and counter consumption have different measurement rules.
- Usage idempotency, correction validation and rebuildable rollups.
- Subscription lifecycle is separate from tenant operational status.
- Billing/provider records are an operational mirror, not a full tax/accounting engine.
- Monetary totals use integer minor units and explicit currency; never floating-point arithmetic.

Implement critical race-sensitive checks with actual concurrency control: no check-then-insert quota allocation race, double event charging, overlapping contract activation or replayed action approval. If hard quota reservation requires an additional small internal table, implement and document it within these two schemas rather than claiming asynchronous rollups enforce a hard limit. Do not create a general job scheduler or billing engine as scope expansion.

### 6. Required database engineering

Translate the specifications into real PostgreSQL objects:

- Schemas and all 48 logical tables.
- Every common and table-specific column, type, nullability and default.
- Primary, unique and tenant/org-qualified foreign keys.
- Named CHECK constraints, partial unique indexes and necessary lookup indexes.
- Deferred constraints where subtype/bootstrap order genuinely requires them.
- Timestamp/actor/version maintenance and immutable-envelope enforcement.
- Cross-row subtype, role-class, same-grant credential, approval and lifecycle validation.
- Safe hierarchy cycle prevention under concurrent mutations.
- Append-only audit/usage/lifecycle handling and controlled retention boundaries.
- RLS visibility/write policies appropriate to each table and command.
- Explicit runtime grants, schema ownership and restricted routine execution.
- SQL COMMENT ON statements documenting important entities and security assumptions.

No secrets, tokens, passwords or live customer PII in seeds or source control. No security-critical state hidden in free-form metadata. No CHECK functions that pretend to safely validate mutable other-table state. Triggers that maintain cross-row invariants must handle changes on both sides or enforce immutability.

Use advisory/row locks or exclusion constraints as appropriate and demonstrate concurrency behavior. If an extension such as btree_gist is required, make it explicit in preflight and document the installation privilege. Never silently omit an invariant because the extension is unavailable.

If using SECURITY DEFINER functions, fix a safe search_path, qualify objects, restrict ownership and EXECUTE grants, avoid untrusted dynamic SQL and validate caller authority. Do not grant end users direct SQL access to the trusted runtime connection.

Transaction-local context for RLS must be established by trusted backend code. Arbitrary SQL by a compromised runtime role is not magically secured by user-settable custom settings; document the trust boundary honestly. Runtime role must not be owner, superuser or BYPASSRLS. Tenant-wide rows require more than blanket tenant visibility for credentials, sessions and identity administration.

Bootstrap must support the first tenant, organization, human profile, membership and administrator without disabling isolation globally. Use a controlled administrative routine/transaction and immutable system audit actor where appropriate. Do not ship a default admin password, permanently open bootstrap endpoint or executable production demo accounts.

### 7. Critical constraint: only two schemas, Catalog later

The Identity source references domain/asset tables that do not exist yet. Solve this deliberately:

1. Create Tenant and Identity successfully without Catalog or Settings.
2. Keep the specified domain_id/asset_id columns and future contract shapes.
3. Enable fully functional organization-scoped identity and permission operations now.
4. Install explicit fail-closed guards rejecting domain/asset scope creation, team-domain writes and resource-dependent authorization until a trusted Catalog resolver is installed. Unknown resources must never be accepted merely because a UUID was supplied.
5. Document which Catalog FKs are pending; never describe unconstrained future references as already database-enforced.
6. Provide a separately invoked future integration migration/template that first verifies real Catalog tables and composite keys, then installs and validates actual FKs and the trusted resolver, and only then enables dependent operations transactionally. It must not run in the initial installer.
7. Do not create fake Catalog masters, duplicate resource ownership in Identity, add a permanent always-true validator, or disable constraints to make tests pass.

Settings-dependent policy values can use explicit secure backend configuration defaults temporarily, with a documented adapter interface. Do not create cob3_settings or silently implement unlimited permissions as a default.

### 8. Backend deliverables

Build a modular persistence and service foundation using the repository's architecture. Keep product-independent interfaces for:

- Tenant onboarding and lifecycle.
- Organization/principal/membership/team operations.
- Role binding and live authorization evaluation.
- Grant approval, credential issuance/revocation and action approval consumption.
- Subscription/entitlement resolution and quota enforcement.
- Audit recording and transaction-local security context.

Use thin transport integration if the project already has FastAPI or equivalent. Do not build a large public CRUD API for every table; many security tables should only be written through controlled services/procedures. If creating a small API surface, protect it through the trusted authentication abstraction and test it. No UI work.

Where responsibility lives in application code rather than SQL, name the exact service/function and test covering it. Clearly separate 'schema installed' from 'full application security operational'. External payment/SSO adapters may remain explicit unavailable interfaces, but none may grant access or acknowledge unverified provider events as trusted.

Keep model metadata and database migrations consistent. SQL is the authoritative schema artifact for this delivery; ORM mappings must reflect it. Do not rely on create_all() as the migration/deployment strategy.

### 9. Mandatory SQL deliverables — directly executable

The most important output is a **complete PostgreSQL SQL script I can open in DBeaver or pgAdmin, paste into the SQL editor for an existing database, and execute to create the foundation**.

Produce a structure equivalent to:

```text
database/syskriti_foundation/
  README.md
  INSTALL_FOUNDATION.sql
  VERIFY_FOUNDATION.sql
  BOOTSTRAP_EXAMPLE.sql
  migrations/
    001_initial_foundation.sql
  seeds/
    core_permission_templates.sql
    optional_observei_examples.sql
  future_integrations/
    catalog_integration_contract.md
    catalog_integration.sql.template
  tests/
    ...
docs/platform-foundation/
  IMPLEMENTATION_DECISIONS.md
  SCHEMA_COVERAGE.md
  SECURITY_AND_AUTHORIZATION.md
  REUSE_IN_ANOTHER_PRODUCT.md
  VALIDATION_REPORT.md
```

Adapt file locations to the project, preserving these responsibilities.

Requirements for `INSTALL_FOUNDATION.sql`:

- Complete standalone plain PostgreSQL SQL/PLpgSQL.
- No psql-only backslash commands, `\\i`, `\\set`, shell commands, unresolved `${...}` / `{{...}}` placeholders, omitted fragments or external includes.
- No need for Alembic, Python or a running API to create the database objects.
- Target an existing database. Do not mix CREATE DATABASE into the transactional schema installer; document database creation separately if needed.
- Resolved canonical schema identifiers.
- Preflight supported PostgreSQL version, required extension availability and installation privileges before mutation where feasible.
- Arrange tables, delayed FKs, routines, triggers, policies and grants in dependency-safe order.
- Use a transactional fresh installation where supported. Keep any operations that cannot run transactionally outside and explain them; avoid unnecessary CONCURRENTLY clauses in a new empty schema.
- Include role/ownership setup if the installer requires CREATEROLE, with an explicit preflight and no passwords. For a managed environment that pre-provisions roles, support a documented least-privilege path without weakening security.
- Only create application objects inside the two requested schemas; PostgreSQL roles/extensions are explicitly documented infrastructure exceptions.
- No DROP SCHEMA CASCADE, table truncation, sample customers or automatic destructive reset.
- Make rerun behavior safe and explicit: verify matching version/checksum and no-op, or fail early without mutations. Do not conceal incompatible existing tables with blind IF NOT EXISTS.
- Keep a migration/version record in one of the two schemas if needed and document it as an internal support table beyond the 48 logical tables.

`VERIFY_FOUNDATION.sql` must be read-only and usable in the same SQL editor. Check installed version, object counts, expected constraints/triggers/policies/indexes, runtime role attributes and any unvalidated constraints. Flag intentionally unavailable Catalog integration separately from errors. Avoid claiming a policy is secure merely because its name exists.

`BOOTSTRAP_EXAMPLE.sql` must be separate, plainly labeled NONPRODUCTION EXAMPLE, complete and runnable against a disposable database with safe synthetic values and no default credentials. It should demonstrate creation of a tenant, organization, human principal/profile, membership and approved administrator bindings. Use supported bootstrap routines; do not disable security to load it. Provide explicit guidance for substituting real provider subjects/values in a real onboarding workflow.

Keep optional Observei permission/feature examples out of the mandatory core installer. Provide generic core IAM permissions and a tenant-provisioning routine that creates tenant-owned role/permission seeds per tenant. Platform plan catalogs and tenant-owned Identity role definitions have different ownership scopes; do not seed tenant roles with NULL tenant_id or a made-up universal tenant.

Installer and migration files must have one source of truth. If the installer is assembled from ordered SQL source files, include the deterministic build command and a drift check proving the committed standalone installer matches them. Future migrations must alter existing objects safely; the fresh installer is not an upgrade strategy.

### 10. Required tests and honest validation

Use a disposable local PostgreSQL database/container matching the supported version. Do not run destructive tests against a configured corporate/RDS database. A configured URL is not authorization to modify it.

Execute the delivered standalone installer itself, not only ORM-generated substitutes. Implement and run meaningful checks for:

1. Fresh install creates all 48 source tables plus documented support objects.
2. All specified columns, nullability, keys, constraints and reference scopes exist.
3. Second install is a verified no-op or clean early failure with existing data preserved.
4. Bootstrap commits without broken circular/subtype references.
5. Cross-tenant and cross-organization references are rejected.
6. Global commercial catalog policy is distinct from tenant-owned data policy.
7. Missing/incorrect runtime context fails closed; test under the actual nonowner runtime role.
8. Tenant-wide sensitive rows are not exposed to every member.
9. Hierarchy cycles and concurrent cycle attempts are rejected.
10. Grantor/grantee/subtype rules, same-grant credential references and immutable authorized envelopes hold.
11. A personal token cannot exceed its approved subset; empty subset denies.
12. Removing grantor/grantee authority, disabling membership, or revoking grant/credential blocks the next authoritative request.
13. Role expansion does not expand grant entries; automation cannot self-mint or administer IAM.
14. Sensitive action approval matches exact payload/resource and is single-use, including a concurrency test.
15. Domain/asset references fail closed without Catalog; organization-scoped authorization works.
16. Published catalog and issued invoice snapshots are immutable.
17. Subscription/override overlap prevention, usage idempotency, correction limits and quota races are tested.
18. Audit/event records cannot be updated/deleted/truncated by runtime writers.
19. Installer/migration/model/schema-coverage drift checks pass.

If local execution is unavailable, still finish scripts, backend code, static checks and reproducible test commands. Report precisely which runtime tests could not run and why. Never label unexecuted SQL 'tested', imply RLS was validated as a superuser, or claim production readiness from table creation alone.

### 11. Documentation and reuse requirements

`SCHEMA_COVERAGE.md` must map every source table and column to implemented objects. For each nontrivial invariant, identify its concrete constraint, trigger, procedure, service or test. Include explicit gaps, deliberate revisions and future Catalog-only dependencies.

`README.md` must explain:

- Prerequisites and minimum PostgreSQL version.
- Exact script execution order in DBeaver/pgAdmin.
- Which database connection privileges are required.
- Whether an empty database or empty target schemas are required.
- What fresh installation creates and what it intentionally does not create.
- Bootstrap and verification steps.
- Runtime role/context setup and backend configuration.
- Known external integration limitations.
- Backup/upgrade approach and safe recovery from an installation error.

`REUSE_IN_ANOTHER_PRODUCT.md` must explain how to install the same foundation in another Syskriti product database, provide new product permission/feature/plan seeds, bind a future Catalog adapter, and upgrade the shared foundation without forking its core. Do not copy Observei-specific seeds by default. Document isolated per-product tenancy as the initial model and explicitly separate any future shared-account strategy.

Provide a concise architecture diagram and a table of schema responsibilities. Record versions and actual test results in VALIDATION_REPORT.md. Keep product terminology out of core object names except for explicit optional seed examples.

### 12. Completion behavior

Proceed through discovery, reconciliation, implementation, local validation and documentation. Keep me informed with concise progress updates; do not stop after the plan.

At completion, report:

1. Canonical schema names used.
2. Path to the standalone installer I should execute.
3. Exact execution order and installer prerequisites.
4. Implemented table/object count and source coverage.
5. Backend modules delivered.
6. Tests actually run and their results.
7. Catalog/Settings-dependent functionality deliberately disabled.
8. Any remaining blocker or security invariant not yet implemented.

Do not deploy to production, execute against my real PostgreSQL database, publish, push to a remote repository or modify external services unless separately instructed. Local file creation and disposable local testing are authorized.

**Start by reading both source MD files and the repository instructions, then implement the reusable Syskriti Tenant and Identity foundation.**

## END MASTER PROMPT
