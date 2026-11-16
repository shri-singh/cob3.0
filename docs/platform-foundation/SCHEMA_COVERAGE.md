# Schema coverage

**Tables:** 48/48 logical tables (21 `cob3_tenant`, 27 `cob3_identity`) + 2 support tables.
**Columns:** 807/807 specified columns implemented with exactly the specified type and nullability, and
no unspecified columns on logical tables. Per-table column, constraint, index, trigger and policy
inventory: [SCHEMA_COVERAGE_APPENDIX.md](SCHEMA_COVERAGE_APPENDIX.md) (generated from the source documents
and a live install). The same comparison runs as test
`test_01_install::test_every_specified_column_type_and_nullability` (both schemas).

Test file prefixes below: `t01` = `tests/test_01_install.py`, `t02` = `test_02_bootstrap_isolation.py`,
`t03` = `test_03_identity_rules.py`, `t04` = `test_04_authorization.py`, `t05` = `test_05_action_approvals.py`,
`t06` = `test_06_commercial.py`, `t07` = `test_07_audit.py`, `t08` = `test_08_catalog_integration_template.py`,
`t09` = `test_09_operator_scripts.py`.

## Common conventions (all 48 tables)

| Requirement | Implementation | Test |
|---|---|---|
| Common columns, types, defaults | Explicit in every `CREATE TABLE` | t01 column coverage |
| `metadata` JSON object; no secrets | `<t>_metadata_object_ck`, heuristic `<t>_metadata_no_secrets_ck` | t07 (secret key rejected in audit details) |
| `row_version > 0`, actor format | `<t>_row_version_positive_ck`, `<t>_created_by_actor_ck`, `<t>_updated_by_actor_ck` | t01 install |
| Creation fields immutable; trusted update stamping; scope ids immutable | `trg_90_stamp_row` → `cob3_identity.tg_stamp_row` | t03/t06 (updates succeed with stamps) |
| Codes lowercase ASCII; names nonblank | `*_format_ck`, `*_nonblank_ck` | t01 install |
| Half-open windows `[from, until)` | `*_window_ck`; runtime checks use `from <= at < until` | t04 revocation tests |
| RESTRICT FK actions, every FK indexed | all 128 FKs; `t01::test_every_foreign_key_has_covering_index…` | t01 |
| No TRUNCATE | `trg_00_block_truncate` on 50 tables | t07 |
| RLS enabled + forced | all 50 tables | t01, t02 |

## Tenant invariants

| Invariant (spec §) | Mechanism | Test |
|---|---|---|
| Tenant status rules, suspension/closure fields (5.1) | `tenants_suspension_ck`, `tenants_closed_ck`, `tenants_active_requires_activation_ck`, `trg_10_state`, `trg_30_lifecycle` | t02 bootstrap |
| Status change recorded atomically (5.1, 5.3) | deferred `trg_80_lifecycle_recorded`; `transition_tenant_status` | t02 bootstrap example (2 events) |
| Lifecycle events append-only; idempotent request id | `trg_05_append_only`, `tenant_lifecycle_events_request_uq`, `_append_only_ck` | t07 |
| Provisioning job states, leases, idempotency (5.4) | CHECKs, `trg_10_state`, `claim_provisioning_job` (`SKIP LOCKED`) | — (routine not exercised by tests) |
| Platform catalog scope NULL/NULL (6) | `*_platform_scope_ck` + platform policies | t02 catalog policy test |
| Published versions freeze entitlements; lock parent (6.2/6.4) | `tg_plan_entitlements_guard` (`FOR SHARE` parent), `trg_40_freeze` | t06 published catalog test |
| Entitlement shape vs feature type; gauge/counter reset (6.4) | `plan_entitlements_shape_ck`, `assert_entitlement_shape` | t06 (via helpers) |
| Feature definition immutable after use (6.3) | `tg_features_definition_guard` | t06 |
| Published price immutable (6.5) | `trg_40_freeze`, `tg_plan_prices_guard` | t06 |
| Provider fields all-or-none; provider customer unique (7.1) | `billing_accounts_provider_all_or_none_ck`, `billing_accounts_provider_customer_uix`, immutable once set | — |
| One live base subscription (7.2) | `subscriptions_one_live_per_tenant_uix` | t06 overlaps test |
| Provider subscription reference unique per provider account (7.2) | `assert_provider_subscription_reference_unique` (advisory lock) on both tables | — |
| No overlapping contract segments; currency = price; retired terms only continue (7.3) | `subscription_periods_no_overlap_ex`, `tg_subscription_periods_guard` | t06 |
| Segments immutable after activation (7.3) | `trg_40_freeze`, `trg_50_delete_scheduled_only` | — |
| Change approval before apply; lock subscription (7.4) | CHECKs, `trg_10_state`, `tg_subscription_changes_guard` | — |
| Override = replacement; no overlapping approved windows; commercial authority only (8.1) | `tenant_entitlement_overrides_no_overlap_ex`, `effective_entitlement`, RLS (runtime read-only) | t06, t02 (tenant admin denied) |
| Allocation sum ≤ entitlement at every boundary; contract changes revalidate (8.2) | `validate_allocations` (advisory lock) from allocation/period/override triggers; `organization_quota_allocations_no_overlap_ex` | t06 concurrent allocation + downgrade test |
| Partitioned capacity: no allocation = zero share (8.2) | `assert_gauge_capacity`, `record_usage_internal` | — |
| Usage idempotency with payload comparison (8.3) | `usage_events_idempotency_uq` + `record_usage_internal` | t06 |
| Corrections negative, same feature/org, bounded by original (8.3) | `usage_events_quantity_sign_ck`, `tg_usage_events_validate` (original row locked) | t06 |
| Counter features only; hard limits | `tg_usage_events_validate`; `quota_counters` row locks | t06 concurrent counter test (20 vs limit 10) |
| Rollups unique incl. NULL org (8.4) | `usage_rollups_window_uq` `NULLS NOT DISTINCT` | t01 |
| Invoice arithmetic; issuance validates lines; snapshot frozen; paid needs reconciled payments (9.1/9.2) | `invoices_total_ck`, `tg_invoices_guard`, `tg_invoice_lines_guard` (invoice locked), `trg_40_freeze` | t06 invoice test |
| Reversals same invoice, ≤ parent, parent succeeded payment (9.3) | `payment_transactions_parent_fk` (tenant, invoice, parent), `tg_payment_transactions_guard` | t06 |
| Provider events idempotent by digest (9.4) | `provider_events_external_uq`, `record_provider_event` | — |
| Gauge quotas enforced (10/11) | `enforce_gauge` triggers on organizations/principals/subtypes/credentials | t06 gauge concurrency + missing entitlement |

## Identity invariants

| Invariant (spec table #) | Mechanism | Test |
|---|---|---|
| Org parent same tenant; no cycles under concurrency (1) | `organizations_parent_fk`, `tg_organizations_hierarchy` | t03 (sequential + concurrent) |
| Principal type immutable; exactly one subtype (2–5) | `trg_20_immutable`, deferred `trg_80_exactly_one_subtype`, `tg_subtype_validate` | t02, t03 |
| Creator human/service; owner human; own membership (4, 5) | `tg_subtype_validate`, `*_self_membership_fk` (deferred) | t03 |
| Membership type matches principal; revoked_at exact (6) | `tg_org_memberships_validate`, `*_revoked_ck`, `tg_maintain_revoked_at` | t03 |
| Team parent same org; no cycles (7) | `teams_parent_fk`, `tg_teams_hierarchy` | t03 |
| Team membership needs active source; source maps same team (8, 9) | `effective_team_ids`, `tg_team_membership_sources_validate`, partial uniques | — |
| team_domains Catalog-backed (10) | **fails closed** `trg_05_catalog_guard` | t04, t08 |
| Permission code/class immutable after use; automation ≠ IAM (11) | `tg_permissions_definition_guard`, `permissions_automation_not_iam_ck` | — |
| Role class immutable after use; role class = permission class (12, 13) | `tg_roles_class_guard`, `tg_role_permissions_validate` | — |
| Scope target shape; immutable; Catalog FKs (14) | `access_scopes_target_shape_ck`, `trg_20_immutable`, **fails closed** for domain/asset | t04, t08 |
| Role binding XOR, org-class only, no duplicates (15) | `role_bindings_recipient_xor_ck`, `tg_role_bindings_validate`, partial uniques | t02 |
| Tenant bindings: tenant_control only, no automations, last admin protected (16) | `tg_tenant_role_bindings_validate`, deferred `trg_81_last_tenant_admin` | t03 |
| Grant shape/subtype; one active delegated per automation; draft-only edits; nonempty; lifetimes (17) | CHECKs, `authorization_grants_one_active_delegated_uix`, `tg_authorization_grants_validate`, `trg_40_freeze` | t03 |
| Entries: active, organization-class, delegable; automation-safe for delegated; parent locked (18) | `tg_grant_permissions_guard` (`FOR UPDATE` parent) | t03 |
| Credential = grantee; expiry ≤ grant; usage ↔ type; no draft/suspended/revoked grants; terminal revocation (19) | `principal_credentials_grant_grantee_fk`, `tg_credentials_validate`, `trg_40_freeze` | t03 |
| Bindings same grant; created with credential; immutable (20) | compound FKs, `tg_credential_bindings_validate`, `trg_05_append_only` | t03 |
| Approval: requester = grantee; approver ≠ requester, human; digest 32 bytes; single use (21) | `action_approvals_grant_grantee_fk`, CHECKs, `tg_action_approvals_validate`, `consume_action_approval` | t05 (incl. concurrent) |
| Provider issuer/protocol immutable once used (22) | `tg_identity_providers_guard` | — |
| External identity linkage immutable (23) | `trg_20_immutable` | — |
| Session shapes; API key never interactive; preserves audience/expiry; grantee = principal (26) | CHECKs, compound FKs, `tg_auth_sessions_validate` | t04 (exchange), t04 (no automation interactive) |
| Audit append-only, no secrets, org validated (27) | `trg_05_append_only`, CHECKs, `write_audit_event`, no runtime DML | t07 |

## Authorization contract (Identity §8)

| Requirement | Implementation | Test |
|---|---|---|
| Interactive human → live RBAC | `evaluate_access` interactive path, `rbac_permits` | t04 |
| Token → grantor ∩ grantee ∩ grant entry ∩ credential subset | `evaluate_access` grant path | t04 |
| Empty subset denies | binding required for credential decisions | t04 |
| Tenant control separate from org data | `tenant_control_permits`; org-null sessions tenant-control only | t04 |
| Automation / automation-usage tokens cannot do IAM | `automation_restricted` | t04 |
| Personal/integration tokens cannot do IAM; only provisioning service credentials | `iam_requires_interactive_or_provisioning` | t04 |
| Narrow credential cannot mint broader authority | credential-envelope checks in `authorize_authorization_grant`, `issue_principal_credential` | — (code path; not separately tested) |
| Revocation effective at next authoritative check | live evaluation, no cache | t04 |
| Approval requirement: strictest applicable entry | `bool_or(requires_human_approval)` over all applicable entries | t05 |

## Gaps and items enforced outside the database

* Group-sync freshness policy, maximum grant lifetimes, organization automation policy → backend with
  secure defaults (Settings not installed).
* Federated token verification, API-key secret generation/digesting, webhook authenticity → backend.
* `claim_provisioning_job`, provider-event intake, provider subscription reference uniqueness,
  subscription changes, and several Identity "immutable after use" guards are implemented but **not
  covered by automated tests** in this delivery (marked "—" above).
* Account expiry of the last tenant administrator via `valid_until` passing is not prevented (time does
  not run triggers); only explicit revocation/disablement is guarded.
* Proration, tax, FX, credit notes and general-ledger posting are out of scope (spec §9).

## Catalog-only dependencies (pending)

`access_scopes.domain_id`, `access_scopes.asset_id`, `team_domains.domain_id` FKs; domain/asset scope
resolution; team-domain requirement for domain/asset team bindings; authorization of Catalog/product
resources. All fail closed now; enabled only by the separately invoked, tested template (t08).
