-- =============================================================================
-- 70  AUTHORIZATION: CATALOG RESOLVER, PERMISSION TEMPLATES, CONTEXT HELPERS,
--     TRUSTED ROUTINES
-- -----------------------------------------------------------------------------
-- Replaces the fail-closed Catalog guards of foundation 1.0.0 with the real
-- resolver (same signatures, owner and privileges preserved), adding the
-- design's explicit/governed gate (6.3), project inheritance (6.4) and exact
-- team bindings on explicit resources (6.5).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Catalog guards: accept only existing ACTIVE rows of the same tenant/org.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cob3_identity.catalog_integration_installed()
    RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT true $fn$;

CREATE OR REPLACE FUNCTION cob3_identity.assert_catalog_domain(p_tenant_id uuid, p_organization_id uuid, p_domain_id uuid)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_catalog.domains d
                    WHERE d.tenant_id = p_tenant_id AND d.organization_id = p_organization_id
                      AND d.domain_id = p_domain_id AND d.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCAT', MESSAGE = 'Unknown or inactive Catalog domain for this organization.';
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION cob3_identity.assert_catalog_asset(p_tenant_id uuid, p_organization_id uuid, p_asset_id uuid)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_catalog.assets a
                    WHERE a.tenant_id = p_tenant_id AND a.organization_id = p_organization_id
                      AND a.asset_id = p_asset_id AND a.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCAT', MESSAGE = 'Unknown or inactive Catalog asset for this organization.';
    END IF;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Resolver. Rules (target = what the operation acts on):
--  1. target 'organization' (the scope's own organization): organization-level
--     product operations such as project.create or catalog.manage; covered only
--     by an organization scope.
--  2. target 'domain': domain scope on that domain, or organization scope with
--     include_contained_assets; team bindings need team_domains responsibility.
--     Permission resource_type must be 'domain' or the generic 'asset'.
--  3. target = an asset (target_type = its asset type code): permission
--     resource_type equals the type code, or is the generic 'asset'.
--     * governed assets: organization/domain containment as in the Identity
--       design (team bindings keep the team_domains responsibility check);
--     * explicit assets: ONLY the exact asset scope, or a Workspace project
--       scope with include_workspace_artifacts covering an artifact of that
--       project with inherit_project_access = true. Exact team bindings on
--       explicit assets need no domain responsibility (6.5).
-- Anything else denies. Live state only (active rows); nothing is cached.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_catalog.team_responsible_for(p_tenant_id uuid, p_organization_id uuid, p_team_id uuid, p_domain_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p_team_id IS NULL
        OR (p_domain_id IS NOT NULL AND EXISTS (
               SELECT 1 FROM cob3_identity.team_domains td
                WHERE td.tenant_id = p_tenant_id AND td.organization_id = p_organization_id
                  AND td.team_id = p_team_id AND td.domain_id = p_domain_id AND td.status = 'active'))
$fn$;

CREATE FUNCTION cob3_catalog.scope_covers(
        p_tenant_id uuid, p_organization_id uuid, p_scope_type text, p_domain_id uuid, p_asset_id uuid,
        p_include_contained_assets boolean, p_include_workspace_artifacts boolean, p_team_id uuid,
        p_resource_type text, p_target_type text, p_target_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    a record;
BEGIN
    IF p_target_type IS NULL OR p_target_id IS NULL THEN
        RETURN false;
    END IF;
    -- Rule 1
    IF p_target_type = 'organization' THEN
        RETURN p_scope_type = 'organization' AND p_target_id = p_organization_id;
    END IF;
    -- Rule 2
    IF p_target_type = 'domain' THEN
        IF p_resource_type NOT IN ('domain', 'asset') OR NOT EXISTS (
               SELECT 1 FROM cob3_catalog.domains d
                WHERE d.tenant_id = p_tenant_id AND d.organization_id = p_organization_id
                  AND d.domain_id = p_target_id AND d.status = 'active') THEN
            RETURN false;
        END IF;
        RETURN CASE p_scope_type
                   WHEN 'organization' THEN p_include_contained_assets AND p_team_id IS NULL
                   WHEN 'domain' THEN p_domain_id = p_target_id
                                      AND cob3_catalog.team_responsible_for(p_tenant_id, p_organization_id, p_team_id, p_domain_id)
                   ELSE false
               END;
    END IF;
    -- Rule 3
    SELECT x.asset_id, x.domain_id, x.authorization_mode, t.type_code INTO a
      FROM cob3_catalog.assets x
      JOIN cob3_catalog.asset_types t ON t.asset_type_id = x.asset_type_id
     WHERE x.tenant_id = p_tenant_id AND x.organization_id = p_organization_id
       AND x.asset_id = p_target_id AND x.status = 'active';
    IF NOT FOUND OR a.type_code <> p_target_type OR p_resource_type NOT IN (a.type_code, 'asset') THEN
        RETURN false;
    END IF;
    IF p_scope_type = 'organization' THEN
        RETURN a.authorization_mode = 'governed' AND p_include_contained_assets AND p_team_id IS NULL;
    ELSIF p_scope_type = 'domain' THEN
        RETURN a.authorization_mode = 'governed' AND p_include_contained_assets AND a.domain_id = p_domain_id
           AND cob3_catalog.team_responsible_for(p_tenant_id, p_organization_id, p_team_id, p_domain_id);
    ELSIF p_scope_type = 'asset' THEN
        IF p_asset_id = a.asset_id THEN
            RETURN a.authorization_mode = 'explicit'
                OR cob3_catalog.team_responsible_for(p_tenant_id, p_organization_id, p_team_id, a.domain_id);
        END IF;
        IF p_include_workspace_artifacts AND a.type_code = 'saved_artifact' THEN
            RETURN EXISTS (
                SELECT 1
                  FROM cob3_workspace.artifacts w
                  JOIN cob3_workspace.projects p
                    ON p.tenant_id = w.tenant_id AND p.organization_id = w.organization_id AND p.project_id = w.project_id
                  JOIN cob3_catalog.assets pa
                    ON pa.tenant_id = p.tenant_id AND pa.organization_id = p.organization_id AND pa.asset_id = p.asset_id
                 WHERE w.tenant_id = p_tenant_id AND w.organization_id = p_organization_id
                   AND w.asset_id = a.asset_id AND w.inherit_project_access
                   AND p.asset_id = p_asset_id AND pa.status = 'active');
        END IF;
    END IF;
    RETURN false;
END
$fn$;

-- Compatibility: the foundation signature delegates without inheritance.
CREATE OR REPLACE FUNCTION cob3_identity.catalog_scope_covers(
        p_tenant_id uuid, p_organization_id uuid, p_scope_type text, p_domain_id uuid, p_asset_id uuid,
        p_include_contained_assets boolean, p_team_id uuid, p_resource_type text,
        p_target_type text, p_target_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_catalog.scope_covers(p_tenant_id, p_organization_id, p_scope_type, p_domain_id, p_asset_id,
                                     p_include_contained_assets, false, p_team_id, p_resource_type, p_target_type, p_target_id, p_at)
$fn$;

-- Same signature and decision for organization-administered resources; every
-- other target goes to the resolver WITH the scope's inheritance flag. Used by
-- roles, grantor/grantee RBAC, grant entries and credential subsets alike.
CREATE OR REPLACE FUNCTION cob3_identity.scope_covers_target(
        p_tenant_id uuid, p_organization_id uuid, p_scope_id uuid, p_team_id uuid,
        p_resource_type text, p_target_type text, p_target_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((
        SELECT CASE
                 WHEN s.status <> 'active' THEN false
                 WHEN s.scope_type = 'organization'
                      AND p_target_type = 'organization'
                      AND p_target_id = s.organization_id
                      AND cob3_identity.is_org_administered_resource(p_resource_type) THEN true
                 ELSE cob3_catalog.scope_covers(
                          s.tenant_id, s.organization_id, s.scope_type, s.domain_id, s.asset_id,
                          s.include_contained_assets, s.include_workspace_artifacts, p_team_id,
                          p_resource_type, p_target_type, p_target_id, p_at)
               END
          FROM cob3_identity.access_scopes s
         WHERE s.tenant_id = p_tenant_id
           AND s.organization_id = p_organization_id
           AND s.scope_id = p_scope_id), false)
$fn$;

-- include_workspace_artifacts is valid only on a Workspace project asset scope.
CREATE FUNCTION cob3_catalog.tg_access_scopes_workspace_inheritance()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.include_workspace_artifacts THEN
        PERFORM cob3_catalog.assert_asset_type(NEW.tenant_id, NEW.organization_id, NEW.asset_id, 'workspace_project');
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_06_workspace_inheritance BEFORE INSERT ON cob3_identity.access_scopes
    FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_access_scopes_workspace_inheritance();

-- ---------------------------------------------------------------------------
-- Context helpers used by RLS policies (evaluated per row; SECURITY DEFINER so
-- they can read Catalog rows independently of the caller's own visibility).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_catalog.ctx_asset_permitted(p_organization_id uuid, p_asset_id uuid, p_permission_code text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p_organization_id = cob3_identity.ctx_organization_id()
       AND p_permission_code IS NOT NULL
       AND COALESCE((
           SELECT d.allowed
             FROM cob3_catalog.assets a
             JOIN cob3_catalog.asset_types t ON t.asset_type_id = a.asset_type_id
            CROSS JOIN LATERAL cob3_identity.evaluate_access(
                      cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), cob3_identity.ctx_principal_id(),
                      cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(),
                      p_permission_code, t.type_code, a.asset_id, pg_catalog.now(), NULL) AS d
            WHERE a.tenant_id = cob3_identity.ctx_tenant_id()
              AND a.organization_id = p_organization_id
              AND a.asset_id = p_asset_id), false)
       AND cob3_identity.ctx_auth_valid()
$fn$;

-- Type-specific read permission, or generic catalog.read on the asset.
CREATE FUNCTION cob3_catalog.ctx_asset_readable(p_organization_id uuid, p_asset_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_catalog.ctx_asset_permitted(p_organization_id, p_asset_id,
               (SELECT t.read_permission_code FROM cob3_catalog.assets a JOIN cob3_catalog.asset_types t ON t.asset_type_id = a.asset_type_id
                 WHERE a.tenant_id = cob3_identity.ctx_tenant_id() AND a.asset_id = p_asset_id))
        OR cob3_catalog.ctx_asset_permitted(p_organization_id, p_asset_id, 'catalog.read')
$fn$;

-- Type-specific write permission, or generic catalog.manage on the asset.
CREATE FUNCTION cob3_catalog.ctx_asset_writable(p_organization_id uuid, p_asset_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_catalog.ctx_asset_permitted(p_organization_id, p_asset_id,
               (SELECT t.write_permission_code FROM cob3_catalog.assets a JOIN cob3_catalog.asset_types t ON t.asset_type_id = a.asset_type_id
                 WHERE a.tenant_id = cob3_identity.ctx_tenant_id() AND a.asset_id = p_asset_id))
        OR cob3_catalog.ctx_asset_permitted(p_organization_id, p_asset_id, 'catalog.manage')
$fn$;

-- Settings scope access. Modes: read | write | lock | integration.
-- Self-service (principal, principal_org) is a fixed authenticated capability
-- of an interactive human for its own scope (design section 10 choice).
CREATE FUNCTION cob3_settings.ctx_scope_access(p_tenant_id uuid, p_setting_scope_id uuid, p_mode text)
    RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    s       cob3_settings.setting_scopes%ROWTYPE;
    v_self  boolean;
    v_asset uuid;
BEGIN
    IF p_tenant_id IS DISTINCT FROM cob3_identity.ctx_tenant_id() OR NOT cob3_identity.ctx_auth_valid() THEN
        RETURN false;
    END IF;
    SELECT x.* INTO s FROM cob3_settings.setting_scopes x WHERE x.tenant_id = p_tenant_id AND x.setting_scope_id = p_setting_scope_id;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    IF s.organization_id IS NOT NULL
       AND (s.organization_id IS DISTINCT FROM cob3_identity.ctx_organization_id() OR NOT cob3_identity.ctx_in_org()) THEN
        RETURN false;
    END IF;
    v_self := s.principal_id = cob3_identity.ctx_principal_id() AND cob3_identity.ctx_is_interactive();
    CASE s.scope_type
        WHEN 'tenant' THEN
            RETURN CASE WHEN p_mode = 'read' THEN cob3_identity.ctx_is_tenant_member()
                        ELSE cob3_identity.ctx_has_tenant_permission('settings.manage_tenant') END;
        WHEN 'organization' THEN
            RETURN CASE p_mode
                       WHEN 'read'        THEN true
                       WHEN 'write'       THEN cob3_identity.ctx_has_org_permission('settings.manage_organization')
                       WHEN 'lock'        THEN cob3_identity.ctx_has_org_permission('settings.manage_policy')
                       WHEN 'integration' THEN cob3_identity.ctx_has_org_permission('settings.manage_integrations')
                       ELSE false
                   END;
        WHEN 'team' THEN
            RETURN CASE p_mode
                       WHEN 'read'        THEN true
                       WHEN 'write'       THEN cob3_identity.ctx_has_org_permission('settings.manage_team')
                       WHEN 'integration' THEN cob3_identity.ctx_has_org_permission('settings.manage_integrations')
                       ELSE false
                   END;
        WHEN 'principal', 'principal_org' THEN
            RETURN v_self AND p_mode IN ('read', 'write');
        WHEN 'project' THEN
            SELECT p.asset_id INTO v_asset FROM cob3_workspace.projects p
             WHERE p.tenant_id = s.tenant_id AND p.organization_id = s.organization_id AND p.project_id = s.project_id;
            RETURN CASE p_mode
                       WHEN 'read'  THEN cob3_catalog.ctx_asset_permitted(s.organization_id, v_asset, 'project.read')
                       WHEN 'write' THEN cob3_catalog.ctx_asset_permitted(s.organization_id, v_asset, 'project.update')
                       ELSE false
                   END;
        ELSE
            RETURN false;
    END CASE;
END
$fn$;

-- Ready principal-scope media (avatars) are visible to whoever may view that
-- principal's profile; all other media follow their scope's read access.
CREATE FUNCTION cob3_settings.ctx_can_view_media(p_tenant_id uuid, p_setting_scope_id uuid, p_status text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_settings.ctx_scope_access(p_tenant_id, p_setting_scope_id, 'read')
        OR (p_status = 'ready' AND EXISTS (
               SELECT 1 FROM cob3_settings.setting_scopes s
                WHERE s.tenant_id = p_tenant_id AND s.setting_scope_id = p_setting_scope_id
                  AND s.scope_type = 'principal' AND p_tenant_id = cob3_identity.ctx_tenant_id()
                  AND cob3_identity.ctx_can_view_principal(s.principal_id)))
$fn$;

-- ---------------------------------------------------------------------------
-- Security-sensitive asset changes (6.3/6.4): access classification, domain
-- and project inheritance changes need share/governance authority.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_catalog.tg_assets_share_authority()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF (NEW.authorization_mode, NEW.domain_id) IS DISTINCT FROM (OLD.authorization_mode, OLD.domain_id)
       AND cob3_identity.ctx_principal_id() IS NOT NULL
       AND NOT (cob3_catalog.ctx_asset_permitted(NEW.organization_id, NEW.asset_id, 'asset.share')
                OR cob3_identity.ctx_has_org_permission('catalog.manage')) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Changing an asset''s authorization mode or domain requires asset.share or catalog.manage.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_16_share_authority BEFORE UPDATE OF authorization_mode, domain_id ON cob3_catalog.assets
    FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_assets_share_authority();

CREATE FUNCTION cob3_workspace.tg_artifacts_inheritance_authority()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.inherit_project_access IS DISTINCT FROM OLD.inherit_project_access
       AND cob3_identity.ctx_principal_id() IS NOT NULL
       AND NOT cob3_catalog.ctx_asset_permitted(NEW.organization_id, NEW.asset_id, 'asset.share') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Changing inherit_project_access requires asset.share on the artifact.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_16_inheritance_authority BEFORE UPDATE OF inherit_project_access ON cob3_workspace.artifacts
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_artifacts_inheritance_authority();

-- ---------------------------------------------------------------------------
-- Permission and role templates. The foundation's 20 core permissions and 4
-- roles move unchanged into foundation_*_templates(); module templates are
-- composed by core_*_templates() (same signatures as 1.0.0), so later
-- migrations add their own module function and re-compose only the wrapper.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.foundation_permission_templates()
    RETURNS TABLE (permission_code text, resource_type text, action text, permission_class text,
                   is_delegable boolean, automation_allowed boolean, is_identity_management boolean, description text)
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    VALUES
        ('tenant.manage_organizations',     'tenant',          'manage_organizations',     'tenant_control', false, false, true,  'Tenant organization lifecycle'),
        ('tenant.manage_roles',             'tenant',          'manage_roles',             'tenant_control', false, false, true,  'Shared role/permission administration'),
        ('tenant.manage_identity_providers','tenant',          'manage_identity_providers','tenant_control', false, false, true,  'Trusted identity provider configuration'),
        ('tenant.manage_administrators',    'tenant',          'manage_administrators',    'tenant_control', false, false, true,  'Tenant administrator assignment and tenant-wide principal lifecycle'),
        ('organization.read',               'organization',    'read',                     'organization',   true,  true,  false, 'Read the organization resource'),
        ('organization.manage_members',     'organization',    'manage_members',           'organization',   true,  false, true,  'Organization membership administration'),
        ('team.read',                       'team',            'read',                     'organization',   true,  true,  false, 'Read teams in organization context'),
        ('team.manage',                     'team',            'manage',                   'organization',   true,  false, true,  'Team and team membership administration'),
        ('role.assign',                     'role',            'assign',                   'organization',   true,  false, true,  'Assign approved roles in the organization'),
        ('service_account.manage',          'service_account', 'manage',                   'organization',   true,  false, true,  'Service account lifecycle'),
        ('automation.create',               'automation',      'create',                   'organization',   true,  false, true,  'Create automation identities'),
        ('automation.manage',               'automation',      'manage',                   'organization',   true,  false, true,  'Automation owner/lifecycle administration'),
        ('automation.revoke',               'automation',      'revoke',                   'organization',   true,  false, true,  'Disable automations or revoke their authority'),
        ('grant.authorize',                 'grant',           'authorize',                'organization',   true,  false, true,  'Approve restricted-self and delegated grants'),
        ('grant.revoke',                    'grant',           'revoke',                   'organization',   true,  false, true,  'Revoke grants'),
        ('credential.issue',                'credential',      'issue',                    'organization',   true,  false, true,  'Issue scoped credentials'),
        ('credential.revoke',               'credential',      'revoke',                   'organization',   true,  false, true,  'Revoke credentials'),
        ('action.approve',                  'action',          'approve',                  'organization',   false, false, false, 'Human approval of a sensitive action; requires target action authority too'),
        ('audit.read',                      'audit',           'read',                     'organization',   true,  false, false, 'Read organization audit events'),
        ('domain.read',                     'domain',          'read',                     'organization',   true,  true,  false, 'Read a Catalog domain')
$fn$;

CREATE FUNCTION cob3_identity.foundation_role_templates()
    RETURNS TABLE (role_code text, role_name text, role_class text, permission_code text)
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT r.role_code, r.role_name, r.role_class, p.permission_code
      FROM (VALUES
              ('tenant_administrator',       'Tenant administrator',       'tenant_control',
               ARRAY['tenant.manage_organizations', 'tenant.manage_roles', 'tenant.manage_identity_providers', 'tenant.manage_administrators']),
              ('organization_administrator', 'Organization administrator', 'organization',
               ARRAY['organization.read', 'organization.manage_members', 'team.read', 'team.manage', 'role.assign',
                     'service_account.manage', 'automation.create', 'automation.manage', 'automation.revoke',
                     'grant.authorize', 'grant.revoke', 'credential.issue', 'credential.revoke', 'action.approve', 'audit.read']),
              ('automation_creator',         'Automation creator',         'organization',
               ARRAY['automation.create', 'automation.manage', 'grant.authorize', 'credential.issue', 'credential.revoke', 'grant.revoke']),
              ('audit_reader',               'Audit reader',               'organization',
               ARRAY['audit.read'])
           ) AS r(role_code, role_name, role_class, perms)
     CROSS JOIN LATERAL pg_catalog.unnest(r.perms) AS p(permission_code)
$fn$;

-- Settings / profile / Catalog / Workspace permissions (design section 10).
-- resource_type equals the Catalog asset type code the permission is checked
-- against; 'asset' is the generic Catalog type matching any asset type.
CREATE FUNCTION cob3_catalog.module_permission_templates()
    RETURNS TABLE (permission_code text, resource_type text, action text, permission_class text,
                   is_delegable boolean, automation_allowed boolean, is_identity_management boolean, description text)
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    VALUES
        ('settings.read',                 'settings',          'read',                'organization',   true,  true,  false, 'Read organization/team settings'),
        ('settings.update_self',          'settings',          'update_self',         'organization',   false, false, false, 'Own principal preferences (interactive self-service)'),
        ('settings.manage_organization',  'settings',          'manage_organization', 'organization',   true,  false, false, 'Organization settings, branding and mailboxes'),
        ('settings.manage_team',          'settings',          'manage_team',         'organization',   true,  false, false, 'Team settings and branding'),
        ('settings.manage_policy',        'settings',          'manage_policy',       'organization',   false, false, false, 'Setting locks and automation policies (restricted, interactive only)'),
        ('settings.manage_integrations',  'settings',          'manage_integrations', 'organization',   false, false, false, 'Adapter configurations and secret references (restricted, interactive only)'),
        ('settings.manage_tenant',        'settings',          'manage_tenant',       'tenant_control', false, false, false, 'Tenant-scope settings, SSO configuration and tenant automation policy'),
        ('profile.read_self',             'profile',           'read_self',           'organization',   false, false, false, 'Read own profile'),
        ('profile.update_self',           'profile',           'update_self',         'organization',   false, false, false, 'Update own profile fields'),
        ('profile.manage_directory',      'profile',           'manage_directory',    'organization',   true,  false, true,  'Organization directory administration'),
        ('catalog.read',                  'asset',             'read',                'organization',   true,  true,  false, 'Read Catalog metadata of a domain or exact asset'),
        ('catalog.manage',                'asset',             'manage',              'organization',   true,  false, false, 'Register and govern Catalog domains/assets'),
        ('asset.share',                   'asset',             'share',               'organization',   false, false, true,  'Share an exact asset/project (IAM-related; no automation in v1)'),
        ('project.read',                  'workspace_project', 'read',                'organization',   true,  true,  false, 'Read a Workspace project'),
        ('project.update',                'workspace_project', 'update',              'organization',   true,  true,  false, 'Update a Workspace project and its folders'),
        ('project.create',                'workspace_project', 'create',              'organization',   true,  true,  false, 'Create Workspace projects in the organization'),
        ('artifact.create',               'workspace_project', 'create_artifact',     'organization',   true,  true,  false, 'Create artifacts in a project (checked on the parent project)'),
        ('workspace.manage_reports',      'workspace_project', 'manage_reports',      'organization',   true,  false, false, 'Administer report schedules (approved provisioning only)'),
        ('artifact.read',                 'saved_artifact',    'read',                'organization',   true,  true,  false, 'Read a saved artifact'),
        ('artifact.update',               'saved_artifact',    'update',              'organization',   true,  true,  false, 'Commit artifact revisions'),
        ('artifact.execute',              'saved_artifact',    'execute',             'organization',   true,  true,  false, 'Execute an artifact (each source asset is checked separately)'),
        ('report.schedule',               'saved_artifact',    'schedule',            'organization',   true,  true,  false, 'Schedule an artifact as a report'),
        ('report.run',                    'saved_artifact',    'run',                 'organization',   true,  true,  false, 'Run a scheduled report'),
        ('report.deliver',                'saved_artifact',    'deliver',             'organization',   true,  true,  false, 'Deliver a report output to approved recipients')
$fn$;

CREATE FUNCTION cob3_catalog.module_role_templates()
    RETURNS TABLE (role_code text, role_name text, role_class text, permission_code text)
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT r.role_code, r.role_name, r.role_class, p.permission_code
      FROM (VALUES
              ('tenant_administrator',       'Tenant administrator',       'tenant_control', ARRAY['settings.manage_tenant']),
              ('organization_administrator', 'Organization administrator', 'organization',
               ARRAY['settings.read', 'settings.manage_organization', 'settings.manage_team', 'settings.manage_policy',
                     'settings.manage_integrations', 'profile.manage_directory', 'catalog.read', 'catalog.manage']),
              ('organization_member',        'Organization member',        'organization',
               ARRAY['organization.read', 'team.read', 'settings.read', 'settings.update_self', 'profile.read_self',
                     'profile.update_self', 'catalog.read', 'project.create']),
              ('workspace_viewer',           'Workspace viewer',           'organization', ARRAY['project.read', 'artifact.read']),
              ('workspace_editor',           'Workspace editor',           'organization',
               ARRAY['project.read', 'project.update', 'artifact.create', 'artifact.read', 'artifact.update']),
              ('workspace_owner',            'Workspace owner',            'organization',
               ARRAY['project.read', 'project.update', 'artifact.create', 'artifact.read', 'artifact.update', 'asset.share', 'report.schedule']),
              ('report_operator',            'Report operator',            'organization',
               ARRAY['artifact.read', 'artifact.execute', 'report.run', 'report.deliver'])
           ) AS r(role_code, role_name, role_class, perms)
     CROSS JOIN LATERAL pg_catalog.unnest(r.perms) AS p(permission_code)
$fn$;

CREATE OR REPLACE FUNCTION cob3_identity.core_permission_templates()
    RETURNS TABLE (permission_code text, resource_type text, action text, permission_class text,
                   is_delegable boolean, automation_allowed boolean, is_identity_management boolean, description text)
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT * FROM cob3_identity.foundation_permission_templates()
    UNION ALL
    SELECT * FROM cob3_catalog.module_permission_templates()
$fn$;

CREATE OR REPLACE FUNCTION cob3_identity.core_role_templates()
    RETURNS TABLE (role_code text, role_name text, role_class text, permission_code text)
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT * FROM cob3_identity.foundation_role_templates()
    UNION ALL
    SELECT * FROM cob3_catalog.module_role_templates()
$fn$;

-- ---------------------------------------------------------------------------
-- Trusted creation routines (6.4 / 8.2): asset + module row + primary
-- ownership + owner role binding in ONE transaction.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_catalog.require_org_context()
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() OR cob3_identity.ctx_organization_id() IS NULL OR NOT cob3_identity.ctx_in_org() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'An authenticated organization context is required.';
    END IF;
END
$fn$;

-- Internal (not granted): registers the asset, its primary owner and, for a
-- human creator, the type's owner role on the exact asset scope.
CREATE FUNCTION cob3_catalog.register_asset_core(
        p_type_code text, p_asset_code text, p_name text, p_description text, p_domain_id uuid,
        p_authorization_mode text, p_owner_principal_id uuid, p_attributes jsonb)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_actor  text := cob3_identity.ctx_actor();
    v_caller uuid := cob3_identity.ctx_principal_id();
    v_owner  uuid;
    t        cob3_catalog.asset_types%ROWTYPE;
    v_asset  uuid := gen_random_uuid();
    v_scope  uuid;
    v_role   uuid;
BEGIN
    SELECT x.* INTO t FROM cob3_catalog.asset_types x WHERE x.type_code = p_type_code AND x.status = 'active';
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown or retired asset type %s.', p_type_code);
    END IF;
    v_owner := COALESCE(p_owner_principal_id, v_caller);
    IF v_owner IS DISTINCT FROM v_caller
       AND NOT cob3_identity.ctx_has_org_permission('catalog.manage')
       AND cob3_identity.principal_type_of(v_tenant, v_caller) = 'human' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Assigning another accountable owner requires catalog.manage.';
    END IF;
    IF NOT cob3_identity.membership_is_effective(v_tenant, v_org, v_owner, pg_catalog.now()) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The accountable owner must be an effective member of the organization.';
    END IF;
    INSERT INTO cob3_catalog.assets (tenant_id, organization_id, asset_id, asset_type_id, asset_code, name, description,
                                     domain_id, authorization_mode, attributes, status, created_by, updated_by)
    VALUES (v_tenant, v_org, v_asset, t.asset_type_id, p_asset_code, p_name, p_description, p_domain_id,
            CASE WHEN t.owning_module IN ('workspace', 'ai') THEN 'explicit' ELSE COALESCE(p_authorization_mode, 'explicit') END,
            COALESCE(p_attributes, '{}'::jsonb), 'active', v_actor, v_actor);
    INSERT INTO cob3_catalog.asset_ownerships (tenant_id, organization_id, asset_id, principal_id, responsibility, is_primary,
                                               created_by, updated_by)
    VALUES (v_tenant, v_org, v_asset, v_owner, 'owner', true, v_actor, v_actor);
    -- Owner role binding only for a human owner who is also the creator, or
    -- one assigned by a catalog.manage holder. An automation creating on behalf
    -- of an accountable human records ownership only; it never grants rights.
    IF t.owner_role_code IS NOT NULL AND cob3_identity.principal_type_of(v_tenant, v_owner) = 'human'
       AND (v_owner = v_caller OR cob3_identity.ctx_has_org_permission('catalog.manage')) THEN
        SELECT r.role_id INTO v_role FROM cob3_identity.roles r
         WHERE r.tenant_id = v_tenant AND r.role_code = t.owner_role_code AND r.status = 'active';
        IF v_role IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Owner role %s is not provisioned for this tenant (run provision_tenant_iam_seed).', t.owner_role_code);
        END IF;
        INSERT INTO cob3_identity.access_scopes (tenant_id, organization_id, scope_type, asset_id, include_contained_assets,
                                                 include_workspace_artifacts, created_by, updated_by)
        VALUES (v_tenant, v_org, 'asset', v_asset, false, p_type_code = 'workspace_project', v_actor, v_actor)
        RETURNING scope_id INTO v_scope;
        INSERT INTO cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, grant_reason,
                                                 created_by, updated_by)
        VALUES (v_tenant, v_org, v_role, v_scope, v_owner, 'Accountable owner of a newly registered asset', v_actor, v_actor);
    END IF;
    PERFORM cob3_identity.audit_ctx('catalog.asset_registered', 'asset', v_asset,
                                    pg_catalog.jsonb_build_object('asset_type', p_type_code, 'owner_principal_id', v_owner));
    RETURN v_asset;
END
$fn$;

CREATE FUNCTION cob3_catalog.register_asset(
        p_type_code text, p_asset_code text, p_name text, p_description text DEFAULT NULL, p_domain_id uuid DEFAULT NULL,
        p_authorization_mode text DEFAULT NULL, p_owner_principal_id uuid DEFAULT NULL, p_attributes jsonb DEFAULT '{}'::jsonb)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_perm text;
BEGIN
    PERFORM cob3_catalog.require_org_context();
    SELECT COALESCE(t.create_permission_code, 'catalog.manage') INTO v_perm
      FROM cob3_catalog.asset_types t WHERE t.type_code = p_type_code;
    PERFORM cob3_identity.require_ctx_permission(COALESCE(v_perm, 'catalog.manage'), 'organization');
    RETURN cob3_catalog.register_asset_core(p_type_code, p_asset_code, p_name, p_description, p_domain_id,
                                            p_authorization_mode, p_owner_principal_id, p_attributes);
END
$fn$;

CREATE FUNCTION cob3_workspace.create_project(
        p_asset_code text, p_name text, p_project_kind text, p_description text DEFAULT NULL,
        p_domain_id uuid DEFAULT NULL, p_icon_code text DEFAULT NULL, p_color text DEFAULT NULL,
        p_owner_principal_id uuid DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_asset   uuid;
    v_project uuid := gen_random_uuid();
    v_owner   uuid := COALESCE(p_owner_principal_id, cob3_identity.ctx_principal_id());
    v_actor   text := cob3_identity.ctx_actor();
BEGIN
    v_asset := cob3_catalog.register_asset('workspace_project', p_asset_code, p_name, p_description, p_domain_id,
                                           'explicit', p_owner_principal_id, '{}'::jsonb);
    INSERT INTO cob3_workspace.projects (tenant_id, organization_id, project_id, asset_id, project_kind,
                                         personal_owner_principal_id, icon_code, color, created_by, updated_by)
    VALUES (cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), v_project, v_asset, p_project_kind,
            CASE WHEN p_project_kind = 'personal' THEN v_owner END, p_icon_code, p_color, v_actor, v_actor);
    RETURN v_project;
END
$fn$;

CREATE FUNCTION cob3_workspace.create_artifact(
        p_project_id uuid, p_artifact_kind text, p_asset_code text, p_name text,
        p_definition jsonb, p_definition_schema_version integer, p_content_sha256 bytea,
        p_folder_id uuid DEFAULT NULL, p_description text DEFAULT NULL, p_inherit_project_access boolean DEFAULT true,
        p_change_note text DEFAULT NULL, p_owner_principal_id uuid DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant   uuid := cob3_identity.ctx_tenant_id();
    v_org      uuid := cob3_identity.ctx_organization_id();
    v_actor    text := cob3_identity.ctx_actor();
    v_project  cob3_workspace.projects%ROWTYPE;
    v_asset    uuid;
    v_artifact uuid := gen_random_uuid();
    v_revision uuid := gen_random_uuid();
BEGIN
    PERFORM cob3_catalog.require_org_context();
    SELECT p.* INTO v_project FROM cob3_workspace.projects p
     WHERE p.tenant_id = v_tenant AND p.organization_id = v_org AND p.project_id = p_project_id;
    IF NOT FOUND OR NOT cob3_catalog.ctx_asset_permitted(v_org, v_project.asset_id, 'artifact.create') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'artifact.create on the project is required.';
    END IF;
    v_asset := cob3_catalog.register_asset_core('saved_artifact', p_asset_code, p_name, p_description, NULL,
                                                'explicit', p_owner_principal_id, '{}'::jsonb);
    INSERT INTO cob3_workspace.artifacts (tenant_id, organization_id, artifact_id, asset_id, project_id, folder_id, artifact_kind,
                                          inherit_project_access, created_via, created_by, updated_by)
    VALUES (v_tenant, v_org, v_artifact, v_asset, p_project_id, p_folder_id, p_artifact_kind, p_inherit_project_access,
            CASE WHEN cob3_identity.ctx_is_interactive() THEN 'manual' ELSE 'automation' END, v_actor, v_actor);
    INSERT INTO cob3_workspace.artifact_revisions (tenant_id, organization_id, artifact_revision_id, artifact_id, revision_number,
                                                   content_kind, definition, definition_schema_version, content_sha256,
                                                   change_note, author_principal_id, created_by, updated_by)
    VALUES (v_tenant, v_org, v_revision, v_artifact, 1, 'inline', p_definition, p_definition_schema_version, p_content_sha256,
            p_change_note, cob3_identity.ctx_principal_id(), v_actor, v_actor);
    UPDATE cob3_workspace.artifacts SET current_revision_id = v_revision, updated_by = v_actor
     WHERE tenant_id = v_tenant AND organization_id = v_org AND artifact_id = v_artifact;
    RETURN v_artifact;
END
$fn$;

-- Optimistic head advance: fails with SKINV when the caller's head is stale.
CREATE FUNCTION cob3_workspace.commit_artifact_revision(
        p_artifact_id uuid, p_expected_row_version bigint, p_content_kind text, p_definition jsonb,
        p_file_object_id uuid, p_external_location_id uuid, p_definition_schema_version integer,
        p_content_sha256 bytea, p_change_note text DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant   uuid := cob3_identity.ctx_tenant_id();
    v_org      uuid := cob3_identity.ctx_organization_id();
    v_actor    text := cob3_identity.ctx_actor();
    a          cob3_workspace.artifacts%ROWTYPE;
    v_next     bigint;
    v_revision uuid := gen_random_uuid();
BEGIN
    PERFORM cob3_catalog.require_org_context();
    SELECT x.* INTO a FROM cob3_workspace.artifacts x
     WHERE x.tenant_id = v_tenant AND x.organization_id = v_org AND x.artifact_id = p_artifact_id
       FOR UPDATE;
    IF NOT FOUND OR NOT cob3_catalog.ctx_asset_permitted(v_org, a.asset_id, 'artifact.update') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'artifact.update on the artifact is required.';
    END IF;
    IF a.row_version <> p_expected_row_version THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Stale artifact head: expected row_version %s, current %s.', p_expected_row_version, a.row_version);
    END IF;
    SELECT COALESCE(pg_catalog.max(r.revision_number), 0) + 1 INTO v_next FROM cob3_workspace.artifact_revisions r
     WHERE r.tenant_id = v_tenant AND r.organization_id = v_org AND r.artifact_id = p_artifact_id;
    INSERT INTO cob3_workspace.artifact_revisions (tenant_id, organization_id, artifact_revision_id, artifact_id, revision_number,
                                                   content_kind, definition, file_object_id, external_location_id,
                                                   definition_schema_version, content_sha256, change_note, author_principal_id,
                                                   created_by, updated_by)
    VALUES (v_tenant, v_org, v_revision, p_artifact_id, v_next, p_content_kind, p_definition, p_file_object_id,
            p_external_location_id, p_definition_schema_version, p_content_sha256, p_change_note,
            cob3_identity.ctx_principal_id(), v_actor, v_actor);
    UPDATE cob3_workspace.artifacts SET current_revision_id = v_revision, updated_by = v_actor
     WHERE tenant_id = v_tenant AND organization_id = v_org AND artifact_id = p_artifact_id;
    RETURN v_revision;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Settings: scope handles, resolver (7.2), restrictive automation policy.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_settings.ensure_scope(p_scope_type text, p_team_id uuid DEFAULT NULL, p_project_id uuid DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant    uuid := cob3_identity.ctx_tenant_id();
    v_org       uuid := cob3_identity.ctx_organization_id();
    v_principal uuid := cob3_identity.ctx_principal_id();
    v_actor     text := cob3_identity.ctx_actor();
    v_s_org     uuid;
    v_s_prin    uuid;
    v_s_team    uuid;
    v_s_proj    uuid;
    v_asset     uuid;
    v_id        uuid;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    CASE p_scope_type
        WHEN 'tenant' THEN NULL;
        WHEN 'organization' THEN v_s_org := v_org;
        WHEN 'team' THEN v_s_org := v_org; v_s_team := p_team_id;
        WHEN 'principal' THEN v_s_prin := v_principal;
        WHEN 'principal_org' THEN v_s_org := v_org; v_s_prin := v_principal;
        WHEN 'project' THEN
            v_s_org := v_org; v_s_proj := p_project_id;
            SELECT p.asset_id INTO v_asset FROM cob3_workspace.projects p
             WHERE p.tenant_id = v_tenant AND p.organization_id = v_org AND p.project_id = p_project_id;
            IF NOT cob3_catalog.ctx_asset_permitted(v_org, v_asset, 'project.read') THEN
                RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'project.read is required for a project settings scope.';
            END IF;
        ELSE
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown settings scope type %L.', p_scope_type);
    END CASE;
    IF v_s_org IS NOT NULL AND NOT cob3_identity.ctx_in_org() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'An organization context is required for this settings scope.';
    END IF;
    IF p_scope_type IN ('principal', 'principal_org') AND NOT cob3_identity.ctx_is_interactive() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Personal settings scopes are interactive self-service only.';
    END IF;
    PERFORM cob3_identity.xact_lock('settings.scope', pg_catalog.concat_ws(':', v_tenant, p_scope_type, v_s_org, v_s_prin, v_s_team, v_s_proj));
    SELECT s.setting_scope_id INTO v_id FROM cob3_settings.setting_scopes s
     WHERE s.tenant_id = v_tenant AND s.scope_type = p_scope_type
       AND s.organization_id IS NOT DISTINCT FROM v_s_org AND s.principal_id IS NOT DISTINCT FROM v_s_prin
       AND s.team_id IS NOT DISTINCT FROM v_s_team AND s.project_id IS NOT DISTINCT FROM v_s_proj;
    IF v_id IS NULL THEN
        INSERT INTO cob3_settings.setting_scopes (tenant_id, organization_id, scope_type, principal_id, team_id, project_id,
                                                  created_by, updated_by)
        VALUES (v_tenant, v_s_org, p_scope_type, v_s_prin, v_s_team, v_s_proj, v_actor, v_actor)
        RETURNING setting_scope_id INTO v_id;
    END IF;
    RETURN v_id;
END
$fn$;

-- Effective value for the CURRENT context: default -> tenant -> organization
-- -> selected team -> principal -> principal_org -> project (when allowed).
-- Replacement per key; tenant/organization locks stop lower levels.
CREATE FUNCTION cob3_settings.resolve_setting(p_setting_key text, p_team_id uuid DEFAULT NULL, p_project_id uuid DEFAULT NULL)
    RETURNS TABLE (value jsonb, definition_version integer, winning_scope_type text, winning_scope_id uuid, locked_at_scope text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_tenant    uuid := cob3_identity.ctx_tenant_id();
    v_org       uuid := cob3_identity.ctx_organization_id();
    v_principal uuid := cob3_identity.ctx_principal_id();
    d           cob3_settings.setting_definitions%ROWTYPE;
    v_asset     uuid;
    r           record;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    SELECT x.* INTO d FROM cob3_settings.setting_definitions x WHERE x.setting_key = p_setting_key AND x.status = 'active';
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown setting %L.', p_setting_key);
    END IF;
    IF p_team_id IS NOT NULL AND (v_org IS NULL OR p_team_id NOT IN (
           SELECT cob3_identity.effective_team_ids(v_tenant, v_org, v_principal, pg_catalog.now()))) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'The selected team is not an effective team of the caller.';
    END IF;
    IF p_project_id IS NOT NULL THEN
        SELECT p.asset_id INTO v_asset FROM cob3_workspace.projects p
         WHERE p.tenant_id = v_tenant AND p.organization_id = v_org AND p.project_id = p_project_id;
        IF NOT cob3_catalog.ctx_asset_permitted(v_org, v_asset, 'project.read') THEN
            RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'project.read is required for project settings.';
        END IF;
    END IF;
    SELECT c.* INTO r
      FROM (SELECT v.value, s.scope_type, s.setting_scope_id, v.is_locked,
                   CASE s.scope_type WHEN 'tenant' THEN 1 WHEN 'organization' THEN 2 WHEN 'team' THEN 3
                                     WHEN 'principal' THEN 4 WHEN 'principal_org' THEN 5 WHEN 'project' THEN 6 END AS precedence
              FROM cob3_settings.setting_values v
              JOIN cob3_settings.setting_scopes s ON s.tenant_id = v.tenant_id AND s.setting_scope_id = v.setting_scope_id
             WHERE v.tenant_id = v_tenant AND v.setting_definition_id = d.setting_definition_id AND s.status = 'active'
               AND s.scope_type = ANY (d.allowed_scopes)
               AND (   s.scope_type = 'tenant'
                    OR (s.scope_type = 'organization'  AND s.organization_id = v_org)
                    OR (s.scope_type = 'team'          AND s.organization_id = v_org AND s.team_id = p_team_id)
                    OR (s.scope_type = 'principal'     AND s.principal_id = v_principal AND d.user_overridable)
                    OR (s.scope_type = 'principal_org' AND s.organization_id = v_org AND s.principal_id = v_principal AND d.user_overridable)
                    OR (s.scope_type = 'project'       AND s.organization_id = v_org AND s.project_id = p_project_id))) AS c
     ORDER BY CASE WHEN c.is_locked THEN 0 ELSE 1 END,          -- the highest lock wins outright
              CASE WHEN c.is_locked THEN c.precedence ELSE -c.precedence END
     LIMIT 1;
    IF r IS NULL OR r.value IS NULL THEN
        RETURN QUERY SELECT d.default_value, d.definition_version, 'default'::text, NULL::uuid, NULL::text;
    ELSE
        RETURN QUERY SELECT r.value, d.definition_version, r.scope_type::text, r.setting_scope_id,
                            CASE WHEN r.is_locked THEN r.scope_type::text END;
    END IF;
END
$fn$;

-- Restrictive composition: allow AND, lifetimes MIN, approvals OR. No active
-- tenant policy => unattended execution denied (nothing defaults to unlimited).
CREATE FUNCTION cob3_settings.effective_automation_policy(p_tenant_id uuid, p_organization_id uuid)
    RETURNS TABLE (allow_automation boolean, max_grant_lifetime_seconds integer, max_credential_lifetime_seconds integer,
                   require_approval_for_writes boolean, allow_external_delivery boolean,
                   tenant_policy_version integer, organization_policy_version integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    t cob3_settings.automation_policies%ROWTYPE;
    o cob3_settings.automation_policies%ROWTYPE;
BEGIN
    IF p_tenant_id IS DISTINCT FROM cob3_identity.ctx_tenant_id() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'Policy lookup is limited to the context tenant.';
    END IF;
    SELECT x.* INTO t FROM cob3_settings.automation_policies x
     WHERE x.tenant_id = p_tenant_id AND x.organization_id IS NULL AND x.status = 'active';
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, NULL::integer, NULL::integer, true, false, NULL::integer, NULL::integer;
        RETURN;
    END IF;
    SELECT x.* INTO o FROM cob3_settings.automation_policies x
     WHERE x.tenant_id = p_tenant_id AND x.organization_id = p_organization_id AND x.status = 'active';
    RETURN QUERY SELECT
        t.allow_automation AND COALESCE(o.allow_automation, true),
        LEAST(t.max_grant_lifetime_seconds, COALESCE(o.max_grant_lifetime_seconds, t.max_grant_lifetime_seconds)),
        LEAST(t.max_credential_lifetime_seconds, COALESCE(o.max_credential_lifetime_seconds, t.max_credential_lifetime_seconds)),
        t.require_approval_for_writes OR COALESCE(o.require_approval_for_writes, false),
        t.allow_external_delivery AND COALESCE(o.allow_external_delivery, true),
        t.policy_version, o.policy_version;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Email proof of control (Identity). Raw tokens never reach the database;
-- callers pass a digest. Digest comparison in SQL is not constant-time.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.issue_email_verification(p_principal_email_id uuid, p_token_digest bytea, p_expires_at timestamptz)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_actor  text := cob3_identity.ctx_actor();
    e        cob3_identity.principal_emails%ROWTYPE;
    v_id     uuid;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    SELECT x.* INTO e FROM cob3_identity.principal_emails x
     WHERE x.tenant_id = v_tenant AND x.principal_email_id = p_principal_email_id FOR UPDATE;
    IF NOT FOUND
       OR NOT ((e.principal_id = cob3_identity.ctx_principal_id() AND cob3_identity.ctx_is_interactive())
               OR cob3_identity.ctx_can_manage_principal(e.principal_id)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Not permitted to verify this address.';
    END IF;
    IF e.status <> 'active' OR e.verified_at IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Only active unverified addresses can be verified.';
    END IF;
    IF p_expires_at <= pg_catalog.now() OR p_expires_at > pg_catalog.now() + interval '24 hours' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Challenge expiry must be within the next 24 hours.';
    END IF;
    UPDATE cob3_identity.email_verification_challenges
       SET revoked_at = pg_catalog.now(), updated_by = v_actor
     WHERE tenant_id = v_tenant AND principal_email_id = p_principal_email_id
       AND consumed_at IS NULL AND revoked_at IS NULL;
    INSERT INTO cob3_identity.email_verification_challenges (tenant_id, principal_email_id, token_digest, expires_at, created_by, updated_by)
    VALUES (v_tenant, p_principal_email_id, p_token_digest, p_expires_at, v_actor, v_actor)
    RETURNING email_verification_challenge_id INTO v_id;
    PERFORM cob3_identity.audit_ctx('identity.email_verification_issued', 'principal_email', p_principal_email_id);
    RETURN v_id;
END
$fn$;

-- Owner proof of control: returns true on success; failed attempts are
-- counted and persisted (no exception), five failures revoke the challenge.
CREATE FUNCTION cob3_identity.consume_email_verification(p_principal_email_id uuid, p_token_digest bytea)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_actor  text := cob3_identity.ctx_actor();
    c        cob3_identity.email_verification_challenges%ROWTYPE;
BEGIN
    IF NOT cob3_identity.ctx_is_interactive() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'Email verification requires the address owner''s interactive session.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cob3_identity.principal_emails e
                    WHERE e.tenant_id = v_tenant AND e.principal_email_id = p_principal_email_id
                      AND e.principal_id = cob3_identity.ctx_principal_id() AND e.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Not permitted to verify this address.';
    END IF;
    SELECT x.* INTO c FROM cob3_identity.email_verification_challenges x
     WHERE x.tenant_id = v_tenant AND x.principal_email_id = p_principal_email_id
       AND x.consumed_at IS NULL AND x.revoked_at IS NULL
     ORDER BY x.created_at DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    IF c.expires_at <= pg_catalog.now() OR c.attempt_count >= 5 THEN
        UPDATE cob3_identity.email_verification_challenges SET revoked_at = pg_catalog.now(), updated_by = v_actor
         WHERE tenant_id = v_tenant AND email_verification_challenge_id = c.email_verification_challenge_id;
        RETURN false;
    END IF;
    IF c.token_digest IS DISTINCT FROM p_token_digest THEN
        UPDATE cob3_identity.email_verification_challenges SET attempt_count = c.attempt_count + 1, updated_by = v_actor
         WHERE tenant_id = v_tenant AND email_verification_challenge_id = c.email_verification_challenge_id;
        RETURN false;
    END IF;
    UPDATE cob3_identity.email_verification_challenges
       SET consumed_at = pg_catalog.now(), attempt_count = c.attempt_count + 1, updated_by = v_actor
     WHERE tenant_id = v_tenant AND email_verification_challenge_id = c.email_verification_challenge_id;
    UPDATE cob3_identity.principal_emails
       SET verified_at = pg_catalog.now(), verification_source = 'email_challenge', updated_by = v_actor
     WHERE tenant_id = v_tenant AND principal_email_id = p_principal_email_id AND verified_at IS NULL;
    PERFORM cob3_identity.audit_ctx('identity.email_verified', 'principal_email', p_principal_email_id);
    RETURN true;
END
$fn$;
