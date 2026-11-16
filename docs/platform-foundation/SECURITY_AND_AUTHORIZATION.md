# Security and authorization model

## "Schema installed" is not "application security operational"

Installing `INSTALL_FOUNDATION.sql` gives you database-enforced isolation, integrity and a tested
authorization evaluator. Application security is operational only when, in addition:

1. a trusted authentication adapter verifies OIDC/SAML assertions before calling
   `open_interactive_session`, and generates/digests API-key secrets before `issue_principal_credential`;
2. the backend connects with a login that holds **only** `cob3_runtime` and sets request context
   transaction-locally for every request;
3. every endpoint calls `evaluate_access` (or a routine that does) for the exact operation and target,
   and honors `requires_approval`;
4. Settings-dependent limits (grant lifetime caps, group freshness, org automation policy) are enforced
   with explicit secure defaults;
5. denials are audited with `record_audit_event` in a separate transaction.

## Roles and trust boundary

| Role | Purpose | Can |
|---|---|---|
| `cob3_owner` | Owns all objects; SECURITY DEFINER context; migrations | Everything (explicit `*_owner_all` policies). NOLOGIN; reachable only through membership (the migrator) and definer routines. |
| `cob3_runtime` | Customer-facing backend | Read with RLS; limited DML guarded by RLS + triggers; execute request-scoped routines |
| `cob3_provisioner` | Onboarding/provisioning workers | Tenant lifecycle and bootstrap routines; provisioning job queue |
| `cob3_commercial_admin` | Platform commercial authority, billing workers | Platform catalog, contracts, overrides, invoices, payments, provider events |

The runtime role is never owner, superuser or BYPASSRLS (checked by preflight and VERIFY).
**Trust boundary:** `cob3.*` context settings are ordinary user-settable GUCs. They are trustworthy only
because the trusted backend sets them after authentication and end users never get SQL access to the
runtime connection. A compromised runtime connection can claim any context; RLS still requires a valid
session or credential row for the claimed principal, but a malicious backend is outside what the
database can defend. This is documented rather than hidden.

## Request context protocol

`set_request_context(tenant, organization, principal, session, credential)` inside an explicit
transaction. `ctx_auth_valid()` then requires: tenant active; principal active with a live subtype
(service/automation not expired); and either a valid interactive session (not revoked/expired,
`auth_version` current, external identity and provider active, session organization equals context
organization) or a valid credential (active, unexpired, same principal and organization, grant
effective). Missing, malformed or mismatched context → `false` → RLS returns no rows.

## RLS model

* Tenant restriction on every tenant-owned row; exact organization match on organization-owned rows
  (never `organization_id IS NULL OR …`).
* Principals and profiles: self, members of the current organization (for an active member), or tenant
  controllers — not blanket tenant visibility.
* Credentials, sessions, grants, approvals: need-to-know (own rows, or holders of `credential.revoke`,
  `grant.revoke`, `action.approve`, `audit.read`, `tenant.manage_administrators`); digest columns are
  not granted to the runtime at all (column privileges).
* Tenant commercial data: tenant controllers (interactive session + active tenant-control role) read
  their own tenant; only `cob3_commercial_admin` writes. Platform catalog: active/published rows to
  authenticated runtime contexts; drafts invisible.
* Writes on lower-risk admin tables (organizations, human principals, memberships, teams, roles,
  scopes, bindings, federation) are allowed by RLS `WITH CHECK` predicates that call `evaluate_access`
  for the specific permission. High-risk state (grants, entries, credentials, bindings, approvals,
  sessions, service/automation creation, audit, usage) has **no runtime DML privilege**; it is written
  only through SECURITY DEFINER routines.
* Context predicates are wrapped in scalar sub-selects so they evaluate once per statement.

## Authorization decision (`cob3_identity.evaluate_access`)

* **Interactive human session:** tenant-control permissions require an active tenant role binding;
  organization permissions require the session's organization, effective membership and live RBAC
  (direct or effective team bindings, active role and permission, matching active scope).
* **Credential or noninteractive session:** permission must be organization-class and delegable;
  grant active and current; grantee = principal; both grantor and grantee eligible and effective
  members; automation principals and automation-usage credentials only `automation_allowed`, never IAM;
  other credentials may perform IAM only as a `provisioning` credential of a service account; an
  approved grant entry must match permission and scope; a credential must be bound to such an entry
  (empty subset denies); live RBAC for grantee **and** grantor; optional initiating user intersected.
  `requires_approval` is true if **any** applicable entry requires approval.
* Targets: `('tenant', tenant_id)` for tenant control, `('organization', organization_id)` for
  identity-administered resources (organization, team, role, service_account, automation, grant,
  credential, action, audit). Any other target needs the Catalog resolver and is denied until installed.
* Decisions are live (no cache). Revocation of a grant, credential, membership, role binding or
  principal takes effect at the next authoritative check. If a cache is introduced later, publish and
  enforce a bounded revocation SLA.

## Grants, credentials and approvals

* Grants are created draft, filled with explicit permission+scope entries (never roles), and authorized
  only if the authorizer acts for the grantor and the grantor currently holds every entry over the whole
  requested scope; a credential-based authorizer must also hold each entry in its own envelope. The
  envelope is frozen at authorization; only suspend/resume/revoke remain. Revoking a grant revokes its
  credentials and sessions.
* Credentials store only a digest; bindings are created with the credential and are immutable;
  rotation = new credential. `provisioning` credentials require an interactive human with
  `service_account.manage`.
* Approvals bind an exact 32-byte action digest, are decided by a different human with `action.approve`
  and authority over the target, and are consumed exactly once by a conditional update; consumption
  re-validates approver eligibility and requester access.

## SECURITY DEFINER hygiene

All 112 definer functions are owned by `cob3_owner`, pin `search_path = pg_catalog, pg_temp`, qualify
every object, use no untrusted dynamic SQL (the only dynamic SQL is in the installer over a fixed table
list), and derive caller authority from the request context (runtime) or EXECUTE grants (platform roles).
No function is executable by PUBLIC.

## Concurrency

Hierarchy changes, gauge quotas, allocations and admin protection take transaction-scoped advisory locks
and then read with a fresh snapshot; counter quotas lock `quota_counters` rows; approvals and draft-grant
edits use row locks. REPEATABLE READ is refused for quota/allocation writes (`SKISO`); hierarchy walks use
`FOR SHARE` so REPEATABLE READ conflicts raise serialization failures instead of creating cycles.
