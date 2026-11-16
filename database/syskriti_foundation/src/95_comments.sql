-- =============================================================================
-- 95  SQL DOCUMENTATION (COMMENT ON)
-- =============================================================================
COMMENT ON SCHEMA cob3_tenant IS
    'Syskriti foundation Tenant module: tenant master and lifecycle, versioned platform commercial catalog (tenant_id/organization_id NULL = platform-owned, not a wildcard), subscriptions, entitlements, quota allocation, usage and billing mirror. Reused unchanged across Syskriti products (one installation per product database).';
COMMENT ON SCHEMA cob3_identity IS
    'Syskriti foundation Identity module: organizations, principals (human/service_account/automation), memberships, teams, RBAC, bounded grants, credentials, federation, approvals, sessions and identity audit. Domain/asset references await the separately installed Catalog integration and fail closed until then.';

-- Support tables
COMMENT ON TABLE cob3_tenant.foundation_installations IS
    'SUPPORT TABLE (not one of the 48 logical tables). Append-only installation/version record used by the installer rerun guard and VERIFY_FOUNDATION.sql.';
COMMENT ON TABLE cob3_tenant.quota_counters IS
    'SUPPORT TABLE (not one of the 48 logical tables). Transactionally maintained hard-quota counters for counter features, written only by record_usage_internal under row locks. Rebuildable from usage_events. usage_rollups are NOT used for enforcement.';

-- Tenant tables
COMMENT ON TABLE cob3_tenant.tenants IS 'Tenant master: customer account and operational lifecycle. Status changes are recorded atomically in tenant_lifecycle_events (deferred check). Subscription status is separate.';
COMMENT ON TABLE cob3_tenant.tenant_contacts IS 'Commercial, support and security contacts. Contact information grants no permissions; optional principal link is tenant-qualified.';
COMMENT ON TABLE cob3_tenant.tenant_lifecycle_events IS 'Append-only tenant lifecycle transition history (UPDATE/DELETE/TRUNCATE blocked). actor_principal_id is a historical reference, intentionally not an FK.';
COMMENT ON TABLE cob3_tenant.provisioning_jobs IS 'Idempotent onboarding/offboarding orchestration. Workers claim with FOR UPDATE SKIP LOCKED + lease (claim_provisioning_job). External steps must be independently idempotent.';
COMMENT ON TABLE cob3_tenant.plans IS 'PLATFORM CATALOG (tenant_id/organization_id must be NULL). Named commercial plan families; only cob3_commercial_admin mutates.';
COMMENT ON TABLE cob3_tenant.plan_versions IS 'PLATFORM CATALOG. Immutable published editions of plans; publication freezes entitlements (parent row lock serializes edits vs publish).';
COMMENT ON TABLE cob3_tenant.features IS 'PLATFORM CATALOG. Commercial capabilities and quota units. Type/unit/measurement immutable once used. Core identity gauges are seeded by the installer; product features come from optional seeds.';
COMMENT ON TABLE cob3_tenant.plan_entitlements IS 'PLATFORM CATALOG. Feature allowances per plan version. Missing entitlement means disabled, never unlimited. Editable only while the version is draft.';
COMMENT ON TABLE cob3_tenant.plan_prices IS 'PLATFORM CATALOG. Published recurring base prices (integer minor units + currency). Published amount/currency/interval immutable.';
COMMENT ON TABLE cob3_tenant.billing_accounts IS 'Billing party and provider-customer references. No payment-card data. Provider mapping immutable once set.';
COMMENT ON TABLE cob3_tenant.subscriptions IS 'Tenant subscription lifecycle. One live base subscription per tenant (partial unique index). Plan/price resolved from subscription_periods.';
COMMENT ON TABLE cob3_tenant.subscription_periods IS 'Effective dated contract segments. Overlap prevented by exclusion constraint (btree_gist). Immutable after leaving scheduled.';
COMMENT ON TABLE cob3_tenant.subscription_changes IS 'Scheduled upgrades/downgrades/cancellations with approval before apply; idempotent per tenant.';
COMMENT ON TABLE cob3_tenant.tenant_entitlement_overrides IS 'Approved contract exceptions that REPLACE the plan entitlement for a feature. Written only by platform commercial authority; overlapping approved windows excluded.';
COMMENT ON TABLE cob3_tenant.organization_quota_allocations IS 'Organization share of finite tenant capacity. Allocation sums are validated against the effective entitlement at every change boundary under a per-tenant/feature lock; contract changes revalidate.';
COMMENT ON TABLE cob3_tenant.usage_events IS 'Append-only metered consumption for COUNTER features. Idempotent by (tenant, source_code, source_event_id) with payload comparison; corrections bounded by the original quantity.';
COMMENT ON TABLE cob3_tenant.usage_rollups IS 'Rebuildable usage projection (NULL organization = unattributed bucket). Not used for hard quota enforcement.';
COMMENT ON TABLE cob3_tenant.invoices IS 'Issued invoice headers and monetary snapshots (bigint minor units). Lines/totals/snapshot frozen at issuance; paid requires reconciled net payments.';
COMMENT ON TABLE cob3_tenant.invoice_lines IS 'Recurring and usage charge snapshots; editable only while the invoice is draft (invoice row locked).';
COMMENT ON TABLE cob3_tenant.payment_transactions IS 'Payment, refund and chargeback mirror. Reversals reference a succeeded payment on the same invoice and cannot exceed it (parent row locked).';
COMMENT ON TABLE cob3_tenant.provider_events IS 'Idempotent processing of authenticated, tenant-resolved billing-provider events (payload digest only). Unresolved events belong in a restricted platform ingress queue outside this table.';

-- Identity tables
COMMENT ON TABLE cob3_identity.organizations IS 'Organization master; multiple per tenant. Parentage grants no inherited access; cycles prevented under concurrency.';
COMMENT ON TABLE cob3_identity.principals IS 'One acting identity per tenant: human, service_account or automation (a token is a credential, never a principal). Exactly one matching subtype at commit (deferred). Status is the master kill switch.';
COMMENT ON TABLE cob3_identity.user_profiles IS 'Human-only profile. Email is contact data, not an authentication identifier.';
COMMENT ON TABLE cob3_identity.service_accounts IS 'Accountable workload identity owned by an organization. Creator immutable (human/service), owner human; own membership enforced by deferred FK.';
COMMENT ON TABLE cob3_identity.automation_profiles IS 'Distinct bot/agent/assistant identity. Created only by humans/services (no self-provisioning or recursive delegation in v1). Creator, accountable owner and delegating authority are distinct.';
COMMENT ON TABLE cob3_identity.organization_memberships IS 'Admission of a principal into an organization; grants no data permissions by itself. Membership type must match principal type.';
COMMENT ON TABLE cob3_identity.teams IS 'Organization-owned team; nested structure is informational (no inherited permissions in v1).';
COMMENT ON TABLE cob3_identity.team_memberships IS 'Team membership; effective only with at least one active current source.';
COMMENT ON TABLE cob3_identity.team_membership_sources IS 'Justifications for team membership (manual or external group mapping to the same team).';
COMMENT ON TABLE cob3_identity.team_domains IS 'CATALOG-DEPENDENT: team responsibility in a Catalog domain. Writes fail closed (SQLSTATE SKCAT) until the Catalog integration installs real FKs and a resolver.';
COMMENT ON TABLE cob3_identity.permissions IS 'Tenant-owned atomic operation codes seeded per tenant by provisioning routines (never NULL tenant). Code/class/resource/action immutable after use.';
COMMENT ON TABLE cob3_identity.roles IS 'Tenant-wide capability bundles. System roles are changed only through controlled provisioning; no role inheritance or wildcard.';
COMMENT ON TABLE cob3_identity.role_permissions IS 'Explicit role-to-permission associations; role class must equal permission class.';
COMMENT ON TABLE cob3_identity.access_scopes IS 'Immutable authorization targets. Organization scope is fully functional; domain/asset scopes fail closed until Catalog integration.';
COMMENT ON TABLE cob3_identity.role_bindings IS 'Organization-class role assigned to exactly one principal or team at a scope.';
COMMENT ON TABLE cob3_identity.tenant_role_bindings IS 'Tenant control-plane roles (no organization data access). Automations rejected; last active human tenant administrator protected.';
COMMENT ON TABLE cob3_identity.authorization_grants IS 'Approved immutable ceiling for personal tokens, service credentials and automations. restricted_self: grantor=grantee; delegated: human/service -> automation. Envelope frozen at authorization.';
COMMENT ON TABLE cob3_identity.authorization_grant_permissions IS 'Explicit approved permission + scope entries (never a role). Editable only while the grant is draft (parent locked).';
COMMENT ON TABLE cob3_identity.principal_credentials IS 'Foundation-issued API keys (digest only, never the secret). Bound to one grant; expiry within grant validity; revocation terminal. secret_digest is not readable by cob3_runtime.';
COMMENT ON TABLE cob3_identity.credential_permission_bindings IS 'Per-credential subset of the same grant''s entries (compound FKs). Created with the credential, append-only; empty subset denies all access.';
COMMENT ON TABLE cob3_identity.action_approvals IS 'Single-use approval bound to an exact action digest; approval never creates permission. Consumed atomically once.';
COMMENT ON TABLE cob3_identity.identity_providers IS 'Trusted SSO/workload authority metadata. Secrets live in a secret manager referenced from Settings; issuer/protocol immutable once used.';
COMMENT ON TABLE cob3_identity.external_identities IS 'Trusted provider subject -> principal mapping. Email never silently merges identities.';
COMMENT ON TABLE cob3_identity.external_groups IS 'Trusted directory group metadata; not application permissions.';
COMMENT ON TABLE cob3_identity.group_team_mappings IS 'Explicit admission path from an external group to a team; never grants a role directly.';
COMMENT ON TABLE cob3_identity.auth_sessions IS 'Revocable interactive (human, oidc/saml) or bounded noninteractive sessions. An API key can never become an interactive session. Digest columns are not readable by cob3_runtime.';
COMMENT ON TABLE cob3_identity.audit_events IS 'Append-only identity/authorization audit (UPDATE/DELETE/TRUNCATE blocked; inserts via record_audit_event/write_audit_event). Actor/credential/grant ids are historical references, not FKs. PK includes occurred_at for future monthly partitioning.';

-- Security-relevant columns
COMMENT ON COLUMN cob3_tenant.plans.tenant_id IS 'Always NULL: platform catalog row. NULL is NOT a row-security wildcard.';
COMMENT ON COLUMN cob3_tenant.features.tenant_id IS 'Always NULL: platform catalog row. NULL is NOT a row-security wildcard.';
COMMENT ON COLUMN cob3_tenant.invoices.total_minor IS 'Integer minor units; CHECK total = subtotal - discount + tax. Never floating point.';
COMMENT ON COLUMN cob3_identity.principals.principal_type IS 'human | service_account | automation; immutable. Tokens are credentials, not principals.';
COMMENT ON COLUMN cob3_identity.principals.auth_version IS 'Authentication invalidation counter (sessions issued at an older version are invalid). Not a substitute for revoking roles/grants.';
COMMENT ON COLUMN cob3_identity.principal_credentials.secret_digest IS 'Digest of a high-entropy server-generated secret. Raw keys are never stored. Not granted to cob3_runtime.';
COMMENT ON COLUMN cob3_identity.principal_credentials.credential_usage IS 'Immutable usage label. automation usage carries all automation restrictions even for human/service owners; provisioning requires an interactive authorized workflow.';
COMMENT ON COLUMN cob3_identity.auth_sessions.session_handle_digest IS 'Digest of the opaque server-issued session handle. Not granted to cob3_runtime.';
COMMENT ON COLUMN cob3_identity.access_scopes.domain_id IS 'PENDING Catalog FK to cob3_catalog.domains(tenant_id, organization_id, domain_id). Writes rejected until Catalog integration; not database-enforced yet.';
COMMENT ON COLUMN cob3_identity.access_scopes.asset_id IS 'PENDING Catalog FK to cob3_catalog.assets(tenant_id, organization_id, asset_id). Writes rejected until Catalog integration; not database-enforced yet.';
COMMENT ON COLUMN cob3_identity.team_domains.domain_id IS 'PENDING Catalog FK to cob3_catalog.domains(tenant_id, organization_id, domain_id). Writes rejected until Catalog integration.';

-- Key routines
COMMENT ON FUNCTION cob3_identity.set_request_context(uuid, uuid, uuid, uuid, uuid) IS
    'Sets transaction-local request context. Call inside an explicit transaction from trusted backend code after authentication. TRUST BOUNDARY: user-settable GUCs are only as trustworthy as the backend that sets them.';
COMMENT ON FUNCTION cob3_identity.evaluate_access(uuid, uuid, uuid, uuid, uuid, text, text, uuid, timestamptz, uuid) IS
    'Authoritative decision. Interactive human session -> live RBAC. Credential/noninteractive -> live grantor RBAC AND live grantee RBAC AND approved grant entry AND credential subset, plus lifecycle, organization, scope, usage and expiry checks. Non-organization targets need the Catalog resolver and are denied until it is installed.';
COMMENT ON FUNCTION cob3_identity.catalog_scope_covers(uuid, uuid, text, uuid, uuid, boolean, uuid, text, text, uuid, timestamptz) IS
    'FAIL-CLOSED placeholder: returns false until the separately invoked Catalog integration replaces it with a trusted resolver.';
COMMENT ON FUNCTION cob3_identity.bootstrap_tenant(text, text, text, text, text, text, text, text, text, uuid, boolean, text) IS
    'Controlled onboarding (cob3_provisioner only): creates tenant, per-tenant IAM seed, first organization, human principal/profile/membership and administrator bindings, then activates. Refuses tenants that are not provisioning or already have administrators.';
COMMENT ON FUNCTION cob3_identity.consume_action_approval(uuid, bytea) IS
    'Atomic single-use consumption bound to request_id and exact action digest; revalidates approver eligibility and requester access before success.';
COMMENT ON FUNCTION cob3_tenant.record_usage_internal(uuid, uuid, text, text, text, timestamptz, numeric, uuid, uuid, boolean) IS
    'Idempotent usage recording with hard counter enforcement (row-locked quota_counters). Duplicate key + same payload = no-op; different payload = error.';
