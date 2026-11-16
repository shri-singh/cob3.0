-- =============================================================================
-- 90  ROW-LEVEL SECURITY AND PRIVILEGES
-- -----------------------------------------------------------------------------
-- Roles:
--   cob3_owner             owns everything; trusted DDL/migration and
--                          SECURITY DEFINER context (explicit *_owner_all
--                          policy; FORCE RLS makes that access explicit).
--   cob3_runtime           customer-facing backend. Non-owner, no BYPASSRLS.
--                          Sees nothing without a valid authenticated
--                          transaction-local context (fail closed).
--   cob3_provisioner       platform onboarding/provisioning workers.
--   cob3_commercial_admin  platform commercial authority and billing workers.
-- Policy predicates wrap context functions in scalar sub-selects so they are
-- evaluated once per statement (initplans), not once per row.
-- Policy names describe intent; correctness is demonstrated by tests, not by
-- the existence of a policy name.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enable + force RLS everywhere; explicit owner policy on every table.
-- ---------------------------------------------------------------------------
FOREACH _i_table IN ARRAY (_i_logical_tables || _i_support_tables) LOOP
    _i_schema := pg_catalog.split_part(_i_table, '.', 1);
    _i_name   := pg_catalog.split_part(_i_table, '.', 2);
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', _i_schema, _i_name);
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', _i_schema, _i_name);
    EXECUTE pg_catalog.format('CREATE POLICY %I ON %I.%I AS PERMISSIVE FOR ALL TO cob3_owner USING (true) WITH CHECK (true)',
                              _i_name || '_owner_all', _i_schema, _i_name);
END LOOP;

-- ===========================================================================
-- cob3_tenant policies
-- ===========================================================================
CREATE POLICY foundation_installations_read ON cob3_tenant.foundation_installations
    FOR SELECT TO PUBLIC USING (true);

CREATE POLICY tenants_runtime_select ON cob3_tenant.tenants FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY tenants_platform_select ON cob3_tenant.tenants FOR SELECT TO cob3_provisioner, cob3_commercial_admin
    USING (true);

CREATE POLICY tenant_contacts_runtime_select ON cob3_tenant.tenant_contacts FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY tenant_contacts_commercial_all ON cob3_tenant.tenant_contacts FOR ALL TO cob3_commercial_admin
    USING (true) WITH CHECK (true);

CREATE POLICY tenant_lifecycle_events_runtime_select ON cob3_tenant.tenant_lifecycle_events FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY tenant_lifecycle_events_platform_select ON cob3_tenant.tenant_lifecycle_events FOR SELECT TO cob3_provisioner, cob3_commercial_admin
    USING (true);

CREATE POLICY provisioning_jobs_provisioner_select ON cob3_tenant.provisioning_jobs FOR SELECT TO cob3_provisioner USING (true);
CREATE POLICY provisioning_jobs_provisioner_insert ON cob3_tenant.provisioning_jobs FOR INSERT TO cob3_provisioner WITH CHECK (true);
CREATE POLICY provisioning_jobs_provisioner_update ON cob3_tenant.provisioning_jobs FOR UPDATE TO cob3_provisioner USING (true) WITH CHECK (true);
CREATE POLICY provisioning_jobs_commercial_select ON cob3_tenant.provisioning_jobs FOR SELECT TO cob3_commercial_admin USING (true);

-- Platform catalog: runtime reads only sellable/published rows with an
-- authenticated tenant context; only commercial authority mutates.
CREATE POLICY plans_runtime_select ON cob3_tenant.plans FOR SELECT TO cob3_runtime
    USING (status = 'active' AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY plans_platform_select ON cob3_tenant.plans FOR SELECT TO cob3_provisioner USING (true);
CREATE POLICY plans_commercial_all ON cob3_tenant.plans FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY plan_versions_runtime_select ON cob3_tenant.plan_versions FOR SELECT TO cob3_runtime
    USING (status = 'published' AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY plan_versions_platform_select ON cob3_tenant.plan_versions FOR SELECT TO cob3_provisioner USING (true);
CREATE POLICY plan_versions_commercial_all ON cob3_tenant.plan_versions FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY features_runtime_select ON cob3_tenant.features FOR SELECT TO cob3_runtime
    USING (status = 'active' AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY features_platform_select ON cob3_tenant.features FOR SELECT TO cob3_provisioner USING (true);
CREATE POLICY features_commercial_all ON cob3_tenant.features FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY plan_entitlements_runtime_select ON cob3_tenant.plan_entitlements FOR SELECT TO cob3_runtime
    USING ((SELECT cob3_identity.ctx_is_tenant_member())
           AND EXISTS (SELECT 1 FROM cob3_tenant.plan_versions v
                        WHERE v.plan_version_id = plan_entitlements.plan_version_id AND v.status = 'published'));
CREATE POLICY plan_entitlements_platform_select ON cob3_tenant.plan_entitlements FOR SELECT TO cob3_provisioner USING (true);
CREATE POLICY plan_entitlements_commercial_all ON cob3_tenant.plan_entitlements FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY plan_prices_runtime_select ON cob3_tenant.plan_prices FOR SELECT TO cob3_runtime
    USING (status = 'published' AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY plan_prices_platform_select ON cob3_tenant.plan_prices FOR SELECT TO cob3_provisioner USING (true);
CREATE POLICY plan_prices_commercial_all ON cob3_tenant.plan_prices FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

-- Tenant-owned commercial records: tenant controllers read their own;
-- platform commercial authority writes (tenant admins cannot self-approve
-- overrides, publish prices or mark invoices paid).
CREATE POLICY billing_accounts_runtime_select ON cob3_tenant.billing_accounts FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY billing_accounts_commercial_all ON cob3_tenant.billing_accounts FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY subscriptions_runtime_select ON cob3_tenant.subscriptions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY subscriptions_commercial_all ON cob3_tenant.subscriptions FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY subscription_periods_runtime_select ON cob3_tenant.subscription_periods FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY subscription_periods_commercial_all ON cob3_tenant.subscription_periods FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY subscription_changes_runtime_select ON cob3_tenant.subscription_changes FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY subscription_changes_commercial_all ON cob3_tenant.subscription_changes FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY tenant_entitlement_overrides_runtime_select ON cob3_tenant.tenant_entitlement_overrides FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY tenant_entitlement_overrides_commercial_all ON cob3_tenant.tenant_entitlement_overrides FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

-- Allocations are a tenant administrator decision within purchased capacity.
CREATE POLICY organization_quota_allocations_runtime_select ON cob3_tenant.organization_quota_allocations FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((SELECT cob3_identity.ctx_is_tenant_controller())
                OR (organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()))));
CREATE POLICY organization_quota_allocations_runtime_insert ON cob3_tenant.organization_quota_allocations FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_organizations')));
CREATE POLICY organization_quota_allocations_runtime_update ON cob3_tenant.organization_quota_allocations FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_organizations')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_organizations')));
CREATE POLICY organization_quota_allocations_commercial_select ON cob3_tenant.organization_quota_allocations FOR SELECT TO cob3_commercial_admin USING (true);

CREATE POLICY usage_events_runtime_select ON cob3_tenant.usage_events FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY usage_events_commercial_select ON cob3_tenant.usage_events FOR SELECT TO cob3_commercial_admin USING (true);

CREATE POLICY usage_rollups_runtime_select ON cob3_tenant.usage_rollups FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY usage_rollups_commercial_all ON cob3_tenant.usage_rollups FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY invoices_runtime_select ON cob3_tenant.invoices FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY invoices_commercial_all ON cob3_tenant.invoices FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY invoice_lines_runtime_select ON cob3_tenant.invoice_lines FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY invoice_lines_commercial_all ON cob3_tenant.invoice_lines FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY payment_transactions_runtime_select ON cob3_tenant.payment_transactions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_controller()));
CREATE POLICY payment_transactions_commercial_all ON cob3_tenant.payment_transactions FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY provider_events_commercial_all ON cob3_tenant.provider_events FOR ALL TO cob3_commercial_admin USING (true) WITH CHECK (true);

CREATE POLICY quota_counters_commercial_select ON cob3_tenant.quota_counters FOR SELECT TO cob3_commercial_admin USING (true);

-- ===========================================================================
-- cob3_identity policies (runtime). Platform roles use routines only.
-- ===========================================================================
CREATE POLICY organizations_runtime_select ON cob3_identity.organizations FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (cob3_identity.ctx_is_member_of(organization_id) OR (SELECT cob3_identity.ctx_is_tenant_controller())));
CREATE POLICY organizations_runtime_insert ON cob3_identity.organizations FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_organizations')));
CREATE POLICY organizations_runtime_update ON cob3_identity.organizations FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_organizations')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_organizations')));

-- Tenant-wide principals are NOT visible to every tenant member.
CREATE POLICY principals_runtime_select ON cob3_identity.principals FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_identity.ctx_can_view_principal(principal_id));
CREATE POLICY principals_runtime_insert ON cob3_identity.principals FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND principal_type = 'human'
                AND ((SELECT cob3_identity.ctx_has_org_permission('organization.manage_members'))
                     OR (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_administrators'))));
CREATE POLICY principals_runtime_update ON cob3_identity.principals FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_identity.ctx_can_manage_principal(principal_id))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_identity.ctx_can_manage_principal(principal_id));

CREATE POLICY user_profiles_runtime_select ON cob3_identity.user_profiles FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_identity.ctx_can_view_principal(principal_id));
CREATE POLICY user_profiles_runtime_insert ON cob3_identity.user_profiles FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_identity.ctx_can_manage_principal(principal_id));
CREATE POLICY user_profiles_runtime_update ON cob3_identity.user_profiles FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()))
                OR cob3_identity.ctx_can_manage_principal(principal_id)))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()))
                     OR cob3_identity.ctx_can_manage_principal(principal_id)));

CREATE POLICY service_accounts_runtime_select ON cob3_identity.service_accounts FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY service_accounts_runtime_update ON cob3_identity.service_accounts FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('service_account.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('service_account.manage')));

CREATE POLICY automation_profiles_runtime_select ON cob3_identity.automation_profiles FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY automation_profiles_runtime_update ON cob3_identity.automation_profiles FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('automation.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('automation.manage')));

CREATE POLICY organization_memberships_runtime_select ON cob3_identity.organization_memberships FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()))
                OR (principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()))
                OR (SELECT cob3_identity.ctx_is_tenant_controller())));
CREATE POLICY organization_memberships_runtime_insert ON cob3_identity.organization_memberships FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND membership_type IN ('employee', 'contractor', 'guest')
                AND (SELECT cob3_identity.ctx_has_org_permission('organization.manage_members')));
CREATE POLICY organization_memberships_runtime_update ON cob3_identity.organization_memberships FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('organization.manage_members')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('organization.manage_members')));

CREATE POLICY teams_runtime_select ON cob3_identity.teams FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY teams_runtime_insert ON cob3_identity.teams FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));
CREATE POLICY teams_runtime_update ON cob3_identity.teams FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));

CREATE POLICY team_memberships_runtime_select ON cob3_identity.team_memberships FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY team_memberships_runtime_insert ON cob3_identity.team_memberships FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));
CREATE POLICY team_memberships_runtime_update ON cob3_identity.team_memberships FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));

CREATE POLICY team_membership_sources_runtime_select ON cob3_identity.team_membership_sources FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY team_membership_sources_runtime_insert ON cob3_identity.team_membership_sources FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));
CREATE POLICY team_membership_sources_runtime_update ON cob3_identity.team_membership_sources FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));

CREATE POLICY team_domains_runtime_select ON cob3_identity.team_domains FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY team_domains_runtime_insert ON cob3_identity.team_domains FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));
CREATE POLICY team_domains_runtime_update ON cob3_identity.team_domains FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));

CREATE POLICY group_team_mappings_runtime_select ON cob3_identity.group_team_mappings FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY group_team_mappings_runtime_insert ON cob3_identity.group_team_mappings FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage'))
                AND (SELECT cob3_identity.ctx_has_org_permission('organization.manage_members')));
CREATE POLICY group_team_mappings_runtime_update ON cob3_identity.group_team_mappings FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('team.manage')));

CREATE POLICY permissions_runtime_select ON cob3_identity.permissions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()));

CREATE POLICY roles_runtime_select ON cob3_identity.roles FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY roles_runtime_insert ON cob3_identity.roles FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND NOT is_system
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_roles')));
CREATE POLICY roles_runtime_update ON cob3_identity.roles FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND NOT is_system
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_roles')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND NOT is_system
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_roles')));

CREATE POLICY role_permissions_runtime_select ON cob3_identity.role_permissions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY role_permissions_runtime_insert ON cob3_identity.role_permissions FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND NOT cob3_identity.role_is_system(tenant_id, role_id)
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_roles')));
CREATE POLICY role_permissions_runtime_delete ON cob3_identity.role_permissions FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND NOT cob3_identity.role_is_system(tenant_id, role_id)
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_roles')));

CREATE POLICY access_scopes_runtime_select ON cob3_identity.access_scopes FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY access_scopes_runtime_insert ON cob3_identity.access_scopes FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('role.assign')));
CREATE POLICY access_scopes_runtime_update ON cob3_identity.access_scopes FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('role.assign')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('role.assign')));

CREATE POLICY role_bindings_runtime_select ON cob3_identity.role_bindings FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org())
           AND (principal_id = (SELECT cob3_identity.ctx_principal_id())
                OR (SELECT cob3_identity.ctx_has_org_permission('role.assign'))
                OR (SELECT cob3_identity.ctx_has_org_permission('audit.read'))));
CREATE POLICY role_bindings_runtime_insert ON cob3_identity.role_bindings FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('role.assign')));
CREATE POLICY role_bindings_runtime_update ON cob3_identity.role_bindings FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('role.assign')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('role.assign')));

CREATE POLICY tenant_role_bindings_runtime_select ON cob3_identity.tenant_role_bindings FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()))
                OR (SELECT cob3_identity.ctx_is_tenant_controller())));
CREATE POLICY tenant_role_bindings_runtime_insert ON cob3_identity.tenant_role_bindings FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_administrators')));
CREATE POLICY tenant_role_bindings_runtime_update ON cob3_identity.tenant_role_bindings FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_administrators')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_administrators')));

-- Grants, entries, credentials, bindings, approvals: read with need-to-know;
-- writes only through routines.
CREATE POLICY authorization_grants_runtime_select ON cob3_identity.authorization_grants FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND cob3_identity.ctx_can_view_grant(organization_id, authorization_grant_id));
CREATE POLICY authorization_grant_permissions_runtime_select ON cob3_identity.authorization_grant_permissions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND cob3_identity.ctx_can_view_grant(organization_id, authorization_grant_id));
CREATE POLICY principal_credentials_runtime_select ON cob3_identity.principal_credentials FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND cob3_identity.ctx_can_view_credential(organization_id, credential_id));
CREATE POLICY credential_permission_bindings_runtime_select ON cob3_identity.credential_permission_bindings FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND cob3_identity.ctx_can_view_credential(organization_id, credential_id));
CREATE POLICY action_approvals_runtime_select ON cob3_identity.action_approvals FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org())
           AND (requesting_principal_id = (SELECT cob3_identity.ctx_principal_id())
                OR decided_by_principal_id = (SELECT cob3_identity.ctx_principal_id())
                OR (SELECT cob3_identity.ctx_has_org_permission('action.approve'))
                OR (SELECT cob3_identity.ctx_has_org_permission('audit.read'))));

-- Federation: trust configuration is tenant-control administration.
CREATE POLICY identity_providers_runtime_select ON cob3_identity.identity_providers FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY identity_providers_runtime_insert ON cob3_identity.identity_providers FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')));
CREATE POLICY identity_providers_runtime_update ON cob3_identity.identity_providers FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')));

CREATE POLICY external_identities_runtime_select ON cob3_identity.external_identities FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()))
                OR (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers'))));
CREATE POLICY external_identities_runtime_insert ON cob3_identity.external_identities FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')));
CREATE POLICY external_identities_runtime_update ON cob3_identity.external_identities FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')));

CREATE POLICY external_groups_runtime_select ON cob3_identity.external_groups FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()));
CREATE POLICY external_groups_runtime_insert ON cob3_identity.external_groups FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')));
CREATE POLICY external_groups_runtime_update ON cob3_identity.external_groups FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_identity_providers')));

-- Sessions: own sessions, or tenant administrators. Digest columns are not
-- granted to the runtime at all (column privileges below).
CREATE POLICY auth_sessions_runtime_select ON cob3_identity.auth_sessions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()))
                OR (SELECT cob3_identity.ctx_has_tenant_permission('tenant.manage_administrators'))));

-- Audit: organization audit readers see their organization; tenant
-- controllers see tenant-level (organization-less) events.
CREATE POLICY audit_events_runtime_select ON cob3_identity.audit_events FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((organization_id = (SELECT cob3_identity.ctx_organization_id())
                 AND (SELECT cob3_identity.ctx_has_org_permission('audit.read')))
                OR (organization_id IS NULL AND (SELECT cob3_identity.ctx_is_tenant_controller()))));

-- ===========================================================================
-- PRIVILEGES
-- ===========================================================================
REVOKE ALL ON ALL TABLES IN SCHEMA cob3_tenant, cob3_identity FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA cob3_tenant, cob3_identity FROM PUBLIC;

GRANT USAGE ON SCHEMA cob3_tenant, cob3_identity TO cob3_runtime, cob3_provisioner, cob3_commercial_admin;
GRANT SELECT ON cob3_tenant.foundation_installations TO PUBLIC;

-- Context/stamping helpers are needed by every writer (RLS predicates and
-- invoker triggers run as the calling role).
GRANT EXECUTE ON FUNCTION
    cob3_identity.ctx_uuid(text), cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(),
    cob3_identity.ctx_principal_id(), cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(),
    cob3_identity.ctx_actor(), cob3_identity.set_request_context(uuid, uuid, uuid, uuid, uuid),
    cob3_identity.clear_request_context(), cob3_identity.set_system_context(text),
    cob3_identity.assert_catalog_domain(uuid, uuid, uuid), cob3_identity.assert_catalog_asset(uuid, uuid, uuid),
    cob3_identity.catalog_integration_installed()
    TO cob3_runtime, cob3_provisioner, cob3_commercial_admin;

-- ---------------------------------------------------------------------------
-- cob3_runtime
-- ---------------------------------------------------------------------------
GRANT SELECT ON
    cob3_tenant.tenants, cob3_tenant.tenant_contacts, cob3_tenant.tenant_lifecycle_events,
    cob3_tenant.plans, cob3_tenant.plan_versions, cob3_tenant.features, cob3_tenant.plan_entitlements, cob3_tenant.plan_prices,
    cob3_tenant.billing_accounts, cob3_tenant.subscriptions, cob3_tenant.subscription_periods, cob3_tenant.subscription_changes,
    cob3_tenant.tenant_entitlement_overrides, cob3_tenant.organization_quota_allocations,
    cob3_tenant.usage_events, cob3_tenant.usage_rollups, cob3_tenant.invoices, cob3_tenant.invoice_lines,
    cob3_tenant.payment_transactions
    TO cob3_runtime;
GRANT INSERT, UPDATE ON cob3_tenant.organization_quota_allocations TO cob3_runtime;

GRANT SELECT ON
    cob3_identity.organizations, cob3_identity.principals, cob3_identity.user_profiles, cob3_identity.service_accounts,
    cob3_identity.automation_profiles, cob3_identity.organization_memberships, cob3_identity.teams,
    cob3_identity.team_memberships, cob3_identity.team_membership_sources, cob3_identity.team_domains,
    cob3_identity.permissions, cob3_identity.roles, cob3_identity.role_permissions, cob3_identity.access_scopes,
    cob3_identity.role_bindings, cob3_identity.tenant_role_bindings, cob3_identity.authorization_grants,
    cob3_identity.authorization_grant_permissions, cob3_identity.credential_permission_bindings,
    cob3_identity.action_approvals, cob3_identity.identity_providers, cob3_identity.external_identities,
    cob3_identity.external_groups, cob3_identity.group_team_mappings, cob3_identity.audit_events
    TO cob3_runtime;
-- Secret digests are never readable by the runtime role.
GRANT SELECT (tenant_id, credential_id, organization_id, principal_id, authorization_grant_id, credential_name,
              credential_usage, public_identifier, digest_algorithm, audience, status, expires_at, last_used_at,
              revoked_at, created_at, created_by, updated_at, updated_by, metadata, row_version)
    ON cob3_identity.principal_credentials TO cob3_runtime;
GRANT SELECT (tenant_id, session_id, organization_id, principal_id, session_kind, authentication_method,
              external_identity_id, authorization_grant_id, credential_id, audience, auth_version_at_issue,
              authenticated_at, expires_at, revoked_at, last_seen_at, ip_address, user_agent,
              created_at, created_by, updated_at, updated_by, metadata, row_version)
    ON cob3_identity.auth_sessions TO cob3_runtime;

GRANT INSERT, UPDATE ON
    cob3_identity.organizations, cob3_identity.user_profiles, cob3_identity.organization_memberships,
    cob3_identity.teams, cob3_identity.team_memberships, cob3_identity.team_membership_sources, cob3_identity.team_domains,
    cob3_identity.roles, cob3_identity.identity_providers, cob3_identity.external_identities,
    cob3_identity.external_groups, cob3_identity.group_team_mappings, cob3_identity.role_bindings,
    cob3_identity.tenant_role_bindings, cob3_identity.access_scopes
    TO cob3_runtime;
GRANT INSERT ON cob3_identity.principals TO cob3_runtime;
GRANT UPDATE (display_name, status, auth_version, metadata, updated_by) ON cob3_identity.principals TO cob3_runtime;
GRANT INSERT, DELETE ON cob3_identity.role_permissions TO cob3_runtime;
GRANT UPDATE (owner_principal_id, purpose, expires_at, metadata, updated_by) ON cob3_identity.service_accounts TO cob3_runtime;
GRANT UPDATE (owner_principal_id, purpose, automation_category, expires_at, metadata, updated_by) ON cob3_identity.automation_profiles TO cob3_runtime;

GRANT EXECUTE ON FUNCTION
    cob3_identity.ctx_auth_valid(), cob3_identity.ctx_is_tenant_member(), cob3_identity.ctx_is_interactive(),
    cob3_identity.ctx_in_org(), cob3_identity.ctx_is_member_of(uuid), cob3_identity.ctx_is_tenant_controller(),
    cob3_identity.ctx_has_org_permission(text), cob3_identity.ctx_has_tenant_permission(text),
    cob3_identity.ctx_can_view_principal(uuid), cob3_identity.ctx_can_manage_principal(uuid),
    cob3_identity.ctx_can_view_grant(uuid, uuid), cob3_identity.ctx_can_view_credential(uuid, uuid),
    cob3_identity.role_is_system(uuid, uuid),
    cob3_identity.evaluate_access(uuid, uuid, uuid, uuid, uuid, text, text, uuid, timestamptz, uuid),
    cob3_identity.record_audit_event(text, text, uuid, text, text, jsonb, uuid, text, inet, uuid, uuid, uuid, uuid, uuid),
    cob3_identity.create_service_account(text, text, uuid, text, timestamptz),
    cob3_identity.create_automation(text, text, uuid, text, text, text, timestamptz),
    cob3_identity.create_authorization_grant(uuid, uuid, text, timestamptz, timestamptz, text),
    cob3_identity.add_authorization_grant_permission(uuid, text, uuid, boolean),
    cob3_identity.authorize_authorization_grant(uuid),
    cob3_identity.set_authorization_grant_status(uuid, text, text),
    cob3_identity.issue_principal_credential(uuid, text, text, text, bytea, text, text, timestamptz, uuid[]),
    cob3_identity.revoke_principal_credential(uuid, text),
    cob3_identity.verify_api_key(uuid, text, bytea, text),
    cob3_identity.open_interactive_session(uuid, uuid, text, uuid, bytea, bytea, text, timestamptz, timestamptz, inet, text),
    cob3_identity.open_api_key_session(uuid, text, bytea, text, bytea, timestamptz, inet, text),
    cob3_identity.revoke_session(uuid),
    cob3_identity.request_action_approval(uuid, uuid, text, uuid, bytea, timestamptz),
    cob3_identity.decide_action_approval(uuid, boolean),
    cob3_identity.consume_action_approval(uuid, bytea),
    cob3_identity.lookup_identity_providers(uuid),
    cob3_tenant.resolve_entitlement(text, timestamptz),
    cob3_tenant.record_usage_event(text, text, text, timestamptz, numeric, uuid, uuid, uuid, boolean)
    TO cob3_runtime;

-- ---------------------------------------------------------------------------
-- cob3_provisioner
-- ---------------------------------------------------------------------------
GRANT SELECT ON cob3_tenant.tenants, cob3_tenant.tenant_lifecycle_events,
                cob3_tenant.plans, cob3_tenant.plan_versions, cob3_tenant.features,
                cob3_tenant.plan_entitlements, cob3_tenant.plan_prices
    TO cob3_provisioner;
GRANT SELECT, INSERT, UPDATE ON cob3_tenant.provisioning_jobs TO cob3_provisioner;
GRANT EXECUTE ON FUNCTION
    cob3_tenant.create_tenant(text, text, text, text, uuid, text, text),
    cob3_tenant.transition_tenant_status(uuid, text, text, uuid, text, text, uuid),
    cob3_tenant.claim_provisioning_job(text[], interval, text),
    cob3_tenant.resolve_tenant_entitlement(uuid, text, timestamptz),
    cob3_identity.bootstrap_tenant(text, text, text, text, text, text, text, text, text, uuid, boolean, text),
    cob3_identity.bootstrap_tenant_administration(uuid, text, text, text, text, text, text),
    cob3_identity.provision_tenant_iam_seed(uuid, text),
    cob3_identity.register_tenant_permission(uuid, text, text, text, text, boolean, boolean, boolean, text, text),
    cob3_identity.register_tenant_role(uuid, text, text, text, text, text),
    cob3_identity.add_role_permission(uuid, text, text, text),
    cob3_identity.core_permission_templates(), cob3_identity.core_role_templates(),
    cob3_identity.bootstrap_identity_provider(uuid, text, text, text, text, text, text),
    cob3_identity.bootstrap_link_external_identity(uuid, uuid, uuid, text, text),
    cob3_identity.record_platform_audit_event(uuid, uuid, text, text, text, uuid, text, text, jsonb, uuid, text)
    TO cob3_provisioner;

-- ---------------------------------------------------------------------------
-- cob3_commercial_admin
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA cob3_tenant TO cob3_commercial_admin;
GRANT INSERT, UPDATE ON
    cob3_tenant.plans, cob3_tenant.plan_versions, cob3_tenant.features, cob3_tenant.plan_entitlements, cob3_tenant.plan_prices,
    cob3_tenant.tenant_contacts, cob3_tenant.billing_accounts, cob3_tenant.subscriptions, cob3_tenant.subscription_periods,
    cob3_tenant.subscription_changes, cob3_tenant.tenant_entitlement_overrides, cob3_tenant.usage_rollups,
    cob3_tenant.invoices, cob3_tenant.invoice_lines, cob3_tenant.payment_transactions, cob3_tenant.provider_events
    TO cob3_commercial_admin;
GRANT DELETE ON cob3_tenant.plan_entitlements, cob3_tenant.plan_prices, cob3_tenant.subscription_periods,
                cob3_tenant.invoices, cob3_tenant.invoice_lines, cob3_tenant.usage_rollups
    TO cob3_commercial_admin;
GRANT EXECUTE ON FUNCTION
    cob3_tenant.resolve_tenant_entitlement(uuid, text, timestamptz),
    cob3_tenant.record_platform_usage_event(uuid, text, text, text, timestamptz, numeric, uuid, uuid, uuid, boolean),
    cob3_tenant.record_provider_event(uuid, text, text, text, text, timestamptz, bytea, text),
    cob3_identity.record_platform_audit_event(uuid, uuid, text, text, text, uuid, text, text, jsonb, uuid, text)
    TO cob3_commercial_admin;
