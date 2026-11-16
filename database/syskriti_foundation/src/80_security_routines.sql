-- =============================================================================
-- 80  CONTROLLED SECURITY ROUTINES
-- -----------------------------------------------------------------------------
-- High-risk identity state (grants, credentials, approvals, sessions,
-- service/automation creation, bootstrap) is written only through these
-- SECURITY DEFINER routines. Each validates caller authority from the
-- transaction-local request context (runtime) or from role membership
-- (EXECUTE granted only to cob3_provisioner / cob3_commercial_admin).
-- Successful operations are audited in the same transaction. Denials raise;
-- the backend records denial audit events in a separate transaction.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit writing
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.write_audit_event(
        p_tenant_id                         uuid,
        p_organization_id                   uuid,
        p_actor_principal_id                uuid,
        p_actor_identifier                  text,
        p_action                            text,
        p_target_type                       text,
        p_target_id                         uuid,
        p_outcome                           text,
        p_reason_code                       text    DEFAULT NULL,
        p_details                           jsonb   DEFAULT '{}'::jsonb,
        p_request_id                        uuid    DEFAULT NULL,
        p_correlation_id                    text    DEFAULT NULL,
        p_ip_address                        inet    DEFAULT NULL,
        p_session_id                        uuid    DEFAULT NULL,
        p_credential_id                     uuid    DEFAULT NULL,
        p_authorization_grant_id            uuid    DEFAULT NULL,
        p_authorization_grant_permission_id uuid    DEFAULT NULL,
        p_action_approval_id                uuid    DEFAULT NULL,
        p_on_behalf_of_principal_id         uuid    DEFAULT NULL,
        p_initiating_principal_id           uuid    DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_org     uuid := p_organization_id;
    v_details jsonb := COALESCE(p_details, '{}'::jsonb);
    v_actor   text := COALESCE(NULLIF(pg_catalog.btrim(p_actor_identifier), ''), 'unauthenticated');
    v_writer  text;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- Record an organization only after resolving it; keep an unverified
    -- claim in redacted details instead of blocking the audit insert.
    IF v_org IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cob3_identity.organizations o
                                          WHERE o.tenant_id = p_tenant_id AND o.organization_id = v_org) THEN
        v_details := v_details || pg_catalog.jsonb_build_object('claimed_organization_id', v_org::text);
        v_org := NULL;
    END IF;
    v_writer := CASE WHEN v_actor ~ '^(principal:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|system:[a-z0-9][a-z0-9_.:-]{0,200})$'
                     THEN v_actor ELSE 'system:audit-writer' END;
    INSERT INTO cob3_identity.audit_events
           (tenant_id, audit_event_id, organization_id, occurred_at, actor_principal_id, actor_identifier,
            on_behalf_of_principal_id, initiating_principal_id, credential_id, session_id,
            authorization_grant_id, authorization_grant_permission_id, action_approval_id,
            action, target_type, target_id, outcome, reason_code, request_id, correlation_id, ip_address,
            details, created_by, updated_by)
    VALUES (p_tenant_id, v_id, v_org, pg_catalog.clock_timestamp(), p_actor_principal_id, v_actor,
            p_on_behalf_of_principal_id, p_initiating_principal_id, p_credential_id, p_session_id,
            p_authorization_grant_id, p_authorization_grant_permission_id, p_action_approval_id,
            p_action, p_target_type, p_target_id, p_outcome, p_reason_code, p_request_id, p_correlation_id, p_ip_address,
            v_details, v_writer, v_writer);
    RETURN v_id;
END
$fn$;

-- Audit from the current request context (used by routines below).
CREATE FUNCTION cob3_identity.audit_ctx(
        p_action text, p_target_type text, p_target_id uuid, p_details jsonb DEFAULT '{}'::jsonb,
        p_grant_id uuid DEFAULT NULL, p_grant_permission_id uuid DEFAULT NULL, p_approval_id uuid DEFAULT NULL,
        p_on_behalf_of uuid DEFAULT NULL)
    RETURNS uuid
    LANGUAGE sql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_identity.write_audit_event(
        cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), cob3_identity.ctx_principal_id(),
        cob3_identity.ctx_actor(), p_action, p_target_type, p_target_id, 'success', NULL, p_details, NULL, NULL, NULL,
        cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(), p_grant_id, p_grant_permission_id,
        p_approval_id, p_on_behalf_of, NULL)
$fn$;

-- Runtime: audit (including denials) for the context tenant. Does not require
-- a valid authenticated context so denied requests remain auditable.
CREATE FUNCTION cob3_identity.record_audit_event(
        p_action            text,
        p_target_type       text,
        p_target_id         uuid,
        p_outcome           text,
        p_reason_code       text  DEFAULT NULL,
        p_details           jsonb DEFAULT '{}'::jsonb,
        p_request_id        uuid  DEFAULT NULL,
        p_correlation_id    text  DEFAULT NULL,
        p_ip_address        inet  DEFAULT NULL,
        p_authorization_grant_id            uuid DEFAULT NULL,
        p_authorization_grant_permission_id uuid DEFAULT NULL,
        p_action_approval_id                uuid DEFAULT NULL,
        p_on_behalf_of_principal_id         uuid DEFAULT NULL,
        p_initiating_principal_id           uuid DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF cob3_identity.ctx_tenant_id() IS NULL
       OR NOT EXISTS (SELECT 1 FROM cob3_tenant.tenants t WHERE t.tenant_id = cob3_identity.ctx_tenant_id()) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'Audit events require a resolved tenant context.';
    END IF;
    RETURN cob3_identity.write_audit_event(
        cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), cob3_identity.ctx_principal_id(),
        cob3_identity.ctx_actor(), p_action, p_target_type, p_target_id, p_outcome, p_reason_code, p_details,
        p_request_id, p_correlation_id, p_ip_address, cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(),
        p_authorization_grant_id, p_authorization_grant_permission_id, p_action_approval_id,
        p_on_behalf_of_principal_id, p_initiating_principal_id);
END
$fn$;

-- Platform roles: explicit tenant and system actor.
CREATE FUNCTION cob3_identity.record_platform_audit_event(
        p_tenant_id uuid, p_organization_id uuid, p_actor text, p_action text, p_target_type text, p_target_id uuid,
        p_outcome text, p_reason_code text DEFAULT NULL, p_details jsonb DEFAULT '{}'::jsonb,
        p_request_id uuid DEFAULT NULL, p_correlation_id text DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF p_actor IS NULL OR p_actor !~ '^system:[a-z0-9][a-z0-9_.:-]{0,200}$' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'Platform audit actor must match system:<name>.';
    END IF;
    RETURN cob3_identity.write_audit_event(p_tenant_id, p_organization_id, NULL, p_actor, p_action, p_target_type,
                                           p_target_id, p_outcome, p_reason_code, p_details, p_request_id, p_correlation_id);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Core IAM templates (generic, product-independent). Product permissions are
-- registered by optional seed scripts through register_tenant_* routines.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.core_permission_templates()
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
        ('domain.read',                     'domain',          'read',                     'organization',   true,  true,  false, 'Read a Catalog domain (resource-dependent: denied until Catalog integration)')
$fn$;

CREATE FUNCTION cob3_identity.core_role_templates()
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

-- Idempotent registration primitives (provisioning role; used by product seeds).
CREATE FUNCTION cob3_identity.register_tenant_permission(
        p_tenant_id uuid, p_permission_code text, p_resource_type text, p_action text, p_permission_class text,
        p_is_delegable boolean, p_automation_allowed boolean, p_is_identity_management boolean,
        p_description text, p_actor text DEFAULT 'system:provisioning')
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_p cob3_identity.permissions%ROWTYPE;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    SELECT x.* INTO v_p FROM cob3_identity.permissions x WHERE x.tenant_id = p_tenant_id AND x.permission_code = p_permission_code;
    IF v_p.permission_id IS NOT NULL THEN
        IF (v_p.resource_type, v_p.action, v_p.permission_class, v_p.is_delegable, v_p.automation_allowed, v_p.is_identity_management)
           IS DISTINCT FROM (p_resource_type, p_action, p_permission_class, p_is_delegable, p_automation_allowed, p_is_identity_management) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Permission %s already exists with a different definition; use a reviewed migration.', p_permission_code);
        END IF;
        RETURN v_p.permission_id;
    END IF;
    INSERT INTO cob3_identity.permissions
           (tenant_id, permission_code, resource_type, action, description, permission_class,
            is_delegable, automation_allowed, is_identity_management, created_by, updated_by)
    VALUES (p_tenant_id, p_permission_code, p_resource_type, p_action, p_description, p_permission_class,
            p_is_delegable, p_automation_allowed, p_is_identity_management, p_actor, p_actor)
    RETURNING permission_id INTO v_p.permission_id;
    RETURN v_p.permission_id;
END
$fn$;

CREATE FUNCTION cob3_identity.register_tenant_role(
        p_tenant_id uuid, p_role_code text, p_name text, p_role_class text, p_description text DEFAULT NULL,
        p_actor text DEFAULT 'system:provisioning')
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_r cob3_identity.roles%ROWTYPE;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    SELECT x.* INTO v_r FROM cob3_identity.roles x WHERE x.tenant_id = p_tenant_id AND x.role_code = p_role_code;
    IF v_r.role_id IS NOT NULL THEN
        IF v_r.role_class <> p_role_class THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Role %s already exists with class %s.', p_role_code, v_r.role_class);
        END IF;
        RETURN v_r.role_id;
    END IF;
    INSERT INTO cob3_identity.roles (tenant_id, role_code, name, description, role_class, is_system, created_by, updated_by)
    VALUES (p_tenant_id, p_role_code, p_name, p_description, p_role_class, true, p_actor, p_actor)
    RETURNING role_id INTO v_r.role_id;
    RETURN v_r.role_id;
END
$fn$;

CREATE FUNCTION cob3_identity.add_role_permission(
        p_tenant_id uuid, p_role_code text, p_permission_code text, p_actor text DEFAULT 'system:provisioning')
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_role uuid;
    v_perm uuid;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    SELECT r.role_id INTO v_role FROM cob3_identity.roles r WHERE r.tenant_id = p_tenant_id AND r.role_code = p_role_code;
    SELECT p.permission_id INTO v_perm FROM cob3_identity.permissions p WHERE p.tenant_id = p_tenant_id AND p.permission_code = p_permission_code;
    IF v_role IS NULL OR v_perm IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Unknown role %s or permission %s for tenant.', p_role_code, p_permission_code);
    END IF;
    INSERT INTO cob3_identity.role_permissions (tenant_id, role_id, permission_id, created_by, updated_by)
    VALUES (p_tenant_id, v_role, v_perm, p_actor, p_actor)
    ON CONFLICT ON CONSTRAINT role_permissions_role_permission_uq DO NOTHING;
END
$fn$;

-- Per-tenant core IAM seed (tenant-owned rows; never NULL tenant).
CREATE FUNCTION cob3_identity.provision_tenant_iam_seed(p_tenant_id uuid, p_actor text DEFAULT 'system:provisioning')
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_t record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Unknown tenant.';
    END IF;
    FOR v_t IN SELECT * FROM cob3_identity.core_permission_templates() LOOP
        PERFORM cob3_identity.register_tenant_permission(p_tenant_id, v_t.permission_code, v_t.resource_type, v_t.action,
                    v_t.permission_class, v_t.is_delegable, v_t.automation_allowed, v_t.is_identity_management,
                    v_t.description, p_actor);
    END LOOP;
    FOR v_t IN SELECT DISTINCT r.role_code, r.role_name, r.role_class FROM cob3_identity.core_role_templates() r LOOP
        PERFORM cob3_identity.register_tenant_role(p_tenant_id, v_t.role_code, v_t.role_name, v_t.role_class, NULL, p_actor);
    END LOOP;
    FOR v_t IN SELECT r.role_code, r.permission_code FROM cob3_identity.core_role_templates() r LOOP
        PERFORM cob3_identity.add_role_permission(p_tenant_id, v_t.role_code, v_t.permission_code, p_actor);
    END LOOP;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Bootstrap (provisioning role). Works only while the tenant is still
-- 'provisioning' and has no tenant administrator: not a permanent open door.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.bootstrap_tenant_administration(
        p_tenant_id uuid, p_organization_code text, p_organization_name text,
        p_admin_principal_code text, p_admin_display_name text, p_admin_email text,
        p_actor text DEFAULT 'system:bootstrap',
        OUT organization_id uuid, OUT admin_principal_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_variable
DECLARE
    v_status text;
    v_scope  uuid;
    v_org    uuid := gen_random_uuid();
    v_admin  uuid := gen_random_uuid();
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    SELECT t.status INTO v_status FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id FOR UPDATE;
    IF v_status IS DISTINCT FROM 'provisioning' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Bootstrap is allowed only for a tenant in provisioning status.';
    END IF;
    IF EXISTS (SELECT 1 FROM cob3_identity.tenant_role_bindings b WHERE b.tenant_id = p_tenant_id AND b.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Tenant administration was already bootstrapped.';
    END IF;
    PERFORM cob3_identity.provision_tenant_iam_seed(p_tenant_id, p_actor);

    INSERT INTO cob3_identity.organizations (tenant_id, organization_id, organization_code, name, status, created_by, updated_by)
    VALUES (p_tenant_id, v_org, p_organization_code, p_organization_name, 'active', p_actor, p_actor);
    INSERT INTO cob3_identity.access_scopes (tenant_id, organization_id, scope_type, include_contained_assets, created_by, updated_by)
    VALUES (p_tenant_id, v_org, 'organization', false, p_actor, p_actor)
    RETURNING scope_id INTO v_scope;

    INSERT INTO cob3_identity.principals (tenant_id, principal_id, principal_type, principal_code, display_name, status, created_by, updated_by)
    VALUES (p_tenant_id, v_admin, 'human', p_admin_principal_code, p_admin_display_name, 'active', p_actor, p_actor);
    INSERT INTO cob3_identity.user_profiles (tenant_id, principal_id, email, created_by, updated_by)
    VALUES (p_tenant_id, v_admin, p_admin_email, p_actor, p_actor);
    INSERT INTO cob3_identity.organization_memberships
           (tenant_id, organization_id, principal_id, membership_type, status, created_by, updated_by)
    VALUES (p_tenant_id, v_org, v_admin, 'employee', 'active', p_actor, p_actor);

    INSERT INTO cob3_identity.tenant_role_bindings (tenant_id, principal_id, role_id, grant_reason, created_by, updated_by)
    SELECT p_tenant_id, v_admin, r.role_id, 'Initial tenant administrator (controlled bootstrap)', p_actor, p_actor
      FROM cob3_identity.roles r WHERE r.tenant_id = p_tenant_id AND r.role_code = 'tenant_administrator';
    INSERT INTO cob3_identity.role_bindings (tenant_id, organization_id, role_id, scope_id, principal_id, grant_reason, created_by, updated_by)
    SELECT p_tenant_id, v_org, r.role_id, v_scope, v_admin, 'Initial organization administrator (controlled bootstrap)', p_actor, p_actor
      FROM cob3_identity.roles r WHERE r.tenant_id = p_tenant_id AND r.role_code = 'organization_administrator';

    PERFORM cob3_identity.write_audit_event(p_tenant_id, v_org, NULL, p_actor, 'tenant.bootstrap_administration',
                                            'principal', v_admin, 'success', NULL,
                                            pg_catalog.jsonb_build_object('organization_code', p_organization_code));
    organization_id := v_org;
    admin_principal_id := v_admin;
END
$fn$;

CREATE FUNCTION cob3_identity.bootstrap_tenant(
        p_tenant_code text, p_tenant_name text, p_legal_name text, p_home_region text,
        p_organization_code text, p_organization_name text,
        p_admin_principal_code text, p_admin_display_name text, p_admin_email text,
        p_request_id uuid, p_activate boolean DEFAULT true, p_actor text DEFAULT 'system:bootstrap',
        OUT tenant_id uuid, OUT organization_id uuid, OUT admin_principal_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_variable
DECLARE
    v_tenant uuid;
    v_res    record;
BEGIN
    v_tenant := cob3_tenant.create_tenant(p_tenant_code, p_tenant_name, p_legal_name, p_home_region,
                                          p_request_id, 'Tenant created by controlled bootstrap', p_actor);
    SELECT * INTO v_res FROM cob3_identity.bootstrap_tenant_administration(
        v_tenant, p_organization_code, p_organization_name, p_admin_principal_code, p_admin_display_name, p_admin_email, p_actor);
    IF p_activate THEN
        PERFORM cob3_tenant.transition_tenant_status(v_tenant, 'active', 'Bootstrap complete',
                    pg_catalog.md5(p_request_id::text || ':activate')::uuid, p_actor);
    END IF;
    tenant_id := v_tenant;
    organization_id := v_res.organization_id;
    admin_principal_id := v_res.admin_principal_id;
END
$fn$;

-- Federation bootstrap/recovery path for the platform (audited). Normal
-- tenant administration uses direct DML guarded by RLS + triggers.
CREATE FUNCTION cob3_identity.bootstrap_identity_provider(
        p_tenant_id uuid, p_provider_code text, p_name text, p_protocol text, p_issuer text,
        p_configuration_reference text, p_actor text DEFAULT 'system:bootstrap')
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_id uuid;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    INSERT INTO cob3_identity.identity_providers
           (tenant_id, provider_code, name, protocol, issuer, configuration_reference, created_by, updated_by)
    VALUES (p_tenant_id, p_provider_code, p_name, p_protocol, p_issuer, p_configuration_reference, p_actor, p_actor)
    RETURNING identity_provider_id INTO v_id;
    PERFORM cob3_identity.write_audit_event(p_tenant_id, NULL, NULL, p_actor, 'identity_provider.bootstrap',
                                            'identity_provider', v_id, 'success');
    RETURN v_id;
END
$fn$;

CREATE FUNCTION cob3_identity.bootstrap_link_external_identity(
        p_tenant_id uuid, p_principal_id uuid, p_identity_provider_id uuid, p_subject text,
        p_actor text DEFAULT 'system:bootstrap')
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_id uuid;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    INSERT INTO cob3_identity.external_identities (tenant_id, principal_id, identity_provider_id, subject, created_by, updated_by)
    VALUES (p_tenant_id, p_principal_id, p_identity_provider_id, p_subject, p_actor, p_actor)
    RETURNING external_identity_id INTO v_id;
    PERFORM cob3_identity.write_audit_event(p_tenant_id, NULL, NULL, p_actor, 'external_identity.bootstrap_link',
                                            'principal', p_principal_id, 'success');
    RETURN v_id;
END
$fn$;

-- Pre-authentication lookup for the trusted authentication adapter.
CREATE FUNCTION cob3_identity.lookup_identity_providers(p_tenant_id uuid)
    RETURNS TABLE (identity_provider_id uuid, provider_code text, protocol text, issuer text, configuration_reference text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT ip.identity_provider_id, ip.provider_code::text, ip.protocol::text, ip.issuer, ip.configuration_reference::text
      FROM cob3_identity.identity_providers ip
      JOIN cob3_tenant.tenants t ON t.tenant_id = ip.tenant_id
     WHERE ip.tenant_id = p_tenant_id AND ip.status = 'active' AND t.status IN ('active', 'suspended')
$fn$;

-- ---------------------------------------------------------------------------
-- Service account and automation creation (principal + subtype + membership
-- in one transaction; quota and entitlement enforced by triggers).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.create_service_account(
        p_principal_code text, p_display_name text, p_owner_principal_id uuid, p_purpose text,
        p_expires_at timestamptz DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_actor  text := cob3_identity.ctx_actor();
    v_id     uuid := gen_random_uuid();
BEGIN
    PERFORM cob3_identity.require_ctx_permission('service_account.manage');
    INSERT INTO cob3_identity.principals (tenant_id, principal_id, principal_type, principal_code, display_name, status, created_by, updated_by)
    VALUES (v_tenant, v_id, 'service_account', p_principal_code, p_display_name, 'active', v_actor, v_actor);
    INSERT INTO cob3_identity.organization_memberships (tenant_id, organization_id, principal_id, membership_type, status, created_by, updated_by)
    VALUES (v_tenant, v_org, v_id, 'service', 'active', v_actor, v_actor);
    INSERT INTO cob3_identity.service_accounts
           (tenant_id, principal_id, organization_id, creator_principal_id, owner_principal_id, purpose, expires_at, created_by, updated_by)
    VALUES (v_tenant, v_id, v_org, cob3_identity.ctx_principal_id(), p_owner_principal_id, p_purpose, p_expires_at, v_actor, v_actor);
    PERFORM cob3_identity.audit_ctx('service_account.create', 'service_account', v_id);
    RETURN v_id;
END
$fn$;

CREATE FUNCTION cob3_identity.create_automation(
        p_principal_code text, p_display_name text, p_owner_principal_id uuid, p_purpose text,
        p_automation_category text, p_creation_method text DEFAULT 'portal', p_expires_at timestamptz DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_actor  text := cob3_identity.ctx_actor();
    v_id     uuid := gen_random_uuid();
BEGIN
    PERFORM cob3_identity.require_ctx_permission('automation.create');
    IF cob3_identity.ctx_is_interactive() THEN
        IF p_creation_method NOT IN ('portal', 'api') THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Interactive creation method must be portal or api.';
        END IF;
    ELSIF p_creation_method <> 'provisioning' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Credential-based creation is recorded as provisioning.';
    END IF;
    INSERT INTO cob3_identity.principals (tenant_id, principal_id, principal_type, principal_code, display_name, status, created_by, updated_by)
    VALUES (v_tenant, v_id, 'automation', p_principal_code, p_display_name, 'active', v_actor, v_actor);
    INSERT INTO cob3_identity.organization_memberships (tenant_id, organization_id, principal_id, membership_type, status, created_by, updated_by)
    VALUES (v_tenant, v_org, v_id, 'automation', 'active', v_actor, v_actor);
    INSERT INTO cob3_identity.automation_profiles
           (tenant_id, principal_id, organization_id, creator_principal_id, owner_principal_id, purpose,
            automation_category, creation_method, expires_at, created_by, updated_by)
    VALUES (v_tenant, v_id, v_org, cob3_identity.ctx_principal_id(), p_owner_principal_id, p_purpose,
            p_automation_category, p_creation_method, p_expires_at, v_actor, v_actor);
    PERFORM cob3_identity.audit_ctx('automation.create', 'automation', v_id);
    RETURN v_id;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Grant lifecycle
-- ---------------------------------------------------------------------------
-- Authority over a grantor: the grantor itself, or a manager of a service
-- account grantor (service_account.manage). For delegated grants the caller
-- must also own/have created the automation, or hold automation.manage.
CREATE FUNCTION cob3_identity.assert_grant_authority(p_grantor uuid, p_grantee uuid, p_grant_type text)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_ctx    uuid := cob3_identity.ctx_principal_id();
BEGIN
    IF NOT (p_grantor = v_ctx
            OR (cob3_identity.principal_type_of(v_tenant, p_grantor) = 'service_account'
                AND EXISTS (SELECT 1 FROM cob3_identity.service_accounts s
                             WHERE s.tenant_id = v_tenant AND s.principal_id = p_grantor AND s.organization_id = v_org)
                AND cob3_identity.ctx_has_org_permission('service_account.manage'))) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Caller has no authority to act for this grantor.';
    END IF;
    IF p_grant_type = 'delegated' AND NOT (
           EXISTS (SELECT 1 FROM cob3_identity.automation_profiles a
                    WHERE a.tenant_id = v_tenant AND a.principal_id = p_grantee AND a.organization_id = v_org
                      AND (a.owner_principal_id IN (v_ctx, p_grantor) OR a.creator_principal_id IN (v_ctx, p_grantor)))
           OR cob3_identity.ctx_has_org_permission('automation.manage')) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Caller does not own or manage the grantee automation.';
    END IF;
END
$fn$;

CREATE FUNCTION cob3_identity.create_authorization_grant(
        p_grantor_principal_id uuid, p_grantee_principal_id uuid, p_grant_type text,
        p_valid_from timestamptz, p_valid_until timestamptz, p_grant_reason text)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_actor text := cob3_identity.ctx_actor();
    v_id    uuid;
BEGIN
    PERFORM cob3_identity.require_ctx_permission('grant.authorize');
    PERFORM cob3_identity.assert_grant_authority(p_grantor_principal_id, p_grantee_principal_id, p_grant_type);
    INSERT INTO cob3_identity.authorization_grants
           (tenant_id, organization_id, grantor_principal_id, grantee_principal_id, grant_type, status,
            valid_from, valid_until, grant_reason, created_by, updated_by)
    VALUES (cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), p_grantor_principal_id, p_grantee_principal_id,
            p_grant_type, 'draft', COALESCE(p_valid_from, pg_catalog.now()), p_valid_until, p_grant_reason, v_actor, v_actor)
    RETURNING authorization_grant_id INTO v_id;
    PERFORM cob3_identity.audit_ctx('grant.create_draft', 'grant', v_id, '{}'::jsonb, v_id, NULL, NULL, p_grantor_principal_id);
    RETURN v_id;
END
$fn$;

CREATE FUNCTION cob3_identity.add_authorization_grant_permission(
        p_authorization_grant_id uuid, p_permission_code text, p_scope_id uuid, p_requires_human_approval boolean DEFAULT false)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_actor  text := cob3_identity.ctx_actor();
    v_grant  cob3_identity.authorization_grants%ROWTYPE;
    v_perm   uuid;
    v_id     uuid;
BEGIN
    PERFORM cob3_identity.require_ctx_permission('grant.authorize');
    SELECT g.* INTO v_grant FROM cob3_identity.authorization_grants g
     WHERE g.tenant_id = v_tenant AND g.organization_id = v_org AND g.authorization_grant_id = p_authorization_grant_id;
    IF v_grant.authorization_grant_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Grant not found in the request organization.';
    END IF;
    PERFORM cob3_identity.assert_grant_authority(v_grant.grantor_principal_id, v_grant.grantee_principal_id, v_grant.grant_type);
    SELECT p.permission_id INTO v_perm FROM cob3_identity.permissions p WHERE p.tenant_id = v_tenant AND p.permission_code = p_permission_code;
    IF v_perm IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown permission %s.', p_permission_code);
    END IF;
    INSERT INTO cob3_identity.authorization_grant_permissions
           (tenant_id, organization_id, authorization_grant_id, permission_id, scope_id, requires_human_approval, created_by, updated_by)
    VALUES (v_tenant, v_org, p_authorization_grant_id, v_perm, p_scope_id, COALESCE(p_requires_human_approval, false), v_actor, v_actor)
    RETURNING authorization_grant_permission_id INTO v_id;
    RETURN v_id;
END
$fn$;

CREATE FUNCTION cob3_identity.authorize_authorization_grant(p_authorization_grant_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_grant  cob3_identity.authorization_grants%ROWTYPE;
    v_e      record;
    v_d      record;
BEGIN
    PERFORM cob3_identity.require_ctx_permission('grant.authorize');
    SELECT g.* INTO v_grant FROM cob3_identity.authorization_grants g
     WHERE g.tenant_id = v_tenant AND g.organization_id = v_org AND g.authorization_grant_id = p_authorization_grant_id
       FOR UPDATE;
    IF v_grant.authorization_grant_id IS NULL OR v_grant.status <> 'draft' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Only a draft grant in the request organization can be authorized.';
    END IF;
    PERFORM cob3_identity.assert_grant_authority(v_grant.grantor_principal_id, v_grant.grantee_principal_id, v_grant.grant_type);
    -- The grantor must currently hold every permission over the ENTIRE
    -- requested scope; a credential-based caller must also hold each one
    -- in its own envelope (a narrow credential cannot mint broader authority).
    FOR v_e IN
        SELECT e.authorization_grant_permission_id, e.permission_id, p.permission_code, p.resource_type, s.scope_type
          FROM cob3_identity.authorization_grant_permissions e
          JOIN cob3_identity.permissions p ON p.tenant_id = e.tenant_id AND p.permission_id = e.permission_id
          JOIN cob3_identity.access_scopes s ON s.tenant_id = e.tenant_id AND s.organization_id = e.organization_id AND s.scope_id = e.scope_id
         WHERE e.tenant_id = v_tenant AND e.organization_id = v_org AND e.authorization_grant_id = p_authorization_grant_id
    LOOP
        IF v_e.scope_type <> 'organization' THEN
            PERFORM cob3_identity.assert_catalog_domain(v_tenant, v_org, NULL);
        END IF;
        IF NOT cob3_identity.rbac_permits(v_tenant, v_org, v_grant.grantor_principal_id, v_e.permission_id,
                                          'organization', v_org, pg_catalog.now()) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
                MESSAGE = pg_catalog.format('Grantor does not currently hold %s over the requested scope.', v_e.permission_code);
        END IF;
        IF cob3_identity.ctx_credential_id() IS NOT NULL THEN
            SELECT * INTO v_d FROM cob3_identity.evaluate_access(v_tenant, v_org, cob3_identity.ctx_principal_id(),
                        cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(), v_e.permission_code,
                        'organization', v_org, pg_catalog.now(), NULL);
            IF NOT v_d.allowed THEN
                RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
                    MESSAGE = pg_catalog.format('Calling credential envelope does not include %s (%s).', v_e.permission_code, v_d.reason_code);
            END IF;
        END IF;
    END LOOP;
    UPDATE cob3_identity.authorization_grants g
       SET status = 'active', authorized_by_principal_id = cob3_identity.ctx_principal_id(), authorized_at = pg_catalog.now()
     WHERE g.tenant_id = v_tenant AND g.organization_id = v_org AND g.authorization_grant_id = p_authorization_grant_id;
    PERFORM cob3_identity.audit_ctx('grant.authorize', 'grant', p_authorization_grant_id, '{}'::jsonb,
                                    p_authorization_grant_id, NULL, NULL, v_grant.grantor_principal_id);
END
$fn$;

CREATE FUNCTION cob3_identity.set_authorization_grant_status(p_authorization_grant_id uuid, p_status text, p_reason text DEFAULT NULL)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_ctx    uuid := cob3_identity.ctx_principal_id();
    v_grant  cob3_identity.authorization_grants%ROWTYPE;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    SELECT g.* INTO v_grant FROM cob3_identity.authorization_grants g
     WHERE g.tenant_id = v_tenant AND g.organization_id = v_org AND g.authorization_grant_id = p_authorization_grant_id
       FOR UPDATE;
    IF v_grant.authorization_grant_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Grant not found in the request organization.';
    END IF;
    IF p_status IN ('suspended', 'revoked') THEN
        -- Self-service reduction by a human/service grantor or grantee, or grant.revoke.
        IF NOT (v_ctx IN (v_grant.grantor_principal_id, v_grant.grantee_principal_id)
                AND cob3_identity.principal_type_of(v_tenant, v_ctx) IN ('human', 'service_account')) THEN
            PERFORM cob3_identity.require_ctx_permission('grant.revoke');
        END IF;
    ELSIF p_status = 'active' THEN
        PERFORM cob3_identity.require_ctx_permission('grant.authorize');
        PERFORM cob3_identity.assert_grant_authority(v_grant.grantor_principal_id, v_grant.grantee_principal_id, v_grant.grant_type);
    ELSE
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Use authorize_authorization_grant to activate a draft grant.';
    END IF;
    UPDATE cob3_identity.authorization_grants g
       SET status = p_status,
           revocation_reason = CASE WHEN p_status = 'revoked' THEN p_reason ELSE g.revocation_reason END
     WHERE g.tenant_id = v_tenant AND g.organization_id = v_org AND g.authorization_grant_id = p_authorization_grant_id;
    IF p_status = 'revoked' THEN
        UPDATE cob3_identity.principal_credentials c SET status = 'revoked'
         WHERE c.tenant_id = v_tenant AND c.organization_id = v_org
           AND c.authorization_grant_id = p_authorization_grant_id AND c.status = 'active';
        UPDATE cob3_identity.auth_sessions s SET revoked_at = pg_catalog.now()
         WHERE s.tenant_id = v_tenant AND s.organization_id = v_org
           AND s.authorization_grant_id = p_authorization_grant_id AND s.revoked_at IS NULL;
    END IF;
    PERFORM cob3_identity.audit_ctx('grant.' || p_status, 'grant', p_authorization_grant_id,
                                    pg_catalog.jsonb_build_object('reason', p_reason), p_authorization_grant_id);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Credentials (API keys). The backend generates the secret, computes its
-- digest, returns the secret once, and never stores it. The database stores
-- only the digest.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.issue_principal_credential(
        p_authorization_grant_id uuid, p_credential_name text, p_credential_usage text,
        p_public_identifier text, p_secret_digest bytea, p_digest_algorithm text, p_audience text,
        p_expires_at timestamptz, p_grant_permission_ids uuid[])
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_ctx    uuid := cob3_identity.ctx_principal_id();
    v_actor  text := cob3_identity.ctx_actor();
    v_grant  cob3_identity.authorization_grants%ROWTYPE;
    v_type   text;
    v_id     uuid;
    v_entry  uuid;
    v_code   text;
    v_d      record;
BEGIN
    PERFORM cob3_identity.require_ctx_permission('credential.issue');
    SELECT g.* INTO v_grant FROM cob3_identity.authorization_grants g
     WHERE g.tenant_id = v_tenant AND g.organization_id = v_org AND g.authorization_grant_id = p_authorization_grant_id;
    IF v_grant.authorization_grant_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Grant not found in the request organization.';
    END IF;
    v_type := cob3_identity.principal_type_of(v_tenant, v_grant.grantee_principal_id);
    -- Principal management/ownership check.
    IF NOT (v_grant.grantee_principal_id = v_ctx
            OR (v_type = 'service_account' AND cob3_identity.ctx_has_org_permission('service_account.manage'))
            OR (v_type = 'automation' AND (
                    EXISTS (SELECT 1 FROM cob3_identity.automation_profiles a
                             WHERE a.tenant_id = v_tenant AND a.principal_id = v_grant.grantee_principal_id
                               AND v_ctx IN (a.owner_principal_id, a.creator_principal_id))
                    OR cob3_identity.ctx_has_org_permission('automation.manage')))) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Caller cannot issue credentials for this principal.';
    END IF;
    -- Provisioning credentials only through an interactive, authorized human workflow.
    IF p_credential_usage = 'provisioning'
       AND NOT (cob3_identity.ctx_is_interactive() AND cob3_identity.ctx_has_org_permission('service_account.manage')) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
            MESSAGE = 'Provisioning credentials require an interactive session with service_account.manage.';
    END IF;
    -- Credential-based issuers may only pass on permissions in their own envelope.
    IF cob3_identity.ctx_credential_id() IS NOT NULL THEN
        FOREACH v_entry IN ARRAY COALESCE(p_grant_permission_ids, ARRAY[]::uuid[]) LOOP
            SELECT p.permission_code INTO v_code
              FROM cob3_identity.authorization_grant_permissions e
              JOIN cob3_identity.permissions p ON p.tenant_id = e.tenant_id AND p.permission_id = e.permission_id
             WHERE e.tenant_id = v_tenant AND e.organization_id = v_org AND e.authorization_grant_permission_id = v_entry;
            SELECT * INTO v_d FROM cob3_identity.evaluate_access(v_tenant, v_org, v_ctx, cob3_identity.ctx_session_id(),
                        cob3_identity.ctx_credential_id(), v_code, 'organization', v_org, pg_catalog.now(), NULL);
            IF NOT COALESCE(v_d.allowed, false) THEN
                RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
                    MESSAGE = pg_catalog.format('Calling credential envelope does not include %s.', COALESCE(v_code, v_entry::text));
            END IF;
        END LOOP;
    END IF;
    INSERT INTO cob3_identity.principal_credentials
           (tenant_id, organization_id, principal_id, authorization_grant_id, credential_name, credential_usage,
            public_identifier, secret_digest, digest_algorithm, audience, status, expires_at, created_by, updated_by)
    VALUES (v_tenant, v_org, v_grant.grantee_principal_id, p_authorization_grant_id, p_credential_name, p_credential_usage,
            p_public_identifier, p_secret_digest, p_digest_algorithm, p_audience, 'active', p_expires_at, v_actor, v_actor)
    RETURNING credential_id INTO v_id;
    INSERT INTO cob3_identity.credential_permission_bindings
           (tenant_id, organization_id, credential_id, authorization_grant_id, authorization_grant_permission_id, created_by, updated_by)
    SELECT v_tenant, v_org, v_id, p_authorization_grant_id, x.entry_id, v_actor, v_actor
      FROM (SELECT DISTINCT pg_catalog.unnest(COALESCE(p_grant_permission_ids, ARRAY[]::uuid[])) AS entry_id) AS x;
    PERFORM cob3_identity.audit_ctx('credential.issue', 'credential', v_id,
                                    pg_catalog.jsonb_build_object('usage', p_credential_usage, 'public_identifier', p_public_identifier,
                                                                  'bound_entries', COALESCE(pg_catalog.cardinality(p_grant_permission_ids), 0)),
                                    p_authorization_grant_id);
    RETURN v_id;
END
$fn$;

CREATE FUNCTION cob3_identity.revoke_principal_credential(p_credential_id uuid, p_reason text DEFAULT NULL)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_ctx    uuid := cob3_identity.ctx_principal_id();
    v_cred   cob3_identity.principal_credentials%ROWTYPE;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    SELECT c.* INTO v_cred FROM cob3_identity.principal_credentials c
     WHERE c.tenant_id = v_tenant AND c.organization_id = v_org AND c.credential_id = p_credential_id
       FOR UPDATE;
    IF v_cred.credential_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Credential not found in the request organization.';
    END IF;
    IF NOT (v_cred.principal_id = v_ctx AND cob3_identity.principal_type_of(v_tenant, v_ctx) IN ('human', 'service_account')) THEN
        PERFORM cob3_identity.require_ctx_permission('credential.revoke');
    END IF;
    UPDATE cob3_identity.principal_credentials c SET status = 'revoked'
     WHERE c.tenant_id = v_tenant AND c.credential_id = p_credential_id AND c.status = 'active';
    UPDATE cob3_identity.auth_sessions s SET revoked_at = pg_catalog.now()
     WHERE s.tenant_id = v_tenant AND s.credential_id = p_credential_id AND s.revoked_at IS NULL;
    PERFORM cob3_identity.audit_ctx('credential.revoke', 'credential', p_credential_id,
                                    pg_catalog.jsonb_build_object('reason', p_reason), v_cred.authorization_grant_id);
END
$fn$;

-- API key authentication step (no request context yet). Returns no rows on
-- any failure, without revealing which check failed.
CREATE FUNCTION cob3_identity.verify_api_key(p_tenant_id uuid, p_public_identifier text, p_secret_digest bytea, p_audience text)
    RETURNS TABLE (tenant_id uuid, organization_id uuid, principal_id uuid, credential_id uuid,
                   authorization_grant_id uuid, credential_usage text, expires_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_c cob3_identity.principal_credentials%ROWTYPE;
BEGIN
    SELECT c.* INTO v_c FROM cob3_identity.principal_credentials c
     WHERE c.tenant_id = p_tenant_id AND c.public_identifier = p_public_identifier;
    IF v_c.credential_id IS NULL
       OR v_c.secret_digest <> p_secret_digest
       OR v_c.status <> 'active'
       OR v_c.expires_at <= pg_catalog.now()
       OR v_c.audience <> p_audience
       OR NOT cob3_identity.tenant_is_active(p_tenant_id)
       OR NOT cob3_identity.principal_is_eligible(p_tenant_id, v_c.principal_id, pg_catalog.now())
       OR NOT cob3_identity.membership_is_effective(p_tenant_id, v_c.organization_id, v_c.principal_id, pg_catalog.now())
       OR NOT cob3_identity.grant_is_effective(p_tenant_id, v_c.organization_id, v_c.authorization_grant_id, v_c.principal_id, pg_catalog.now()) THEN
        RETURN;
    END IF;
    UPDATE cob3_identity.principal_credentials c SET last_used_at = pg_catalog.now()
     WHERE c.tenant_id = p_tenant_id AND c.credential_id = v_c.credential_id;
    RETURN QUERY SELECT v_c.tenant_id, v_c.organization_id, v_c.principal_id, v_c.credential_id,
                        v_c.authorization_grant_id, v_c.credential_usage::text, v_c.expires_at;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Sessions. The trusted authentication adapter verifies the IdP assertion
-- (signature, issuer, audience, nonce) BEFORE calling this routine; the
-- database cannot verify federated tokens and does not pretend to.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.open_interactive_session(
        p_tenant_id uuid, p_identity_provider_id uuid, p_subject text, p_organization_id uuid,
        p_session_handle_digest bytea, p_refresh_token_digest bytea, p_audience text,
        p_authenticated_at timestamptz, p_expires_at timestamptz,
        p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL)
    RETURNS TABLE (session_id uuid, principal_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_ext      cob3_identity.external_identities%ROWTYPE;
    v_protocol text;
    v_session  uuid;
    v_actor    text;
BEGIN
    SELECT e.* INTO v_ext FROM cob3_identity.external_identities e
     WHERE e.tenant_id = p_tenant_id AND e.identity_provider_id = p_identity_provider_id AND e.subject = p_subject;
    SELECT ip.protocol INTO v_protocol FROM cob3_identity.identity_providers ip
     WHERE ip.tenant_id = p_tenant_id AND ip.identity_provider_id = p_identity_provider_id AND ip.status = 'active';
    IF v_ext.external_identity_id IS NULL OR v_ext.status <> 'active' OR v_protocol IS NULL
       OR NOT cob3_identity.tenant_is_active(p_tenant_id)
       OR cob3_identity.principal_type_of(p_tenant_id, v_ext.principal_id) <> 'human'
       OR NOT cob3_identity.principal_is_eligible(p_tenant_id, v_ext.principal_id, pg_catalog.now())
       OR (p_organization_id IS NOT NULL
           AND NOT cob3_identity.membership_is_effective(p_tenant_id, p_organization_id, v_ext.principal_id, pg_catalog.now())) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Interactive session cannot be opened for this identity.';
    END IF;
    v_actor := 'principal:' || v_ext.principal_id::text;
    INSERT INTO cob3_identity.auth_sessions AS s
           (tenant_id, organization_id, principal_id, session_kind, authentication_method, external_identity_id,
            session_handle_digest, refresh_token_digest, audience, auth_version_at_issue, authenticated_at, expires_at,
            ip_address, user_agent, created_by, updated_by)
    VALUES (p_tenant_id, p_organization_id, v_ext.principal_id, 'interactive', v_protocol, v_ext.external_identity_id,
            p_session_handle_digest, p_refresh_token_digest, p_audience, 1, p_authenticated_at, p_expires_at,
            p_ip_address, p_user_agent, v_actor, v_actor)
    RETURNING s.session_id INTO v_session;
    UPDATE cob3_identity.principals p SET last_authenticated_at = p_authenticated_at, updated_by = v_actor
     WHERE p.tenant_id = p_tenant_id AND p.principal_id = v_ext.principal_id;
    UPDATE cob3_identity.external_identities e SET last_seen_at = p_authenticated_at, updated_by = v_actor
     WHERE e.tenant_id = p_tenant_id AND e.external_identity_id = v_ext.external_identity_id;
    PERFORM cob3_identity.write_audit_event(p_tenant_id, p_organization_id, v_ext.principal_id, v_actor,
                                            'session.open_interactive', 'session', v_session, 'success',
                                            NULL, '{}'::jsonb, NULL, NULL, p_ip_address, v_session);
    RETURN QUERY SELECT v_session, v_ext.principal_id;
END
$fn$;

-- Exchange an API key for a bounded noninteractive session that preserves the
-- credential's audience, expiry and capability subset (never interactive).
CREATE FUNCTION cob3_identity.open_api_key_session(
        p_tenant_id uuid, p_public_identifier text, p_secret_digest bytea, p_audience text,
        p_session_handle_digest bytea, p_expires_at timestamptz,
        p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_k       record;
    v_until   timestamptz;
    v_session uuid;
    v_actor   text;
BEGIN
    SELECT * INTO v_k FROM cob3_identity.verify_api_key(p_tenant_id, p_public_identifier, p_secret_digest, p_audience);
    IF v_k.credential_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'API key authentication failed.';
    END IF;
    SELECT LEAST(p_expires_at, v_k.expires_at, g.valid_until) INTO v_until
      FROM cob3_identity.authorization_grants g
     WHERE g.tenant_id = p_tenant_id AND g.organization_id = v_k.organization_id AND g.authorization_grant_id = v_k.authorization_grant_id;
    v_actor := 'principal:' || v_k.principal_id::text;
    INSERT INTO cob3_identity.auth_sessions AS s
           (tenant_id, organization_id, principal_id, session_kind, authentication_method, authorization_grant_id, credential_id,
            session_handle_digest, audience, auth_version_at_issue, authenticated_at, expires_at, ip_address, user_agent,
            created_by, updated_by)
    VALUES (p_tenant_id, v_k.organization_id, v_k.principal_id, 'noninteractive', 'api_key', v_k.authorization_grant_id, v_k.credential_id,
            p_session_handle_digest, p_audience, 1, pg_catalog.now(), v_until, p_ip_address, p_user_agent, v_actor, v_actor)
    RETURNING s.session_id INTO v_session;
    RETURN v_session;
END
$fn$;

CREATE FUNCTION cob3_identity.revoke_session(p_session_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_owner  uuid;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    SELECT s.principal_id INTO v_owner FROM cob3_identity.auth_sessions s
     WHERE s.tenant_id = v_tenant AND s.session_id = p_session_id;
    IF v_owner IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Session not found.';
    END IF;
    IF v_owner <> cob3_identity.ctx_principal_id() THEN
        PERFORM cob3_identity.require_ctx_permission('tenant.manage_administrators', 'tenant');
    END IF;
    UPDATE cob3_identity.auth_sessions s SET revoked_at = pg_catalog.now()
     WHERE s.tenant_id = v_tenant AND s.session_id = p_session_id AND s.revoked_at IS NULL;
    PERFORM cob3_identity.audit_ctx('session.revoke', 'session', p_session_id);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Single-use exact-action approvals
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.request_action_approval(
        p_authorization_grant_permission_id uuid, p_request_id uuid, p_target_type text, p_target_id uuid,
        p_action_digest bytea, p_expires_at timestamptz)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_actor  text := cob3_identity.ctx_actor();
    v_entry  record;
    v_d      record;
    v_id     uuid;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    SELECT e.authorization_grant_id, p.permission_code INTO v_entry
      FROM cob3_identity.authorization_grant_permissions e
      JOIN cob3_identity.permissions p ON p.tenant_id = e.tenant_id AND p.permission_id = e.permission_id
     WHERE e.tenant_id = v_tenant AND e.organization_id = v_org AND e.authorization_grant_permission_id = p_authorization_grant_permission_id;
    IF v_entry.authorization_grant_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Grant entry not found in the request organization.';
    END IF;
    -- Approval never creates permission: the requester must already be allowed.
    SELECT * INTO v_d FROM cob3_identity.evaluate_access(v_tenant, v_org, cob3_identity.ctx_principal_id(),
                cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(), v_entry.permission_code,
                p_target_type, p_target_id, pg_catalog.now(), NULL);
    IF NOT v_d.allowed OR v_d.matched_grant_id IS DISTINCT FROM v_entry.authorization_grant_id THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
            MESSAGE = pg_catalog.format('Requester is not authorized for this action under the grant (%s).', v_d.reason_code);
    END IF;
    INSERT INTO cob3_identity.action_approvals
           (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id, requesting_principal_id,
            request_id, target_type, target_id, action_digest, status, expires_at, created_by, updated_by)
    VALUES (v_tenant, v_org, v_entry.authorization_grant_id, p_authorization_grant_permission_id, cob3_identity.ctx_principal_id(),
            p_request_id, p_target_type, p_target_id, p_action_digest, 'pending', p_expires_at, v_actor, v_actor)
    RETURNING action_approval_id INTO v_id;
    PERFORM cob3_identity.audit_ctx('action_approval.request', p_target_type, p_target_id, '{}'::jsonb,
                                    v_entry.authorization_grant_id, p_authorization_grant_permission_id, v_id);
    RETURN v_id;
END
$fn$;

CREATE FUNCTION cob3_identity.decide_action_approval(p_action_approval_id uuid, p_approve boolean)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_ctx    uuid := cob3_identity.ctx_principal_id();
    v_a      cob3_identity.action_approvals%ROWTYPE;
    v_perm   uuid;
BEGIN
    IF NOT cob3_identity.ctx_is_interactive() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Action approval decisions require an interactive human session.';
    END IF;
    PERFORM cob3_identity.require_ctx_permission('action.approve');
    SELECT a.* INTO v_a FROM cob3_identity.action_approvals a
     WHERE a.tenant_id = v_tenant AND a.organization_id = v_org AND a.action_approval_id = p_action_approval_id
       FOR UPDATE;
    IF v_a.action_approval_id IS NULL OR v_a.status <> 'pending' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Approval request is not pending in the request organization.';
    END IF;
    IF v_a.requesting_principal_id = v_ctx THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'The requesting principal cannot approve its own action.';
    END IF;
    IF p_approve THEN
        SELECT e.permission_id INTO v_perm FROM cob3_identity.authorization_grant_permissions e
         WHERE e.tenant_id = v_tenant AND e.authorization_grant_permission_id = v_a.authorization_grant_permission_id;
        IF NOT cob3_identity.rbac_permits(v_tenant, v_org, v_ctx, v_perm, v_a.target_type, v_a.target_id, pg_catalog.now()) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Approver lacks authority over the target action.';
        END IF;
    END IF;
    UPDATE cob3_identity.action_approvals a
       SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
           decided_by_principal_id = v_ctx, decided_at = pg_catalog.now()
     WHERE a.tenant_id = v_tenant AND a.action_approval_id = p_action_approval_id;
    PERFORM cob3_identity.audit_ctx(CASE WHEN p_approve THEN 'action_approval.approve' ELSE 'action_approval.reject' END,
                                    v_a.target_type, v_a.target_id, '{}'::jsonb, v_a.authorization_grant_id,
                                    v_a.authorization_grant_permission_id, p_action_approval_id);
END
$fn$;

-- Atomic single-use consumption bound to the exact action digest. Concurrent
-- consumers serialize on the row; only one sees status='approved'.
CREATE FUNCTION cob3_identity.consume_action_approval(p_request_id uuid, p_action_digest bytea)
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_ctx    uuid := cob3_identity.ctx_principal_id();
    v_a      cob3_identity.action_approvals%ROWTYPE;
    v_perm   cob3_identity.permissions%ROWTYPE;
    v_d      record;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    UPDATE cob3_identity.action_approvals a
       SET status = 'consumed'
     WHERE a.tenant_id = v_tenant AND a.organization_id = v_org AND a.request_id = p_request_id
       AND a.requesting_principal_id = v_ctx AND a.action_digest = p_action_digest
       AND a.status = 'approved' AND a.expires_at > pg_catalog.now()
    RETURNING a.* INTO v_a;
    IF v_a.action_approval_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
            MESSAGE = 'No approved, unexpired, unconsumed approval matches this request and exact action digest.';
    END IF;
    -- Revalidate approver eligibility and the requester's live access.
    SELECT p.* INTO v_perm FROM cob3_identity.permissions p
      JOIN cob3_identity.authorization_grant_permissions e ON e.tenant_id = p.tenant_id AND e.permission_id = p.permission_id
     WHERE e.tenant_id = v_tenant AND e.authorization_grant_permission_id = v_a.authorization_grant_permission_id;
    IF NOT cob3_identity.principal_is_eligible(v_tenant, v_a.decided_by_principal_id, pg_catalog.now())
       OR NOT cob3_identity.membership_is_effective(v_tenant, v_org, v_a.decided_by_principal_id, pg_catalog.now())
       OR NOT cob3_identity.rbac_permits(v_tenant, v_org, v_a.decided_by_principal_id,
                (SELECT x.permission_id FROM cob3_identity.permissions x WHERE x.tenant_id = v_tenant AND x.permission_code = 'action.approve'),
                'organization', v_org, pg_catalog.now()) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Approver is no longer eligible; approval cannot be consumed.';
    END IF;
    SELECT * INTO v_d FROM cob3_identity.evaluate_access(v_tenant, v_org, v_ctx, cob3_identity.ctx_session_id(),
                cob3_identity.ctx_credential_id(), v_perm.permission_code, v_a.target_type, v_a.target_id, pg_catalog.now(), NULL);
    IF NOT v_d.allowed THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
            MESSAGE = pg_catalog.format('Requester is no longer authorized for the approved action (%s).', v_d.reason_code);
    END IF;
    PERFORM cob3_identity.audit_ctx('action_approval.consume', v_a.target_type, v_a.target_id, '{}'::jsonb,
                                    v_a.authorization_grant_id, v_a.authorization_grant_permission_id, v_a.action_approval_id);
    RETURN v_a.action_approval_id;
END
$fn$;
