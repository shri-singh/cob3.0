# Syskriti Settings, Catalog and Workspace — Consolidated Design

**Version 1.0 • 16 November 2026**  
**Status:** proposed schema specification, not executable SQL or a deployed migration.

Based on the current Tenant and Identity specifications and the two Settings/Workspace ERD screenshots. This proposal preserves the reusable Syskriti foundation rather than binding it to Observei. Existing documents are not overwritten; this document specifies the amendments they need.

## 1. Five schemas and ownership

Use the canonical `cob3_*` prefix from the latest master prompt. Existing screenshots use `obs3_*`; the Identity draft uses `cop3_*`. Map those names in one coordinated migration, not by creating duplicate masters.

| Schema | Authoritative content |
|---|---|
| cob3_tenant | Tenant/account lifecycle, purchased entitlements, quota, billing and billable metering |
| cob3_identity | Organizations, principals, profile identity, verified personal emails, roles, permissions, grants, credentials and authentication |
| cob3_settings | Preferences, branding, profile-media metadata, notification destinations, adapter configuration and restrictive policy settings |
| cob3_catalog | Business domains and canonical resource/asset registry, accountability, metadata, locations and semantic links |
| cob3_workspace | Projects, folders, saved artifact content/revisions, drafts, bookmarks, UI state, scheduled reports and optional interaction telemetry |

Workspace becomes a deliberate fifth schema. It is not another user-profile database. Settings may be edited from a single Profile screen, but backend ownership remains split cleanly.

| User-facing information | Authoritative storage |
|---|---|
| Name, basic profile, human identity | Identity principals/user_profiles |
| Multiple personal/work email addresses, verification, primary selection | Identity principal_emails and verification challenges |
| Organization/team support or report mailbox | Settings contact_addresses |
| Billing email | Tenant tenant_contacts/billing_accounts |
| Avatar picture bytes | Private object storage |
| Avatar object metadata | Settings media_objects |
| Which picture is the person's avatar | Identity user_profiles.avatar_media_id |
| Tenant/org/team logos and brand tokens | Settings branding_profiles referencing media_objects |
| Preferred timezone, locale, theme, accessibility, navigation | Settings definitions/scopes/values |
| Saved report, query or dashboard identity/title | Catalog assets |
| Saved report/query/dashboard content | Workspace artifact_revisions |
| Authentication session | Identity auth_sessions |
| Browser tab/filter state | Workspace ui_sessions |
| UI activity counts | Workspace interaction_events/daily |
| Chargeable consumption | Tenant usage_events/rollups |

## 2. Findings from the screenshots

Settings currently contains org_customization, user_customization, user_preferences and org_appearance. Both organization tables are keyed by tenant_id, so they cannot distinguish multiple organizations. Three generic JSON bags also overlap and have no visible typed validation or deterministic inheritance contract.

Workspace shows project, project_member, folder, saved_artifact, saved_artifact_revision, report_schedule, report_run, bookmark, recent_item, ui_session, trajectory, usage_event, usage_daily, tag and tag_link. The screenshot does not establish all actual database constraints; a live-schema export is required before migration.

The visible gaps are organization isolation, user-only ownership, duplicate mutable/revision definitions, free-form target_type/target_id links, recipient JSON, ambiguous trajectory semantics, and UI telemetry that could be confused with billable usage. The redesigned tables below address those gaps without duplicating Identity ACLs.

## 3. Shared conventions

Every table below explicitly includes tenant_id, organization_id, created_at/by, updated_at/by, metadata and row_version. Platform registries have both scope IDs NULL; tenant tables have tenant required and org NULL; org tables require both; context tables have tenant required and org determined by the declared scope owner.

- Tenant/organization masters remain in the existing schemas. Every tenant-owned row has a tenant FK; non-NULL organization values use the composite Identity organization FK. Tenant_id NULL is permitted only in named platform registries.
- Tenant/context entity PK: `(tenant_id, entity_id)`; platform registry PK: entity_id. Tenant-owned IDs generated with gen_random_uuid(). Organization-owned rows expose UNIQUE `(tenant_id,organization_id,entity_id)` for scoped FKs. Context-row references also require exact organization equality including NULL; ordinary MATCH SIMPLE does not prove this when nullable columns are involved, so use a tenant-qualified FK plus a two-sided scope-consistency trigger or typed composite references.
- All required columns are marked; unspecified nullable defaults are NULL. No default can infer a caller's tenant, organization or owner from untrusted request fields.
- Every optional reference has a real FK unless explicitly labeled opaque provenance. Tenant principal FK for tenant-wide identity; organization_memberships FK for org-bound actors. Status/lifetime eligibility must still be checked at runtime.
- ON DELETE/UPDATE RESTRICT by default. Controlled purge/tombstone workflows preserve evidence. Archived records and code names are not silently recycled.
- metadata and any designated object JSON column require jsonb_typeof='object'. Typed scalar setting values follow their registry type. All JSON has size/depth limits and schema validation; jsonb alone is not a validator.
- Positive row_version; immutable created fields; trusted mutation trigger updates modified fields and version. Append-only records keep modified fields equal to creation and version=1.
- Required names/codes/reasons are nonblank. Stable codes lowercase ASCII with approved syntax. UTC timestamps; IANA timezone strings for user/scheduler display. No raw secrets, signed URLs or binary files in metadata.
- Definitions below are a database/application enforcement contract. Cross-table rules require FKs, triggers or locked service transactions; they are not ordinary row CHECK expressions. A FK proves existence, not current permission.
- All new writes must be tenant/org scoped and authorized through trusted service functions. RLS runtime role is nonowner without BYPASSRLS, with both read and write policies. Tenant filtering alone does not protect personal drafts, emails or private artifacts.

## 4. Complete inventory


| Schema | Table | Scope | Purpose |
|---|---|---|---|
| `cob3_identity` | `principal_emails` | tenant | Authoritative contact addresses for humans; SSO provider subject remains the login identity. |
| `cob3_identity` | `email_verification_challenges` | tenant | Short-lived proof-of-control challenges; never store raw verification tokens. |
| `cob3_settings` | `setting_definitions` | platform | Versioned product-supported settings registry; not an unrestricted JSON preference bag. |
| `cob3_settings` | `setting_scopes` | context | Typed subject to which settings apply. |
| `cob3_settings` | `setting_values` | context | Validated explicit override; deleting the row means inherit. |
| `cob3_settings` | `setting_change_events` | context | Append-only redacted settings change history. |
| `cob3_settings` | `media_objects` | context | Private object-storage metadata for avatars, logos and other presentation media. |
| `cob3_settings` | `branding_profiles` | context | Brand identity at tenant/organization/team scope. |
| `cob3_settings` | `contact_addresses` | org | Organization/team operational mailboxes; human verified email remains in Identity. |
| `cob3_settings` | `notification_endpoints` | context | Verified destination for notification delivery, separate from preference. |
| `cob3_settings` | `notification_preferences` | context | Per-category notification/digest and quiet-hour choices. |
| `cob3_settings` | `integration_configurations` | context | Versioned validated nonsecret configuration and secret references for SSO/mail/webhook/integration adapters. |
| `cob3_settings` | `automation_policies` | context | Typed upper bounds on delegated execution; separate from cosmetic preferences. |
| `cob3_catalog` | `asset_types` | platform | Supported resource families with module ownership. |
| `cob3_catalog` | `domains` | org | Canonical business domain master required by Identity.team_domains and access_scopes. |
| `cob3_catalog` | `assets` | org | Canonical resource identity and access classification for all governed product/workspace objects. |
| `cob3_catalog` | `asset_ownerships` | org | Accountability and stewardship; not an ACL. |
| `cob3_catalog` | `asset_external_identifiers` | org | Trusted external ID mappings for imported/discovered resources. |
| `cob3_catalog` | `asset_locations` | org | Stable links or product routes; not bearer share links. |
| `cob3_catalog` | `asset_relationships` | org | Typed semantic/lineage links between registered assets. |
| `cob3_catalog` | `tags` | org | Shared or personal catalog labels; no authorization effect. |
| `cob3_catalog` | `asset_tags` | org | Tag assignments to actual registered assets. |
| `cob3_catalog` | `asset_metadata_versions` | org | Immutable Catalog metadata history; distinct from artifact content versions. |
| `cob3_workspace` | `projects` | org | Personal/team collaborative container, registered as one explicit Catalog asset. |
| `cob3_workspace` | `folders` | org | Folder tree for project organization; folders do not introduce independent ACLs in v1. |
| `cob3_workspace` | `artifacts` | org | Workspace content root registered as one Catalog asset; content stored in revisions. |
| `cob3_workspace` | `file_objects` | org | Private object storage records for artifact uploads and report outputs. |
| `cob3_workspace` | `artifact_revisions` | org | Immutable saved content history; replaces mutable definition plus duplicate revision copies. |
| `cob3_workspace` | `artifact_drafts` | org | Per-principal autosave state, separate from committed revisions. |
| `cob3_workspace` | `bookmarks` | org | Personal saved pointers; bookmark is not a resource access grant. |
| `cob3_workspace` | `recent_items` | org | Personal recent resource activity, not a resource master. |
| `cob3_workspace` | `ui_sessions` | org | Short-lived browser/app state; distinct from Identity authentication session. |
| `cob3_workspace` | `interaction_journeys` | org | Optional grouped UI workflow analytics, replacing ambiguous trajectory semantics. |
| `cob3_workspace` | `interaction_events` | org | UI telemetry; distinct from billable Tenant usage_events and security audit. |
| `cob3_workspace` | `interaction_daily` | org | Rebuildable daily UI usage projection. |
| `cob3_workspace` | `report_schedules` | org | Scheduled generation authorized by a specific principal and restricted execution credential. |
| `cob3_workspace` | `report_recipients` | org | Explicit distribution destinations; no arbitrary recipient email array. |
| `cob3_workspace` | `report_runs` | org | Idempotent execution record with resolved input revision and private output. |
| `cob3_workspace` | `report_deliveries` | org | Per-recipient delivery/retry status without regeneration of report. |

## 5. Full table dictionaries

### `cob3_identity.principal_emails`

Authoritative contact addresses for humans; SSO provider subject remains the login identity.

Scope: **tenant**. Primary key follows Section 3 using `principal_email_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| principal_email_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_id | uuid | NOT NULL | Human principal FK. |
| email_address | varchar(320) | NOT NULL | Preserved display/delivery spelling. |
| email_key | varchar(320) | NOT NULL | Canonical comparison key under explicit normalization policy. |
| label | varchar(32) | NOT NULL | work, personal, alternate. |
| is_primary | boolean | NOT NULL DEFAULT false | At most one active verified primary per principal. |
| verified_at | timestamptz | NULL | Verification evidence timestamp. |
| verification_source | varchar(24) | NULL | email_challenge, trusted_idp, migration_review. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, revoked. |

Constraints and behavior:

- UNIQUE (tenant_id, principal_id, email_key). Partial UNIQUE (tenant_id, principal_id) WHERE is_primary AND status='active'.
- Primary requires verified_at and active status. Verification timestamp/source set together. Same email may belong to multiple principals; never merge them by address.
- FK (tenant_id, principal_id) -> principals; subtype human. Add UNIQUE (tenant_id, principal_id, principal_email_id) for owner-bound endpoint references.
- Canonicalization policy: trim boundary whitespace, normalize domain case/IDNA; do not remove plus aliases or dots or assume all local parts are case-insensitive. Address changes create new record and require re-verification.

### `cob3_identity.email_verification_challenges`

Short-lived proof-of-control challenges; never store raw verification tokens.

Scope: **tenant**. Primary key follows Section 3 using `email_verification_challenge_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| email_verification_challenge_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_email_id | uuid | NOT NULL | Tenant-qualified principal_emails FK. |
| token_digest | bytea | NOT NULL | Digest of random high-entropy challenge. |
| expires_at | timestamptz | NOT NULL | Deadline. |
| consumed_at | timestamptz | NULL | One-time consumption. |
| revoked_at | timestamptz | NULL | Canceled challenge. |
| attempt_count | integer | NOT NULL DEFAULT 0 | Nonnegative attempts. |

Constraints and behavior:

- UNIQUE (tenant_id, token_digest); expires_at > created_at; attempt_count >= 0. Reject simultaneous consumed/revoked states.
- Consume atomically and set verified_at only for the exact unchanged address record. Rate-limit issuance/validation and redact tokens from logs; prune expired challenge secrets under retention policy.

### `cob3_settings.setting_definitions`

Versioned product-supported settings registry; not an unrestricted JSON preference bag.

Scope: **platform**. Primary key follows Section 3 using `setting_definition_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| setting_definition_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_key | varchar(128) | NOT NULL | Namespaced code, e.g. ui.theme or locale.timezone. |
| definition_version | integer | NOT NULL | Positive schema version. |
| value_type | varchar(16) | NOT NULL | boolean, integer, decimal, string, array, object. |
| default_value | jsonb | NOT NULL | Typed default; SQL NULL and JSON null are not an inheritance mechanism. |
| validation_schema | jsonb | NOT NULL | Approved JSON Schema object. |
| allowed_scopes | text[] | NOT NULL | Nonempty subset of tenant, organization, team, principal, principal_org, project. |
| category | varchar(24) | NOT NULL | appearance, localization, navigation, accessibility, workspace, notification, data_display. |
| user_overridable | boolean | NOT NULL DEFAULT false | Whether principal scopes may override. |
| lockable | boolean | NOT NULL DEFAULT false | Whether tenant/org may lock this value. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, retired. |

Constraints and behavior:

- UNIQUE (setting_key, definition_version); >0; tenant_id and organization_id must be NULL. Both JSON documents valid against application-pinned validator dialect.
- Only trusted product-release/admin code defines keys; tenants cannot invent policy or executable code. Type/schema immutable once used. One active definition version per key (partial unique index); controlled migration revalidates all existing values before activating changed definition.
- Store security limits in automation_policies, not generic preference keys; commercial entitlement never originates here.

### `cob3_settings.setting_scopes`

Typed subject to which settings apply.

Scope: **context**. Primary key follows Section 3 using `setting_scope_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| setting_scope_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| scope_type | varchar(24) | NOT NULL | tenant, organization, team, principal, principal_org, project. |
| principal_id | uuid | NULL | Human/service/automation principal where appropriate. |
| team_id | uuid | NULL | Organization-owned team. |
| project_id | uuid | NULL | Workspace project. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, archived. |

Constraints and behavior:

- tenant -> org/principal/team/project all NULL; organization -> org only; team -> org+team only; principal -> principal only and org NULL; principal_org -> org+principal only; project -> org+project only.
- Use six partial unique indexes on exact scope key: (tenant_id), (tenant_id,organization_id), (tenant_id,organization_id,team_id), (tenant_id,principal_id), (tenant_id,organization_id,principal_id), (tenant_id,organization_id,project_id), each filtered by scope_type; preserve one logical scope even when archived.
- Tenant principal FK for principal scope; scoped organization_membership FK for principal_org; scoped team/project FKs. Scope identity immutable. Deferred project FK added after Workspace creation.

### `cob3_settings.setting_values`

Validated explicit override; deleting the row means inherit.

Scope: **context**. Primary key follows Section 3 using `setting_value_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| setting_value_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_scope_id | uuid | NOT NULL | Scope FK. |
| setting_definition_id | uuid | NOT NULL | Global definition FK. |
| value | jsonb | NOT NULL | Typed validated value; reject JSON null unless definition explicitly permits it. |
| is_locked | boolean | NOT NULL DEFAULT false | Only authorized tenant/org lockable settings. |
| change_reason | text | NULL | Required for locks or administrative changes. |

Constraints and behavior:

- UNIQUE (tenant_id, setting_scope_id, setting_definition_id). Scope tenant/org must match row, including NULL using IS NOT DISTINCT FROM validation.
- Definition active, scope allowed, JSON type/schema and value-size validated. Lock decisions require explicit settings.manage_policy authority; principal/team cannot lock. Existing locks cannot be removed by lower scopes.
- Concurrent edits require row_version. Changing definition/value invalidates effective-settings cache and writes change event.

### `cob3_settings.setting_change_events`

Append-only redacted settings change history.

Scope: **context**. Primary key follows Section 3 using `setting_change_event_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| setting_change_event_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_scope_id | uuid | NOT NULL | Scope FK. |
| setting_key | varchar(128) | NOT NULL | Stable key snapshot. |
| operation | varchar(20) | NOT NULL | set, reset, lock, unlock. |
| old_value | jsonb | NULL | Redacted prior value. |
| new_value | jsonb | NULL | Redacted new value. |
| request_id | uuid | NOT NULL | Operation correlation. |
| occurred_at | timestamptz | NOT NULL | Change time. |

Constraints and behavior:

- UNIQUE (tenant_id,request_id,setting_scope_id,setting_key). Append-only; common updated fields equal creation fields and row_version=1. Scope organization equality enforced.
- Do not log credentials, private webhook tokens or PII unnecessarily; principal actor comes from trusted audit context.

### `cob3_settings.media_objects`

Private object-storage metadata for avatars, logos and other presentation media.

Scope: **context**. Primary key follows Section 3 using `media_object_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| media_object_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_scope_id | uuid | NOT NULL | Who owns this media: principal, tenant, organization or team scope. |
| uploaded_by_principal_id | uuid | NOT NULL | Uploader principal. |
| storage_provider | varchar(32) | NOT NULL | Approved configured storage driver. |
| storage_container | varchar(255) | NOT NULL | Bucket/container reference, not credentials. |
| object_key | text | NOT NULL | Stable private object key; no expiring signed URL. |
| object_version | varchar(255) | NULL | Immutable provider object version. |
| original_filename | varchar(255) | NULL | Sanitized original name. |
| mime_type | varchar(128) | NOT NULL | Verified content type. |
| size_bytes | bigint | NOT NULL | Nonnegative size. |
| sha256 | bytea | NOT NULL | 32-byte checksum. |
| width_px | integer | NULL | Positive if image. |
| height_px | integer | NULL | Positive if image. |
| status | varchar(20) | NOT NULL DEFAULT 'quarantined' | quarantined, ready, rejected, deleted. |

Constraints and behavior:

- Scope must not be project/principal_org for v1 profile/branding media; organization equality matches scope. Principal-profile media is tenant-scoped with owner principal in scope.
- Validate actual MIME/size, re-encode raster uploads, reject/strictly sanitize active formats, scan before ready. Object location immutable. Signed download URLs issued only after current media-use authorization; identifier/URL possession grants no read permission.
- No global object reuse across tenant boundaries. Binary content stays in object storage, not PostgreSQL JSON/BYTEA. Deletion waits until no live profile/branding reference and retention allows.

### `cob3_settings.branding_profiles`

Brand identity at tenant/organization/team scope.

Scope: **context**. Primary key follows Section 3 using `branding_profile_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| branding_profile_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_scope_id | uuid | NOT NULL | Tenant, organization or team scope only. |
| display_name | varchar(200) | NULL | Presentation name override; legal/master name remains elsewhere. |
| logo_media_id | uuid | NULL | Same-scope ready media. |
| favicon_media_id | uuid | NULL | Same-scope ready media. |
| theme_tokens | jsonb | NOT NULL DEFAULT '{}'::jsonb | Validated design tokens; no arbitrary JavaScript/CSS injection. |
| support_url | text | NULL | Validated HTTPS help URL. |
| support_email | varchar(320) | NULL | Display-only published support contact; not a notification identity. |

Constraints and behavior:

- UNIQUE (tenant_id,setting_scope_id). Scoped media FK plus exact ownership validation. Only theme-token allowlist, contrast/accessibility requirements and supported formats.
- Branding follows selected tenant/org/team context, not arbitrary union of every team. Email shown in branding does not confer proof of control or authorize message sending.

### `cob3_settings.contact_addresses`

Organization/team operational mailboxes; human verified email remains in Identity.

Scope: **org**. Primary key follows Section 3 using `contact_address_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| contact_address_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| team_id | uuid | NULL | NULL = organization contact; otherwise same-org team. |
| purpose | varchar(24) | NOT NULL | support, security, operations, reports. |
| email_address | varchar(320) | NOT NULL | Delivery address. |
| email_key | varchar(320) | NOT NULL | Canonical comparison key. |
| verification_method | varchar(24) | NULL | trusted_directory, provider_verified, admin_attested. |
| verified_at | timestamptz | NULL | Proof or explicit administrator attestation time. |
| verified_by_principal_id | uuid | NULL | Authorized verifier; scoped membership. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, revoked. |

Constraints and behavior:

- Separate partial unique keys (tenant_id,organization_id,purpose,email_key) for NULL team and (tenant_id,organization_id,team_id,purpose,email_key) for non-NULL team. Record verification method honestly; admin_attested is not challenge verification.
- Delivery permitted only to active verified/approved address under policy. Address mutation requires new verification. Do not copy billing contacts here; Tenant tenant_contacts/billing_accounts remain commercial source.

### `cob3_settings.notification_endpoints`

Verified destination for notification delivery, separate from preference.

Scope: **context**. Primary key follows Section 3 using `notification_endpoint_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| notification_endpoint_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_scope_id | uuid | NOT NULL | Principal or organization/team destination owner. |
| endpoint_type | varchar(16) | NOT NULL | email, in_app, webhook. |
| principal_email_id | uuid | NULL | Identity verified principal email; principal-scope endpoint only. |
| contact_address_id | uuid | NULL | Settings organization/team mailbox. |
| webhook_url | text | NULL | Approved HTTPS destination, no secret query string. |
| secret_reference | varchar(512) | NULL | Webhook signing credential reference only. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, disabled. |

Constraints and behavior:

- Email has exactly one email/contact FK and no webhook URL; in_app has neither and requires human principal scope; webhook requires URL and no email/contact FK. Webhook may have a signing secret reference.
- Validate endpoint scope matches address owner incl NULL org. User cannot select someone else's principal_email_id. Email source must remain active and verified at send time.
- Webhook URLs are server-validated against approved destinations; block network SSRF paths and revalidate DNS/redirects. No raw secrets in JSON. Disabling endpoint blocks pending sends.

### `cob3_settings.notification_preferences`

Per-category notification/digest and quiet-hour choices.

Scope: **context**. Primary key follows Section 3 using `notification_preference_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| notification_preference_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_scope_id | uuid | NOT NULL | Tenant/org/team/principal/principal_org scope. |
| category_code | varchar(64) | NOT NULL | Product-supported category: incidents, reports, mentions, security. |
| channel_type | varchar(16) | NOT NULL | email, in_app, webhook. |
| enabled | boolean | NOT NULL DEFAULT true | User preference; mandatory security events follow documented policy. |
| delivery_mode | varchar(16) | NOT NULL DEFAULT 'immediate' | immediate, daily_digest, weekly_digest. |
| quiet_start | time | NULL | Local quiet window start. |
| quiet_end | time | NULL | Local quiet window end. |
| timezone | varchar(64) | NOT NULL | Valid IANA timezone, e.g. Asia/Kolkata. |
| destination_endpoint_id | uuid | NULL | Optional explicit compatible endpoint. |

Constraints and behavior:

- UNIQUE (tenant_id,setting_scope_id,category_code,channel_type). Quiet endpoints both set or both NULL; equal endpoints rejected; overnight window permitted. Category validated by product registry.
- Endpoint's owner/scope must be compatible; a principal_org override may use that same principal's tenant-scoped endpoint, never another principal's. Mandatory security delivery cannot be disabled by a lower-level preference. Missing endpoint fails safely, not to a guessed email.

### `cob3_settings.integration_configurations`

Versioned validated nonsecret configuration and secret references for SSO/mail/webhook/integration adapters.

Scope: **context**. Primary key follows Section 3 using `integration_configuration_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| integration_configuration_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| setting_scope_id | uuid | NOT NULL | Tenant/org/team scope per adapter. |
| integration_code | varchar(64) | NOT NULL | Stable integration identity. |
| configuration_version | integer | NOT NULL | Positive version. |
| adapter_type | varchar(32) | NOT NULL | oidc, saml, smtp, email_api, webhook, product_adapter. |
| identity_provider_id | uuid | NULL | Existing tenant Identity provider for SSO configs. |
| configuration | jsonb | NOT NULL | Validated adapter-specific nonsecret object. |
| secret_reference | varchar(512) | NULL | Secret manager reference. |
| status | varchar(20) | NOT NULL DEFAULT 'draft' | draft, active, retired. |
| last_verified_at | timestamptz | NULL | Successful adapter validation time. |

Constraints and behavior:

- UNIQUE (tenant_id,setting_scope_id,integration_code,configuration_version); partial unique active integration code per scope. SSO requires tenant scope and matching Identity provider; other adapters disallow that provider reference.
- Active content immutable; rotate by a new version and transactional activation. SSO provider issuer/protocol remain authoritative in Identity and must match config. References replace the earlier free-form configuration_reference with a controlled mapping, not a second issuer master.
- SMTP sender address/domain is provider-verified configuration, not a human profile email. Credentials never in configuration JSON; expose redacted views only.

### `cob3_settings.automation_policies`

Typed upper bounds on delegated execution; separate from cosmetic preferences.

Scope: **context**. Primary key follows Section 3 using `automation_policy_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| automation_policy_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| policy_version | integer | NOT NULL | Positive version. |
| allow_automation | boolean | NOT NULL DEFAULT false | Explicit enablement subject to purchased entitlement. |
| max_grant_lifetime_seconds | integer | NOT NULL | Positive maximum. |
| max_credential_lifetime_seconds | integer | NOT NULL | Positive maximum. |
| require_approval_for_writes | boolean | NOT NULL DEFAULT true | Additional approval gate. |
| allow_external_delivery | boolean | NOT NULL DEFAULT false | Whether authorized report/webhook distribution is permitted. |
| status | varchar(20) | NOT NULL DEFAULT 'draft' | draft, active, retired. |

Constraints and behavior:

- Only tenant/org scope: no setting_scope_id needed; tenant_id required; organization nullable. Separate NULL/non-NULL unique keys for (scope,policy_version), one active per scope.
- Organization may tighten tenant/platform bounds only: logical AND for allowed actions, MIN for lifetimes, OR for required approvals. No active policy -> deny unattended execution until policy approved. Missing flags never default to unlimited.
- Active content immutable. Human/approved provisioning authority manages policies; automation cannot weaken its own policy. Neither this table nor feature settings grant Identity permissions or Tenant entitlements.

### `cob3_catalog.asset_types`

Supported resource families with module ownership.

Scope: **platform**. Primary key follows Section 3 using `asset_type_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_type_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| type_code | varchar(64) | NOT NULL | application, dataset, dashboard, document, portal, workflow, workspace_project, saved_artifact. |
| name | varchar(150) | NOT NULL | Display name. |
| owning_module | varchar(32) | NOT NULL | catalog, workspace, registered_product. |
| attributes_schema | jsonb | NOT NULL | Typed extension schema; no secret fields. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, retired. |

Constraints and behavior:

- UNIQUE type_code; both scope IDs NULL. Product-managed registry only; tenants do not define executable handlers. Definition changes versioned through reviewed migration; existing attributes revalidated.

### `cob3_catalog.domains`

Canonical business domain master required by Identity.team_domains and access_scopes.

Scope: **org**. Primary key follows Section 3 using `domain_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| domain_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| domain_code | varchar(64) | NOT NULL | Stable normalized code. |
| name | varchar(200) | NOT NULL | Display name. |
| description | text | NULL | Business description. |
| parent_domain_id | uuid | NULL | Same organization parent. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, archived. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,domain_code). Scoped parent FK. Reject self/indirect cycles with organization-serialized hierarchy updates.
- Hierarchy describes business structure only; descendant domains do not inherit authorization by default. Teams responsible for a domain remain in Identity.team_domains; do not create another team-role master.

### `cob3_catalog.assets`

Canonical resource identity and access classification for all governed product/workspace objects.

Scope: **org**. Primary key follows Section 3 using `asset_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_type_id | uuid | NOT NULL | Global asset type FK. |
| asset_code | varchar(128) | NOT NULL | Stable org-unique resource code. |
| name | varchar(255) | NOT NULL | Canonical display title. |
| description | text | NULL | Description. |
| domain_id | uuid | NULL | One primary authorization domain; same org. |
| authorization_mode | varchar(16) | NOT NULL DEFAULT 'explicit' | explicit or governed; controlled change. |
| attributes | jsonb | NOT NULL DEFAULT '{}'::jsonb | Validated type-specific descriptive attributes. |
| status | varchar(20) | NOT NULL DEFAULT 'draft' | draft, active, archived, deleted. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,asset_code); type FK, scoped domain FK. assets exposes UNIQUE (tenant_id,organization_id,asset_id) matching Identity contract.
- Explicit resources allow exact asset grants or explicit workspace project inheritance; org/domain-wide containment grants do NOT open them. Governed resources participate in existing org/domain containment semantics. Ownership labels and search visibility never grant access.
- Workspace projects/artifacts must use explicit mode in v1 and have matching workspace subtype row at commit; catalog-only applications/datasets need no Workspace row. No duplicate title/ownership/location master in Workspace.
- Changing authorization_mode or domain is security-sensitive and audited; require share/governance authority. Organization moves require explicit copy/migration and grant revalidation, not a simple update.

### `cob3_catalog.asset_ownerships`

Accountability and stewardship; not an ACL.

Scope: **org**. Primary key follows Section 3 using `asset_ownership_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_ownership_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_id | uuid | NOT NULL | Scoped asset FK. |
| principal_id | uuid | NULL | Scoped membership. |
| team_id | uuid | NULL | Scoped team. |
| responsibility | varchar(20) | NOT NULL | owner, steward, operator. |
| is_primary | boolean | NOT NULL DEFAULT false | Primary accountable owner. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, revoked. |

Constraints and behavior:

- Exactly one recipient principal/team. Partial unique active recipient+asset+responsibility; at most one active primary owner per asset via partial unique (tenant_id,organization_id,asset_id) WHERE responsibility='owner' AND is_primary AND status='active'.
- Active assets require one primary owner through deferred constraint/service workflow. User-managed workspace assets require a human owner; service/automation can create on behalf of an accountable owner. An owner still needs explicit Identity grants.

### `cob3_catalog.asset_external_identifiers`

Trusted external ID mappings for imported/discovered resources.

Scope: **org**. Primary key follows Section 3 using `asset_external_identifier_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_external_identifier_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_id | uuid | NOT NULL | Scoped asset FK. |
| source_system | varchar(64) | NOT NULL | Registered source name. |
| source_instance | varchar(128) | NOT NULL | Source deployment/account identifier. |
| external_id | varchar(512) | NOT NULL | Stable source-issued resource ID. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,source_system,source_instance,external_id). Source mappings immutable after use except controlled reconciliation. External IDs/URLs are not authorization credentials.

### `cob3_catalog.asset_locations`

Stable links or product routes; not bearer share links.

Scope: **org**. Primary key follows Section 3 using `asset_location_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_location_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_id | uuid | NOT NULL | Scoped asset FK. |
| location_kind | varchar(24) | NOT NULL | app_route, external_url, documentation. |
| uri | text | NOT NULL | Stable validated locator without embedded secrets. |
| is_primary | boolean | NOT NULL DEFAULT false | At most one primary per location kind per asset. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, retired. |

Constraints and behavior:

- Partial UNIQUE (tenant_id,organization_id,asset_id,location_kind) WHERE is_primary AND status='active'. Add UNIQUE (tenant_id,organization_id,asset_id,asset_location_id) for artifact-revision target matching.
- Do not persist presigned object URLs as canonical location. Validate schemes/origins, strip credential fragments, and never fetch arbitrary URLs from privileged backend without network policy. Following external URLs cannot guarantee external system access/revocation.

### `cob3_catalog.asset_relationships`

Typed semantic/lineage links between registered assets.

Scope: **org**. Primary key follows Section 3 using `asset_relationship_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_relationship_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| source_asset_id | uuid | NOT NULL | Scoped asset FK. |
| target_asset_id | uuid | NOT NULL | Scoped asset FK. |
| relationship_type | varchar(32) | NOT NULL | depends_on, derived_from, documents, related_to. |
| evidence_reference | text | NULL | Provenance locator, no secrets. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, retired. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,source_asset_id,target_asset_id,relationship_type); source != target. Both scoped FKs. No automatic ACL inheritance along lineage edges.
- Related_to uses canonical ID ordering if symmetric; other directions meaningful. Do not enforce a universal DAG: actual dependencies can be cyclic. Transitive exposure filters unauthorized nodes/edge endpoints.

### `cob3_catalog.tags`

Shared or personal catalog labels; no authorization effect.

Scope: **org**. Primary key follows Section 3 using `tag_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| tag_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| tag_code | varchar(64) | NOT NULL | Normalized code. |
| name | varchar(100) | NOT NULL | Display label. |
| color | varchar(9) | NULL | Validated hex color. |
| visibility | varchar(16) | NOT NULL DEFAULT 'organization' | organization or private. |
| owner_principal_id | uuid | NULL | Required for private tags; same-org membership. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, archived. |

Constraints and behavior:

- Private requires owner; organization requires NULL owner. Partial unique organization tag_code; private unique (tenant_id,organization_id,owner_principal_id,tag_code). Private tag existence and assignments visible only to owner/authorized support process.
- Tags do not implement security classification; classification with enforcement needs separately typed policy fields.

### `cob3_catalog.asset_tags`

Tag assignments to actual registered assets.

Scope: **org**. Primary key follows Section 3 using `asset_tag_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_tag_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_id | uuid | NOT NULL | Scoped asset FK. |
| tag_id | uuid | NOT NULL | Scoped tag FK. |
| applied_by_principal_id | uuid | NOT NULL | Scoped membership actor. |
| confidence | numeric(5,4) | NULL | Optional 0..1 automated classification confidence. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,asset_id,tag_id). confidence in [0,1] if present. Tag permissions and resource access both required; private tag owner must match acting user unless explicit authority.

### `cob3_catalog.asset_metadata_versions`

Immutable Catalog metadata history; distinct from artifact content versions.

Scope: **org**. Primary key follows Section 3 using `asset_metadata_version_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| asset_metadata_version_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_id | uuid | NOT NULL | Scoped asset FK. |
| version_number | bigint | NOT NULL | Positive monotonically assigned per asset. |
| snapshot | jsonb | NOT NULL | Validated redacted asset metadata object. |
| change_reason | text | NULL | Reason for metadata change. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,asset_id,version_number); >0; append-only. Lock asset to allocate version. Never store workspace content or credentials here.
- Historical metadata reads still use current resource authorization; history is not a back door to deleted/private resources.

### `cob3_workspace.projects`

Personal/team collaborative container, registered as one explicit Catalog asset.

Scope: **org**. Primary key follows Section 3 using `project_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| project_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_id | uuid | NOT NULL | Same-org Catalog asset of type workspace_project. |
| project_kind | varchar(16) | NOT NULL | personal or shared. |
| personal_owner_principal_id | uuid | NULL | Human membership; required only for personal kind. |
| default_automation_principal_id | uuid | NULL | Same-org automation principal, not a credential. |
| icon_code | varchar(64) | NULL | Allowlisted UI icon. |
| color | varchar(9) | NULL | Validated hex color. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,asset_id). Personal requires personal_owner; shared requires NULL. At most one live personal project per principal/org, enforced using Catalog asset lifecycle in serialized project service/deferred trigger.
- Name, description, domain, lifecycle, owner and resource ACL come from Catalog+Identity. Creation inserts asset+project+primary ownership+owner role binding in one transaction. Personal project remains org-bound; a user may have one per org.
- Default automation must be active and authorized at execution; choosing it grants no new capabilities. Display settings live in Settings project scope. Missing settings uses registered defaults.

### `cob3_workspace.folders`

Folder tree for project organization; folders do not introduce independent ACLs in v1.

Scope: **org**. Primary key follows Section 3 using `folder_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| folder_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| project_id | uuid | NOT NULL | Scoped project FK. |
| parent_folder_id | uuid | NULL | Parent within same project. |
| name | varchar(200) | NOT NULL | Nonblank folder name. |
| sort_order | integer | NOT NULL DEFAULT 0 | Stable ordering. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, archived. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,project_id,folder_id) for parent/artifact refs. Compound self-parent FK includes project. Root/sibling normalized name uniqueness uses separate partial unique indexes for NULL/non-NULL parent.
- No self/indirect cycles; serialize project tree edits. Path is computed/cached, not an authoritative stored key. Moving between projects is a controlled operation revalidating child artifacts; no cross-project parent updates.
- Folder browsing requires project permission and filters children by current artifact authorization.

### `cob3_workspace.artifacts`

Workspace content root registered as one Catalog asset; content stored in revisions.

Scope: **org**. Primary key follows Section 3 using `artifact_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| artifact_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| asset_id | uuid | NOT NULL | Same-org saved_artifact Catalog asset. |
| project_id | uuid | NOT NULL | Scoped project FK. |
| folder_id | uuid | NULL | Compound same-project folder FK. |
| artifact_kind | varchar(32) | NOT NULL | dashboard, saved_query, report, document, visualization, notebook, prompt, workflow, external_link. |
| current_revision_id | uuid | NULL | Revision from THIS artifact; nullable only during creation. |
| inherit_project_access | boolean | NOT NULL DEFAULT true | Allow explicit project-artifact inheritance. |
| created_via | varchar(20) | NOT NULL | manual, import, automation. |
| source_thread_asset_id | uuid | NULL | Optional already registered conversation resource, same org. |
| source_run_reference | varchar(255) | NULL | Opaque execution provenance; not a permission key. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,asset_id). Deferred compound FK (tenant_id,organization_id,artifact_id,current_revision_id) -> artifact_revisions. Active artifact requires a current committed revision.
- Catalog asset is explicit mode. Title/description/owner/status never duplicated in Workspace. folder belongs to project via compound FK. Current revision pointer advances only with expected row_version.
- Setting inherit_project_access=false requires explicit asset grants. It blocks project-derived access, not an administrator's separately approved exact asset grant. Changing inheritance/project membership is security-sensitive.

### `cob3_workspace.file_objects`

Private object storage records for artifact uploads and report outputs.

Scope: **org**. Primary key follows Section 3 using `file_object_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| file_object_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| uploaded_by_principal_id | uuid | NOT NULL | Same-org membership. |
| storage_provider | varchar(32) | NOT NULL | Approved driver. |
| storage_container | varchar(255) | NOT NULL | Private bucket/container. |
| object_key | text | NOT NULL | Stable object key. |
| object_version | varchar(255) | NULL | Immutable object version. |
| filename | varchar(255) | NOT NULL | Sanitized file name. |
| mime_type | varchar(128) | NOT NULL | Verified MIME. |
| size_bytes | bigint | NOT NULL | Nonnegative. |
| sha256 | bytea | NOT NULL | 32-byte checksum. |
| status | varchar(20) | NOT NULL DEFAULT 'quarantined' | quarantined, ready, rejected, deleted. |

Constraints and behavior:

- Object bytes immutable; replacements create new objects. Ready only after upload validation and scanning. No public default bucket access or persistent presigned URLs.
- Authorization derives from an authorized referencing revision/report output, not simply same organization or uploader. Do not expose raw file lookup as a permission bypass. Orphan uploads expire through retention job; attachment GC respects all live versions.

### `cob3_workspace.artifact_revisions`

Immutable saved content history; replaces mutable definition plus duplicate revision copies.

Scope: **org**. Primary key follows Section 3 using `artifact_revision_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| artifact_revision_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| artifact_id | uuid | NOT NULL | Scoped artifact FK. |
| revision_number | bigint | NOT NULL | Positive sequence per artifact. |
| content_kind | varchar(16) | NOT NULL | inline, file, external. |
| definition | jsonb | NULL | Validated artifact-kind document for inline content. |
| file_object_id | uuid | NULL | Ready same-org file. |
| external_location_id | uuid | NULL | Catalog asset location for this artifact asset. |
| definition_schema_version | integer | NOT NULL | Positive payload schema version. |
| content_sha256 | bytea | NOT NULL | 32-byte canonical-content checksum. |
| change_note | text | NULL | Revision explanation. |
| author_principal_id | uuid | NOT NULL | Actual human/service/automation author membership. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,artifact_id,revision_number); UNIQUE (tenant_id,organization_id,artifact_id,artifact_revision_id). revision/schema >0.
- Exactly one content branch: inline -> definition only; file -> file only; external -> location only. Trigger verifies external_location.asset_id = artifacts.asset_id. Scoped FKs on every reference.
- Append-only; creation locks artifact and advances head with expected row_version. Definition validator forbids embedded secrets/unchecked executable code. Saved SQL/prompts are inert content until an authorized execution service validates their capability.

### `cob3_workspace.artifact_drafts`

Per-principal autosave state, separate from committed revisions.

Scope: **org**. Primary key follows Section 3 using `artifact_draft_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| artifact_draft_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| artifact_id | uuid | NOT NULL | Scoped artifact FK. |
| principal_id | uuid | NOT NULL | Same-org owner membership. |
| base_revision_id | uuid | NULL | Compound same-artifact revision FK. |
| draft_definition | jsonb | NOT NULL | Validated bounded draft object. |
| expires_at | timestamptz | NOT NULL | Autosave retention deadline. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,artifact_id,principal_id). Draft reads/writes require current artifact edit permission and owner; never globally visible through project membership.
- Commit requires base matches expected head or explicit conflict resolution; do not silently overwrite others. Retain per-user UI draft expiry; no autosave credentials.

### `cob3_workspace.bookmarks`

Personal saved pointers; bookmark is not a resource access grant.

Scope: **org**. Primary key follows Section 3 using `bookmark_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| bookmark_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_id | uuid | NOT NULL | Human membership owner. |
| target_asset_id | uuid | NULL | Scoped actual Catalog asset. |
| external_url | text | NULL | External nonsecret HTTPS URL. |
| label | varchar(255) | NULL | User label. |
| position | integer | NOT NULL DEFAULT 0 | Ordering. |

Constraints and behavior:

- Exactly one target_asset_id/external_url. Partial UNIQUE (tenant_id,organization_id,principal_id,target_asset_id) when asset set. External URL optional duplication; do not enforce index on arbitrarily long URL.
- Check current access before rendering asset title/preview/open; revoked resource shows generic unavailable. Validate URL scheme; bookmark storage does not authorize server fetching.

### `cob3_workspace.recent_items`

Personal recent resource activity, not a resource master.

Scope: **org**. Primary key follows Section 3 using `recent_item_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| recent_item_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_id | uuid | NOT NULL | Human membership owner. |
| target_asset_id | uuid | NOT NULL | Scoped Catalog resource. |
| last_route | varchar(512) | NULL | Sanitized internal route without query secrets. |
| first_visited_at | timestamptz | NOT NULL | First visit. |
| last_visited_at | timestamptz | NOT NULL | Latest visit. |
| visit_count | bigint | NOT NULL DEFAULT 1 | Positive count. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,principal_id,target_asset_id); last>=first; count>0. Do not duplicate target title as public cache. Filter by current resource authorization; prune by configured retention.

### `cob3_workspace.ui_sessions`

Short-lived browser/app state; distinct from Identity authentication session.

Scope: **org**. Primary key follows Section 3 using `ui_session_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| ui_session_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_id | uuid | NOT NULL | Human membership. |
| auth_session_id | uuid | NOT NULL | Tenant Identity auth_session with same principal. |
| client_instance_id | uuid | NOT NULL | Browser/app instance ID. |
| app_version | varchar(64) | NULL | Client version. |
| started_at | timestamptz | NOT NULL | Start. |
| last_seen_at | timestamptz | NOT NULL | Activity. |
| ended_at | timestamptz | NULL | End. |
| expires_at | timestamptz | NOT NULL | TTL. |
| state | jsonb | NOT NULL DEFAULT '{}'::jsonb | Bounded route/panel/filter state; no auth secrets. |
| device_context | jsonb | NOT NULL DEFAULT '{}'::jsonb | Minimal device metadata; no fingerprinting by default. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,principal_id,client_instance_id). Validate Identity session human principal and active org membership; UI state grants no session authority. last>=start, expiry>start, end>=start if set.
- New organization context creates separate UI state. Read state only as owner; every restored resource is reauthorized. Tabs may share client instance only intentionally; avoid accidental last-writer wins using row_version.

### `cob3_workspace.interaction_journeys`

Optional grouped UI workflow analytics, replacing ambiguous trajectory semantics.

Scope: **org**. Primary key follows Section 3 using `interaction_journey_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| interaction_journey_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_id | uuid | NOT NULL | Human membership. |
| ui_session_id | uuid | NOT NULL | Same-user/org UI session. |
| journey_type | varchar(64) | NOT NULL | Product-supported workflow name. |
| started_at | timestamptz | NOT NULL | Start. |
| ended_at | timestamptz | NULL | End. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, completed, abandoned. |

Constraints and behavior:

- Scoped session FK plus principal-match validation; end>=start. Any learning-container relationships must be actual resource IDs in separate typed extension when that domain is defined, not an unexplained UUID array.

### `cob3_workspace.interaction_events`

UI telemetry; distinct from billable Tenant usage_events and security audit.

Scope: **org**. Primary key follows Section 3 using `interaction_event_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| interaction_event_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_id | uuid | NOT NULL | Human membership. |
| ui_session_id | uuid | NOT NULL | Matching user session. |
| interaction_journey_id | uuid | NULL | Matching same-session journey. |
| client_event_id | uuid | NOT NULL | Retry-safe client event ID. |
| event_name | varchar(64) | NOT NULL | Allowlisted analytics event. |
| feature_code | varchar(128) | NULL | Product feature label, not billing authority. |
| target_asset_id | uuid | NULL | Optional authorized resource. |
| occurred_at | timestamptz | NOT NULL | Client event time, validated clock bounds. |
| received_at | timestamptz | NOT NULL DEFAULT now() | Server ingestion time. |
| active_seconds | integer | NOT NULL DEFAULT 0 | Bounded nonnegative activity increment. |
| properties | jsonb | NOT NULL DEFAULT '{}'::jsonb | Allowlisted redacted properties. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,ui_session_id,client_event_id). Composite refs and triggers bind user/session/journey. Client cannot attribute to another principal.
- Append-only; quota/billing never trusts client telemetry. Separate deduplication design needed before time partitioning. Bound retention/sampling; avoid prompts, SQL bodies, secrets or raw URL parameters in properties.

### `cob3_workspace.interaction_daily`

Rebuildable daily UI usage projection.

Scope: **org**. Primary key follows Section 3 using `interaction_daily_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| interaction_daily_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| principal_id | uuid | NOT NULL | Human owner. |
| day | date | NOT NULL | UTC aggregation day. |
| feature_code | varchar(128) | NOT NULL | Product feature label. |
| event_count | bigint | NOT NULL DEFAULT 0 | Nonnegative deduplicated count. |
| active_seconds | bigint | NOT NULL DEFAULT 0 | Nonnegative bounded aggregated activity. |
| computed_at | timestamptz | NOT NULL | Projection time. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,principal_id,day,feature_code). Rebuild from deduplicated interaction_events; specify activity overlap handling across tabs. Not authoritative billable usage or actual employee productivity measurement.

### `cob3_workspace.report_schedules`

Scheduled generation authorized by a specific principal and restricted execution credential.

Scope: **org**. Primary key follows Section 3 using `report_schedule_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| report_schedule_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| artifact_id | uuid | NOT NULL | Report/query/dashboard artifact. |
| revision_policy | varchar(16) | NOT NULL | pinned, latest. |
| pinned_revision_id | uuid | NULL | Required for pinned; same artifact. |
| execution_principal_id | uuid | NOT NULL | Active human/service/automation membership. |
| credential_id | uuid | NOT NULL | Identity credential/grant envelope; no stored secret here. |
| cron_expression | varchar(128) | NOT NULL | Validated scheduler grammar. |
| timezone | varchar(64) | NOT NULL | Valid IANA timezone. |
| output_format | varchar(16) | NOT NULL | pdf, csv, xlsx, json. |
| status | varchar(20) | NOT NULL DEFAULT 'paused' | active, paused, retired. |
| next_run_at | timestamptz | NULL | Derived next execution time. |
| misfire_policy | varchar(16) | NOT NULL DEFAULT 'skip' | skip, catch_up_once. |
| overlap_policy | varchar(16) | NOT NULL DEFAULT 'skip' | skip, queue. |

Constraints and behavior:

- Pinned iff pinned_revision set; same-artifact FK. Credential principal/org must equal execution principal/org. Worker obtains trusted execution context, never a token from this table.
- Reauthorize schedule, revision, datasource assets, principal/grant/credential and recipient policy every run; expired credentials pause execution. Delegated automation subject to grant intersection and approvals. Latest policy resolves to an immutable revision at start of each run.
- Timezone/DST behavior explicit: at most once per scheduled instant, skip nonexistent local time; repeated local-time handling set by scheduler and stored scheduled_for UTC. No unlimited catch-up flood.

### `cob3_workspace.report_recipients`

Explicit distribution destinations; no arbitrary recipient email array.

Scope: **org**. Primary key follows Section 3 using `report_recipient_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| report_recipient_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| report_schedule_id | uuid | NOT NULL | Scoped schedule. |
| recipient_principal_id | uuid | NULL | Internal recipient membership. |
| notification_endpoint_id | uuid | NULL | Verified email/webhook endpoint. |
| delivery_mode | varchar(16) | NOT NULL DEFAULT 'link' | link; external attachment distribution deferred. |
| status | varchar(20) | NOT NULL DEFAULT 'active' | active, revoked. |

Constraints and behavior:

- Require internal recipient in v1; optional endpoint must belong to recipient or explicitly approved same-org contact with per-recipient access mechanism. Prefer principal-owned verified endpoint; shared mailboxes cannot impersonate a principal.
- UNIQUE active (tenant_id,organization_id,report_schedule_id,recipient_principal_id). Recipient must currently have artifact and underlying data access compatible with report result. Link opens authenticated endpoint; no bearer URL bypass.
- External-only recipients/attachments require a separately designed egress approval and disclosure model; reject them in v1 rather than assuming verified email authorizes data release.

### `cob3_workspace.report_runs`

Idempotent execution record with resolved input revision and private output.

Scope: **org**. Primary key follows Section 3 using `report_run_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| report_run_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| report_schedule_id | uuid | NOT NULL | Scoped schedule. |
| artifact_revision_id | uuid | NOT NULL | Resolved same-artifact revision. |
| scheduled_for | timestamptz | NOT NULL | Original UTC schedule instant. |
| status | varchar(20) | NOT NULL DEFAULT 'queued' | queued, running, succeeded, failed, canceled. |
| started_at | timestamptz | NULL | Start. |
| completed_at | timestamptz | NULL | End. |
| lease_expires_at | timestamptz | NULL | Worker lease. |
| attempt_count | integer | NOT NULL DEFAULT 0 | Nonnegative retries on same run. |
| output_file_id | uuid | NULL | Ready private object; success requires output. |
| row_count | bigint | NULL | Nonnegative result rows. |
| error_code | varchar(64) | NULL | Redacted error code. |
| correlation_id | varchar(128) | NOT NULL | Execution trace reference. |
| data_access_manifest | jsonb | NOT NULL | Validated source assets, policy/filter fingerprints and output classification; bound to resolved revision/output checksum. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,report_schedule_id,scheduled_for). Match revision's artifact to schedule. Lease/conditional state transitions prevent concurrent workers; remote effects use idempotency keys.
- Output reads recheck authorization. Success requires completed_at/output; failures have completed_at/error code. Do not store sensitive stack traces/query text here. Retry uses same resolved revision or explicit new manual run contract.

### `cob3_workspace.report_deliveries`

Per-recipient delivery/retry status without regeneration of report.

Scope: **org**. Primary key follows Section 3 using `report_delivery_id`.

| Column | PostgreSQL type | Nullability/default | Purpose |
|---|---|---|---|
| report_delivery_id | uuid | NOT NULL DEFAULT gen_random_uuid() | Entity identifier. |
| tenant_id | uuid | NULL only for platform scope; otherwise NOT NULL | Tenant FK, except platform definition tables. |
| organization_id | uuid | See scope below | Composite Identity organization FK when non-NULL. |
| created_at | timestamptz | NOT NULL DEFAULT now() | Immutable creation time. |
| created_by | varchar(255) | NOT NULL | Trusted stable actor identifier. |
| updated_at | timestamptz | NOT NULL DEFAULT now() | Mutation-trigger timestamp. |
| updated_by | varchar(255) | NOT NULL | Trusted last-modifying actor. |
| metadata | jsonb | NOT NULL DEFAULT '{}'::jsonb | JSON object; no secrets/security decisions. |
| row_version | bigint | NOT NULL DEFAULT 1; > 0 | Optimistic concurrency. |
| report_run_id | uuid | NOT NULL | Scoped completed run. |
| report_recipient_id | uuid | NOT NULL | Recipient on same schedule. |
| status | varchar(20) | NOT NULL DEFAULT 'pending' | pending, sent, failed, skipped. |
| attempt_count | integer | NOT NULL DEFAULT 0 | Nonnegative. |
| delivered_at | timestamptz | NULL | Successful provider acceptance, not proof of reading. |
| provider_message_reference | varchar(255) | NULL | Delivery idempotency/reconciliation reference. |
| last_error_code | varchar(64) | NULL | Redacted failure code. |

Constraints and behavior:

- UNIQUE (tenant_id,organization_id,report_run_id,report_recipient_id). Validate run and recipient share schedule; recipient active; verify current recipient access/endpoint at send time.
- Link points to authenticated report route. Mark sent only with provider result; use provider idempotency/reconciliation where supported, and document ambiguous send outcomes rather than promising exactly-once email.

## 6. Required amendments to the existing Identity design

These amendments are mandatory for the new cross-schema behavior. They are changes to the proposal, not claims that the current database already supports them.

### 6.1 Profiles and email migration

Add `avatar_media_id uuid NULL` to user_profiles with tenant-qualified FK to Settings.media_objects and validation that its scope is principal, belongs to this profile principal, and status=ready. Maintain the same validation when media ownership/state changes; ownership is immutable and deletion must clear/reassign references through a controlled operation.

Move authoritative contact-email state from user_profiles.email/email_verified_at to principal_emails. During transition, expose the old fields as a compatibility read projection of the primary active address; do not permit two independently writable masters. Move avatar_uri to a compatibility API-generated URL for avatar_media_id. Existing external avatar URIs require review/import before conversion; do not blindly fetch private-network URLs. User profile given/family name and job title remain in Identity.

Email verification is proof of control under a declared verification source. Changing email never changes the trusted SSO subject automatically. No local password/MFA recovery system is introduced by adding contact verification challenges.

### 6.2 Complete the Catalog foreign keys

Install and validate scoped FKs from:

- Identity.team_domains -> Catalog.domains `(tenant_id,organization_id,domain_id)`.
- Identity.access_scopes.domain_id -> Catalog.domains with full scope key.
- Identity.access_scopes.asset_id -> Catalog.assets with full scope key.

Only after existing references are reconciled and FKs validate may the previous fail-closed Catalog guards be replaced with the real resource resolver. Catalog must not create a second organization, team or role master.

### 6.3 Explicit versus governed resource access

The earlier Identity design lets broad organization/domain scopes include contained assets. That is appropriate for governed enterprise resources, but unsafe for private workspace content unless explicitly limited.

Add the runtime gate:

- `assets.authorization_mode = 'governed'`: existing organization/domain containment rules may apply, with normal permission matching.
- `assets.authorization_mode = 'explicit'`: only exact asset grants or the explicit project-to-artifact inheritance described below apply. Organization/domain-wide data grants do not open the asset merely because it belongs to that organization/domain.

All Workspace project and artifact assets are explicit in v1. Classification does not grant access by itself. Tenant administrators are not automatically readers of private content. An approved support/break-glass route, if needed, requires separately designed explicit grant, expiry and audit; PostgreSQL superuser access is outside application privacy guarantees.

### 6.4 Add explicit project inheritance to access_scopes

Add `include_workspace_artifacts boolean NOT NULL DEFAULT false` to Identity.access_scopes.

Rules:

1. True is valid only when scope_type=asset and the asset is a registered Workspace project.
2. Keep include_contained_assets=false for all asset scopes, preserving its existing domain/organization meaning.
3. Replace the existing asset-scope unique index with `(tenant_id,organization_id,asset_id,include_workspace_artifacts)` WHERE scope_type='asset'. This permits a project-only and a project-plus-artifacts scope without ambiguity.
4. Scope content remains immutable. Existing scopes receive false and retain their current semantics; do not silently upgrade old grants.
5. A project scope with this flag covers the project itself plus artifacts whose project_id matches AND inherit_project_access=true. Folder nesting has no additional ACL semantics.
6. It never covers underlying data-source assets referenced by a query/report, unrelated Catalog relationships, artifacts in another project, or artifacts opting out of project inheritance.
7. The same resource-matching function is used for roles, grantor RBAC, grantee RBAC, approved grant scope and credential subset. Adding inheritance only in the UI or role checker would create privilege inconsistencies.
8. A grant to a project plus future inheriting artifacts is a dynamic resource set, just like a domain-contained-assets grant. Use exact artifact scopes to approve a fixed resource set.

For project folder operations, the requested permission is evaluated on the project resource. Folder ID is validated to that project; it is not an independent securable target in v1.

### 6.5 Team access to workspace resources

The original asset-team binding rule requires team responsibility for the asset's domain. A personal/shared Workspace resource may have no business domain.

Amend that rule narrowly: an exact explicit Workspace project/artifact binding may target an active team in the same organization when a human/authorized provisioning actor with share authority creates it. It does not require team_domains. All other governed/domain-based team grants preserve the original responsibility checks. No cross-organization team sharing is introduced.

Do not retain Workspace.project_member.role as a second permission engine. Expose project members as an authorized view of Identity role_bindings targeting the project scope plus effective team memberships. A UI can label roles Owner/Editor/Viewer, but their actual permission bundles live in Identity.roles and role_permissions. Catalog asset_ownerships records accountability only.

## 7. Settings resolver and precedence

### 7.1 Supported categories

| Category | Example keys/records | Ownership |
|---|---|---|
| Theme/accessibility | ui.theme, ui.density, ui.font_scale, ui.reduce_motion, ui.high_contrast | Generic typed preference |
| Locale | locale.language, locale.timezone, locale.date_format, locale.number_format | Generic typed preference |
| Navigation | navigation.home_asset_id, navigation.pinned_routes, navigation.sidebar_order | Preference only; referenced assets validated and reauthorized |
| Data display | display.page_size, display.default_time_range, display.chart_palette | Bounded product-supported preference |
| Profile | names, verified emails, avatar selection | Identity plus Settings media reference |
| Brand | logo, favicon, allowed theme tokens, support links | branding_profiles |
| Notifications | category/channel enabled, digest, quiet hours, verified endpoint | Dedicated preference/endpoint tables |
| Workspaces | editor defaults, project display layout, default save format | Project/person scoped typed preferences |
| Integrations | SSO/mail/webhook validated config; secret reference | integration_configurations |
| Automation | lifetime bounds, execution allowance, approval/external-delivery policy | automation_policies |

“All settings” means an extensible registered model; it does not mean arbitrary free-form keys, arbitrary executable code or every future product feature implemented now. Product-specific keys may be added by validated release migrations without making new wide tables for every toggle.

### 7.2 Resolution algorithm

For a normal preference key, apply only scopes allowed by its active definition:

1. Product definition default.
2. Explicit tenant value.
3. Explicit current organization value.
4. Explicit selected team value, if this operation actually has a team context.
5. Principal-wide preference, if user_overridable.
6. Principal-in-current-organization preference, if user_overridable.
7. Project value only for keys whose definition explicitly permits project scope and whose semantics are project-local (e.g. editor default format).

This is replacement per key, not arbitrary deep JSON merge. A missing row inherits; a reset deletes the override. Arrays replace as a whole unless a future definition explicitly implements another strategy. The resolver returns value, definition version, winning scope and lock provenance for troubleshooting.

Do not merge every team a user belongs to. If there is no selected team, skip team scope. If a project UI selects a team context, validate current membership and use that one. There is no random “last team wins” behavior. Personal and org preferences do not change how a project-level policy authorizes an operation.

Tenant/org locks on lockable keys stop lower levels, including principal/project, from overriding. Only authorized administrators may create/remove such locks. Parent locks remain binding even if a lower record already exists; the lower record is ignored and explained in the effective-value response.

Notification preferences use the same eligible-scope precedence for their category/channel, but mandatory security notifications follow explicit policy, not an unchecked enabled flag. Generic settings definitions cannot duplicate dedicated notification preference keys.

Automation policy uses restrictive composition, not last-writer precedence: allow flags AND, maximum durations MIN, approval requirements OR. Tenant purchased feature entitlement is an independent ceiling. No policy table may unlock a feature the tenant does not own or grant a permission the principal lacks.

Cache keys include tenant, current organization, principal, explicit team/project context and settings/policy revision. Changes invalidate effective values. Authorization-sensitive policy checks need a defined revocation bound; ordinary UI theme caching is not an adequate security-policy strategy.

## 8. Media, resource URLs and artifact content

### 8.1 Avatars/logos

Upload to private quarantine -> verify actual content/MIME/size -> scan/re-encode -> mark ready -> atomically set approved avatar/logo reference. Generate short-lived URLs only after checking allowed profile/brand visibility; do not place permanent public URLs in profile tables by default. Removing a profile reference does not immediately delete bytes still used by another legitimate current reference; run reference-aware garbage collection.

Principal avatars are tenant-level identity media. Organization/team logos are owned by their Settings scopes. Uploading someone else's picture or selecting another scope's private media requires an explicit administrative workflow; a valid UUID is not enough.

### 8.2 Catalog and Workspace describe the same resource at different levels

A saved dashboard has:

- One Catalog asset row: stable asset_id, title, description, type, domain, access classification and lifecycle.
- One Workspace artifacts row: artifact_id, project/folder association, current revision, content kind metadata and provenance.
- Many immutable artifact_revisions: actual dashboard/query/document content.
- Optional file_objects for binary content.
- Identity role bindings for actual access.

A project also has one Catalog asset and one Workspace projects row. Folders are organizational objects within a project, not independent Catalog assets in v1. New independent folder ACLs would require an explicit extension, not a hidden visibility flag.

Metadata version numbers and artifact revision numbers track different streams. Editing a Catalog description does not generate a new dashboard content revision; saving the dashboard content does not overwrite metadata history.

### 8.3 Stable URLs

Use stable authenticated routes such as `/organizations/{org}/assets/{asset_id}` for application resources. Resolve a requested content revision only after current authorization. Object keys remain private server-side locators; presigned URL expiry is shorter than the access-revocation expectation and content-download checks are still enforced at issuance. A URL never substitutes for an ACL.

External links can point outside the product; COP3 cannot revoke access already provided by that external site. No public anonymous share links are added in v1. If required later, use a separate hashed, scoped, expiring share-token model with an explicit disclosure workflow.

## 9. Saved reports and automation

A report schedule is an unattended job with an explicit execution principal, credential/grant and an input revision policy. Storing default_automation_principal_id or selecting an execution account grants no permissions.

At execution:

1. Validate tenant/organization, purchased capabilities, account and membership lifetimes.
2. Validate credential, grantor/grantee and exact requested artifact/datasource operations.
3. Resolve pinned/latest artifact revision and preserve its ID in the run.
4. Validate required action approval for sensitive operations; report delivery is a data disclosure decision, not merely a cosmetic notification preference.
5. Execute using a trusted bounded context and record output as a private file.
6. Validate each recipient independently before delivery and again when opening the output link.
7. Require access to the actual underlying data represented, not only access to the report definition. If row-level filters/clearances differ or cannot be proven compatible, deny reuse of that output and generate a recipient-specific authorized result through a separate execution; never share the executor's broader result with a narrower reader.

Add `data_access_manifest jsonb NOT NULL` to report_runs in implementation: a validated object listing source asset IDs, data-policy versions/filter fingerprints and output classification, without secrets/raw data. Bind it to output checksum and resolved revision. Access checks compare current recipient eligibility against the manifest and applied filtering; a matching asset list alone does not prove row-level equivalence. Source services must provide the validation contract; if missing, fail closed for distribution of data-bearing results.

In v1, deliver authenticated internal links. External-only recipients and attachments remain disabled until an egress/disclosure model is designed. Email verification proves destination control, not authorization to receive private data. Current report_recipients supports internal principals and their verified endpoints; shared mailboxes require explicit group-safe disclosure mechanics, not principal impersonation.

Report generation, provider acceptance and user download have separate audit events. Sent email cannot be recalled by revoking a database row; avoid attachments where continuing revocation is needed.

## 10. Initial Identity permission additions

These codes are proposed product-supported operations; register them in the existing Identity permission system. An entry alone does not implement an endpoint. All roles use explicit permission bundles, not wildcard strings.

| Permission code | Scope/resource | Automation execution |
|---|---|---|
| profile.read_self / profile.update_self | Principal self operations | No human impersonation; approved profile provisioning separate |
| profile.manage_directory | Organization directory with explicit target checks | No |
| settings.read / settings.update_self | Approved settings scope ownership | No for human-only settings |
| settings.manage_organization / settings.manage_team | Organization/team scope | Only dedicated authorized provisioning |
| settings.manage_policy / settings.manage_integrations | Restricted administration | No automation |
| catalog.read / catalog.manage | Domain or exact Catalog resource | Read as granted; metadata writes require explicit capability |
| asset.share | Exact asset/project | No automation in v1; sharing is IAM-related |
| project.read / project.update | workspace_project asset | As explicitly delegated |
| project.create | Organization operation | As delegated, with approved ownership/grant provisioning service |
| artifact.read / artifact.create / artifact.update | saved_artifact or authorized parent project creation operation | As explicitly delegated |
| artifact.execute | Artifact plus each source asset | As delegated with approval if required |
| report.schedule / report.run | Artifact | As delegated |
| report.deliver | Report output and approved recipient context | As delegated and policy permits |
| workspace.manage_reports | Project/org administrative operation, target-scoped | Approved provisioning only |

Extend the existing access resolver for self/team/project resource targets deliberately; do not shoehorn personal tenant-scope profile updates into an organization asset grant with a fabricated ID. Self-service profile/settings routes require authenticated principal equality and approved field allowlist; administrative routes require specific authority. These self-service permissions can be enforced as fixed authenticated self-service capabilities initially or through an explicit Identity self-scope extension, but the deployment must choose and document one. This proposal chooses fixed authenticated self-service capabilities with field-level guards; they do not allow noninteractive automation to act as a human.

Creation of an artifact by an automation cannot grant new rights to arbitrary recipients. A trusted server workflow attaches already-authorized project inheritance and approved accountable ownership atomically; explicit new sharing requires authorized human/provisioning action. A tenant administrator does not automatically gain grantor rights over private content.

Suggested Workspace roles stored in Identity:

| Role | Permission bundle |
|---|---|
| workspace_viewer | project.read, artifact.read |
| workspace_editor | project.read, project.update, artifact.read, artifact.create, artifact.update |
| workspace_owner | Editor bundle plus asset.share, report.schedule; explicit audit/ownership duties |
| report_operator | artifact.read, artifact.execute, report.run, report.deliver |

Context match matters: project roles with include_workspace_artifacts=true cover only inheriting artifacts, and artifact.execute still independently checks every datasource. Organization membership alone does not make a user a project viewer.

## 11. Screenshot-to-new-model mapping

| Existing visible object/field | Proposed mapping |
|---|---|
| obs3_settings.org_customization | setting_scopes + setting_values; role_navigation is presentation-only |
| org_appearance.custom_theme | branding_profiles.theme_tokens with validator |
| org_appearance.custom_logo | branding_profiles -> media_objects |
| user_customization/customization | Registered setting_values at principal/principal_org scope |
| user_preferences/preferences | Registered settings and dedicated notification_preferences |
| tenant_id used as organization key | Preserve tenant, add real organization FK from reviewed mapping |
| project | projects + Catalog assets + asset_ownerships |
| project.owner_user_id | Catalog primary accountable ownership principal; explicit Identity role grants |
| project_member.principal_type/id/role | Identity role_bindings and effective membership view; principal/team XOR |
| project.visibility / team_id | Explicit Identity recipient grants; no parallel visibility-based access |
| project.settings | Migrate registered project setting keys; quarantine unknown keys |
| folder.path | Derive from folder tree; no independently writable canonical path |
| saved_artifact | artifacts + Catalog assets |
| saved_artifact.definition/version | artifact_revisions + current_revision_id |
| saved_artifact.visibility | Explicit Identity asset grants and inherit_project_access flag |
| saved_artifact.is_default | Principal/project registered default-artifact setting, not universal artifact flag |
| saved_artifact.dataset_group | Catalog source asset relationship or validated product attribute; not an ACL |
| saved_artifact_revision.changed_by/_type | author_principal_id plus stable common audit actor; resolve legacy type |
| source_thread_id/source_run_id | Registered source_thread_asset_id where available; opaque run provenance otherwise |
| report_schedule.recipients JSON | report_recipients + verified notification endpoints |
| report_run.output_uri | file_objects reference and authenticated download route |
| bookmark.target_type/target_id | Real Catalog asset FK or explicit external URL branch |
| recent_item.route/target_type/target_id | Asset FK plus sanitized route hint |
| ui_session | ui_sessions linked to Identity auth session; no auth token storage |
| trajectory | interaction_journeys; define any learning-specific entities separately |
| usage_event / usage_daily | interaction_events / interaction_daily; not billable usage |
| tag / tag_link | Catalog tags + asset_tags with scoped FKs |

Do not drop old tables immediately. Build migration ID maps and compatibility reads, validate user/team/org assignment and reconcile grants before switching writers.

## 12. Migration sequence and validation

1. Export current PostgreSQL DDL/constraints and row counts; screenshots do not prove deployed schema details. Resolve actual schema prefix and backup strategy.
2. Confirm Tenant/Identity installation version. Treat this proposal as additive versioned migrations; never recreate live foundations destructively.
3. Create platform setting/type registries and Catalog domains/assets. Create Settings scope/media tables, then dependent profile references; add deferred FKs after all referenced tables exist.
4. Create Workspace tables and add cyclic artifact-head/revision and project-scope FKs in dependency-safe order. Create project + asset + owner + explicit role binding atomically.
5. Add Identity email tables and profile media reference. Backfill email verification only from genuine evidence; legacy non-NULL email does not prove verification. Build compatibility views/API projections.
6. Map legacy tenant-only org settings: when a tenant has one verified organization, copy to that org explicitly; when multiple exist, retain as tenant default pending reviewed mapping. Never arbitrarily choose an organization.
7. Register Catalog asset IDs for legacy projects/artifacts and import one consistent revision history. Quarantine invalid/missing links. Map legacy user IDs to principals; unknown identity records fail closed.
8. Convert project membership/visibility to explicit Identity bindings. Migrate private resources as explicit; do not expose them through new broad org/domain grants. Existing organization-public visibility requires a reviewed sharing design; do not silently convert to public access.
9. Add access_scopes.include_workspace_artifacts and resolver rules, verify old scopes remain false. Install real Catalog FKs and replace old fail-closed guards only after full validation.
10. Validate Settings inheritance, locks, private UI state, notification endpoints and report data-access controls. Run comparison queries and controlled cutover before deprecating old writes.
11. Introduce optional telemetry last, with retention/consent policy appropriate to deployment. Do not block core settings/catalog/artifact delivery on a comprehensive analytics system.

Required tests:

- Cross-tenant/org domain, project, folder, revision, endpoint and media references rejected.
- NULL-org settings scope cannot reference another org's record or bypass a required FK.
- User cannot choose another user's email/avatar, draft or notification endpoint.
- Multiple organization settings coexist without tenant-only uniqueness collisions.
- Team preference resolution deterministic; no union of all memberships.
- Parent lock and restrictive automation policy cannot be weakened by user/project override.
- Private Workspace resources remain inaccessible through broad domain/org grants.
- Project scope inheritance, artifact opt-out and exact asset grants use the same resolver across roles/grants/credentials.
- Team workspace sharing works without inventing a domain responsibility, while original governed-domain guards still apply.
- Catalog ownership labels and navigation visibility never grant access.
- Concurrent revision creation yields unique sequence and rejects stale-head overwrite.
- Folder cycles/cross-project references rejected; moves revalidate access.
- Signed URLs are not persisted as canonical locations; revoked asset cannot issue new download URLs.
- Quarantined media/file cannot be selected or served.
- Schedule/run/recipient links stay in same project/artifact/org; expired principal/grant/credential blocks run.
- A report viewer with narrower source data rights cannot download a broader output; missing data-policy contract denies distribution.
- UI telemetry retries deduplicate and never become authoritative billing events.
- Search, recents, bookmarks, tags and history filter current permissions before exposing titles/previews.
- Runtime RLS tests execute under actual nonowner role; no owner/superuser shortcut.

## 13. Index and retention guidance

In addition to PK/unique indexes, index scoped FK lookup prefixes. Useful access paths include assets(tenant_id,organization_id,domain_id,status), assets(tenant_id,organization_id,asset_type_id,status), setting_scopes(tenant_id,principal_id), setting_values(tenant_id,setting_scope_id), folders(tenant_id,organization_id,project_id,parent_folder_id), artifacts(tenant_id,organization_id,project_id), revisions(tenant_id,organization_id,artifact_id,revision_number DESC), recent_items(tenant_id,organization_id,principal_id,last_visited_at DESC), report_schedules(status,next_run_at) for restricted workers, report_runs(tenant_id,organization_id,report_schedule_id,scheduled_for DESC), and interaction_events(tenant_id,organization_id,principal_id,occurred_at).

Never create duplicate indexes already covered by existing leading columns. Batch authorization checks for list/search endpoints; filter before returning counts/snippets. RLS is a database isolation layer, not a replacement for the resource/delegation resolver.

Apply TTL to UI sessions, abandoned drafts, verification challenges and telemetry. Retain committed content versions under explicit organization retention policy. Before deleting object bytes, check all current profile/branding/revision/report references; a deleted latest artifact cannot leave historical downloadable content exposed. Tenant commercial retention is independent from UI analytics retention.

Cache effective preferences separately from access decisions. Search indexes/OpenSearch store a projection, not final authorization truth: constrain tenant/org at query time and reauthorize resources before returning sensitive titles/content or downloads. Do not use LLM instructions as the enforcement mechanism.

## 14. Implementation boundary and deliverable status

This document adds **11 Settings tables, 10 Catalog tables, 16 Workspace tables and 2 Identity extension tables**. It also specifies amendments to existing user_profiles, access_scopes and authorization behavior. The original Tenant and Identity files are preserved; neither a migration nor runtime application code has been executed.

Initial core: validated settings/scopes, media/profile links, verified contacts, domains/assets/ownership, projects/folders/artifacts/revisions, explicit sharing and current-authorization checks. Optional next layers: notification delivery adapters, versioned integration configuration, report scheduling/delivery and interaction telemetry. All listed tables are specified to make the long-term boundary clear; shipping every adapter is not a prerequisite for a secure core.

Existing missing domains/assets can now be implemented from this contract. General-purpose ingestion connectors, a full workflow runtime, chat-message storage, full column-level lineage, row-level data-policy engines, anonymous public sharing and cross-organization collaboration remain separate modules. Their resource IDs can be registered in Catalog without putting their entire operational data in Catalog.

Static validation checks table/column uniqueness, required common fields and internal reference target names. SQL installation, migrations, RLS policies, concurrent tests and integrations remain implementation work. No claims are made about screenshot-only deployed constraints or production readiness.

## 15. References

Design inputs: COP3_Identity_Consolidated_Schema_v1.md, COB3_Tenant_Schema_Summary_v1.md and the two supplied ERD screenshots. These proposals are not vendor-prescribed database schemas.

- PostgreSQL constraints and composite keys: https://www.postgresql.org/docs/current/ddl-constraints.html
- PostgreSQL row security and bypass behavior: https://www.postgresql.org/docs/current/ddl-rowsecurity.html
