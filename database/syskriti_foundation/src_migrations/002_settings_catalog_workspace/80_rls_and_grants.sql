-- =============================================================================
-- 80  ROW-LEVEL SECURITY AND PRIVILEGES
-- -----------------------------------------------------------------------------
-- Same model as foundation 90_*: RLS enabled AND forced everywhere, explicit
-- owner policy, command-specific runtime policies, no BYPASSRLS anywhere.
--   cob3_runtime : authenticated request context (set_request_context);
--                  private content needs a live permission on the exact asset
--                  (tenant/org filtering alone never opens drafts, emails or
--                  private artifacts).
--   cob3_worker  : trusted background workers inside ONE worker scope
--                  (set_worker_context): rows of that tenant whose
--                  organization is NULL or the scope organization.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Workspace policy helpers (exact-asset permission through the parent row).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_workspace.ctx_project_permitted(p_organization_id uuid, p_project_id uuid, p_permission_code text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((SELECT cob3_catalog.ctx_asset_permitted(p.organization_id, p.asset_id, p_permission_code)
                       FROM cob3_workspace.projects p
                      WHERE p.tenant_id = cob3_identity.ctx_tenant_id() AND p.organization_id = p_organization_id
                        AND p.project_id = p_project_id), false)
$fn$;

CREATE FUNCTION cob3_workspace.ctx_artifact_permitted(p_organization_id uuid, p_artifact_id uuid, p_permission_code text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((SELECT cob3_catalog.ctx_asset_permitted(a.organization_id, a.asset_id, p_permission_code)
                       FROM cob3_workspace.artifacts a
                      WHERE a.tenant_id = cob3_identity.ctx_tenant_id() AND a.organization_id = p_organization_id
                        AND a.artifact_id = p_artifact_id), false)
$fn$;

CREATE FUNCTION cob3_workspace.ctx_schedule_permitted(p_organization_id uuid, p_report_schedule_id uuid, p_permission_code text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((SELECT cob3_workspace.ctx_artifact_permitted(s.organization_id, s.artifact_id, p_permission_code)
                       FROM cob3_workspace.report_schedules s
                      WHERE s.tenant_id = cob3_identity.ctx_tenant_id() AND s.organization_id = p_organization_id
                        AND s.report_schedule_id = p_report_schedule_id), false)
$fn$;

-- File access derives from an authorized referencing revision or report
-- output (or being the uploader), never from file id possession.
CREATE FUNCTION cob3_workspace.ctx_can_read_file(p_organization_id uuid, p_file_object_id uuid, p_uploaded_by uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p_uploaded_by = cob3_identity.ctx_principal_id()
        OR EXISTS (SELECT 1 FROM cob3_workspace.artifact_revisions r
                    WHERE r.tenant_id = cob3_identity.ctx_tenant_id() AND r.organization_id = p_organization_id
                      AND r.file_object_id = p_file_object_id
                      AND cob3_workspace.ctx_artifact_permitted(r.organization_id, r.artifact_id, 'artifact.read'))
        OR EXISTS (SELECT 1 FROM cob3_workspace.report_runs rr
                     JOIN cob3_workspace.report_schedules s
                       ON s.tenant_id = rr.tenant_id AND s.organization_id = rr.organization_id AND s.report_schedule_id = rr.report_schedule_id
                    WHERE rr.tenant_id = cob3_identity.ctx_tenant_id() AND rr.organization_id = p_organization_id
                      AND rr.output_file_id = p_file_object_id
                      AND cob3_workspace.ctx_artifact_permitted(s.organization_id, s.artifact_id, 'artifact.read')
                      AND (cob3_workspace.ctx_artifact_permitted(s.organization_id, s.artifact_id, 'report.run')
                           OR EXISTS (SELECT 1 FROM cob3_workspace.report_recipients rc
                                       WHERE rc.tenant_id = s.tenant_id AND rc.organization_id = s.organization_id
                                         AND rc.report_schedule_id = s.report_schedule_id AND rc.status = 'active'
                                         AND rc.recipient_principal_id = cob3_identity.ctx_principal_id())))
$fn$;

-- ---------------------------------------------------------------------------
-- Enable + force RLS everywhere; owner policy; worker read within its scope.
-- ---------------------------------------------------------------------------
FOREACH _m_table IN ARRAY _m_tables LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', _m_schema, _m_name);
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', _m_schema, _m_name);
    EXECUTE pg_catalog.format('CREATE POLICY %I ON %I.%I AS PERMISSIVE FOR ALL TO cob3_owner USING (true) WITH CHECK (true)',
                              _m_name || '_owner_all', _m_schema, _m_name);
    IF _m_table IN ('cob3_settings.setting_definitions', 'cob3_catalog.asset_types') THEN
        EXECUTE pg_catalog.format('CREATE POLICY %I ON %I.%I FOR SELECT TO cob3_worker USING ((SELECT cob3_identity.ctx_is_worker()))',
                                  _m_name || '_worker_select', _m_schema, _m_name);
    ELSE
        EXECUTE pg_catalog.format(
            'CREATE POLICY %I ON %I.%I FOR SELECT TO cob3_worker USING ((SELECT cob3_identity.ctx_is_worker())'
            ' AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())'
            ' AND (organization_id IS NULL OR organization_id = (SELECT cob3_identity.ctx_organization_id())))',
            _m_name || '_worker_select', _m_schema, _m_name);
    END IF;
END LOOP;

-- ===========================================================================
-- cob3_identity additions
-- ===========================================================================
CREATE POLICY principal_emails_runtime_select ON cob3_identity.principal_emails FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_tenant_member()))
                OR cob3_identity.ctx_can_manage_principal(principal_id)));
CREATE POLICY principal_emails_runtime_insert ON cob3_identity.principal_emails FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_interactive()))
                     OR cob3_identity.ctx_can_manage_principal(principal_id)));
CREATE POLICY principal_emails_runtime_update ON cob3_identity.principal_emails FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_interactive()))
                OR cob3_identity.ctx_can_manage_principal(principal_id)))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND ((principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_is_interactive()))
                     OR cob3_identity.ctx_can_manage_principal(principal_id)));
-- email_verification_challenges: no runtime policy; routines only.

-- ===========================================================================
-- cob3_settings
-- ===========================================================================
CREATE POLICY setting_definitions_runtime_select ON cob3_settings.setting_definitions FOR SELECT TO cob3_runtime
    USING (status = 'active' AND (SELECT cob3_identity.ctx_is_tenant_member()));

CREATE POLICY setting_scopes_runtime_select ON cob3_settings.setting_scopes FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'read'));

CREATE POLICY setting_values_runtime_select ON cob3_settings.setting_values FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'read'));
CREATE POLICY setting_values_runtime_insert ON cob3_settings.setting_values FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write')
                AND (NOT is_locked OR cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'lock')));
CREATE POLICY setting_values_runtime_update ON cob3_settings.setting_values FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write')
           AND (NOT is_locked OR cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'lock')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write')
                AND (NOT is_locked OR cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'lock')));
CREATE POLICY setting_values_runtime_delete ON cob3_settings.setting_values FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write')
           AND (NOT is_locked OR cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'lock')));

CREATE POLICY setting_change_events_runtime_select ON cob3_settings.setting_change_events FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'read'));

CREATE POLICY media_objects_runtime_select ON cob3_settings.media_objects FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_can_view_media(tenant_id, setting_scope_id, status));
CREATE POLICY media_objects_runtime_insert ON cob3_settings.media_objects FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND uploaded_by_principal_id = (SELECT cob3_identity.ctx_principal_id())
                AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));
CREATE POLICY media_objects_runtime_update ON cob3_settings.media_objects FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));
CREATE POLICY media_objects_worker_update ON cob3_settings.media_objects FOR UPDATE TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id()))
    WITH CHECK ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id()));

CREATE POLICY branding_profiles_runtime_select ON cob3_settings.branding_profiles FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'read'));
CREATE POLICY branding_profiles_runtime_insert ON cob3_settings.branding_profiles FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));
CREATE POLICY branding_profiles_runtime_update ON cob3_settings.branding_profiles FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));
CREATE POLICY branding_profiles_runtime_delete ON cob3_settings.branding_profiles FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));

CREATE POLICY contact_addresses_runtime_select ON cob3_settings.contact_addresses FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY contact_addresses_runtime_insert ON cob3_settings.contact_addresses FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (verified_by_principal_id IS NULL OR verified_by_principal_id = (SELECT cob3_identity.ctx_principal_id()))
                AND CASE WHEN team_id IS NULL THEN (SELECT cob3_identity.ctx_has_org_permission('settings.manage_organization'))
                         ELSE (SELECT cob3_identity.ctx_has_org_permission('settings.manage_team')) END);
CREATE POLICY contact_addresses_runtime_update ON cob3_settings.contact_addresses FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND CASE WHEN team_id IS NULL THEN (SELECT cob3_identity.ctx_has_org_permission('settings.manage_organization'))
                    ELSE (SELECT cob3_identity.ctx_has_org_permission('settings.manage_team')) END)
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (verified_by_principal_id IS NULL OR verified_by_principal_id = (SELECT cob3_identity.ctx_principal_id()))
                AND CASE WHEN team_id IS NULL THEN (SELECT cob3_identity.ctx_has_org_permission('settings.manage_organization'))
                         ELSE (SELECT cob3_identity.ctx_has_org_permission('settings.manage_team')) END);

CREATE POLICY notification_endpoints_runtime_select ON cob3_settings.notification_endpoints FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'read'));
CREATE POLICY notification_endpoints_runtime_insert ON cob3_settings.notification_endpoints FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write')
                AND (endpoint_type <> 'webhook' OR cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'integration')));
CREATE POLICY notification_endpoints_runtime_update ON cob3_settings.notification_endpoints FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write')
           AND (endpoint_type <> 'webhook' OR cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'integration')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write')
                AND (endpoint_type <> 'webhook' OR cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'integration')));

CREATE POLICY notification_preferences_runtime_select ON cob3_settings.notification_preferences FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'read'));
CREATE POLICY notification_preferences_runtime_insert ON cob3_settings.notification_preferences FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));
CREATE POLICY notification_preferences_runtime_update ON cob3_settings.notification_preferences FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));
CREATE POLICY notification_preferences_runtime_delete ON cob3_settings.notification_preferences FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'write'));

CREATE POLICY integration_configurations_runtime_select ON cob3_settings.integration_configurations FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'integration'));
CREATE POLICY integration_configurations_runtime_insert ON cob3_settings.integration_configurations FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'integration'));
CREATE POLICY integration_configurations_runtime_update ON cob3_settings.integration_configurations FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'integration'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND cob3_settings.ctx_scope_access(tenant_id, setting_scope_id, 'integration'));

CREATE POLICY automation_policies_runtime_select ON cob3_settings.automation_policies FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND (organization_id IS NULL OR organization_id = (SELECT cob3_identity.ctx_organization_id()))
           AND ((SELECT cob3_identity.ctx_has_tenant_permission('settings.manage_tenant'))
                OR (SELECT cob3_identity.ctx_has_org_permission('settings.manage_policy'))));
CREATE POLICY automation_policies_runtime_insert ON cob3_settings.automation_policies FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND CASE WHEN organization_id IS NULL THEN (SELECT cob3_identity.ctx_has_tenant_permission('settings.manage_tenant'))
                         ELSE organization_id = (SELECT cob3_identity.ctx_organization_id())
                              AND (SELECT cob3_identity.ctx_has_org_permission('settings.manage_policy')) END);
CREATE POLICY automation_policies_runtime_update ON cob3_settings.automation_policies FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND CASE WHEN organization_id IS NULL THEN (SELECT cob3_identity.ctx_has_tenant_permission('settings.manage_tenant'))
                    ELSE organization_id = (SELECT cob3_identity.ctx_organization_id())
                         AND (SELECT cob3_identity.ctx_has_org_permission('settings.manage_policy')) END)
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND CASE WHEN organization_id IS NULL THEN (SELECT cob3_identity.ctx_has_tenant_permission('settings.manage_tenant'))
                         ELSE organization_id = (SELECT cob3_identity.ctx_organization_id())
                              AND (SELECT cob3_identity.ctx_has_org_permission('settings.manage_policy')) END);

-- ===========================================================================
-- cob3_catalog
-- ===========================================================================
CREATE POLICY asset_types_runtime_select ON cob3_catalog.asset_types FOR SELECT TO cob3_runtime
    USING (status = 'active' AND (SELECT cob3_identity.ctx_is_tenant_member()));

CREATE POLICY domains_runtime_select ON cob3_catalog.domains FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()));
CREATE POLICY domains_runtime_insert ON cob3_catalog.domains FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')));
CREATE POLICY domains_runtime_update ON cob3_catalog.domains FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')));

CREATE POLICY assets_runtime_select ON cob3_catalog.assets FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_readable(organization_id, asset_id));
CREATE POLICY assets_runtime_insert ON cob3_catalog.assets FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')));
CREATE POLICY assets_runtime_update ON cob3_catalog.assets FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_writable(organization_id, asset_id))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_catalog.ctx_asset_writable(organization_id, asset_id));

CREATE POLICY asset_ownerships_runtime_select ON cob3_catalog.asset_ownerships FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_readable(organization_id, asset_id));
CREATE POLICY asset_ownerships_runtime_insert ON cob3_catalog.asset_ownerships FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'asset.share')
                     OR (SELECT cob3_identity.ctx_has_org_permission('catalog.manage'))));
CREATE POLICY asset_ownerships_runtime_update ON cob3_catalog.asset_ownerships FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'asset.share')
                OR (SELECT cob3_identity.ctx_has_org_permission('catalog.manage'))))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'asset.share')
                     OR (SELECT cob3_identity.ctx_has_org_permission('catalog.manage'))));

CREATE POLICY asset_external_identifiers_runtime_select ON cob3_catalog.asset_external_identifiers FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_readable(organization_id, asset_id));
CREATE POLICY asset_external_identifiers_runtime_insert ON cob3_catalog.asset_external_identifiers FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')));

CREATE POLICY asset_locations_runtime_select ON cob3_catalog.asset_locations FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_readable(organization_id, asset_id));
CREATE POLICY asset_locations_runtime_insert ON cob3_catalog.asset_locations FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_catalog.ctx_asset_writable(organization_id, asset_id));
CREATE POLICY asset_locations_runtime_update ON cob3_catalog.asset_locations FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_writable(organization_id, asset_id))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_catalog.ctx_asset_writable(organization_id, asset_id));

CREATE POLICY asset_relationships_runtime_select ON cob3_catalog.asset_relationships FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_readable(organization_id, source_asset_id)
           AND cob3_catalog.ctx_asset_readable(organization_id, target_asset_id));
CREATE POLICY asset_relationships_runtime_insert ON cob3_catalog.asset_relationships FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_catalog.ctx_asset_writable(organization_id, source_asset_id)
                AND cob3_catalog.ctx_asset_readable(organization_id, target_asset_id));
CREATE POLICY asset_relationships_runtime_update ON cob3_catalog.asset_relationships FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_writable(organization_id, source_asset_id))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_catalog.ctx_asset_writable(organization_id, source_asset_id));

CREATE POLICY tags_runtime_select ON cob3_catalog.tags FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org())
           AND (visibility = 'organization' OR owner_principal_id = (SELECT cob3_identity.ctx_principal_id())));
CREATE POLICY tags_runtime_insert ON cob3_catalog.tags FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org())
                AND CASE WHEN visibility = 'private' THEN owner_principal_id = (SELECT cob3_identity.ctx_principal_id())
                         ELSE (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')) END);
CREATE POLICY tags_runtime_update ON cob3_catalog.tags FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org())
           AND CASE WHEN visibility = 'private' THEN owner_principal_id = (SELECT cob3_identity.ctx_principal_id())
                    ELSE (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')) END)
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND CASE WHEN visibility = 'private' THEN owner_principal_id = (SELECT cob3_identity.ctx_principal_id())
                         ELSE (SELECT cob3_identity.ctx_has_org_permission('catalog.manage')) END);

CREATE POLICY asset_tags_runtime_select ON cob3_catalog.asset_tags FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_readable(organization_id, asset_id)
           AND EXISTS (SELECT 1 FROM cob3_catalog.tags g
                        WHERE g.tenant_id = asset_tags.tenant_id AND g.organization_id = asset_tags.organization_id
                          AND g.tag_id = asset_tags.tag_id));
CREATE POLICY asset_tags_runtime_insert ON cob3_catalog.asset_tags FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND applied_by_principal_id = (SELECT cob3_identity.ctx_principal_id())
                AND cob3_catalog.ctx_asset_readable(organization_id, asset_id)
                AND EXISTS (SELECT 1 FROM cob3_catalog.tags g
                             WHERE g.tenant_id = asset_tags.tenant_id AND g.organization_id = asset_tags.organization_id
                               AND g.tag_id = asset_tags.tag_id
                               AND (g.visibility = 'private' OR cob3_catalog.ctx_asset_writable(asset_tags.organization_id, asset_tags.asset_id))));
CREATE POLICY asset_tags_runtime_delete ON cob3_catalog.asset_tags FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND EXISTS (SELECT 1 FROM cob3_catalog.tags g
                        WHERE g.tenant_id = asset_tags.tenant_id AND g.organization_id = asset_tags.organization_id
                          AND g.tag_id = asset_tags.tag_id
                          AND (g.visibility = 'private' OR cob3_catalog.ctx_asset_writable(asset_tags.organization_id, asset_tags.asset_id))));

CREATE POLICY asset_metadata_versions_runtime_select ON cob3_catalog.asset_metadata_versions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_readable(organization_id, asset_id));

-- ===========================================================================
-- cob3_workspace
-- ===========================================================================
CREATE POLICY projects_runtime_select ON cob3_workspace.projects FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'project.read'));
CREATE POLICY projects_runtime_update ON cob3_workspace.projects FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'project.update'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'project.update'));

CREATE POLICY folders_runtime_select ON cob3_workspace.folders FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_workspace.ctx_project_permitted(organization_id, project_id, 'project.read'));
CREATE POLICY folders_runtime_insert ON cob3_workspace.folders FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_workspace.ctx_project_permitted(organization_id, project_id, 'project.update'));
CREATE POLICY folders_runtime_update ON cob3_workspace.folders FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_workspace.ctx_project_permitted(organization_id, project_id, 'project.update'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_workspace.ctx_project_permitted(organization_id, project_id, 'project.update'));

CREATE POLICY artifacts_runtime_select ON cob3_workspace.artifacts FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'artifact.read'));
CREATE POLICY artifacts_runtime_update ON cob3_workspace.artifacts FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'artifact.update'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'artifact.update'));

CREATE POLICY file_objects_runtime_select ON cob3_workspace.file_objects FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org())
           AND cob3_workspace.ctx_can_read_file(organization_id, file_object_id, uploaded_by_principal_id));
CREATE POLICY file_objects_runtime_insert ON cob3_workspace.file_objects FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org())
                AND uploaded_by_principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY file_objects_runtime_update ON cob3_workspace.file_objects FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND uploaded_by_principal_id = (SELECT cob3_identity.ctx_principal_id()))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND uploaded_by_principal_id = (SELECT cob3_identity.ctx_principal_id()));

CREATE POLICY artifact_revisions_runtime_select ON cob3_workspace.artifact_revisions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_workspace.ctx_artifact_permitted(organization_id, artifact_id, 'artifact.read'));

-- Personal rows: owner only (drafts additionally need current edit permission).
CREATE POLICY artifact_drafts_runtime_all ON cob3_workspace.artifact_drafts FOR ALL TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id())
           AND cob3_workspace.ctx_artifact_permitted(organization_id, artifact_id, 'artifact.update'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id())
                AND cob3_workspace.ctx_artifact_permitted(organization_id, artifact_id, 'artifact.update'));

CREATE POLICY bookmarks_runtime_select ON cob3_workspace.bookmarks FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY bookmarks_runtime_insert ON cob3_workspace.bookmarks FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_in_org())
                AND (target_asset_id IS NULL OR cob3_catalog.ctx_asset_readable(organization_id, target_asset_id)));
CREATE POLICY bookmarks_runtime_update ON cob3_workspace.bookmarks FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY bookmarks_runtime_delete ON cob3_workspace.bookmarks FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));

CREATE POLICY recent_items_runtime_select ON cob3_workspace.recent_items FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY recent_items_runtime_insert ON cob3_workspace.recent_items FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id()) AND (SELECT cob3_identity.ctx_in_org())
                AND cob3_catalog.ctx_asset_readable(organization_id, target_asset_id));
CREATE POLICY recent_items_runtime_update ON cob3_workspace.recent_items FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY recent_items_runtime_delete ON cob3_workspace.recent_items FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));

CREATE POLICY ui_sessions_runtime_select ON cob3_workspace.ui_sessions FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY ui_sessions_runtime_insert ON cob3_workspace.ui_sessions FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id())
                AND auth_session_id = (SELECT cob3_identity.ctx_session_id()) AND (SELECT cob3_identity.ctx_is_interactive()));
CREATE POLICY ui_sessions_runtime_update ON cob3_workspace.ui_sessions FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY ui_sessions_runtime_delete ON cob3_workspace.ui_sessions FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));

CREATE POLICY interaction_journeys_runtime_select ON cob3_workspace.interaction_journeys FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY interaction_journeys_runtime_insert ON cob3_workspace.interaction_journeys FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY interaction_journeys_runtime_update ON cob3_workspace.interaction_journeys FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id()));

CREATE POLICY interaction_events_runtime_select ON cob3_workspace.interaction_events FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY interaction_events_runtime_insert ON cob3_workspace.interaction_events FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND principal_id = (SELECT cob3_identity.ctx_principal_id())
                AND (target_asset_id IS NULL OR cob3_catalog.ctx_asset_readable(organization_id, target_asset_id)));

CREATE POLICY interaction_daily_runtime_select ON cob3_workspace.interaction_daily FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
CREATE POLICY interaction_daily_worker_all ON cob3_workspace.interaction_daily FOR ALL TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()))
    WITH CHECK ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()));

CREATE POLICY report_schedules_runtime_select ON cob3_workspace.report_schedules FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_workspace.ctx_artifact_permitted(organization_id, artifact_id, 'artifact.read'));
CREATE POLICY report_schedules_runtime_insert ON cob3_workspace.report_schedules FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_workspace.ctx_artifact_permitted(organization_id, artifact_id, 'report.schedule')
                AND (execution_principal_id = (SELECT cob3_identity.ctx_principal_id())
                     OR (SELECT cob3_identity.ctx_has_org_permission('workspace.manage_reports'))));
CREATE POLICY report_schedules_runtime_update ON cob3_workspace.report_schedules FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_workspace.ctx_artifact_permitted(organization_id, artifact_id, 'report.schedule'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_workspace.ctx_artifact_permitted(organization_id, artifact_id, 'report.schedule')
                AND (execution_principal_id = (SELECT cob3_identity.ctx_principal_id())
                     OR (SELECT cob3_identity.ctx_has_org_permission('workspace.manage_reports'))));
CREATE POLICY report_schedules_worker_update ON cob3_workspace.report_schedules FOR UPDATE TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()))
    WITH CHECK ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()));

CREATE POLICY report_recipients_runtime_select ON cob3_workspace.report_recipients FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND (recipient_principal_id = (SELECT cob3_identity.ctx_principal_id())
                OR cob3_workspace.ctx_schedule_permitted(organization_id, report_schedule_id, 'artifact.read')));
CREATE POLICY report_recipients_runtime_insert ON cob3_workspace.report_recipients FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_workspace.ctx_schedule_permitted(organization_id, report_schedule_id, 'report.schedule'));
CREATE POLICY report_recipients_runtime_update ON cob3_workspace.report_recipients FOR UPDATE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_workspace.ctx_schedule_permitted(organization_id, report_schedule_id, 'report.schedule'))
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND cob3_workspace.ctx_schedule_permitted(organization_id, report_schedule_id, 'report.schedule'));

CREATE POLICY report_runs_runtime_select ON cob3_workspace.report_runs FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND cob3_workspace.ctx_schedule_permitted(organization_id, report_schedule_id, 'artifact.read'));
CREATE POLICY report_runs_runtime_insert ON cob3_workspace.report_runs FOR INSERT TO cob3_runtime
    WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
                AND status = 'queued'
                AND cob3_workspace.ctx_schedule_permitted(organization_id, report_schedule_id, 'report.run'));
CREATE POLICY report_runs_worker_all ON cob3_workspace.report_runs FOR ALL TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()))
    WITH CHECK ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()));

CREATE POLICY report_deliveries_runtime_select ON cob3_workspace.report_deliveries FOR SELECT TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id())
           AND EXISTS (SELECT 1 FROM cob3_workspace.report_recipients rc
                        WHERE rc.tenant_id = report_deliveries.tenant_id AND rc.organization_id = report_deliveries.organization_id
                          AND rc.report_recipient_id = report_deliveries.report_recipient_id));
CREATE POLICY report_deliveries_worker_all ON cob3_workspace.report_deliveries FOR ALL TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()))
    WITH CHECK ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()));

-- Workers: scan verdicts on uploads, report outputs and TTL clean-up.
CREATE POLICY file_objects_worker_insert ON cob3_workspace.file_objects FOR INSERT TO cob3_worker
    WITH CHECK ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()));
CREATE POLICY file_objects_worker_update ON cob3_workspace.file_objects FOR UPDATE TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()))
    WITH CHECK ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
                AND organization_id = (SELECT cob3_identity.ctx_organization_id()));
CREATE POLICY artifact_drafts_worker_delete ON cob3_workspace.artifact_drafts FOR DELETE TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND expires_at <= now());
CREATE POLICY ui_sessions_worker_delete ON cob3_workspace.ui_sessions FOR DELETE TO cob3_worker
    USING ((SELECT cob3_identity.ctx_is_worker()) AND tenant_id = (SELECT cob3_identity.ctx_tenant_id())
           AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND expires_at <= now());

-- ===========================================================================
-- Privileges
-- ===========================================================================
REVOKE ALL ON ALL TABLES IN SCHEMA cob3_settings, cob3_catalog, cob3_workspace FROM PUBLIC;
REVOKE ALL ON cob3_identity.principal_emails, cob3_identity.email_verification_challenges FROM PUBLIC;
GRANT USAGE ON SCHEMA cob3_settings, cob3_catalog, cob3_workspace TO cob3_runtime, cob3_worker, cob3_provisioner;
GRANT USAGE ON SCHEMA cob3_tenant, cob3_identity TO cob3_worker;

-- Workers read everything in their scope (policies above restrict rows).
GRANT SELECT ON ALL TABLES IN SCHEMA cob3_settings, cob3_catalog, cob3_workspace TO cob3_worker;
GRANT SELECT ON cob3_identity.principal_emails TO cob3_worker;
GRANT UPDATE (status, metadata, updated_by) ON cob3_settings.media_objects TO cob3_worker;
GRANT INSERT, UPDATE ON cob3_workspace.report_runs, cob3_workspace.report_deliveries TO cob3_worker;
GRANT UPDATE (status, next_run_at, metadata, updated_by) ON cob3_workspace.report_schedules TO cob3_worker;
GRANT INSERT ON cob3_workspace.file_objects TO cob3_worker;
GRANT UPDATE (status, metadata, updated_by) ON cob3_workspace.file_objects TO cob3_worker;
GRANT INSERT, UPDATE, DELETE ON cob3_workspace.interaction_daily TO cob3_worker;
GRANT DELETE ON cob3_workspace.artifact_drafts, cob3_workspace.ui_sessions TO cob3_worker;

-- Runtime: reads (RLS decides rows) and column-scoped writes.
GRANT SELECT ON ALL TABLES IN SCHEMA cob3_settings, cob3_catalog, cob3_workspace TO cob3_runtime;
GRANT SELECT ON cob3_identity.principal_emails TO cob3_runtime;
GRANT INSERT (tenant_id, principal_email_id, principal_id, email_address, email_key, label, metadata, created_by, updated_by),
      UPDATE (label, is_primary, status, metadata, updated_by)
   ON cob3_identity.principal_emails TO cob3_runtime;

-- user_profiles: email_verified_at/avatar_uri are no longer writable by the
-- runtime and email is never updatable. An email supplied on profile INSERT
-- (legacy writers) is converted into an UNVERIFIED principal_emails row by
-- trg_06_email_projection; the column then only holds the projection.
REVOKE INSERT, UPDATE ON cob3_identity.user_profiles FROM cob3_runtime;
GRANT INSERT (tenant_id, principal_id, organization_id, email, given_name, family_name, job_title, description, avatar_media_id,
              metadata, created_by, updated_by),
      UPDATE (given_name, family_name, job_title, description, avatar_media_id, metadata, updated_by)
   ON cob3_identity.user_profiles TO cob3_runtime;

GRANT INSERT (tenant_id, setting_value_id, organization_id, setting_scope_id, setting_definition_id, value, is_locked, change_reason,
              metadata, created_by, updated_by),
      UPDATE (value, is_locked, change_reason, metadata, updated_by),
      DELETE
   ON cob3_settings.setting_values TO cob3_runtime;
GRANT INSERT (tenant_id, media_object_id, organization_id, setting_scope_id, uploaded_by_principal_id, storage_provider,
              storage_container, object_key, object_version, original_filename, mime_type, size_bytes, sha256, width_px, height_px,
              metadata, created_by, updated_by),
      UPDATE (status, metadata, updated_by)
   ON cob3_settings.media_objects TO cob3_runtime;
GRANT INSERT, UPDATE, DELETE ON cob3_settings.branding_profiles, cob3_settings.notification_preferences TO cob3_runtime;
GRANT INSERT, UPDATE ON cob3_settings.contact_addresses, cob3_settings.notification_endpoints,
                        cob3_settings.integration_configurations, cob3_settings.automation_policies TO cob3_runtime;

GRANT INSERT, UPDATE ON cob3_catalog.domains, cob3_catalog.assets, cob3_catalog.asset_ownerships, cob3_catalog.asset_locations,
                        cob3_catalog.asset_relationships, cob3_catalog.tags TO cob3_runtime;
GRANT INSERT ON cob3_catalog.asset_external_identifiers TO cob3_runtime;
GRANT INSERT, DELETE ON cob3_catalog.asset_tags TO cob3_runtime;

GRANT UPDATE (default_automation_principal_id, icon_code, color, metadata, updated_by) ON cob3_workspace.projects TO cob3_runtime;
GRANT INSERT, UPDATE ON cob3_workspace.folders TO cob3_runtime;
GRANT UPDATE (folder_id, inherit_project_access, metadata, updated_by) ON cob3_workspace.artifacts TO cob3_runtime;
GRANT INSERT ON cob3_workspace.file_objects TO cob3_runtime;
GRANT UPDATE (status, metadata, updated_by) ON cob3_workspace.file_objects TO cob3_runtime;
GRANT INSERT, UPDATE, DELETE ON cob3_workspace.artifact_drafts, cob3_workspace.bookmarks, cob3_workspace.recent_items,
                                cob3_workspace.ui_sessions TO cob3_runtime;
GRANT INSERT, UPDATE ON cob3_workspace.interaction_journeys, cob3_workspace.report_schedules,
                        cob3_workspace.report_recipients TO cob3_runtime;
GRANT INSERT ON cob3_workspace.interaction_events, cob3_workspace.report_runs TO cob3_runtime;

-- Helpers called by invoker triggers and policies run as the calling role.
GRANT EXECUTE ON FUNCTION
    cob3_identity.ctx_uuid(text), cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(),
    cob3_identity.ctx_principal_id(), cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(),
    cob3_identity.ctx_actor(), cob3_identity.clear_request_context(),
    cob3_identity.set_worker_context(uuid, uuid, text),
    cob3_identity.assert_catalog_domain(uuid, uuid, uuid), cob3_identity.assert_catalog_asset(uuid, uuid, uuid),
    cob3_identity.catalog_integration_installed(),
    cob3_identity.evaluate_access(uuid, uuid, uuid, uuid, uuid, text, text, uuid, timestamptz, uuid)
    TO cob3_worker;
GRANT EXECUTE ON FUNCTION
    cob3_identity.ctx_is_worker(), cob3_identity.ctx_is_system_writer(), cob3_identity.is_valid_timezone(text),
    cob3_identity.email_key(text), cob3_settings.value_violation(text, jsonb, jsonb)
    TO cob3_runtime, cob3_worker, cob3_provisioner, cob3_commercial_admin;
GRANT EXECUTE ON FUNCTION
    cob3_identity.foundation_permission_templates(), cob3_identity.foundation_role_templates(),
    cob3_catalog.module_permission_templates(), cob3_catalog.module_role_templates()
    TO cob3_provisioner;
GRANT EXECUTE ON FUNCTION
    cob3_catalog.ctx_asset_permitted(uuid, uuid, text), cob3_catalog.ctx_asset_readable(uuid, uuid),
    cob3_catalog.ctx_asset_writable(uuid, uuid),
    cob3_settings.ctx_scope_access(uuid, uuid, text), cob3_settings.ctx_can_view_media(uuid, uuid, text),
    cob3_workspace.ctx_project_permitted(uuid, uuid, text), cob3_workspace.ctx_artifact_permitted(uuid, uuid, text),
    cob3_workspace.ctx_schedule_permitted(uuid, uuid, text), cob3_workspace.ctx_can_read_file(uuid, uuid, uuid),
    cob3_catalog.register_asset(text, text, text, text, uuid, text, uuid, jsonb),
    cob3_workspace.create_project(text, text, text, text, uuid, text, text, uuid),
    cob3_workspace.create_artifact(uuid, text, text, text, jsonb, integer, bytea, uuid, text, boolean, text, uuid),
    cob3_workspace.commit_artifact_revision(uuid, bigint, text, jsonb, uuid, uuid, integer, bytea, text),
    cob3_settings.ensure_scope(text, uuid, uuid),
    cob3_settings.resolve_setting(text, uuid, uuid),
    cob3_identity.issue_email_verification(uuid, bytea, timestamptz),
    cob3_identity.consume_email_verification(uuid, bytea)
    TO cob3_runtime;
GRANT EXECUTE ON FUNCTION cob3_settings.effective_automation_policy(uuid, uuid) TO cob3_runtime, cob3_worker;
