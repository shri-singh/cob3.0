-- =============================================================================
-- 50  AUTHORIZATION CORE
-- -----------------------------------------------------------------------------
-- * Catalog fail-closed guards (replaced only by the separately invoked
--   Catalog integration; never by an always-true validator).
-- * Eligibility, live RBAC, tenant-control RBAC.
-- * evaluate_access: the single decision function implementing
--     interactive human sessions  -> current RBAC
--     credential / noninteractive -> live grantor RBAC AND live grantee RBAC
--                                    AND approved grant entry AND credential
--                                    subset (when present) AND lifecycle,
--                                    organization, scope, usage and expiry checks.
-- * ctx_* predicates used by RLS policies (evaluate once per statement via
--   scalar sub-selects in the policies).
-- All functions here are read-only. SECURITY DEFINER functions run as
-- cob3_owner with a pinned search_path and fully qualified references.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Catalog guards (pending integration)
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.catalog_integration_installed()
    RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT false $fn$;

CREATE FUNCTION cob3_identity.assert_catalog_domain(p_tenant_id uuid, p_organization_id uuid, p_domain_id uuid)
    RETURNS void
    LANGUAGE plpgsql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    RAISE EXCEPTION USING ERRCODE = 'SKCAT',
        MESSAGE = pg_catalog.format('Catalog integration is not installed: domain %s cannot be validated for organization %s and is rejected (fail closed).', p_domain_id, p_organization_id),
        HINT = 'Domain-scoped access and team-domain responsibility become available only after the separately invoked Catalog integration verifies cob3_catalog and installs real foreign keys.';
END
$fn$;

CREATE FUNCTION cob3_identity.assert_catalog_asset(p_tenant_id uuid, p_organization_id uuid, p_asset_id uuid)
    RETURNS void
    LANGUAGE plpgsql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    RAISE EXCEPTION USING ERRCODE = 'SKCAT',
        MESSAGE = pg_catalog.format('Catalog integration is not installed: asset %s cannot be validated for organization %s and is rejected (fail closed).', p_asset_id, p_organization_id),
        HINT = 'Asset-scoped access becomes available only after the separately invoked Catalog integration.';
END
$fn$;

-- Resource resolution for any target that is not the organization entity
-- itself. Until a trusted Catalog resolver is installed this denies.
CREATE FUNCTION cob3_identity.catalog_scope_covers(
        p_tenant_id uuid, p_organization_id uuid, p_scope_type text, p_domain_id uuid, p_asset_id uuid,
        p_include_contained_assets boolean, p_team_id uuid, p_resource_type text,
        p_target_type text, p_target_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT false $fn$;

-- ---------------------------------------------------------------------------
-- Eligibility helpers
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tenant_is_active(p_tenant_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (SELECT 1 FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id AND t.status = 'active')
$fn$;

CREATE FUNCTION cob3_identity.principal_is_eligible(p_tenant_id uuid, p_principal_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (
        SELECT 1
          FROM cob3_identity.principals p
         WHERE p.tenant_id = p_tenant_id
           AND p.principal_id = p_principal_id
           AND p.status = 'active'
           AND CASE p.principal_type
                 WHEN 'human' THEN EXISTS (
                     SELECT 1 FROM cob3_identity.user_profiles u
                      WHERE u.tenant_id = p.tenant_id AND u.principal_id = p.principal_id)
                 WHEN 'service_account' THEN EXISTS (
                     SELECT 1 FROM cob3_identity.service_accounts s
                      WHERE s.tenant_id = p.tenant_id AND s.principal_id = p.principal_id
                        AND (s.expires_at IS NULL OR s.expires_at > p_at))
                 WHEN 'automation' THEN EXISTS (
                     SELECT 1 FROM cob3_identity.automation_profiles a
                      WHERE a.tenant_id = p.tenant_id AND a.principal_id = p.principal_id
                        AND (a.expires_at IS NULL OR a.expires_at > p_at))
                 ELSE false
               END)
$fn$;

CREATE FUNCTION cob3_identity.membership_is_effective(p_tenant_id uuid, p_organization_id uuid, p_principal_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (
        SELECT 1
          FROM cob3_identity.organization_memberships m
          JOIN cob3_identity.organizations o
            ON o.tenant_id = m.tenant_id AND o.organization_id = m.organization_id
         WHERE m.tenant_id = p_tenant_id
           AND m.organization_id = p_organization_id
           AND m.principal_id = p_principal_id
           AND m.status = 'active'
           AND o.status = 'active'
           AND m.valid_from <= p_at
           AND (m.valid_until IS NULL OR m.valid_until > p_at))
$fn$;

CREATE FUNCTION cob3_identity.grant_is_effective(p_tenant_id uuid, p_organization_id uuid, p_grant_id uuid, p_grantee_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (
        SELECT 1
          FROM cob3_identity.authorization_grants g
         WHERE g.tenant_id = p_tenant_id
           AND g.organization_id = p_organization_id
           AND g.authorization_grant_id = p_grant_id
           AND g.grantee_principal_id = p_grantee_id
           AND g.status = 'active'
           AND g.valid_from <= p_at
           AND g.valid_until > p_at)
$fn$;

CREATE FUNCTION cob3_identity.session_is_valid(p_tenant_id uuid, p_session_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (
        SELECT 1
          FROM cob3_identity.auth_sessions s
          JOIN cob3_identity.principals p
            ON p.tenant_id = s.tenant_id AND p.principal_id = s.principal_id
         WHERE s.tenant_id = p_tenant_id
           AND s.session_id = p_session_id
           AND s.revoked_at IS NULL
           AND s.authenticated_at <= p_at
           AND s.expires_at > p_at
           AND s.auth_version_at_issue = p.auth_version
           AND (s.external_identity_id IS NULL OR EXISTS (
                SELECT 1
                  FROM cob3_identity.external_identities e
                  JOIN cob3_identity.identity_providers ip
                    ON ip.tenant_id = e.tenant_id AND ip.identity_provider_id = e.identity_provider_id
                 WHERE e.tenant_id = s.tenant_id
                   AND e.external_identity_id = s.external_identity_id
                   AND e.status = 'active'
                   AND ip.status = 'active')))
$fn$;

-- Identity-administered resource types are authorized at organization scope
-- with the organization itself as the target. Every other resource type is a
-- Catalog/product resource and needs the Catalog resolver.
CREATE FUNCTION cob3_identity.is_org_administered_resource(p_resource_type text)
    RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p_resource_type IN ('organization', 'team', 'role', 'service_account', 'automation',
                               'grant', 'credential', 'action', 'audit')
$fn$;

CREATE FUNCTION cob3_identity.scope_covers_target(
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
                 ELSE cob3_identity.catalog_scope_covers(
                          s.tenant_id, s.organization_id, s.scope_type, s.domain_id, s.asset_id,
                          s.include_contained_assets, p_team_id, p_resource_type, p_target_type, p_target_id, p_at)
               END
          FROM cob3_identity.access_scopes s
         WHERE s.tenant_id = p_tenant_id
           AND s.organization_id = p_organization_id
           AND s.scope_id = p_scope_id), false)
$fn$;

-- Effective teams: active team, active current membership, and at least one
-- active current source (manual, or external group whose mapping, group and
-- provider are all active). Group freshness SLA is a backend/Settings policy.
CREATE FUNCTION cob3_identity.effective_team_ids(p_tenant_id uuid, p_organization_id uuid, p_principal_id uuid, p_at timestamptz)
    RETURNS SETOF uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT tm.team_id
      FROM cob3_identity.team_memberships tm
      JOIN cob3_identity.teams t
        ON t.tenant_id = tm.tenant_id AND t.organization_id = tm.organization_id AND t.team_id = tm.team_id
     WHERE tm.tenant_id = p_tenant_id
       AND tm.organization_id = p_organization_id
       AND tm.principal_id = p_principal_id
       AND tm.status = 'active'
       AND t.status = 'active'
       AND tm.valid_from <= p_at
       AND (tm.valid_until IS NULL OR tm.valid_until > p_at)
       AND EXISTS (
           SELECT 1
             FROM cob3_identity.team_membership_sources src
             LEFT JOIN cob3_identity.group_team_mappings g
               ON g.tenant_id = src.tenant_id AND g.organization_id = src.organization_id
              AND g.group_team_mapping_id = src.group_team_mapping_id
             LEFT JOIN cob3_identity.external_groups eg
               ON eg.tenant_id = g.tenant_id AND eg.external_group_id = g.external_group_id
             LEFT JOIN cob3_identity.identity_providers ip
               ON ip.tenant_id = eg.tenant_id AND ip.identity_provider_id = eg.identity_provider_id
            WHERE src.tenant_id = tm.tenant_id
              AND src.organization_id = tm.organization_id
              AND src.team_membership_id = tm.team_membership_id
              AND src.status = 'active'
              AND src.valid_from <= p_at
              AND (src.valid_until IS NULL OR src.valid_until > p_at)
              AND (src.source_type = 'manual'
                   OR (g.status = 'active' AND eg.status = 'active' AND ip.status = 'active')))
$fn$;

-- Live organization RBAC for one principal, permission and target.
CREATE FUNCTION cob3_identity.rbac_permits(
        p_tenant_id uuid, p_organization_id uuid, p_principal_id uuid, p_permission_id uuid,
        p_target_type text, p_target_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (
        SELECT 1
          FROM cob3_identity.permissions perm
          JOIN cob3_identity.role_permissions rp
            ON rp.tenant_id = perm.tenant_id AND rp.permission_id = perm.permission_id
          JOIN cob3_identity.roles r
            ON r.tenant_id = rp.tenant_id AND r.role_id = rp.role_id
          JOIN cob3_identity.role_bindings rb
            ON rb.tenant_id = r.tenant_id AND rb.role_id = r.role_id
         WHERE perm.tenant_id = p_tenant_id
           AND perm.permission_id = p_permission_id
           AND perm.status = 'active'
           AND perm.permission_class = 'organization'
           AND r.status = 'active'
           AND r.role_class = 'organization'
           AND rb.organization_id = p_organization_id
           AND rb.status = 'active'
           AND rb.valid_from <= p_at
           AND (rb.valid_until IS NULL OR rb.valid_until > p_at)
           AND (rb.principal_id = p_principal_id
                OR rb.team_id IN (SELECT cob3_identity.effective_team_ids(p_tenant_id, p_organization_id, p_principal_id, p_at)))
           AND cob3_identity.scope_covers_target(rb.tenant_id, rb.organization_id, rb.scope_id, rb.team_id,
                                                 perm.resource_type, p_target_type, p_target_id, p_at))
$fn$;

CREATE FUNCTION cob3_identity.tenant_control_permits(p_tenant_id uuid, p_principal_id uuid, p_permission_id uuid, p_at timestamptz)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (
        SELECT 1
          FROM cob3_identity.tenant_role_bindings b
          JOIN cob3_identity.principals pr
            ON pr.tenant_id = b.tenant_id AND pr.principal_id = b.principal_id
          JOIN cob3_identity.roles r
            ON r.tenant_id = b.tenant_id AND r.role_id = b.role_id
          JOIN cob3_identity.role_permissions rp
            ON rp.tenant_id = r.tenant_id AND rp.role_id = r.role_id
          JOIN cob3_identity.permissions perm
            ON perm.tenant_id = rp.tenant_id AND perm.permission_id = rp.permission_id
         WHERE b.tenant_id = p_tenant_id
           AND b.principal_id = p_principal_id
           AND pr.principal_type IN ('human', 'service_account')
           AND b.status = 'active'
           AND b.valid_from <= p_at
           AND (b.valid_until IS NULL OR b.valid_until > p_at)
           AND r.status = 'active'
           AND r.role_class = 'tenant_control'
           AND perm.permission_id = p_permission_id
           AND perm.status = 'active'
           AND perm.permission_class = 'tenant_control')
$fn$;

-- ---------------------------------------------------------------------------
-- evaluate_access: authoritative decision for one operation.
--   p_target_type/p_target_id: use ('tenant', tenant_id) for tenant-control
--   permissions and ('organization', organization_id) for organization-
--   administered resources. Any other target requires the Catalog resolver.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.evaluate_access(
        p_tenant_id               uuid,
        p_organization_id         uuid,
        p_principal_id            uuid,
        p_session_id              uuid,
        p_credential_id           uuid,
        p_permission_code         text,
        p_target_type             text,
        p_target_id               uuid,
        p_at                      timestamptz DEFAULT now(),
        p_initiating_principal_id uuid DEFAULT NULL,
        OUT allowed                     boolean,
        OUT reason_code                 text,
        OUT decision_path               text,
        OUT matched_grant_id            uuid,
        OUT matched_grant_permission_id uuid,
        OUT requires_approval           boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_principal cob3_identity.principals%ROWTYPE;
    v_perm      cob3_identity.permissions%ROWTYPE;
    v_session   cob3_identity.auth_sessions%ROWTYPE;
    v_cred      cob3_identity.principal_credentials%ROWTYPE;
    v_grant     cob3_identity.authorization_grants%ROWTYPE;
    v_cred_id   uuid := p_credential_id;
    v_auto_ctx  boolean;
    v_entry     uuid;
    v_requires  boolean;
BEGIN
    allowed := false;
    requires_approval := false;
    decision_path := 'none';

    IF p_tenant_id IS NULL OR p_principal_id IS NULL OR p_permission_code IS NULL OR p_at IS NULL THEN
        reason_code := 'missing_context'; RETURN;
    END IF;
    IF NOT cob3_identity.tenant_is_active(p_tenant_id) THEN
        reason_code := 'tenant_not_active'; RETURN;
    END IF;
    SELECT p.* INTO v_principal
      FROM cob3_identity.principals p
     WHERE p.tenant_id = p_tenant_id AND p.principal_id = p_principal_id;
    IF NOT FOUND THEN
        reason_code := 'principal_not_found'; RETURN;
    END IF;
    IF NOT cob3_identity.principal_is_eligible(p_tenant_id, p_principal_id, p_at) THEN
        reason_code := 'principal_not_eligible'; RETURN;
    END IF;
    SELECT x.* INTO v_perm
      FROM cob3_identity.permissions x
     WHERE x.tenant_id = p_tenant_id AND x.permission_code = p_permission_code;
    IF NOT FOUND THEN
        reason_code := 'unknown_permission'; RETURN;
    END IF;
    IF v_perm.status <> 'active' THEN
        reason_code := 'permission_inactive'; RETURN;
    END IF;

    IF p_session_id IS NOT NULL THEN
        SELECT s.* INTO v_session
          FROM cob3_identity.auth_sessions s
         WHERE s.tenant_id = p_tenant_id AND s.session_id = p_session_id;
        IF NOT FOUND THEN
            reason_code := 'session_not_found'; RETURN;
        END IF;
        IF v_session.principal_id <> p_principal_id THEN
            reason_code := 'session_principal_mismatch'; RETURN;
        END IF;
        IF NOT cob3_identity.session_is_valid(p_tenant_id, p_session_id, p_at) THEN
            reason_code := 'session_invalid'; RETURN;
        END IF;

        IF v_session.session_kind = 'interactive' THEN
            -- An API key is never promoted into an interactive session.
            IF v_cred_id IS NOT NULL THEN
                reason_code := 'credential_not_permitted_in_interactive_session'; RETURN;
            END IF;
            decision_path := 'interactive_rbac';
            IF v_principal.principal_type <> 'human' THEN
                reason_code := 'interactive_requires_human'; RETURN;
            END IF;
            IF v_perm.permission_class = 'tenant_control' THEN
                IF cob3_identity.tenant_control_permits(p_tenant_id, p_principal_id, v_perm.permission_id, p_at) THEN
                    allowed := true; reason_code := 'allowed';
                ELSE
                    reason_code := 'tenant_rbac_denied';
                END IF;
                RETURN;
            END IF;
            IF p_organization_id IS NULL OR v_session.organization_id IS DISTINCT FROM p_organization_id THEN
                reason_code := 'session_organization_mismatch'; RETURN;
            END IF;
            IF NOT cob3_identity.membership_is_effective(p_tenant_id, p_organization_id, p_principal_id, p_at) THEN
                reason_code := 'membership_not_effective'; RETURN;
            END IF;
            IF NOT cob3_identity.rbac_permits(p_tenant_id, p_organization_id, p_principal_id, v_perm.permission_id,
                                              p_target_type, p_target_id, p_at) THEN
                reason_code := 'rbac_denied'; RETURN;
            END IF;
            allowed := true; reason_code := 'allowed'; RETURN;
        END IF;

        -- Noninteractive session: bounded by its grant (and credential, if any).
        IF v_cred_id IS NOT NULL AND v_cred_id IS DISTINCT FROM v_session.credential_id THEN
            reason_code := 'session_credential_mismatch'; RETURN;
        END IF;
        v_cred_id := v_session.credential_id;
        IF v_session.organization_id IS DISTINCT FROM p_organization_id THEN
            reason_code := 'session_organization_mismatch'; RETURN;
        END IF;
        SELECT g.* INTO v_grant
          FROM cob3_identity.authorization_grants g
         WHERE g.tenant_id = p_tenant_id
           AND g.organization_id = v_session.organization_id
           AND g.authorization_grant_id = v_session.authorization_grant_id;
    ELSIF v_cred_id IS NULL THEN
        reason_code := 'no_authenticated_context'; RETURN;
    END IF;

    -- Grant / credential path.
    decision_path := CASE WHEN v_cred_id IS NOT NULL THEN 'credential_grant' ELSE 'federated_grant' END;
    IF v_perm.permission_class <> 'organization' THEN
        reason_code := 'tenant_control_requires_interactive'; RETURN;
    END IF;
    IF p_organization_id IS NULL THEN
        reason_code := 'organization_context_required'; RETURN;
    END IF;
    IF v_cred_id IS NOT NULL THEN
        SELECT c.* INTO v_cred
          FROM cob3_identity.principal_credentials c
         WHERE c.tenant_id = p_tenant_id AND c.credential_id = v_cred_id;
        IF NOT FOUND
           OR v_cred.organization_id <> p_organization_id
           OR v_cred.principal_id <> p_principal_id
           OR v_cred.status <> 'active'
           OR v_cred.expires_at <= p_at THEN
            reason_code := 'credential_invalid'; RETURN;
        END IF;
        IF v_grant.authorization_grant_id IS NULL THEN
            SELECT g.* INTO v_grant
              FROM cob3_identity.authorization_grants g
             WHERE g.tenant_id = p_tenant_id
               AND g.organization_id = p_organization_id
               AND g.authorization_grant_id = v_cred.authorization_grant_id;
        ELSIF v_grant.authorization_grant_id <> v_cred.authorization_grant_id THEN
            reason_code := 'credential_grant_mismatch'; RETURN;
        END IF;
    END IF;
    IF v_grant.authorization_grant_id IS NULL THEN
        reason_code := 'grant_not_found'; RETURN;
    END IF;
    IF v_grant.organization_id <> p_organization_id OR v_grant.grantee_principal_id <> p_principal_id THEN
        reason_code := 'grant_principal_mismatch'; RETURN;
    END IF;
    IF v_grant.status <> 'active' OR v_grant.valid_from > p_at OR v_grant.valid_until <= p_at THEN
        reason_code := 'grant_not_effective'; RETURN;
    END IF;
    matched_grant_id := v_grant.authorization_grant_id;

    IF NOT cob3_identity.membership_is_effective(p_tenant_id, p_organization_id, p_principal_id, p_at) THEN
        reason_code := 'membership_not_effective'; RETURN;
    END IF;
    IF v_grant.grantor_principal_id <> p_principal_id THEN
        IF NOT cob3_identity.principal_is_eligible(p_tenant_id, v_grant.grantor_principal_id, p_at)
           OR NOT cob3_identity.membership_is_effective(p_tenant_id, p_organization_id, v_grant.grantor_principal_id, p_at) THEN
            reason_code := 'grantor_not_eligible'; RETURN;
        END IF;
    END IF;

    -- Immutable usage restrictions.
    v_auto_ctx := v_principal.principal_type = 'automation' OR COALESCE(v_cred.credential_usage = 'automation', false);
    IF v_auto_ctx THEN
        IF NOT v_perm.automation_allowed OR v_perm.is_identity_management THEN
            reason_code := 'automation_restricted'; RETURN;
        END IF;
    ELSIF v_perm.is_identity_management THEN
        IF NOT (COALESCE(v_cred.credential_usage, '') = 'provisioning' AND v_principal.principal_type = 'service_account') THEN
            reason_code := 'iam_requires_interactive_or_provisioning'; RETURN;
        END IF;
    END IF;
    IF NOT v_perm.is_delegable THEN
        reason_code := 'permission_not_delegable'; RETURN;
    END IF;

    -- Approved entries matching operation + scope. Approval requirement is
    -- aggregated over ALL applicable entries of the grant (strictest wins);
    -- a credential additionally needs one applicable entry it is bound to.
    SELECT bool_or(e.requires_human_approval),
           (array_agg(e.authorization_grant_permission_id ORDER BY e.authorization_grant_permission_id)
                FILTER (WHERE v_cred_id IS NULL OR EXISTS (
                    SELECT 1
                      FROM cob3_identity.credential_permission_bindings b
                     WHERE b.tenant_id = e.tenant_id
                       AND b.organization_id = e.organization_id
                       AND b.authorization_grant_id = e.authorization_grant_id
                       AND b.credential_id = v_cred_id
                       AND b.authorization_grant_permission_id = e.authorization_grant_permission_id)))[1]
      INTO v_requires, v_entry
      FROM cob3_identity.authorization_grant_permissions e
     WHERE e.tenant_id = p_tenant_id
       AND e.organization_id = p_organization_id
       AND e.authorization_grant_id = v_grant.authorization_grant_id
       AND e.permission_id = v_perm.permission_id
       AND cob3_identity.scope_covers_target(e.tenant_id, e.organization_id, e.scope_id, NULL,
                                             v_perm.resource_type, p_target_type, p_target_id, p_at);
    IF v_entry IS NULL THEN
        reason_code := CASE WHEN v_requires IS NULL THEN 'no_matching_grant_entry' ELSE 'credential_subset_denied' END;
        RETURN;
    END IF;
    matched_grant_permission_id := v_entry;
    requires_approval := COALESCE(v_requires, false);

    -- Live RBAC of grantee and grantor.
    IF NOT cob3_identity.rbac_permits(p_tenant_id, p_organization_id, p_principal_id, v_perm.permission_id,
                                      p_target_type, p_target_id, p_at) THEN
        reason_code := 'grantee_rbac_denied'; RETURN;
    END IF;
    IF v_grant.grantor_principal_id <> p_principal_id
       AND NOT cob3_identity.rbac_permits(p_tenant_id, p_organization_id, v_grant.grantor_principal_id, v_perm.permission_id,
                                          p_target_type, p_target_id, p_at) THEN
        reason_code := 'grantor_rbac_denied'; RETURN;
    END IF;

    -- Interactive assistance: the initiating user's live access is intersected too.
    IF p_initiating_principal_id IS NOT NULL AND p_initiating_principal_id <> p_principal_id THEN
        IF NOT cob3_identity.principal_is_eligible(p_tenant_id, p_initiating_principal_id, p_at)
           OR NOT cob3_identity.membership_is_effective(p_tenant_id, p_organization_id, p_initiating_principal_id, p_at)
           OR NOT cob3_identity.rbac_permits(p_tenant_id, p_organization_id, p_initiating_principal_id, v_perm.permission_id,
                                             p_target_type, p_target_id, p_at) THEN
            reason_code := 'initiator_denied'; RETURN;
        END IF;
    END IF;

    allowed := true;
    reason_code := 'allowed';
    RETURN;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Context predicates for RLS and routines
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.ctx_auth_valid()
    RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant    uuid := cob3_identity.ctx_tenant_id();
    v_org       uuid := cob3_identity.ctx_organization_id();
    v_principal uuid := cob3_identity.ctx_principal_id();
    v_session   uuid := cob3_identity.ctx_session_id();
    v_cred      uuid := cob3_identity.ctx_credential_id();
    v_s         cob3_identity.auth_sessions%ROWTYPE;
    v_c         cob3_identity.principal_credentials%ROWTYPE;
BEGIN
    IF v_tenant IS NULL OR v_principal IS NULL OR (v_session IS NULL AND v_cred IS NULL) THEN
        RETURN false;
    END IF;
    IF NOT cob3_identity.tenant_is_active(v_tenant)
       OR NOT cob3_identity.principal_is_eligible(v_tenant, v_principal, pg_catalog.now()) THEN
        RETURN false;
    END IF;
    IF v_session IS NOT NULL THEN
        SELECT s.* INTO v_s
          FROM cob3_identity.auth_sessions s
         WHERE s.tenant_id = v_tenant AND s.session_id = v_session;
        IF NOT FOUND OR v_s.principal_id <> v_principal
           OR NOT cob3_identity.session_is_valid(v_tenant, v_session, pg_catalog.now())
           OR v_s.organization_id IS DISTINCT FROM v_org THEN
            RETURN false;
        END IF;
        IF v_s.session_kind = 'interactive' THEN
            IF v_cred IS NOT NULL THEN
                RETURN false;
            END IF;
            RETURN true;
        END IF;
        IF NOT cob3_identity.grant_is_effective(v_tenant, v_s.organization_id, v_s.authorization_grant_id, v_principal, pg_catalog.now()) THEN
            RETURN false;
        END IF;
        IF v_s.credential_id IS NULL THEN
            RETURN v_cred IS NULL;
        END IF;
        IF v_cred IS NOT NULL AND v_cred <> v_s.credential_id THEN
            RETURN false;
        END IF;
        v_cred := v_s.credential_id;
    END IF;
    IF v_org IS NULL THEN
        RETURN false;
    END IF;
    SELECT c.* INTO v_c
      FROM cob3_identity.principal_credentials c
     WHERE c.tenant_id = v_tenant AND c.credential_id = v_cred;
    IF NOT FOUND OR v_c.principal_id <> v_principal OR v_c.organization_id <> v_org
       OR v_c.status <> 'active' OR v_c.expires_at <= pg_catalog.now() THEN
        RETURN false;
    END IF;
    RETURN cob3_identity.grant_is_effective(v_tenant, v_org, v_c.authorization_grant_id, v_principal, pg_catalog.now());
END
$fn$;

CREATE FUNCTION cob3_identity.ctx_is_tenant_member()
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT cob3_identity.ctx_auth_valid() $fn$;

CREATE FUNCTION cob3_identity.ctx_is_interactive()
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_identity.ctx_credential_id() IS NULL
       AND EXISTS (SELECT 1 FROM cob3_identity.auth_sessions s
                    WHERE s.tenant_id = cob3_identity.ctx_tenant_id()
                      AND s.session_id = cob3_identity.ctx_session_id()
                      AND s.session_kind = 'interactive')
       AND cob3_identity.ctx_auth_valid()
$fn$;

CREATE FUNCTION cob3_identity.ctx_in_org()
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_identity.ctx_organization_id() IS NOT NULL
       AND cob3_identity.ctx_auth_valid()
       AND cob3_identity.membership_is_effective(cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(),
                                                 cob3_identity.ctx_principal_id(), pg_catalog.now())
$fn$;

-- Membership-based visibility of an organization. Credential and
-- noninteractive contexts are bound to their own organization.
CREATE FUNCTION cob3_identity.ctx_is_member_of(p_organization_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_identity.ctx_auth_valid()
       AND cob3_identity.membership_is_effective(cob3_identity.ctx_tenant_id(), p_organization_id,
                                                 cob3_identity.ctx_principal_id(), pg_catalog.now())
       AND (cob3_identity.ctx_is_interactive() OR p_organization_id = cob3_identity.ctx_organization_id())
$fn$;

CREATE FUNCTION cob3_identity.ctx_is_tenant_controller()
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_identity.ctx_is_interactive()
       AND EXISTS (
           SELECT 1
             FROM cob3_identity.tenant_role_bindings b
             JOIN cob3_identity.roles r ON r.tenant_id = b.tenant_id AND r.role_id = b.role_id
            WHERE b.tenant_id = cob3_identity.ctx_tenant_id()
              AND b.principal_id = cob3_identity.ctx_principal_id()
              AND b.status = 'active'
              AND b.valid_from <= pg_catalog.now()
              AND (b.valid_until IS NULL OR b.valid_until > pg_catalog.now())
              AND r.status = 'active'
              AND r.role_class = 'tenant_control')
$fn$;

CREATE FUNCTION cob3_identity.ctx_has_org_permission(p_permission_code text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((
        SELECT d.allowed
          FROM cob3_identity.evaluate_access(
                   cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), cob3_identity.ctx_principal_id(),
                   cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(),
                   p_permission_code, 'organization', cob3_identity.ctx_organization_id(), pg_catalog.now(), NULL) AS d), false)
       AND cob3_identity.ctx_auth_valid()
$fn$;

CREATE FUNCTION cob3_identity.ctx_has_tenant_permission(p_permission_code text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((
        SELECT d.allowed
          FROM cob3_identity.evaluate_access(
                   cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), cob3_identity.ctx_principal_id(),
                   cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(),
                   p_permission_code, 'tenant', cob3_identity.ctx_tenant_id(), pg_catalog.now(), NULL) AS d), false)
       AND cob3_identity.ctx_auth_valid()
$fn$;

-- Directory visibility: self, members of the current organization (for an
-- active member of it), or tenant controllers. Not blanket tenant visibility.
CREATE FUNCTION cob3_identity.ctx_can_view_principal(p_principal_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_identity.ctx_auth_valid()
       AND (p_principal_id = cob3_identity.ctx_principal_id()
            OR (cob3_identity.ctx_in_org()
                AND EXISTS (SELECT 1 FROM cob3_identity.organization_memberships m
                             WHERE m.tenant_id = cob3_identity.ctx_tenant_id()
                               AND m.organization_id = cob3_identity.ctx_organization_id()
                               AND m.principal_id = p_principal_id))
            OR cob3_identity.ctx_is_tenant_controller())
$fn$;

-- Who may change a principal (status, display name, profile).
CREATE FUNCTION cob3_identity.ctx_can_manage_principal(p_principal_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid := cob3_identity.ctx_tenant_id();
    v_org    uuid := cob3_identity.ctx_organization_id();
    v_p      cob3_identity.principals%ROWTYPE;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RETURN false;
    END IF;
    SELECT p.* INTO v_p FROM cob3_identity.principals p
     WHERE p.tenant_id = v_tenant AND p.principal_id = p_principal_id;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    -- Creation flow: a principal created in this transaction by this actor.
    IF v_p.created_at = pg_catalog.now() AND v_p.created_by = cob3_identity.ctx_actor() THEN
        RETURN true;
    END IF;
    IF v_p.principal_type = 'human' THEN
        RETURN cob3_identity.ctx_has_tenant_permission('tenant.manage_administrators')
            OR (cob3_identity.ctx_has_org_permission('organization.manage_members')
                AND EXISTS (SELECT 1 FROM cob3_identity.organization_memberships m
                             WHERE m.tenant_id = v_tenant AND m.organization_id = v_org
                               AND m.principal_id = p_principal_id));
    ELSIF v_p.principal_type = 'service_account' THEN
        RETURN EXISTS (SELECT 1 FROM cob3_identity.service_accounts s
                        WHERE s.tenant_id = v_tenant AND s.principal_id = p_principal_id
                          AND s.organization_id = v_org)
           AND cob3_identity.ctx_has_org_permission('service_account.manage');
    ELSE
        RETURN EXISTS (SELECT 1 FROM cob3_identity.automation_profiles a
                        WHERE a.tenant_id = v_tenant AND a.principal_id = p_principal_id
                          AND a.organization_id = v_org)
           AND (cob3_identity.ctx_has_org_permission('automation.manage')
                OR cob3_identity.ctx_has_org_permission('automation.revoke'));
    END IF;
END
$fn$;

CREATE FUNCTION cob3_identity.ctx_can_view_grant(p_organization_id uuid, p_grant_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p_organization_id = cob3_identity.ctx_organization_id()
       AND cob3_identity.ctx_in_org()
       AND (EXISTS (SELECT 1 FROM cob3_identity.authorization_grants g
                     WHERE g.tenant_id = cob3_identity.ctx_tenant_id()
                       AND g.organization_id = p_organization_id
                       AND g.authorization_grant_id = p_grant_id
                       AND cob3_identity.ctx_principal_id() IN (g.grantor_principal_id, g.grantee_principal_id, g.authorized_by_principal_id))
            OR cob3_identity.ctx_has_org_permission('grant.revoke')
            OR cob3_identity.ctx_has_org_permission('audit.read'))
$fn$;

CREATE FUNCTION cob3_identity.ctx_can_view_credential(p_organization_id uuid, p_credential_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p_organization_id = cob3_identity.ctx_organization_id()
       AND cob3_identity.ctx_in_org()
       AND (EXISTS (SELECT 1 FROM cob3_identity.principal_credentials c
                     WHERE c.tenant_id = cob3_identity.ctx_tenant_id()
                       AND c.organization_id = p_organization_id
                       AND c.credential_id = p_credential_id
                       AND c.principal_id = cob3_identity.ctx_principal_id())
            OR cob3_identity.ctx_has_org_permission('credential.revoke'))
$fn$;

CREATE FUNCTION cob3_identity.role_is_system(p_tenant_id uuid, p_role_id uuid)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((SELECT r.is_system FROM cob3_identity.roles r
                      WHERE r.tenant_id = p_tenant_id AND r.role_id = p_role_id), true)
$fn$;

-- Raise unless the current context holds the permission (routine guard).
CREATE FUNCTION cob3_identity.require_ctx_permission(p_permission_code text, p_target_type text DEFAULT 'organization')
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_target uuid := CASE WHEN p_target_type = 'tenant' THEN cob3_identity.ctx_tenant_id() ELSE cob3_identity.ctx_organization_id() END;
    d        record;
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context (tenant, principal, session or credential).';
    END IF;
    SELECT * INTO d FROM cob3_identity.evaluate_access(
        cob3_identity.ctx_tenant_id(), cob3_identity.ctx_organization_id(), cob3_identity.ctx_principal_id(),
        cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id(),
        p_permission_code, p_target_type, v_target, pg_catalog.now(), NULL);
    IF NOT d.allowed THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
            MESSAGE = pg_catalog.format('Permission %s denied: %s.', p_permission_code, d.reason_code);
    END IF;
END
$fn$;
