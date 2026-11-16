# Syskriti COB3 — AI and Agent State Design

Version 1.0 • 16 November 2026

**Status: proposed architecture and column dictionary. Not executable SQL, a deployed migration, or a verified reconstruction of the live database.** The attached eight ERDs establish the current conceptual structure; a PostgreSQL schema-only export is still needed to generate a safe migration. This document extends the previously designed Tenant, Identity, Settings, Catalog and Workspace foundation. Incident management, operational logs, alert delivery and Ops workflows remain outside this design.

## 1. Architecture decisions

Use `cob3_*` consistently, following the latest foundation design. Map existing `obs3_*`, `cop3_*` and `llmobs_meta` names in a coordinated migration; do not create duplicate masters.

An **agent definition** describes behavior. A **principal** is an identity. A **credential** authenticates that identity. A **run** executes a pinned agent revision under bounded authority. These are separate entities.

- Principal types remain human, service_account and automation. A token is a credential, never a fourth principal type.
- A human can invoke an assistant under their human identity. A scheduled assistant can execute as an automation delegated by a human/service account. An integration can execute directly as a service account. They can all use the same agent definition.
- The authenticated initiator, execution principal, delegation grantor, infrastructure worker, resource owner and original creator are recorded separately. No email/name substitutes for an identity FK.
- An agent spawning a subtask does not create a new automation principal. Child runs inherit the parent's bounded execution context. Creating a distinct automation remains an authorized human/service provisioning operation; recursive automation delegation remains disabled in v1.
- Organization is a mandatory boundary for all AI business data in this proposal. Shared platform templates are distributed as versioned seed packages into an organization; no NULL organization denotes global access.
- Teams express accountability and receive Identity role bindings. Team ownership does not automatically authorize every team member.

| Schema | Responsibility |
|---|---|
| cob3_agent | Agent, prompt, skill, tool and model definitions; immutable executable revisions |
| cob3_ai_runtime | Execution authority, runs, attempts, events, checkpoints, tool actions, context and durable dispatch |
| cob3_copilot | Conversations, message branches, attachments and user-facing projections |
| cob3_memory | Durable knowledge, recall evidence and bounded working memory |
| cob3_learning | Feedback, evaluation, curated training data and controlled promotion |
| cob3_llmobs | AI application configuration, capture policies and LLM invocation accounting |
| cob3_ai_lineage | Typed provenance registry and dependency edges |
| cob3_connectors | Connections, sync cursors, jobs, attempts and imported records |

These are database namespaces, not a requirement for eight microservices. Start in one PostgreSQL database with transactional boundaries. Keep high-volume telemetry and blob content separable later.

## 2. Findings and migration mapping

| Existing area/table | Proposed change |
|---|---|
| agent, agent_revision | Preserve definition/revision split; pin every prompt, tool and skill version; execution principal belongs to runs, not the blueprint |
| model_registry | Separate model deployment identity/configuration from effective-dated pricing; evaluation scores become evaluation results |
| tool.scopes / agent capabilities JSON | Treat as declared requirements only; actual authorization comes from Identity permissions/grants |
| learning_container | Move to memory.containers; explicit Catalog resource, scope owner and retention |
| skill source ID arrays | Replace with lineage edges to exact source versions |
| copilot.agent_run, tool_call, run_event, interrupt | Move execution truth to ai_runtime; interrupts reference Identity approvals |
| learning.agent_checkpoint, agent_checkpoint_write | Move to ai_runtime; checkpoint state is not learning data |
| thread_lock and thread_state | Versioned branch state plus fenced run leases; no thread-wide global lock for unrelated branches |
| thread_share | Migrate to Identity role_bindings against conversation Catalog assets; remove duplicate ACL |
| chat_message role/user fields | Keep conversational role separate from actual author principal and executing run |
| memory_grant_policy | Retire booleans; use Identity scopes, source-access checks and bounded retrieval policies |
| memory_source / ai_lineage_edge free-form targets | Typed registered nodes with verifiable source backing and retained tombstones |
| feedback.user_id, annotation.user_id | Principal FK; distinguish human, automated evaluator and imported signal |
| training_dataset.pii_scrubbed | Replace single assurance flag with versioned review, consent/use basis and immutable manifest |
| llm_gateway_call | Preserve imported observations; add logical-call/attempt distinction for native calls, idempotency and pricing snapshots |
| llmobs_meta policies | Organization-bound versioned policy documents; separate configuration from invocation facts |
| connections.encrypted_secrets | Reference Settings integration configurations and a secrets manager; no duplicated secret master |
| jobs lease_id/lease_until | Attempt history, fencing token, explicit retry/reconciliation semantics and cursor commit |
| alert_rule, slo_definition | Preserve existing configuration during migration; redesign with incident/Ops work later |

A screenshot does not establish that all these controls are absent in application code. These are gaps in the visible model and proposed contracts for the new model.

## 3. Mandatory columns and physical conventions

**Every table below explicitly expands the mandatory column set.** All tables here are organization-owned. Tenant-wide platform registries, if introduced later, require separately reviewed scope rules.

| Mandatory column | Type | Contract |
|---|---|---|
| tenant_id | uuid NOT NULL | FK to Tenant tenants |
| organization_id | uuid NOT NULL | Composite FK (tenant_id,organization_id) to Identity organizations |
| created_at | timestamptz NOT NULL DEFAULT now() | Immutable creation timestamp |
| created_by | varchar(160) NOT NULL | Trusted namespaced audit actor: principal:<uuid> or system:<registered-name> |
| updated_at | timestamptz NOT NULL DEFAULT now() | Trusted mutation timestamp |
| updated_by | varchar(160) NOT NULL | Trusted audit actor, same format |
| metadata | jsonb NOT NULL DEFAULT '{}' | Object only; bounded size; no secrets or authorization rules |
| row_version | bigint NOT NULL DEFAULT 1 | Positive optimistic concurrency counter |

Use the prior audit-string convention rather than silently changing created_by/updated_by to UUIDs. Typed ownership, authority and author columns are separate real FKs. Infrastructure writes stamp the worker/system audit actor while retaining the business actor in typed columns. No client may freely select audit fields.

Dictionary notation: `?` means nullable, default NULL. Other domain columns are NOT NULL; required values without a shown default must be supplied by trusted code. Entity ID defaults are gen_random_uuid(). Identifiers on subtypes are supplied, not regenerated. Unless stated otherwise, PK=(tenant_id,organization_id,table-specific ID). Foreign keys to organization-owned parents include both scope IDs; tenant-scoped principal FKs include tenant_id and require validated organization membership for business actors. Cross-organization references are prohibited in v1.

Every table has organization/tenant FKs, CHECK(row_version>0), CHECK(jsonb_typeof(metadata)='object'), CHECK(updated_at>=created_at), and nonblank audit actor checks. Mutable rows use a trusted update trigger preserving creation columns and increasing row_version. Tables marked **I** are append-only/immutable after creation: updated_at=created_at, updated_by=created_by, row_version=1; corrections create new rows. Tables marked **M** permit controlled mutations. Immutability excludes an explicitly authorized retention/purge operation, never routine application UPDATE.

All UNIQUE keys written without scope columns below are shorthand for UNIQUE(tenant_id,organization_id,...); tenant-wide permission/principal references use their actual tenant-qualified parent keys. All ordinary FKs default ON DELETE RESTRICT / ON UPDATE RESTRICT. Purge is an orchestrated workflow preserving safe tombstones, not broad cascading deletion. Nonblank names/codes; stable codes lowercase ASCII. Monetary values numeric(20,8), durations/counters bigint nonnegative, scores finite and within their declared range. UTC instants; scheduling timezones are validated IANA names. JSON columns have a declared schema version, application validation and size/depth limits; jsonb alone does not enforce a JSON Schema.

Where a row references both a parent and a child (agent plus agent_revision, thread plus branch, run plus step), a composite FK or constraint trigger must prove the child belongs to the specified parent. A UUID-only FK is insufficient. Nullable optional links need explicit all-or-none checks where applicable.

## 4. Authorization and execution contract

For noninteractive work, effective access is the intersection of current grantor permissions, current executing principal permissions, immutable approved grant entries, credential/session restrictions, the run's initial authority ceiling and any narrower child ceiling. Also enforce tenant/org lifecycle, membership, validity, audience, risk, approval and budget limits. Interactive human work uses live session/RBAC plus the recorded run ceiling; it does not require inventing a token grant.

Execution contexts are **evidence and ceilings**, never cached permission grants. Reauthorize before retrieval, each tool side effect, checkpoint resume, export, memory access and delivery of results. Permission gain after run creation must not silently enlarge a run's ceiling. Revocation blocks subsequent actions. It cannot retroactively undo an external action already committed.

An asynchronous handoff from an interactive session needs an explicitly authorized durable grant if it must outlive that session. Do not convert a short-lived session into indefinite background authority. Tokens/credentials are stored only in Identity; the runtime keeps IDs and safe fingerprints, never bearer values. A provider API key configured for a deployment is infrastructure capability, not the caller's permission to read or act on data.

Resource sharing uses Catalog assets with authorization_mode='explicit': agent definitions, tools, skills, conversations, memory containers and datasets. This document proposes exact-resource team bindings for these AI asset types, requiring same-org membership and share authority, as a deliberate extension to the previous Workspace exception. Organization/team/project association alone grants nothing. Existing include_workspace_artifacts does not match conversations or memories. No implicit project-to-chat inheritance in v1.

Suggested permission codes: ai.agent.read/edit/publish/invoke; ai.tool.read/invoke; ai.run.read/cancel/resume; ai.conversation.read/write/share; ai.memory.read/propose/approve/delete; ai.feedback.create; ai.dataset.read/curate/export; ai.evaluation.run; ai.training.submit; ai.release.approve; ai.telemetry.read/read_content; ai.connector.manage/run. Seed these in Identity.permissions and map to roles. A role title such as Developer or Reviewer is not a hard-coded authorization rule. Runtime authorization also requires the underlying asset action (for example a datasource read or external ticket write).

Approval uses existing Identity.action_approvals, bound to action kind, tool revision, canonical argument digest, resolved target assets, execution principal/grant, expiry and run/step. A changed argument, target or tool revision invalidates it. Interrupt resolution merely resumes workflow; only a valid approval plus current permission permits execution. Approval cannot manufacture a missing permission. Use a canonical, versioned digest format and atomic consumption with dispatch recording.

## 5. Full proposed table definitions

Each definition below includes all eight mandatory columns. Domain columns and constraints follow. FK targets refer to the corresponding table in this document unless explicitly qualified as a foundation schema. Common constraints in Section 3 apply to every table.
### 1. `cob3_agent.agents` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| agent_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| agent_key | varchar(100) | NOT NULL; Stable org-unique code |
| description | text | NULL; Description |
| current_revision_id | uuid | NULL; Published agent revision |
| enabled | boolean | NOT NULL; DEFAULT false |

**Constraints and behavior:** Catalog owns display name and accountability. Current revision must belong to this agent and be published; publishing is a controlled transaction.

### 2. `cob3_agent.agent_revisions` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| agent_revision_id | uuid | NOT NULL; PK |
| agent_id | uuid | NOT NULL; Agent FK |
| revision | integer | NOT NULL; Positive revision |
| prompt_version_id | uuid | NOT NULL; Prompt version FK |
| model_deployment_id | uuid | NOT NULL; Model deployment FK |
| model_config | jsonb | NOT NULL; Validated model parameters |
| execution_contract | jsonb | NOT NULL; Versioned output and runtime contract |
| memory_policy | jsonb | NOT NULL; Restrictive retrieval limits |
| autonomy_level | smallint | NOT NULL; 0..3 |
| max_steps | integer | NOT NULL; Positive |
| max_duration_seconds | integer | NOT NULL; Positive |
| max_cost | numeric(20,8) | NOT NULL; Nonnegative budget |
| currency | char(3) | NOT NULL; Uppercase currency |
| content_sha256 | char(64) | NOT NULL; Canonical manifest hash |
| change_note | text | NOT NULL; Reason |

**Constraints and behavior:** UNIQUE(agent_id,revision) within scope. Autonomy is a product risk profile, not an IAM permission. Revisions are immutable; publication/revocation are release records. All bindings below form the hashed manifest and are sealed together; later binding insertion/deletion is prohibited.

### 3. `cob3_agent.prompt_templates` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| prompt_template_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| template_key | varchar(100) | NOT NULL; Org-unique code |
| purpose | text | NOT NULL; Purpose |
| current_version_id | uuid | NULL; Published prompt version |

**Constraints and behavior:** Current version belongs to template; template cannot alter a running revision.

### 4. `cob3_agent.prompt_versions` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| prompt_version_id | uuid | NOT NULL; PK |
| prompt_template_id | uuid | NOT NULL; Template FK |
| version | integer | NOT NULL; Positive |
| body | text | NOT NULL; Bounded template text |
| variables_schema | jsonb | NOT NULL; Validated input schema |
| template_engine | varchar(40) | NOT NULL; Allowlisted engine |
| sha256 | char(64) | NOT NULL; Canonical content hash |

**Constraints and behavior:** UNIQUE(prompt_template_id,version). Sandboxed template rendering; prompts cannot embed secrets or executable database code.

### 5. `cob3_agent.model_deployments` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| model_deployment_id | uuid | NOT NULL; PK |
| deployment_key | varchar(100) | NOT NULL; Org-unique code |
| provider | varchar(80) | NOT NULL; Provider code |
| provider_model_id | varchar(300) | NOT NULL; Exact provider identifier |
| provider_revision | varchar(200) | NULL; Version if available |
| integration_configuration_id | uuid | NOT NULL; Settings version/config FK |
| capabilities | jsonb | NOT NULL; Versioned modality and limit declaration |
| context_window | integer | NULL; Positive if known |
| enabled | boolean | NOT NULL; DEFAULT false |

**Constraints and behavior:** Identity fields/configuration immutable once referenced; replacement deployment for changes. Enabled is a live kill switch. Provider aliases are recorded as aliases; do not claim exact reproducibility where provider supplies no immutable revision.

### 6. `cob3_agent.tools` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| tool_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| tool_key | varchar(100) | NOT NULL; Org-unique code |
| current_revision_id | uuid | NULL; Tool revision |
| enabled | boolean | NOT NULL; DEFAULT false |

**Constraints and behavior:** Tool identity is not permission. Current revision belongs to tool.

### 7. `cob3_agent.tool_revisions` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| tool_revision_id | uuid | NOT NULL; PK |
| tool_id | uuid | NOT NULL; Tool FK |
| revision | integer | NOT NULL; Positive |
| transport | varchar(30) | NOT NULL; http or mcp or internal |
| integration_configuration_id | uuid | NULL; Settings FK |
| operation | varchar(160) | NOT NULL; Allowlisted operation |
| input_schema | jsonb | NOT NULL; Versioned JSON schema |
| output_schema | jsonb | NOT NULL; Versioned JSON schema |
| risk_level | smallint | NOT NULL; 0..3 |
| requires_approval | boolean | NOT NULL; DEFAULT true |
| side_effect_class | varchar(30) | NOT NULL; read_only or idempotent_write or non_idempotent_write |
| timeout_seconds | integer | NOT NULL; Positive |
| sha256 | char(64) | NOT NULL; Manifest hash |

**Constraints and behavior:** UNIQUE(tool_id,revision). Endpoint binding resolved from Settings. No arbitrary model-selected URL execution. Tool permission requirements are normalized in tool_permission_requirements.

### 8. `cob3_agent.tool_permission_requirements` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| requirement_id | uuid | NOT NULL; PK |
| tool_revision_id | uuid | NOT NULL; Tool revision FK |
| permission_id | uuid | NOT NULL; Identity permission FK |
| target_resolver_key | varchar(100) | NOT NULL; Trusted resolver |
| resolver_version | integer | NOT NULL; Positive |

**Constraints and behavior:** UNIQUE(tool_revision_id,permission_id,target_resolver_key,resolver_version). All rows required; resolver determines actual Catalog targets from validated arguments. Empty requirements does not bypass ai.tool.invoke. Resolver code is deployed, not user JSON.

### 9. `cob3_agent.skills` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| skill_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| container_id | uuid | NULL; Memory container FK |
| skill_key | varchar(100) | NOT NULL; Org-unique code |
| current_version_id | uuid | NULL; Approved version |
| status | varchar(20) | NOT NULL; draft or active or archived |

**Constraints and behavior:** Skill version links must belong to this skill; owner comes from Catalog accountability.

### 10. `cob3_agent.skill_versions` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| skill_version_id | uuid | NOT NULL; PK |
| skill_id | uuid | NOT NULL; Skill FK |
| version | integer | NOT NULL; Positive |
| manifest | jsonb | NOT NULL; Versioned skill manifest |
| sha256 | char(64) | NOT NULL; Manifest hash |
| change_note | text | NOT NULL; Reason |

**Constraints and behavior:** UNIQUE(skill_id,version). Source provenance via lineage, approval via releases. Skill text is untrusted instructions and grants no capability.

### 11. `cob3_agent.skill_files` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| skill_file_id | uuid | NOT NULL; PK |
| skill_version_id | uuid | NOT NULL; Version FK |
| relative_path | text | NOT NULL; Normalized safe path |
| file_object_id | uuid | NOT NULL; Workspace private file FK |
| sha256 | char(64) | NOT NULL; Content hash |
| size_bytes | bigint | NOT NULL; Nonnegative |

**Constraints and behavior:** UNIQUE(skill_version_id,relative_path). No traversal/absolute paths; declared checksum and size must match scanned file. Seal with skill version.

### 12. `cob3_agent.agent_tool_bindings` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| binding_id | uuid | NOT NULL; PK |
| agent_revision_id | uuid | NOT NULL; Agent revision FK |
| tool_revision_id | uuid | NOT NULL; Exact tool revision |
| requires_approval | boolean | NOT NULL; Effective requirement |
| limits | jsonb | NOT NULL; Restrictive timeout and invocation bounds |

**Constraints and behavior:** UNIQUE(agent_revision_id,tool_revision_id). Approval effective OR with tool and org policy; overrides may only restrict. Seal with revision.

### 13. `cob3_agent.agent_skill_bindings` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| binding_id | uuid | NOT NULL; PK |
| agent_revision_id | uuid | NOT NULL; Agent revision FK |
| skill_version_id | uuid | NOT NULL; Exact skill version |
| load_order | integer | NOT NULL; Nonnegative |

**Constraints and behavior:** UNIQUE(agent_revision_id,skill_version_id); UNIQUE(agent_revision_id,load_order). No floating current-version references inside published revisions.

### 14. `cob3_agent.releases` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| release_id | uuid | NOT NULL; PK |
| agent_revision_id | uuid | NULL; Agent revision |
| skill_version_id | uuid | NULL; Skill version |
| prompt_version_id | uuid | NULL; Prompt version |
| action | varchar(20) | NOT NULL; publish or revoke |
| approved_by_principal_id | uuid | NOT NULL; Identity principal FK |
| approval_id | uuid | NULL; Identity approval FK |
| evaluation_run_id | uuid | NULL; Learning evaluation FK |
| reason | text | NOT NULL; Decision explanation |

**Constraints and behavior:** Exactly one target. Latest ordered decision is effective; transactionally serialize publication/revocation per target, using created_at plus release_id only for display, not concurrency arbitration. Update parent current pointer atomically. Publish only after checks; revocation blocks new use and resumes subject to policy.

### 15. `cob3_ai_runtime.execution_contexts` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| execution_context_id | uuid | NOT NULL; PK |
| initiator_principal_id | uuid | NOT NULL; Authenticated initiating principal |
| execution_principal_id | uuid | NOT NULL; Effective principal |
| grant_id | uuid | NULL; Identity authorization grant |
| credential_id | uuid | NULL; Identity principal credential |
| auth_session_id | uuid | NULL; Identity auth session |
| parent_context_id | uuid | NULL; Narrowing parent context |
| audience | varchar(200) | NOT NULL; Execution audience |
| valid_until | timestamptz | NOT NULL; Bounded expiry |
| authority_ceiling | jsonb | NOT NULL; Canonical permission/scope envelope |
| ceiling_sha256 | char(64) | NOT NULL; Envelope hash |
| authorization_evidence | jsonb | NOT NULL; Decision and policy versions |

**Constraints and behavior:** Trusted creation only. Validate credential/session principal, grant and organization coherence. Interactive human requires auth_session; noninteractive requires approved grant plus credential or bounded federated session. Child context same execution principal and subset ceiling; no re-delegation. Evidence JSON is not editable authority.

### 16. `cob3_ai_runtime.runs` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| run_id | uuid | NOT NULL; PK |
| execution_context_id | uuid | NOT NULL; Context FK |
| agent_revision_id | uuid | NOT NULL; Pinned revision |
| application_environment_id | uuid | NOT NULL; LLMobs environment FK |
| thread_id | uuid | NULL; Copilot thread FK |
| branch_id | uuid | NULL; Copilot branch FK |
| parent_run_id | uuid | NULL; Parent run FK |
| trigger_kind | varchar(30) | NOT NULL; interactive or scheduled or api or connector or evaluation |
| idempotency_key | varchar(200) | NOT NULL; Caller-scoped stable key |
| status | varchar(30) | NOT NULL; Run state |
| input_payload_id | uuid | NULL; Payload FK |
| output_payload_id | uuid | NULL; Payload FK |
| started_at | timestamptz | NULL; Execution start |
| ended_at | timestamptz | NULL; Terminal time |
| deadline_at | timestamptz | NOT NULL; Absolute deadline |
| trace_id | char(32) | NULL; Validated trace hex |
| error_code | varchar(100) | NULL; Safe code |

**Constraints and behavior:** UNIQUE(execution_context_id,idempotency_key). Thread and branch both NULL or both set; branch belongs to thread. Parent context must be equal or narrower. Terminal states immutable; retry is new attempt, not rewriting historical outcomes. Interactive/evaluation triggers cannot be user-spoofed.

### 17. `cob3_ai_runtime.run_attempts` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| run_attempt_id | uuid | NOT NULL; PK |
| run_id | uuid | NOT NULL; Run FK |
| attempt_number | integer | NOT NULL; Positive |
| worker_principal_id | uuid | NOT NULL; Infrastructure service principal |
| status | varchar(30) | NOT NULL; queued or running or succeeded or failed or lost |
| fencing_token | bigint | NOT NULL; Monotonic run generation |
| lease_until | timestamptz | NULL; Lease expiry |
| heartbeat_at | timestamptz | NULL; Last heartbeat |
| started_at | timestamptz | NULL; Start |
| ended_at | timestamptz | NULL; End |
| error_code | varchar(100) | NULL; Safe code |

**Constraints and behavior:** UNIQUE(run_id,attempt_number); UNIQUE(run_id,fencing_token). Partial unique active attempt per run. All runtime mutations compare active fencing token and lease; expiry alone does not fence an external API.

### 18. `cob3_ai_runtime.run_steps` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| step_id | uuid | NOT NULL; PK |
| run_id | uuid | NOT NULL; Run FK |
| step_key | varchar(200) | NOT NULL; Deterministic logical step key |
| parent_step_id | uuid | NULL; Same-run parent step |
| kind | varchar(30) | NOT NULL; model or tool or retrieval or transform or approval |
| status | varchar(30) | NOT NULL; Step state |
| input_sha256 | char(64) | NOT NULL; Canonical input hash |
| started_at | timestamptz | NULL; Start |
| ended_at | timestamptz | NULL; End |
| result_payload_id | uuid | NULL; Payload FK |

**Constraints and behavior:** UNIQUE(run_id,step_key). Same step key with different input hash is an error. Retry attempts retain logical identity.

### 19. `cob3_ai_runtime.run_events` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| event_id | uuid | NOT NULL; PK |
| run_id | uuid | NOT NULL; Run FK |
| sequence | bigint | NOT NULL; Positive per-run sequence |
| run_attempt_id | uuid | NULL; Attempt FK |
| step_id | uuid | NULL; Step FK |
| occurred_at | timestamptz | NOT NULL; Event time |
| event_type | varchar(100) | NOT NULL; Versioned event code |
| schema_version | integer | NOT NULL; Positive |
| payload | jsonb | NOT NULL; Bounded safe event |
| fencing_token | bigint | NULL; Writer generation |

**Constraints and behavior:** UNIQUE(run_id,sequence); allocate sequence transactionally. Validate same run for attempt/step. Durable execution facts only; token streaming may use ephemeral transport and periodic consolidated events.

### 20. `cob3_ai_runtime.payloads` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| payload_id | uuid | NOT NULL; PK |
| file_object_id | uuid | NOT NULL; Unique Workspace file FK |
| content_type | varchar(160) | NOT NULL; Media type |
| schema_key | varchar(160) | NOT NULL; Allowlisted content schema |
| schema_version | integer | NOT NULL; Positive |
| sha256 | char(64) | NOT NULL; Canonical content hash |
| size_bytes | bigint | NOT NULL; Nonnegative |
| classification | varchar(30) | NOT NULL; Data classification |
| expires_at | timestamptz | NULL; Retention expiry |
| status | varchar(20) | NOT NULL; available or quarantined or purged |

**Constraints and behavior:** Immutable content identity; only lifecycle mutable. Private encrypted blob; no persistent signed URL. Context-sensitive access through referencing run/resource, not possession of payload_id. No unsafe pickle/deserialization.

### 21. `cob3_ai_runtime.context_assemblies` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| context_assembly_id | uuid | NOT NULL; PK |
| step_id | uuid | NOT NULL; Run step FK |
| prompt_version_id | uuid | NOT NULL; Prompt version |
| policy_version_id | uuid | NOT NULL; LLMobs policy version |
| page_payload_id | uuid | NULL; Page snapshot payload |
| manifest_payload_id | uuid | NOT NULL; Ordered exact context manifest |
| token_budget | integer | NOT NULL; Positive |
| estimated_tokens | integer | NOT NULL; Nonnegative |
| content_sha256 | char(64) | NOT NULL; Manifest hash |

**Constraints and behavior:** UNIQUE(step_id). Manifest pins message IDs, source versions, memory revisions, skill files and transformations; no provider private reasoning. Versioned token estimator recorded in manifest.

### 22. `cob3_ai_runtime.context_sources` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| context_source_id | uuid | NOT NULL; PK |
| context_assembly_id | uuid | NOT NULL; Assembly FK |
| lineage_node_id | uuid | NOT NULL; Exact source node |
| position | integer | NOT NULL; Nonnegative |
| source_content_hash | char(64) | NOT NULL; Source hash |
| authorization_checked_at | timestamptz | NOT NULL; Check time |
| included_tokens | integer | NOT NULL; Nonnegative |

**Constraints and behavior:** UNIQUE(context_assembly_id,position). Snapshot is evidence only; authorization revalidated before sending assembled content.

### 23. `cob3_ai_runtime.checkpoints` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| checkpoint_id | uuid | NOT NULL; PK |
| run_id | uuid | NOT NULL; Run FK |
| branch_id | uuid | NULL; Copilot branch FK |
| namespace | varchar(200) | NOT NULL; Framework namespace |
| framework_checkpoint_key | varchar(300) | NOT NULL; Adapter key |
| parent_checkpoint_id | uuid | NULL; Same-run predecessor |
| step_number | bigint | NOT NULL; Nonnegative |
| state_payload_id | uuid | NOT NULL; Serialized state |
| serializer | varchar(80) | NOT NULL; Allowlisted serializer |
| state_schema_version | integer | NOT NULL; Positive |
| runtime_version | varchar(100) | NOT NULL; Executor build |
| manifest_sha256 | char(64) | NOT NULL; Pinned graph/config hash |
| is_interrupt_point | boolean | NOT NULL; DEFAULT false |

**Constraints and behavior:** UNIQUE(run_id,namespace,framework_checkpoint_key). Parent same namespace/run and earlier step; prevent cycles. Separate forks create new run with explicit source-checkpoint provenance. No PK dependency on framework-wide thread ID uniqueness.

### 24. `cob3_ai_runtime.checkpoint_writes` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| checkpoint_write_id | uuid | NOT NULL; PK |
| checkpoint_id | uuid | NOT NULL; Checkpoint FK |
| task_key | varchar(200) | NOT NULL; Framework task key |
| write_index | integer | NOT NULL; Nonnegative |
| channel | varchar(100) | NOT NULL; Allowlisted channel |
| value_payload_id | uuid | NOT NULL; Write value payload |

**Constraints and behavior:** UNIQUE(checkpoint_id,task_key,write_index). Publish checkpoint only after referenced payload/write durability; framework adapter must preserve its documented ordering semantics.

### 25. `cob3_ai_runtime.tool_actions` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| tool_action_id | uuid | NOT NULL; PK |
| step_id | uuid | NOT NULL; Unique tool step |
| tool_revision_id | uuid | NOT NULL; Pinned revision |
| arguments_payload_id | uuid | NOT NULL; Validated canonical arguments |
| arguments_sha256 | char(64) | NOT NULL; Argument digest |
| target_manifest | jsonb | NOT NULL; Resolved resource IDs and actions |
| idempotency_key | varchar(200) | NOT NULL; Stable external-action key |
| status | varchar(30) | NOT NULL; Action state |
| approval_id | uuid | NULL; Identity approval FK |
| result_payload_id | uuid | NULL; Result payload |
| error_code | varchar(100) | NULL; Safe code |

**Constraints and behavior:** Target resolver validates all arguments and referenced resources; agent cannot supply trusted target manifest. Check live authorization and approval immediately before dispatch. No automatic retry after ambiguous non-idempotent result.

### 26. `cob3_ai_runtime.tool_attempts` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| tool_attempt_id | uuid | NOT NULL; PK |
| tool_action_id | uuid | NOT NULL; Logical action FK |
| attempt_number | integer | NOT NULL; Positive |
| run_attempt_id | uuid | NOT NULL; Executing worker attempt |
| status | varchar(30) | NOT NULL; prepared or sent or succeeded or failed or unknown |
| provider_request_id | varchar(300) | NULL; Remote correlation |
| started_at | timestamptz | NOT NULL; Start |
| ended_at | timestamptz | NULL; End |
| result_payload_id | uuid | NULL; Result |
| error_code | varchar(100) | NULL; Safe code |

**Constraints and behavior:** UNIQUE(tool_action_id,attempt_number). Unknown means remote outcome uncertain; reconciliation required. Preserve failed attempts and errors after logical action succeeds.

### 27. `cob3_ai_runtime.interrupts` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| interrupt_id | uuid | NOT NULL; PK |
| run_id | uuid | NOT NULL; Run FK |
| step_id | uuid | NOT NULL; Same-run step FK |
| checkpoint_id | uuid | NULL; Same-run checkpoint |
| kind | varchar(30) | NOT NULL; approval or user_input or clarification |
| request_payload_id | uuid | NOT NULL; Safe request |
| approval_id | uuid | NULL; Identity approval |
| status | varchar(20) | NOT NULL; pending or resolved or expired or cancelled |
| expires_at | timestamptz | NOT NULL; Deadline |
| resolved_by_principal_id | uuid | NULL; Resolver principal |
| resolved_at | timestamptz | NULL; Time |
| resolution_payload_id | uuid | NULL; Response |

**Constraints and behavior:** Resolution actor/time set together. Expiry enforced; resumptions reauthorize. Approval status read from Identity, never inferred from arbitrary resolution JSON.

### 28. `cob3_ai_runtime.outbox` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| outbox_id | uuid | NOT NULL; PK |
| run_id | uuid | NULL; Run FK |
| event_key | varchar(200) | NOT NULL; Org-unique idempotency key |
| event_type | varchar(100) | NOT NULL; Allowlisted dispatch kind |
| payload | jsonb | NOT NULL; Safe identifiers only |
| available_at | timestamptz | NOT NULL; Dispatch time |
| status | varchar(20) | NOT NULL; pending or leased or delivered or failed |
| attempt_count | integer | NOT NULL; DEFAULT 0 |
| lease_until | timestamptz | NULL; Lease |
| fencing_token | bigint | NOT NULL; DEFAULT 0 |
| delivered_at | timestamptz | NULL; Time |

**Constraints and behavior:** Write in same transaction as state change. Delivery at least once; each consumer deduplicates event_key. Supports search invalidation, memory purge and dispatch, not a security audit substitute.

### 29. `cob3_copilot.threads` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| thread_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique conversation Catalog asset |
| project_id | uuid | NULL; Workspace project FK |
| folder_id | uuid | NULL; Same-project folder FK |
| default_agent_id | uuid | NULL; Agent FK |
| status | varchar(20) | NOT NULL; active or archived |
| origin_surface | varchar(80) | NOT NULL; UI or API origin |
| summary_payload_id | uuid | NULL; Derived summary |
| summary_through_message_id | uuid | NULL; Summary boundary |

**Constraints and behavior:** Display name/owner in Catalog. Summary must retain source lineage and access dependencies. Folder requires project. Conversation ACL is explicit; project relationship alone grants no access.

### 30. `cob3_copilot.branches` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| branch_id | uuid | NOT NULL; PK |
| thread_id | uuid | NOT NULL; Thread FK |
| parent_branch_id | uuid | NULL; Same-thread branch |
| fork_message_id | uuid | NULL; Same-thread message |
| head_message_id | uuid | NULL; Same-branch head |
| state_version | bigint | NOT NULL; DEFAULT 1 |
| last_run_id | uuid | NULL; Same-branch run |

**Constraints and behavior:** Prevent branch cycles. Fork retains exact ancestor lineage; thread read alone never overrides underlying source restrictions. Branch head updates use compare-and-swap. No global is_active_branch on each message.

### 31. `cob3_copilot.messages` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| message_id | uuid | NOT NULL; PK |
| thread_id | uuid | NOT NULL; Thread FK |
| branch_id | uuid | NOT NULL; Same-thread branch |
| parent_message_id | uuid | NULL; Allowed predecessor |
| run_id | uuid | NULL; Same-thread run |
| author_principal_id | uuid | NULL; Author/execution principal |
| role | varchar(20) | NOT NULL; user or assistant or tool or system |
| content_payload_id | uuid | NOT NULL; Message content |
| replaces_message_id | uuid | NULL; Same-thread edited predecessor |
| tool_action_id | uuid | NULL; Runtime action |
| sequence | bigint | NOT NULL; Positive branch sequence |

**Constraints and behavior:** UNIQUE(branch_id,sequence). User messages require author principal; assistant messages require run and actor matching execution context. System role only trusted runtime. Tool messages must match action/run. Edits create new message/branch; authorize read of attached sources on rendering.

### 32. `cob3_copilot.message_attachments` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| attachment_id | uuid | NOT NULL; PK |
| message_id | uuid | NOT NULL; Message FK |
| file_object_id | uuid | NOT NULL; Workspace file FK |
| display_name | varchar(255) | NOT NULL; Nonblank |
| position | integer | NOT NULL; Nonnegative |

**Constraints and behavior:** UNIQUE(message_id,position). Reuse Workspace checksum/scan/size/storage lifecycle; no second mutable scan truth. Only approved files reach models.

### 33. `cob3_copilot.thread_preferences` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| thread_preference_id | uuid | NOT NULL; PK |
| thread_id | uuid | NOT NULL; Thread FK |
| principal_id | uuid | NOT NULL; Human principal FK |
| pinned | boolean | NOT NULL; DEFAULT false |
| last_read_message_id | uuid | NULL; Same-thread message |
| selected_branch_id | uuid | NULL; Same-thread branch |

**Constraints and behavior:** UNIQUE(thread_id,principal_id). Preferences do not share thread. Human-only membership checked.

### 34. `cob3_copilot.search_documents` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| search_document_id | uuid | NOT NULL; PK |
| message_id | uuid | NOT NULL; Message FK |
| chunk_index | integer | NOT NULL; Nonnegative |
| content_hash | char(64) | NOT NULL; Exact indexed source hash |
| search_text | text | NOT NULL; Sanitized bounded content |
| search_vector | tsvector | NOT NULL; Derived index value |
| index_version | integer | NOT NULL; Positive |

**Constraints and behavior:** UNIQUE(message_id,chunk_index,index_version). Derived/rebuildable; same ACL and retention as source. Query-time source checks and invalidation on revoke/delete; no broad search snippets before authorization.

### 35. `cob3_copilot.suggestions` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| suggestion_id | uuid | NOT NULL; PK |
| run_id | uuid | NOT NULL; Run FK |
| thread_id | uuid | NOT NULL; Same-run thread |
| message_payload_id | uuid | NOT NULL; Suggestion content |
| position | integer | NOT NULL; Nonnegative |
| expires_at | timestamptz | NULL; Expiry |

**Constraints and behavior:** Display/click events belong in Workspace interaction_events. Clicking is a fresh authorized action, not execution of trusted arbitrary suggestion text.

### 36. `cob3_memory.containers` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| container_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| scope_kind | varchar(20) | NOT NULL; principal or team or project or organization |
| owner_principal_id | uuid | NULL; Scope principal |
| team_id | uuid | NULL; Scope team |
| project_id | uuid | NULL; Scope project |
| retention_days | integer | NOT NULL; Positive |
| enabled | boolean | NOT NULL; DEFAULT false |

**Constraints and behavior:** Exactly matching scope field, other owner fields NULL; organization scope all three NULL. Scope labels do not grant access. Existing learning_container maps here; owner principal may be human/service/automation.

### 37. `cob3_memory.items` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| memory_id | uuid | NOT NULL; PK |
| container_id | uuid | NOT NULL; Container FK |
| memory_kind | varchar(30) | NOT NULL; semantic or episodic or procedural |
| current_revision_id | uuid | NULL; Memory revision |
| status | varchar(20) | NOT NULL; candidate or approved or rejected or superseded or retracted |
| valid_from | timestamptz | NOT NULL; Inclusive start |
| valid_until | timestamptz | NULL; Exclusive end |
| superseded_by_id | uuid | NULL; Same-container replacement |

**Constraints and behavior:** Current revision belongs to item. valid_until>valid_from; no self/cyclic supersession. Status approval requires controlled review; recall counts and feedback counts are derived, not authority.

### 38. `cob3_memory.item_revisions` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| memory_revision_id | uuid | NOT NULL; PK |
| memory_id | uuid | NOT NULL; Memory FK |
| revision | integer | NOT NULL; Positive |
| content_payload_id | uuid | NOT NULL; Memory content |
| structured_claim | jsonb | NULL; Versioned subject/predicate/object |
| confidence | numeric(6,5) | NULL; 0..1 |
| importance | numeric(6,5) | NULL; 0..1 |
| classification | varchar(30) | NOT NULL; Classification |
| content_sha256 | char(64) | NOT NULL; Content hash |
| reviewer_principal_id | uuid | NULL; Reviewer |
| review_approval_id | uuid | NULL; Identity approval |

**Constraints and behavior:** UNIQUE(memory_id,revision). Sources registered through lineage; no source-less inferred fact autoapproved. Human assessment and model confidence remain distinct metadata fields.

### 39. `cob3_memory.access_events` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| memory_access_id | uuid | NOT NULL; PK |
| memory_revision_id | uuid | NOT NULL; Exact revision FK |
| run_id | uuid | NOT NULL; Run FK |
| step_id | uuid | NOT NULL; Same-run step |
| access_type | varchar(20) | NOT NULL; retrieved or included or cited or rejected |
| rank | integer | NULL; Positive |
| score | double precision | NULL; Finite retrieval score |
| occurred_at | timestamptz | NOT NULL; Time |
| authorization_decision_id | varchar(160) | NOT NULL; Trusted decision reference |

**Constraints and behavior:** No raw search query by default. included/cited refer to actual context assembly/source manifest. Log denied access without revealing inaccessible memory content.

### 40. `cob3_memory.working_state` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| working_state_id | uuid | NOT NULL; PK |
| run_id | uuid | NOT NULL; Run FK |
| namespace | varchar(160) | NOT NULL; Scoped state channel |
| state_key | varchar(160) | NOT NULL; Stable key |
| value_payload_id | uuid | NOT NULL; Bounded state payload |
| expires_at | timestamptz | NOT NULL; Mandatory expiry |

**Constraints and behavior:** UNIQUE(run_id,namespace,state_key). Run-local only, optimistic row_version. Cross-run reuse requires explicit approved durable memory; framework checkpoint remains resume truth.

### 41. `cob3_memory.consolidation_jobs` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| consolidation_job_id | uuid | NOT NULL; PK |
| container_id | uuid | NOT NULL; Container FK |
| run_id | uuid | NOT NULL; Runtime run |
| status | varchar(20) | NOT NULL; queued or running or proposed or failed or completed |
| input_manifest_payload_id | uuid | NOT NULL; Pinned memory inputs |
| output_manifest_payload_id | uuid | NULL; Candidate outputs |
| started_at | timestamptz | NULL; Start |
| ended_at | timestamptz | NULL; End |

**Constraints and behavior:** Candidates cannot broaden source scope. All inputs/outputs linked through lineage. Memory-to-skill promotion is a reviewed release, never a counter threshold.

### 42. `cob3_learning.feedback` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| feedback_id | uuid | NOT NULL; PK |
| author_principal_id | uuid | NOT NULL; Identity principal |
| source_kind | varchar(20) | NOT NULL; human or evaluator or imported |
| target_node_id | uuid | NOT NULL; Typed lineage target |
| run_id | uuid | NULL; Runtime run |
| signal | varchar(40) | NOT NULL; Versioned signal |
| rating | smallint | NULL; 1..5 |
| comment_payload_id | uuid | NULL; Sensitive comment |
| correction_payload_id | uuid | NULL; Proposed correction |
| client_event_id | varchar(200) | NOT NULL; Idempotency key |

**Constraints and behavior:** UNIQUE(author_principal_id,client_event_id). Validate source kind from authenticated origin. Votes are evidence; neither correction nor repeated bot votes becomes trusted memory automatically. Corrections require source-access checks.

### 43. `cob3_learning.annotations` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| annotation_id | uuid | NOT NULL; PK |
| author_principal_id | uuid | NOT NULL; Principal FK |
| target_node_id | uuid | NOT NULL; Lineage target |
| annotation_type | varchar(80) | NOT NULL; Registered annotation kind |
| payload_id | uuid | NOT NULL; Annotation payload |
| client_event_id | varchar(200) | NOT NULL; Idempotency key |
| occurred_at | timestamptz | NOT NULL; Event time |

**Constraints and behavior:** UNIQUE(author_principal_id,client_event_id). Separate user interaction telemetry from intentionally submitted learning annotations.

### 44. `cob3_learning.datasets` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| dataset_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| purpose | varchar(20) | NOT NULL; evaluation or training |
| current_version_id | uuid | NULL; Dataset version |
| status | varchar(20) | NOT NULL; draft or active or quarantined or archived |

**Constraints and behavior:** Evaluation/training datasets separate; no silent reuse of holdout cases as training examples.

### 45. `cob3_learning.dataset_versions` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| dataset_version_id | uuid | NOT NULL; PK |
| dataset_id | uuid | NOT NULL; Dataset FK |
| version | integer | NOT NULL; Positive |
| manifest_payload_id | uuid | NOT NULL; Canonical immutable sample manifest |
| manifest_sha256 | char(64) | NOT NULL; Content hash |
| example_count | bigint | NOT NULL; Nonnegative |
| use_basis | varchar(100) | NOT NULL; Reviewed permitted use category |
| reviewer_principal_id | uuid | NOT NULL; Reviewer |
| approval_id | uuid | NULL; Identity approval |
| redaction_policy_version | varchar(100) | NOT NULL; Applied policy |

**Constraints and behavior:** UNIQUE(dataset_id,version). Manifest and examples sealed atomically; verify all sources authorized for declared use, data residency and export. pii_scrubbed alone is not permission or proof of absence.

### 46. `cob3_learning.examples` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| example_id | uuid | NOT NULL; PK |
| dataset_version_id | uuid | NOT NULL; Version FK |
| example_key | varchar(200) | NOT NULL; Stable source-independent key |
| split | varchar(20) | NOT NULL; train or validation or test |
| input_payload_id | uuid | NOT NULL; Input |
| expected_payload_id | uuid | NULL; Expected evaluation output |
| chosen_payload_id | uuid | NULL; Preferred training answer |
| rejected_payload_id | uuid | NULL; Rejected answer |
| rubric | jsonb | NULL; Validated evaluation rubric |
| source_node_id | uuid | NOT NULL; Lineage source |

**Constraints and behavior:** UNIQUE(dataset_version_id,example_key). Purpose-specific XOR constraints: evaluation expected/rubric; training chosen and optional rejected. Split by source lineage/customer/thread as appropriate, not random sibling messages; detect duplicate contamination.

### 47. `cob3_learning.evaluation_runs` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| evaluation_run_id | uuid | NOT NULL; PK |
| dataset_version_id | uuid | NOT NULL; Frozen dataset |
| agent_revision_id | uuid | NOT NULL; Tested revision |
| runtime_run_id | uuid | NOT NULL; Execution FK |
| evaluator_config | jsonb | NOT NULL; Versioned evaluator manifest |
| status | varchar(20) | NOT NULL; queued or running or completed or failed |
| started_at | timestamptz | NULL; Start |
| ended_at | timestamptz | NULL; End |

**Constraints and behavior:** Pin judge model deployment and prompt versions in config with validated scoped references. No floating aliases for a claimed reproducible score. Evaluation tools default sandboxed/no side effects.

### 48. `cob3_learning.evaluation_results` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| evaluation_result_id | uuid | NOT NULL; PK |
| evaluation_run_id | uuid | NOT NULL; Evaluation FK |
| example_id | uuid | NOT NULL; Example in same dataset version |
| metric_key | varchar(100) | NOT NULL; Versioned metric |
| attempt_number | integer | NOT NULL; Positive |
| value | numeric(20,8) | NULL; Measured score |
| passed | boolean | NULL; Threshold result |
| status | varchar(20) | NOT NULL; scored or error or skipped |
| evidence_payload_id | uuid | NULL; Evaluation evidence |
| judge_call_id | uuid | NULL; LLM invocation FK |

**Constraints and behavior:** UNIQUE(evaluation_run_id,example_id,metric_key,attempt_number). Failure is not score zero; aggregate only with documented denominator/missing policy. Metric configuration pins threshold and higher-is-better.

### 49. `cob3_learning.training_jobs` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| training_job_id | uuid | NOT NULL; PK |
| dataset_version_id | uuid | NOT NULL; Training dataset version |
| runtime_run_id | uuid | NOT NULL; Authorized runtime run |
| base_model_deployment_id | uuid | NOT NULL; Base deployment |
| integration_configuration_id | uuid | NOT NULL; Settings provider config |
| hyperparameters | jsonb | NOT NULL; Validated configuration |
| provider_job_id | varchar(300) | NULL; Remote id |
| status | varchar(30) | NOT NULL; queued or exporting or training or succeeded or failed or cancelled or quarantined |
| result_model_deployment_id | uuid | NULL; New model |
| started_at | timestamptz | NULL; Start |
| ended_at | timestamptz | NULL; End |

**Constraints and behavior:** Provider remote ID unique within integration when non-NULL. Export explicitly authorized, manifest captured; result never auto-deployed. Source erasure may require model quarantine and retraining; deletion of examples does not untrain model weights.

### 50. `cob3_llmobs.applications` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| application_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| application_key | varchar(100) | NOT NULL; Org-unique code |
| criticality | smallint | NOT NULL; 0..3 |
| classification | varchar(30) | NOT NULL; Default classification |
| enabled | boolean | NOT NULL; DEFAULT true |

**Constraints and behavior:** Catalog accountability replaces owner_email/owner_team strings. No default_tenant_id fallback for unresolved ingested data.

### 51. `cob3_llmobs.application_environments` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| application_environment_id | uuid | NOT NULL; PK |
| application_id | uuid | NOT NULL; Application FK |
| environment_key | varchar(80) | NOT NULL; dev or test or production or approved code |
| integration_configuration_id | uuid | NULL; Settings exporter config |
| current_policy_version_id | uuid | NULL; Policy version |
| semconv_version | varchar(100) | NOT NULL; Pinned semantic mapping |
| enabled | boolean | NOT NULL; DEFAULT true |

**Constraints and behavior:** UNIQUE(application_id,environment_key). Service-name aliases and instrumentation library/version live in validated metadata; prevent collisions during ingestion. Current policy belongs to environment.

### 52. `cob3_llmobs.policy_versions` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| policy_version_id | uuid | NOT NULL; PK |
| application_environment_id | uuid | NOT NULL; Environment FK |
| version | integer | NOT NULL; Positive |
| capture_prompts | boolean | NOT NULL; DEFAULT false |
| capture_tool_io | boolean | NOT NULL; DEFAULT false |
| capture_retrieval_queries | boolean | NOT NULL; DEFAULT false |
| content_retention_days | integer | NOT NULL; Nonnegative |
| metadata_retention_days | integer | NOT NULL; Positive |
| sampling_rate | numeric(6,5) | NOT NULL; 0..1 |
| guardrail_config | jsonb | NOT NULL; Versioned policy |
| redaction_config | jsonb | NOT NULL; Versioned detectors/actions |
| evaluation_config | jsonb | NOT NULL; Metric definitions and sampling |
| policy_sha256 | char(64) | NOT NULL; Canonical hash |

**Constraints and behavior:** UNIQUE(environment,version). Policy documents validated against deployed schemas; detector patterns sandboxed/bounded. Settings restrictive policy and residency limits override local permissiveness. Zero content retention means no persistent content capture.

### 53. `cob3_llmobs.invocations` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| invocation_id | uuid | NOT NULL; PK |
| application_environment_id | uuid | NOT NULL; Environment FK |
| run_step_id | uuid | NULL; Native model step |
| execution_context_id | uuid | NULL; Native authority |
| source_system | varchar(100) | NOT NULL; Trusted source |
| source_call_id | varchar(300) | NOT NULL; Source logical call |
| status | varchar(30) | NOT NULL; pending or running or succeeded or failed or cancelled or unknown |
| started_at | timestamptz | NOT NULL; Start |
| ended_at | timestamptz | NULL; End |
| policy_version_id | uuid | NOT NULL; Capture policy |
| trace_id | char(32) | NULL; Trace ID |

**Constraints and behavior:** UNIQUE(source_system,source_call_id) within org. Native requires step/context coherence; imported records may have NULL context and are explicitly observations, never authenticated principal assertions. Trusted source mapping resolves tenant/org before insert.

### 54. `cob3_llmobs.invocation_attempts` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| invocation_attempt_id | uuid | NOT NULL; PK |
| invocation_id | uuid | NOT NULL; Logical invocation |
| attempt_number | integer | NOT NULL; Positive |
| model_deployment_id | uuid | NULL; Known deployment |
| provider | varchar(80) | NOT NULL; Actual provider |
| provider_model_id | varchar(300) | NOT NULL; Actual returned model |
| provider_request_id | varchar(300) | NULL; Remote correlation |
| outcome | varchar(30) | NOT NULL; succeeded or failed or cancelled or unknown |
| started_at | timestamptz | NOT NULL; Start |
| ended_at | timestamptz | NULL; End |
| latency_ms | bigint | NULL; Nonnegative |
| time_to_first_token_ms | bigint | NULL; Nonnegative |
| usage_status | varchar(20) | NOT NULL; known or partial or unknown |
| input_tokens | bigint | NULL; Provider-normalized inclusive input |
| output_tokens | bigint | NULL; Inclusive output |
| cache_read_tokens | bigint | NULL; Input subset |
| cache_write_tokens | bigint | NULL; Input subset |
| reasoning_tokens | bigint | NULL; Output subset |
| usage_dimensions | jsonb | NOT NULL; Versioned provider raw units |
| content_payload_id | uuid | NULL; Captured/redacted content |
| error_code | varchar(100) | NULL; Safe code |

**Constraints and behavior:** UNIQUE(invocation_id,attempt_number). Final observation immutable; late usage is adjustment, not overwrite. NULL tokens means unknown, not zero. Normalization adapter records semantics; never blindly sum subsets into totals. Retry/fallback attempts all count toward incurred usage.

### 55. `cob3_llmobs.model_prices` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| model_price_id | uuid | NOT NULL; PK |
| provider | varchar(80) | NOT NULL; Provider |
| model_key | varchar(300) | NOT NULL; Provider billing model key |
| price_dimension | varchar(80) | NOT NULL; input or output or cache or image or audio etc |
| unit_quantity | numeric(20,8) | NOT NULL; Positive |
| unit_price | numeric(20,8) | NOT NULL; Nonnegative |
| currency | char(3) | NOT NULL; Uppercase code |
| valid_from | timestamptz | NOT NULL; Inclusive |
| valid_until | timestamptz | NULL; Exclusive |
| source_reference | text | NOT NULL; Published or contracted price source |

**Constraints and behavior:** No overlapping effective intervals per provider/model/dimension/currency within organization; enforce exclusion/serialized trigger. Prices org-scoped for contract rates. Publish finite future intervals; referenced rates remain immutable. Correct historical valuation with usage_charges adjustments rather than overlapping price rows.

### 56. `cob3_llmobs.usage_charges` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| usage_charge_id | uuid | NOT NULL; PK |
| invocation_attempt_id | uuid | NOT NULL; Attempt FK |
| price_dimension | varchar(80) | NOT NULL; Nonoverlapping billing component |
| quantity | numeric(20,8) | NOT NULL; Signed for corrections |
| model_price_id | uuid | NULL; Applied rate |
| amount | numeric(20,8) | NOT NULL; Signed calculated/actual cost |
| currency | char(3) | NOT NULL; Currency |
| valuation_kind | varchar(20) | NOT NULL; estimate or actual or adjustment |
| adjusts_charge_id | uuid | NULL; Prior charge |
| source_event_key | varchar(300) | NOT NULL; Unique trusted event |
| tenant_usage_event_id | uuid | NULL; Tenant metering reference |

**Constraints and behavior:** UNIQUE(source_event_key). Reconcile estimate to actual using explicit delta/valuation rules, never total both. Provider expense is separate from customer billable entitlement units. Post billable usage once through Tenant usage_events, idempotently; sampled telemetry cannot be billing source.

### 57. `cob3_llmobs.guardrail_events` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| guardrail_event_id | uuid | NOT NULL; PK |
| policy_version_id | uuid | NOT NULL; Policy FK |
| run_id | uuid | NULL; Runtime run |
| invocation_id | uuid | NULL; Invocation |
| stage | varchar(30) | NOT NULL; input or retrieval or tool or output |
| detector_key | varchar(100) | NOT NULL; Versioned detector |
| action | varchar(20) | NOT NULL; allow or redact or block or review |
| score | numeric(6,5) | NULL; 0..1 |
| evidence_payload_id | uuid | NULL; Restricted redacted evidence |
| occurred_at | timestamptz | NOT NULL; Time |

**Constraints and behavior:** At least run or invocation; if both, prove coherence. This is AI policy evidence, not incident-management schema.

### 58. `cob3_llmobs.review_tasks` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| review_task_id | uuid | NOT NULL; PK |
| target_node_id | uuid | NOT NULL; Lineage target |
| assignee_principal_id | uuid | NULL; Reviewer principal |
| reason_codes | jsonb | NOT NULL; Validated code list |
| status | varchar(20) | NOT NULL; open or assigned or resolved or cancelled |
| resolution_payload_id | uuid | NULL; Restricted resolution |
| resolved_at | timestamptz | NULL; Time |

**Constraints and behavior:** Read assignment does not grant prompt/content access. Export requires independent dataset/use approval. Replaces trace_review_queue without introducing an incident workflow.

### 59. `cob3_ai_lineage.nodes` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| lineage_node_id | uuid | NOT NULL; PK |
| node_kind | varchar(60) | NOT NULL; Registered entity/version kind |
| entity_id | uuid | NOT NULL; Exact backing row ID |
| asset_id | uuid | NULL; Associated Catalog authorization resource |
| content_sha256 | char(64) | NULL; Exact content hash |
| external_reference | varchar(300) | NULL; Trusted source identity |

**Constraints and behavior:** UNIQUE(node_kind,entity_id). This is a controlled polymorphic registry: allowlisted kind-specific constraint triggers validate same-scope backing row and version; registry insert through trusted routine only. No arbitrary target_type text bypass. Kind registry and resolver code are release-owned. Controlled purge preserves ID/type tombstone without retaining sensitive content.

### 60. `cob3_ai_lineage.edges` — I

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| lineage_edge_id | uuid | NOT NULL; PK |
| source_node_id | uuid | NOT NULL; Source node FK |
| derived_node_id | uuid | NOT NULL; Derived node FK |
| relation | varchar(40) | NOT NULL; derived_from or evaluated_by or trained_on or summarized_from or supersedes |
| run_id | uuid | NULL; Generating run |
| transformation_key | varchar(100) | NOT NULL; Versioned transform |
| dependency_kind | varchar(20) | NOT NULL; access_dependency or provenance_only |

**Constraints and behavior:** UNIQUE(source_node_id,derived_node_id,relation,transformation_key). No self-edge; source-to-derived ancestry cycles prohibited for derivation relations. Provenance-only classification requires reviewed declassification/export authority; caller cannot shed source permissions by selecting it. Lineage never itself grants access.

### 61. `cob3_connectors.connections` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| connection_id | uuid | NOT NULL; PK |
| asset_id | uuid | NOT NULL; Unique Catalog asset |
| integration_configuration_id | uuid | NOT NULL; Settings config |
| execution_principal_id | uuid | NOT NULL; Service or automation principal |
| grant_id | uuid | NOT NULL; Identity bounded grant |
| credential_id | uuid | NULL; Credential FK |
| auth_session_id | uuid | NULL; Bounded federated session |
| provider | varchar(80) | NOT NULL; Adapter code |
| adapter_version | varchar(80) | NOT NULL; Pinned adapter |
| enabled | boolean | NOT NULL; DEFAULT false |
| next_run_at | timestamptz | NULL; Schedule |

**Constraints and behavior:** Exactly one configured credential/session auth mechanism; rotate via controlled config. Validate principal/grant binding and live authority each execution. Secrets remain in secret manager through Settings config reference.

### 62. `cob3_connectors.sync_cursors` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| sync_cursor_id | uuid | NOT NULL; PK |
| connection_id | uuid | NOT NULL; Connection FK |
| stream_key | varchar(200) | NOT NULL; Provider collection |
| cursor_payload_id | uuid | NULL; Opaque protected cursor |
| watermark | timestamptz | NULL; Watermark |
| last_successful_job_id | uuid | NULL; Same-connection job |

**Constraints and behavior:** UNIQUE(connection_id,stream_key). Advance only atomically with committed records/outbox for completed batch; optimistic row_version prevents two jobs skipping data.

### 63. `cob3_connectors.jobs` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| connector_job_id | uuid | NOT NULL; PK |
| connection_id | uuid | NOT NULL; Connection FK |
| sync_cursor_id | uuid | NULL; Same-connection cursor |
| runtime_run_id | uuid | NULL; Authorized run |
| operation | varchar(100) | NOT NULL; Allowlisted sync operation |
| idempotency_key | varchar(200) | NOT NULL; Stable request key |
| status | varchar(30) | NOT NULL; queued or running or succeeded or failed or cancelled or reconciliation_required |
| available_at | timestamptz | NOT NULL; Schedule |
| window_start | timestamptz | NULL; Inclusive |
| window_end | timestamptz | NULL; Exclusive |
| started_at | timestamptz | NULL; Start |
| ended_at | timestamptz | NULL; End |

**Constraints and behavior:** UNIQUE(connection_id,idempotency_key). Window both NULL or both set with end>start. Overlapping jobs per stream serialized or adapter-specific safe overlap policy.

### 64. `cob3_connectors.job_attempts` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| connector_job_attempt_id | uuid | NOT NULL; PK |
| connector_job_id | uuid | NOT NULL; Job FK |
| attempt_number | integer | NOT NULL; Positive |
| worker_principal_id | uuid | NOT NULL; Infrastructure principal |
| fencing_token | bigint | NOT NULL; Monotonic job token |
| lease_until | timestamptz | NULL; Lease |
| status | varchar(20) | NOT NULL; running or succeeded or failed or lost |
| record_count | bigint | NOT NULL; DEFAULT 0 |
| started_at | timestamptz | NOT NULL; Start |
| ended_at | timestamptz | NULL; End |
| error_code | varchar(100) | NULL; Safe code |

**Constraints and behavior:** UNIQUE(job,attempt_number); one live attempt per job. Fenced compare-and-swap on record/cursor writes. Runtime runs, when used, remain authority source; job_attempts are sync batch history, not a second grant model.

### 65. `cob3_connectors.records` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now(); immutable on I tables |
| updated_by | varchar(160) | NOT NULL; trusted actor; creation actor on I tables |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive; fixed 1 on I tables |
| record_id | uuid | NOT NULL; PK |
| connection_id | uuid | NOT NULL; Connection FK |
| stream_key | varchar(200) | NOT NULL; Collection |
| external_id | varchar(500) | NOT NULL; Provider object id |
| kind | varchar(100) | NOT NULL; Record kind |
| source_version | varchar(200) | NULL; Provider version |
| content_payload_id | uuid | NULL; Protected source content |
| content_sha256 | char(64) | NULL; Content hash |
| asset_id | uuid | NULL; Catalog resource mapping |
| source_updated_at | timestamptz | NULL; Source time |
| last_seen_at | timestamptz | NOT NULL; Last observation |
| deleted_at | timestamptz | NULL; Provider tombstone |
| last_job_id | uuid | NOT NULL; Importing job |

**Constraints and behavior:** UNIQUE(connection_id,stream_key,kind,external_id). Reject stale versions according to adapter ordering; immutable history captured as lineage-backed payload versions before replacement. Provider deletion triggers derivative invalidation. Do not infer deletion merely because one partial sync missed a record.

## 6. Runtime state, concurrency and failure recovery

Allowed run statuses are queued, running, waiting_input, waiting_approval, cancellation_requested, succeeded, failed, cancelled and expired. Run step statuses are pending, running, waiting, succeeded, failed, skipped and unknown. CHECK constraints enforce the vocabulary; trusted transition routines enforce the directed state graph and terminal timestamps.

The run lifecycle is queued → running → waiting_input/waiting_approval → running → succeeded/failed/cancelled/expired. Cancellation is first a request; a run becomes cancelled only after worker acknowledgement or reconciliation. A provider action already in flight may complete after cancellation. Terminal output and terminal events must reflect that outcome rather than conceal it.

Tool actions use proposed → awaiting_approval → ready → executing → succeeded/failed/unknown. A read-only call may retry under a configured policy. A write may retry only using the same stable idempotency key against an adapter that supports it, or after reconciliation proves the first action did not happen. Unknown is not failed and is never automatically treated as safe to repeat.

1. Authenticate initiator and resolve an organization; validate memberships, agent invoke permission and underlying resources.
2. Pin agent revision, prompt, skill/tool bindings, provider deployment, capture policy and initial authority ceiling.
3. Insert execution context, run and dispatch outbox record in one transaction. Reserve concurrency/usage budget where applicable.
4. Worker atomically claims an attempt, advancing a monotonic fencing token. The worker's infrastructure privileges do not enlarge the business principal's authority.
5. Validate every retrieved source before context assembly. Persist source versions and a sanitized manifest. Recheck before sending to a model.
6. For side effects, resolve actual targets from validated arguments, check current permissions and approval, then atomically record prepared action/approval consumption/dispatch intent. Send stable provider idempotency key.
7. Commit result, durable events, checkpoint and outbox notifications consistently. A crash between remote send and local commit becomes unknown until reconciled.
8. On resume, check current tenant/org/principal/grant/session status, expiry, budget, agent/tool release revocation and serializer/graph compatibility. Snapshot approval or old authorization decisions do not bypass these checks.

Run writes carry fencing_token and expected row_version. Branch head writes also carry expected state_version. Enforce one live writer per run; independent branches may progress concurrently. No fencing token can prevent an already dispatched remote write by itself. Use an adapter with remote idempotency/fencing or reconciliation.

Exactly-once effects across PostgreSQL and arbitrary external services are not promised. Outbox delivery and worker execution are at least once; business idempotency and reconciliation provide correctness. A failed run may still have incurred model costs or completed external side effects. Expose those facts in the run outcome.

Checkpoint payloads use versioned safe serialization, checksums, encryption and bounded size. Do not persist arbitrary executable objects. Pin runtime build/graph manifest. Incompatible upgrades require an explicit state migration or a new run, not optimistic reinterpretation of old state. Framework-generated checkpoint tables may remain adapter-managed physically; if so, expose the scoped logical contract here through a tested adapter rather than rewriting framework internals blindly.

## 7. Memory, provenance and controlled learning

### Different kinds of state

| Information | Authoritative storage | Reuse rule |
|---|---|---|
| Current execution cursor and pending writes | Runtime checkpoints/checkpoint_writes | Resume exact compatible execution |
| Temporary scratch variables | Memory working_state | Run-local; expire automatically |
| User-visible discussion | Copilot messages and branches | Conversation authorization plus source restrictions |
| Reusable candidate fact | Memory item/revision | Candidate until approved under explicit policy |
| Approved knowledge | Memory item revision and source lineage | Container permission AND live source-access checks |
| User vote/correction | Learning feedback | Evidence only; never direct instructions or authority |
| Curated examples | Frozen dataset version and manifest | Approved purpose/use, access and export policy |
| Reusable executable instructions | Approved skill/agent release | Reviewed, evaluated and bounded by runtime authority |

Memory retrieval performs scoped candidate filtering and exact authorization verification before content reaches the LLM. Recheck after approximate/vector retrieval and before loading payloads. Indexes and caches include tenant/org, container, content version, embedding model/version and authorization invalidation generation. Cache hits never bypass permission checks. Embedding storage is optional: it is a derived index, not another memory master. Record the embedding model and dimension; rebuild on incompatible changes.

A derived summary combining A and B remains dependent on both sources unless an explicitly authorized declassification/publication process produces a separately approved shareable result. Container sharing alone cannot widen source permissions. Source revocation blocks access to dependent memories, summaries, conversations containing excerpts and assembled-context replay. Maintain dependency invalidation through lineage and an outbox; query-time checks remain the security boundary while invalidation catches up.

Source snippets, search indexes and embeddings are sensitive derivatives. Do not retain a plaintext excerpt after deleting its source merely to preserve provenance. Retain safe IDs/hashes and deletion evidence where policy permits. Metadata can also identify people; minimize it.

Promotion path: feedback or execution evidence → candidate memory/skill → reviewer/use-basis validation → frozen evaluation dataset → evaluation → approved release. Automated evaluation may assist review, but cannot grant itself approval rights. Product policy may allow low-risk automatic candidate approval only under an explicit bounded service authority and auditable rule; high-impact releases require separation of duties.

Human feedback, synthetic evaluator feedback and imported observations remain distinguishable. Repeated automation feedback is not independent human consensus. Prevent training/evaluation leakage by splitting on source lineage and holding out related sessions/documents. Record failures and skipped examples separately from low scores.

Fine-tuning exports require explicit permission and permitted use for every included example, residency checks and a frozen manifest. Model deployment is a separate approval. If source data is withdrawn later, retract examples and affected datasets; quarantine or retrain dependent models as required. Removing a row does not guarantee removal from trained weights.

Do not capture or use private model chain-of-thought as a memory/training requirement. Store observable actions, inputs/outputs where permitted, concise user-facing explanations, tool results, decisions and evaluation evidence. Provider internal reasoning is neither an authorization source nor necessary audit evidence.

## 8. Retention, content capture and legal holds

Default prompt/tool/retrieval content capture is off. Content that the product must persist for chat or resumability has its own explicit purpose and retention; turning off telemetry capture does not imply a chat product stores no messages. Avoid making another copy of product content in telemetry. Payload references preserve that distinction.

Capture policies are immutable versions; active restrictive organization settings are also checked. Redact before telemetry persistence and export. Never store raw credentials, secrets, unrestricted headers or persistent signed URLs. Guardrail evidence itself may contain sensitive text and needs restricted access.

The old retention_policy.legal_hold flag is insufficient for targeted holds. Add this explicit table before migrating existing holds:

### 66. `cob3_llmobs.retention_holds` — M

| Column | PostgreSQL type | Nullability / purpose |
|---|---|---|
| tenant_id | uuid | NOT NULL; Tenant FK |
| organization_id | uuid | NOT NULL; scoped organization FK |
| created_at | timestamptz | NOT NULL DEFAULT now(); immutable |
| created_by | varchar(160) | NOT NULL; trusted namespaced actor |
| updated_at | timestamptz | NOT NULL DEFAULT now() |
| updated_by | varchar(160) | NOT NULL; trusted namespaced actor |
| metadata | jsonb | NOT NULL DEFAULT '{}'; object |
| row_version | bigint | NOT NULL DEFAULT 1; positive |
| retention_hold_id | uuid | NOT NULL; PK |
| target_node_id | uuid | NULL; typed lineage node FK |
| application_environment_id | uuid | NULL; LLMobs environment FK |
| reason_reference | varchar(200) | NOT NULL; restricted case/reference identifier |
| placed_by_principal_id | uuid | NOT NULL; authorized principal |
| placed_at | timestamptz | NOT NULL |
| expires_at | timestamptz | NULL; explicit expiry, otherwise indefinite |
| released_at | timestamptz | NULL |
| released_by_principal_id | uuid | NULL; authorized principal |

Exactly one target (node or environment). Release actor/time set together; expiry/release cannot precede placement. An environment hold includes its run/invocation content and registered descendants according to a versioned documented expansion rule; node holds include the target content and required backing payloads. Holds propagate to underlying Workspace file objects and object-store lifecycle management, not only database rows. Hold placement and purge planning serialize against one another. An active hold prevents purge but does not grant ordinary content access. Migrated broad app holds expand to all relevant environments before any retention job starts.

Purge workflow: determine scoped retention eligibility and active holds → block new reads/retrieval → invalidate derivatives and indexes → delete eligible payload bytes and external/vector copies → retain allowed safe tombstones and deletion audit → confirm completion. Source deletion can affect multi-source descendants; do not delete another source that independently remains retained. Backups follow a documented expiry policy and restored backups must replay deletion manifests before serving traffic. This is an engineering policy, not a claim that one SQL DELETE erases every downstream copy.

## 9. LLM usage, pricing and analytics

Separate logical invocation from actual provider attempts. A fallback from one model to another is one logical request with two potentially billable attempts. Cancellation does not imply zero cost. Imported gateway rows may represent only one provider attempt; keep that limitation explicit rather than inventing missing retries.

Input/output totals, cache tokens and reasoning tokens have provider-specific overlap semantics. Preserve raw usage dimensions and normalize through a versioned adapter. In this proposal cache-read/write are input subsets and reasoning is an output subset; adapters must mark unknown rather than fabricate this interpretation. Cost components must be mutually exclusive after normalization. Record non-token modalities such as images/audio separately. Usage unknown is NULL, not zero.

Model prices are org-specific contract schedules. Version 1 publishes nonoverlapping finite effective intervals and appends future intervals. An open-ended interval must be finalized before it is referenced, or new future pricing must be staged outside the published table until the boundary is known. Corrections to already recorded charges use usage_charges adjustments. Do not mutate historical price rows or insert overlapping corrected prices. A future replacement-schedule catalog is a separate extension, not an undefined required table in this specification. Tenant billing remains authoritative for customer charges.

A charge row records its historical rate reference and amount. Current-price views are display conveniences only. If actual provider expense replaces an estimate, post a delta with adjusts_charge_id; never add actual plus estimate as two independent costs. Tenant usage_events records chargeable customer consumption exactly once using stable provider/attempt business keys. Outbox retries must not duplicate it. This design's provider cost ledger is not an invoice ledger.

Daily views group tenant, organization, environment, provider/model, time bucket and execution-principal category. Team attribution comes from an explicit allocation rule recorded at event time, not whichever team the owner joins later. Do not average daily p95 values; compute p95 from raw durations or mergeable distribution sketches. Separate attempted calls, logical requests, success/error counts and completeness flags. Sampled traces must not produce unsampled financial totals.

Unresolved source tenant/org mappings go to an isolated ingestion quarantine outside customer-readable tables. Never use default_tenant_id as an authority fallback. Imported principal names/claims are untrusted annotations unless mapped by a trusted ingestion adapter.

## 10. Indexes, RLS and scale

- Composite scoped FKs prevent cross-tenant/cross-organization links even when code supplies the wrong IDs. Index child FK columns, especially run_id, thread_id, container_id and connection_id. Include organization in access paths.
- Apply RLS to all business tables with both USING and WITH CHECK. Application roles must not own tables or have BYPASSRLS; use FORCE ROW LEVEL SECURITY where appropriate. PostgreSQL owners/superusers and FK checks have specific bypass behavior, so RLS is defense in depth, not the sole permission engine [1].
- Trusted middleware establishes transaction-local tenant/org context; pooled connections reset it. Client SQL cannot set arbitrary context and thereby authorize itself. Membership and resource authorization are checked independently. Background workers explicitly enter the job's validated scope.
- Index runs by (tenant_id,organization_id,status,deadline_at); attempts/outbox by runnable status and lease/available time; messages by (tenant_id,organization_id,branch_id,sequence); memories by container/status/validity; lineage both source and derived; connector records by scoped external key; invocation attempts by scoped time and invocation.
- Add partial indexes for queued work and unresolved interrupts; GIN only for measured JSON/search query needs. Do not put GIN on every metadata object.
- Keep run/checkpoint authority in PostgreSQL. Large content belongs in private object storage via Workspace file_objects. High-volume analytical facts can later replicate to an analytics store; analytics replicas do not become authorization truth.
- Start unpartitioned at manageable volume. If monthly partitioning is added to event/attempt/charge tables, partition keys must be included in PostgreSQL partitioned unique constraints and referenced keys. Preserve global source-event deduplication in a small unpartitioned ingestion-key registry, or another explicitly transactional equivalent. Do not claim a time-partitioned UNIQUE(source_event_key) works without the partition key [2].
- Apply concurrency and budget reservations atomically. Max-cost fields alone do not prevent parallel overspend; reconcile reserved vs measured usage after attempts finish. Enforce rate limits per tenant/org/principal and provider, with bounded queues and deadlines.
- Dynamic authorization caches need prompt invalidation on IAM changes and live fallback. Never cache access solely by user_id or agent_id. Source filters, policy version, principal/grant/credential restrictions and organization are part of correctness.

## 11. Foundation amendments and integration boundaries

| Foundation | Required amendment |
|---|---|
| Identity | Seed AI permissions; allow audited exact-resource team bindings for explicit AI asset types; expose current authority checks and action approvals; keep principals/grants/credentials as the only identity authority |
| Catalog | Register agent, prompt, tool, skill, conversation, memory_container, dataset and ai_application asset types; use explicit ACL mode; register resources transactionally with domain rows |
| Settings | Reuse integration_configurations and restrictive automation policies; validate AI policy values; no second secret store |
| Workspace | Reuse file_objects; clarify permitted payload content types and lifecycle; link source_thread_asset_id to conversation asset; replace opaque source_run_reference with scoped runtime run FK where feasible |
| Tenant | Reuse entitlements, quota allocation and idempotent usage_events; AI provider costs remain distinct from customer usage/invoices |

Registry/node backing validation must be implemented before enabling lineage-based access checks. Each allowed node kind has a scoped lookup function and deletion behavior. For mutable connector records, node_kind references an immutable imported payload/version manifest, not the changing records row as if it were a version. For run/message/memory/dataset versions, resolve exact backing IDs. Reject unknown kinds. This implementation contract is intentional; SQL cannot declare an ordinary FK to a table chosen by arbitrary node_kind text.

Avoid cyclic migration dependencies: create schemas and parent tables first, then add deferred cross-module FKs/pointers in a second phase. Parent current-version pointers start NULL; insert immutable version/bindings and atomically publish pointer. Deferrable constraints support a publication transaction, not permanently inconsistent rows.

## 12. Migration plan

1. Export current schema-only PostgreSQL DDL, indexes, triggers, RLS policies and row counts. Compare with screenshots. Map all tenant/user/team IDs to canonical masters; preserve legacy identifiers in an explicit migration mapping, not by changing identity semantics.
2. Add organization mapping for each existing application, connection, thread, memory container and descendant. Ambiguous rows are quarantined for assignment; never silently put all data in a default org. Tenant-only shared records require explicit copy/share decisions.
3. Resolve user_id/owner_user_id to principal IDs. Determine actual executor for historical runs when evidence exists. Unknown historical actors remain marked legacy/unknown in import evidence; never invent service authority. Historical rows may require a dedicated import view rather than pretending they satisfy new authenticated-run invariants.
4. Install new schemas, common columns, scoped keys and FK validators. Backfill audit timestamps from trustworthy source fields; preserve migration actor separately. Never label an inferred timestamp as original fact.
5. Migrate agent definitions and freeze version manifests. Resolve floating tool/skill/model references into explicit snapshots with provenance. Review cases where the historical version cannot be reconstructed.
6. Move checkpoint ownership to runtime using an adapter tested against the actual orchestration framework. Preserve namespace, ordering, serializer and pending writes; do not rewrite opaque checkpoint content based on screenshots.
7. Migrate threads, branches and messages. Convert thread_share to reviewed Identity role bindings; compare effective access before deleting old ACL paths. Default ambiguous permissions to no access.
8. Move memory containers, derive source edges and mark unproven/unreviewed memories as candidates. Rebuild search/embedding indexes only after scoped authorization is enabled.
9. Split historical gateway observations into invocations/attempts only where source semantics support that mapping. Preserve unknown usage and price provenance. Reconcile historical totals by tenant/org/day/provider; do not double-post to Tenant billing.
10. Move connector configuration to Settings refs, rotate/rebind secrets under the actual secret manager, migrate jobs/cursors with a controlled dispatch pause, and verify no skipped or duplicated source batches.
11. Dual-read/shadow-compare where practical; use one authoritative writer per entity during migration. Compatibility views preserve old reads temporarily. Cut over per organization with recorded reconciliation checks and rollback boundaries.
12. Retire old memory_grant_policy, free-form thread_share writes and duplicate content/secret masters only after validation. Keep incident/log/Ops tables unchanged pending their own redesign.

## 13. Delivery phases and acceptance tests

The 66 tables form a modular target design, not a requirement to launch every optional capability at once.

**Phase A — correctness first:** principal-aware execution, scoped keys/RLS, pinned definitions/tools, run attempts/events/checkpoints, approval binding, private payloads, conversations, source-aware access and logical/provider LLM accounting. Implement memory as candidates only until retrieval authorization is ready.

**Phase B — knowledge and quality:** reviewed memory, dependency invalidation, feedback, immutable evaluation datasets/results, semantic search, lineage and source-aware summaries. Provenance primitives needed for Phase A can be installed early.

**Phase C — advanced automation:** curated training exports/fine-tuning, skill promotion, broader connectors, analytics offload and more sophisticated policy/price registries. These depend on Phase A controls; they do not bypass them.

Required verification before production implementation is accepted:

| Test | Expected result |
|---|---|
| Insert cross-org run/step/thread/source FK | Database rejects it |
| Worker supplies another tenant/org context | Request fails independent identity/resource checks |
| Same agent invoked by human and automation | Definition reused; distinct execution contexts and bounds |
| Revoke grantor access while run waits | Resume/tool action denied; old snapshot cannot revive access |
| Increase parent's RBAC during an old run | Initial ceiling still limits run |
| Change tool args after approval | Approval rejected; new approval required |
| Worker loses lease then commits | Fencing check rejects stale mutation |
| Remote write succeeds then worker crashes | Reconcile/deduplicate; no blind duplicate action |
| Retry call with same business key | No duplicate logical call/billable usage |
| Provider fallback fails once then succeeds | Both incurred attempts retained, one logical outcome |
| Permission removed from a memory source | Retrieval, snippets and summaries stop exposing it |
| Personal memory consolidated into org container | Rejected unless explicitly authorized publication occurs |
| Bot submits many positive feedback events | Preserved as bot feedback; no automatic trusted promotion |
| Purge source with active hold | Bytes retained but ordinary access still restricted |
| Dataset includes same conversation in train/test | Leakage validation flags it |
| Restore older backup | Apply revocations/deletion manifests before access |
| Framework upgrade changes state schema | Controlled migration/new run; unsafe resume blocked |
| Sample half the traces | Billing total remains independently complete |

**Validation of this deliverable:** table inventory and mandatory-column coverage can be checked mechanically. No SQL installer, framework integration, runtime tests, data migration or live permissions have been executed. The next implementation deliverable should be ordered PostgreSQL migrations plus the authorization/runtime adapter contracts and these integration tests.

## 14. Reference basis

Design choices above are Syskriti proposals, not claims that an external framework automatically provides all these controls. PostgreSQL and framework documentation support the underlying implementation constraints:

1. PostgreSQL, Row Security Policies: https://www.postgresql.org/docs/current/ddl-rowsecurity.html — RLS semantics, owner/bypass behavior and referential-integrity exceptions.
2. PostgreSQL, Table Partitioning: https://www.postgresql.org/docs/current/ddl-partitioning.html — constraints on partitioned unique/primary keys.
3. LangChain/LangGraph, Functional API source documentation: https://github.com/langchain-ai/docs/blob/main/src/oss/langgraph/functional-api.mdx — isolate side effects in tasks and make retries idempotent; the exact persistence adapter must be checked against the installed release.
4. OpenTelemetry, GenAI spans: https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-spans.md — sensitive/large content deserves separate capture and access handling.

Semantic convention and framework versions are pinned in configuration. This design intentionally avoids depending on a floating provider/framework attribute contract.

Document check: 66 numbered table definitions; all 66 explicitly contain the eight mandatory columns. This checks documentation coverage only, not executable schema correctness.
