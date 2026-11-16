-- =============================================================================
-- 70  IDENTITY INVARIANT TRIGGERS
-- -----------------------------------------------------------------------------
-- Cross-row rules either check both sides or rely on referenced attributes
-- that are made immutable here (principal_type, role_class after use,
-- permission class after use, team/mapping linkage, grant envelope, ...).
-- Trigger functions that read other rows are SECURITY DEFINER (owner context)
-- so validation cannot be hidden by the caller's RLS visibility.
-- =============================================================================

-- Principal type lookup used by many validators.
CREATE FUNCTION cob3_identity.principal_type_of(p_tenant_id uuid, p_principal_id uuid)
    RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p.principal_type::text FROM cob3_identity.principals p
     WHERE p.tenant_id = p_tenant_id AND p.principal_id = p_principal_id
$fn$;

CREATE FUNCTION cob3_identity.raise_invariant(p_message text)
    RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = p_message;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Gauge quota triggers (lock -> count with fresh snapshot -> assert).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.enforce_gauge(p_tenant_id uuid, p_organization_id uuid, p_feature_code text)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant_count numeric;
    v_org_count    numeric;
BEGIN
    IF (SELECT t.status FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id) = 'provisioning' THEN
        RETURN;
    END IF;
    PERFORM cob3_identity.assert_isolation_safe();
    PERFORM cob3_identity.xact_lock('quota', p_tenant_id::text || ':' || p_feature_code);
    IF p_feature_code = 'organizations.max' THEN
        SELECT count(*) INTO v_tenant_count FROM cob3_identity.organizations o
         WHERE o.tenant_id = p_tenant_id AND o.status = 'active';
    ELSIF p_feature_code = 'humans.max' THEN
        SELECT count(*) INTO v_tenant_count FROM cob3_identity.principals p
         WHERE p.tenant_id = p_tenant_id AND p.principal_type = 'human' AND p.status = 'active';
    ELSIF p_feature_code = 'service_accounts.max' THEN
        SELECT count(*), count(*) FILTER (WHERE s.organization_id = p_organization_id)
          INTO v_tenant_count, v_org_count
          FROM cob3_identity.principals p
          JOIN cob3_identity.service_accounts s ON s.tenant_id = p.tenant_id AND s.principal_id = p.principal_id
         WHERE p.tenant_id = p_tenant_id AND p.status = 'active';
    ELSIF p_feature_code = 'automations.max' THEN
        SELECT count(*), count(*) FILTER (WHERE a.organization_id = p_organization_id)
          INTO v_tenant_count, v_org_count
          FROM cob3_identity.principals p
          JOIN cob3_identity.automation_profiles a ON a.tenant_id = p.tenant_id AND a.principal_id = p.principal_id
         WHERE p.tenant_id = p_tenant_id AND p.status = 'active';
    ELSIF p_feature_code = 'api_credentials.max' THEN
        SELECT count(*), count(*) FILTER (WHERE c.organization_id = p_organization_id)
          INTO v_tenant_count, v_org_count
          FROM cob3_identity.principal_credentials c
         WHERE c.tenant_id = p_tenant_id AND c.status = 'active' AND c.expires_at > pg_catalog.now();
    ELSE
        PERFORM cob3_identity.raise_invariant('Unknown gauge feature ' || p_feature_code);
    END IF;
    PERFORM cob3_tenant.assert_gauge_capacity(p_tenant_id, p_organization_id, p_feature_code, v_tenant_count, v_org_count);
END
$fn$;

CREATE FUNCTION cob3_identity.tg_gauge_organizations()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'active' AND (TG_OP = 'INSERT' OR OLD.status <> 'active') THEN
        PERFORM cob3_identity.enforce_gauge(NEW.tenant_id, NULL, 'organizations.max');
    END IF;
    RETURN NULL;
END
$fn$;

CREATE FUNCTION cob3_identity.tg_gauge_principals()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_org uuid;
BEGIN
    IF NOT (NEW.status = 'active' AND (TG_OP = 'INSERT' OR OLD.status <> 'active')) THEN
        RETURN NULL;
    END IF;
    IF NEW.principal_type = 'human' THEN
        PERFORM cob3_identity.enforce_gauge(NEW.tenant_id, NULL, 'humans.max');
    ELSIF TG_OP = 'UPDATE' AND NEW.principal_type = 'service_account' THEN
        SELECT s.organization_id INTO v_org FROM cob3_identity.service_accounts s
         WHERE s.tenant_id = NEW.tenant_id AND s.principal_id = NEW.principal_id;
        PERFORM cob3_identity.enforce_gauge(NEW.tenant_id, v_org, 'service_accounts.max');
    ELSIF TG_OP = 'UPDATE' AND NEW.principal_type = 'automation' THEN
        SELECT a.organization_id INTO v_org FROM cob3_identity.automation_profiles a
         WHERE a.tenant_id = NEW.tenant_id AND a.principal_id = NEW.principal_id;
        PERFORM cob3_identity.enforce_gauge(NEW.tenant_id, v_org, 'automations.max');
    END IF;
    -- Service/automation INSERTs are counted when their subtype row is inserted.
    RETURN NULL;
END
$fn$;

CREATE FUNCTION cob3_identity.tg_gauge_subtype()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF EXISTS (SELECT 1 FROM cob3_identity.principals p
                WHERE p.tenant_id = NEW.tenant_id AND p.principal_id = NEW.principal_id AND p.status = 'active') THEN
        PERFORM cob3_identity.enforce_gauge(NEW.tenant_id, NEW.organization_id, TG_ARGV[0]);
    END IF;
    IF TG_ARGV[0] = 'automations.max' THEN
        PERFORM cob3_tenant.assert_feature_enabled(NEW.tenant_id, 'automation.enabled');
    END IF;
    RETURN NULL;
END
$fn$;

CREATE FUNCTION cob3_identity.tg_gauge_credentials()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'active' THEN
        PERFORM cob3_identity.enforce_gauge(NEW.tenant_id, NEW.organization_id, 'api_credentials.max');
    END IF;
    RETURN NULL;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Last active human tenant administrator protection (deferred, serialized).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.assert_tenant_admin_remains(p_tenant_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_status text;
    v_count  integer;
BEGIN
    SELECT t.status INTO v_status FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id;
    IF v_status NOT IN ('active', 'suspended') THEN
        RETURN;
    END IF;
    PERFORM cob3_identity.xact_lock('tenant_admin', p_tenant_id::text);
    SELECT count(DISTINCT b.principal_id) INTO v_count
      FROM cob3_identity.tenant_role_bindings b
      JOIN cob3_identity.principals p ON p.tenant_id = b.tenant_id AND p.principal_id = b.principal_id
      JOIN cob3_identity.roles r ON r.tenant_id = b.tenant_id AND r.role_id = b.role_id
      JOIN cob3_identity.role_permissions rp ON rp.tenant_id = r.tenant_id AND rp.role_id = r.role_id
      JOIN cob3_identity.permissions perm ON perm.tenant_id = rp.tenant_id AND perm.permission_id = rp.permission_id
     WHERE b.tenant_id = p_tenant_id
       AND b.status = 'active'
       AND b.valid_from <= pg_catalog.now()
       AND (b.valid_until IS NULL OR b.valid_until > pg_catalog.now())
       AND p.principal_type = 'human'
       AND p.status = 'active'
       AND r.status = 'active'
       AND r.role_class = 'tenant_control'
       AND perm.permission_code = 'tenant.manage_administrators'
       AND perm.status = 'active';
    IF v_count = 0 THEN
        RAISE EXCEPTION USING ERRCODE = 'SKADM',
            MESSAGE = 'This change would leave the tenant without an active human tenant administrator.',
            HINT = 'Assign a replacement administrator in the same transaction first.';
    END IF;
END
$fn$;

CREATE FUNCTION cob3_identity.tg_last_tenant_admin()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_relevant boolean := false;
BEGIN
    IF TG_TABLE_NAME = 'tenant_role_bindings' THEN
        v_relevant := OLD.status = 'active'
                      AND (NEW.status <> 'active' OR NEW.valid_until IS DISTINCT FROM OLD.valid_until);
    ELSIF TG_TABLE_NAME = 'principals' THEN
        v_relevant := OLD.status = 'active' AND NEW.status <> 'active' AND OLD.principal_type = 'human'
                      AND EXISTS (SELECT 1 FROM cob3_identity.tenant_role_bindings b
                                   WHERE b.tenant_id = OLD.tenant_id AND b.principal_id = OLD.principal_id AND b.status = 'active');
    ELSIF TG_TABLE_NAME = 'roles' THEN
        v_relevant := OLD.role_class = 'tenant_control' AND OLD.status = 'active' AND NEW.status <> 'active';
    ELSIF TG_TABLE_NAME = 'role_permissions' THEN
        v_relevant := EXISTS (SELECT 1 FROM cob3_identity.permissions x
                               WHERE x.tenant_id = OLD.tenant_id AND x.permission_id = OLD.permission_id
                                 AND x.permission_code = 'tenant.manage_administrators');
    ELSIF TG_TABLE_NAME = 'permissions' THEN
        v_relevant := OLD.permission_code = 'tenant.manage_administrators' AND OLD.status = 'active' AND NEW.status <> 'active';
    END IF;
    IF v_relevant THEN
        PERFORM cob3_identity.assert_tenant_admin_remains(OLD.tenant_id);
    END IF;
    RETURN NULL;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Hierarchy cycle prevention (organizations, teams). Serialized per tenant
-- (organizations) / per organization (teams) with an advisory lock; the walk
-- takes FOR SHARE row locks so a concurrently re-parented ancestor either
-- blocks (READ COMMITTED, then re-read) or raises a serialization failure.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_organizations_hierarchy()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_cursor uuid := NEW.parent_organization_id;
    v_depth  integer := 0;
BEGIN
    IF v_cursor IS NULL OR TG_OP = 'INSERT' OR NEW.parent_organization_id IS NOT DISTINCT FROM OLD.parent_organization_id THEN
        RETURN NEW;
    END IF;
    PERFORM cob3_identity.xact_lock('org_hierarchy', NEW.tenant_id::text);
    WHILE v_cursor IS NOT NULL LOOP
        IF v_cursor = NEW.organization_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Organization hierarchy change would create a cycle.';
        END IF;
        v_depth := v_depth + 1;
        IF v_depth > 1000 THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Organization hierarchy is too deep (>1000).';
        END IF;
        SELECT o.parent_organization_id INTO v_cursor
          FROM cob3_identity.organizations o
         WHERE o.tenant_id = NEW.tenant_id AND o.organization_id = v_cursor
           FOR SHARE;
    END LOOP;
    RETURN NEW;
END
$fn$;

CREATE FUNCTION cob3_identity.tg_teams_hierarchy()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_cursor uuid := NEW.parent_team_id;
    v_depth  integer := 0;
BEGIN
    IF v_cursor IS NULL OR TG_OP = 'INSERT' OR NEW.parent_team_id IS NOT DISTINCT FROM OLD.parent_team_id THEN
        RETURN NEW;
    END IF;
    PERFORM cob3_identity.xact_lock('team_hierarchy', NEW.tenant_id::text || ':' || NEW.organization_id::text);
    WHILE v_cursor IS NOT NULL LOOP
        IF v_cursor = NEW.team_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Team hierarchy change would create a cycle.';
        END IF;
        v_depth := v_depth + 1;
        IF v_depth > 1000 THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Team hierarchy is too deep (>1000).';
        END IF;
        SELECT t.parent_team_id INTO v_cursor
          FROM cob3_identity.teams t
         WHERE t.tenant_id = NEW.tenant_id AND t.organization_id = NEW.organization_id AND t.team_id = v_cursor
           FOR SHARE;
    END LOOP;
    RETURN NEW;
END
$fn$;

-- ---------------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------------
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.organizations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>active', '>suspended', 'active>suspended', 'suspended>active', 'active>archived', 'suspended>archived');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.organizations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('organization_code');
CREATE TRIGGER trg_30_hierarchy BEFORE INSERT OR UPDATE OF parent_organization_id ON cob3_identity.organizations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_organizations_hierarchy();
CREATE TRIGGER trg_60_gauge AFTER INSERT OR UPDATE OF status ON cob3_identity.organizations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_gauge_organizations();

-- ---------------------------------------------------------------------------
-- principals and subtypes
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_principals_exactly_one_subtype()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_h integer;
    v_s integer;
    v_a integer;
BEGIN
    SELECT (SELECT count(*) FROM cob3_identity.user_profiles x WHERE x.tenant_id = NEW.tenant_id AND x.principal_id = NEW.principal_id),
           (SELECT count(*) FROM cob3_identity.service_accounts x WHERE x.tenant_id = NEW.tenant_id AND x.principal_id = NEW.principal_id),
           (SELECT count(*) FROM cob3_identity.automation_profiles x WHERE x.tenant_id = NEW.tenant_id AND x.principal_id = NEW.principal_id)
      INTO v_h, v_s, v_a;
    IF v_h + v_s + v_a <> 1
       OR (NEW.principal_type = 'human' AND v_h <> 1)
       OR (NEW.principal_type = 'service_account' AND v_s <> 1)
       OR (NEW.principal_type = 'automation' AND v_a <> 1) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Principal %s (%s) must have exactly one matching subtype row at commit (human=%s, service=%s, automation=%s).',
                        NEW.principal_id, NEW.principal_type, v_h, v_s, v_a);
    END IF;
    RETURN NULL;
END
$fn$;

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.principals
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>active', '>suspended', 'active>suspended', 'active>disabled', 'suspended>active', 'suspended>disabled',
        'disabled>active', 'disabled>suspended');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.principals
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_type', 'principal_code');
CREATE TRIGGER trg_21_nondecreasing BEFORE UPDATE ON cob3_identity.principals
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('auth_version');
CREATE TRIGGER trg_60_gauge AFTER INSERT OR UPDATE OF status ON cob3_identity.principals
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_gauge_principals();
CREATE CONSTRAINT TRIGGER trg_80_exactly_one_subtype AFTER INSERT ON cob3_identity.principals
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_principals_exactly_one_subtype();
CREATE CONSTRAINT TRIGGER trg_81_last_tenant_admin AFTER UPDATE OF status ON cob3_identity.principals
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_last_tenant_admin();

CREATE FUNCTION cob3_identity.tg_subtype_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_expected text := TG_ARGV[0];
    v_creator  text;
    v_owner    text;
BEGIN
    IF TG_OP = 'INSERT' AND cob3_identity.principal_type_of(NEW.tenant_id, NEW.principal_id) IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I rows require a %s principal.', TG_TABLE_NAME, v_expected);
    END IF;
    IF TG_TABLE_NAME IN ('service_accounts', 'automation_profiles') THEN
        IF TG_OP = 'INSERT' THEN
            v_creator := cob3_identity.principal_type_of(NEW.tenant_id, NEW.creator_principal_id);
            -- Automations never create principals in v1 (no self-provisioning or recursion).
            IF v_creator NOT IN ('human', 'service_account') THEN
                RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Creator must be a human or service account principal.';
            END IF;
        END IF;
        IF TG_OP = 'INSERT' OR NEW.owner_principal_id IS DISTINCT FROM OLD.owner_principal_id THEN
            v_owner := cob3_identity.principal_type_of(NEW.tenant_id, NEW.owner_principal_id);
            IF v_owner IS DISTINCT FROM 'human' THEN
                RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Accountable owner must be a human principal.';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;

CREATE TRIGGER trg_10_validate BEFORE INSERT ON cob3_identity.user_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_subtype_validate('human');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.user_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id');

CREATE TRIGGER trg_10_validate BEFORE INSERT OR UPDATE ON cob3_identity.service_accounts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_subtype_validate('service_account');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.service_accounts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'creator_principal_id');
CREATE TRIGGER trg_60_gauge AFTER INSERT ON cob3_identity.service_accounts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_gauge_subtype('service_accounts.max');

CREATE TRIGGER trg_10_validate BEFORE INSERT OR UPDATE ON cob3_identity.automation_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_subtype_validate('automation');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.automation_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'creator_principal_id', 'creation_method');
CREATE TRIGGER trg_60_gauge AFTER INSERT ON cob3_identity.automation_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_gauge_subtype('automations.max');

-- ---------------------------------------------------------------------------
-- organization_memberships
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_org_memberships_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_type text := cob3_identity.principal_type_of(NEW.tenant_id, NEW.principal_id);
BEGIN
    IF NOT ((NEW.membership_type = 'service' AND v_type = 'service_account')
            OR (NEW.membership_type = 'automation' AND v_type = 'automation')
            OR (NEW.membership_type IN ('employee', 'contractor', 'guest') AND v_type = 'human')) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('membership_type %s does not match principal type %s.', NEW.membership_type, v_type);
    END IF;
    IF NEW.status = 'active' THEN
        NEW.joined_at := COALESCE(NEW.joined_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.joined_at END, pg_catalog.now());
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.organization_memberships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>invited', '>active', 'invited>active', 'invited>revoked', 'active>suspended', 'active>revoked',
        'suspended>active', 'suspended>revoked', 'revoked>invited', 'revoked>active');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_identity.organization_memberships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_org_memberships_validate();
CREATE TRIGGER trg_16_revoked_at BEFORE INSERT OR UPDATE ON cob3_identity.organization_memberships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_maintain_revoked_at();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.organization_memberships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id');

-- ---------------------------------------------------------------------------
-- teams, team memberships and sources
-- ---------------------------------------------------------------------------
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.teams
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>active', '>suspended', 'active>suspended', 'suspended>active', 'active>archived', 'suspended>archived');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.teams
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('team_code');
CREATE TRIGGER trg_30_hierarchy BEFORE INSERT OR UPDATE OF parent_team_id ON cob3_identity.teams
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_teams_hierarchy();

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.team_memberships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>active', '>suspended', 'active>suspended', 'active>revoked', 'suspended>active', 'suspended>revoked', 'revoked>active');
CREATE TRIGGER trg_16_revoked_at BEFORE INSERT OR UPDATE ON cob3_identity.team_memberships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_maintain_revoked_at();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.team_memberships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('team_id', 'principal_id');

CREATE FUNCTION cob3_identity.tg_team_membership_sources_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.source_type = 'external_group' AND NOT EXISTS (
           SELECT 1
             FROM cob3_identity.group_team_mappings g
             JOIN cob3_identity.team_memberships tm
               ON tm.tenant_id = g.tenant_id AND tm.organization_id = g.organization_id AND tm.team_id = g.team_id
            WHERE g.tenant_id = NEW.tenant_id AND g.organization_id = NEW.organization_id
              AND g.group_team_mapping_id = NEW.group_team_mapping_id
              AND tm.team_membership_id = NEW.team_membership_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'External-group membership source must map to the same team as the membership.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.team_membership_sources
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_identity.team_membership_sources
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_team_membership_sources_validate();
CREATE TRIGGER trg_16_revoked_at BEFORE INSERT OR UPDATE ON cob3_identity.team_membership_sources
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_maintain_revoked_at();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.team_membership_sources
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('team_membership_id', 'source_type', 'group_team_mapping_id');

-- team_domains: fail closed until Catalog integration.
CREATE FUNCTION cob3_identity.tg_team_domains_catalog_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    PERFORM cob3_identity.assert_catalog_domain(NEW.tenant_id, NEW.organization_id, NEW.domain_id);
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_05_catalog_guard BEFORE INSERT OR UPDATE ON cob3_identity.team_domains
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_team_domains_catalog_guard();
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.team_domains
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>active', 'active>suspended', 'suspended>active', 'active>revoked', 'suspended>revoked');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.team_domains
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('team_id', 'domain_id');

-- ---------------------------------------------------------------------------
-- permissions, roles, role_permissions
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_permissions_definition_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF (NEW.permission_code, NEW.permission_class, NEW.resource_type, NEW.action)
           IS DISTINCT FROM (OLD.permission_code, OLD.permission_class, OLD.resource_type, OLD.action)
       AND (EXISTS (SELECT 1 FROM cob3_identity.role_permissions x WHERE x.tenant_id = OLD.tenant_id AND x.permission_id = OLD.permission_id)
            OR EXISTS (SELECT 1 FROM cob3_identity.authorization_grant_permissions x WHERE x.tenant_id = OLD.tenant_id AND x.permission_id = OLD.permission_id)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = 'Permission code, class, resource_type and action are immutable after use.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.permissions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>deprecated', 'deprecated>active');
CREATE TRIGGER trg_20_definition_guard BEFORE UPDATE ON cob3_identity.permissions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_permissions_definition_guard();
CREATE CONSTRAINT TRIGGER trg_81_last_tenant_admin AFTER UPDATE OF status ON cob3_identity.permissions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_last_tenant_admin();

CREATE FUNCTION cob3_identity.tg_roles_class_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.role_class IS DISTINCT FROM OLD.role_class
       AND (EXISTS (SELECT 1 FROM cob3_identity.role_permissions x WHERE x.tenant_id = OLD.tenant_id AND x.role_id = OLD.role_id)
            OR EXISTS (SELECT 1 FROM cob3_identity.role_bindings x WHERE x.tenant_id = OLD.tenant_id AND x.role_id = OLD.role_id)
            OR EXISTS (SELECT 1 FROM cob3_identity.tenant_role_bindings x WHERE x.tenant_id = OLD.tenant_id AND x.role_id = OLD.role_id)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM', MESSAGE = 'Role class is immutable after use.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.roles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>active', '>disabled', 'active>disabled', 'disabled>active', 'active>archived', 'disabled>archived');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.roles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('role_code');
CREATE TRIGGER trg_21_class_guard BEFORE UPDATE ON cob3_identity.roles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_roles_class_guard();
CREATE CONSTRAINT TRIGGER trg_81_last_tenant_admin AFTER UPDATE OF status ON cob3_identity.roles
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_last_tenant_admin();

CREATE FUNCTION cob3_identity.tg_role_permissions_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_role_class text;
    v_perm_class text;
BEGIN
    SELECT r.role_class INTO v_role_class FROM cob3_identity.roles r WHERE r.tenant_id = NEW.tenant_id AND r.role_id = NEW.role_id;
    SELECT p.permission_class INTO v_perm_class FROM cob3_identity.permissions p WHERE p.tenant_id = NEW.tenant_id AND p.permission_id = NEW.permission_id;
    IF v_role_class IS DISTINCT FROM v_perm_class THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Role class %s cannot contain a %s permission.', v_role_class, v_perm_class);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_validate BEFORE INSERT ON cob3_identity.role_permissions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_role_permissions_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.role_permissions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('role_id', 'permission_id');
CREATE CONSTRAINT TRIGGER trg_81_last_tenant_admin AFTER DELETE ON cob3_identity.role_permissions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_last_tenant_admin();

-- ---------------------------------------------------------------------------
-- access_scopes and role bindings
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_access_scopes_catalog_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.scope_type = 'domain' THEN
        PERFORM cob3_identity.assert_catalog_domain(NEW.tenant_id, NEW.organization_id, NEW.domain_id);
    ELSIF NEW.scope_type = 'asset' THEN
        PERFORM cob3_identity.assert_catalog_asset(NEW.tenant_id, NEW.organization_id, NEW.asset_id);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_05_catalog_guard BEFORE INSERT ON cob3_identity.access_scopes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_access_scopes_catalog_guard();
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.access_scopes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>disabled', 'disabled>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.access_scopes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('scope_type', 'domain_id', 'asset_id', 'include_contained_assets');

CREATE FUNCTION cob3_identity.tg_role_bindings_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_role_class text;
    v_scope      cob3_identity.access_scopes%ROWTYPE;
BEGIN
    SELECT r.role_class INTO v_role_class FROM cob3_identity.roles r WHERE r.tenant_id = NEW.tenant_id AND r.role_id = NEW.role_id;
    IF v_role_class IS DISTINCT FROM 'organization' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'role_bindings accept organization-class roles only (tenant control uses tenant_role_bindings).';
    END IF;
    SELECT s.* INTO v_scope FROM cob3_identity.access_scopes s
     WHERE s.tenant_id = NEW.tenant_id AND s.organization_id = NEW.organization_id AND s.scope_id = NEW.scope_id;
    -- Domain/asset team bindings need Catalog-backed team_domains: fail closed.
    IF NEW.team_id IS NOT NULL AND v_scope.scope_type = 'domain' THEN
        PERFORM cob3_identity.assert_catalog_domain(NEW.tenant_id, NEW.organization_id, v_scope.domain_id);
    ELSIF NEW.team_id IS NOT NULL AND v_scope.scope_type = 'asset' THEN
        PERFORM cob3_identity.assert_catalog_asset(NEW.tenant_id, NEW.organization_id, v_scope.asset_id);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_identity.role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_role_bindings_validate();
CREATE TRIGGER trg_16_revoked_at BEFORE INSERT OR UPDATE ON cob3_identity.role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_maintain_revoked_at();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('role_id', 'scope_id', 'principal_id', 'team_id', 'valid_from', 'grant_reason');

CREATE FUNCTION cob3_identity.tg_tenant_role_bindings_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_role_class text;
    v_type       text := cob3_identity.principal_type_of(NEW.tenant_id, NEW.principal_id);
BEGIN
    SELECT r.role_class INTO v_role_class FROM cob3_identity.roles r WHERE r.tenant_id = NEW.tenant_id AND r.role_id = NEW.role_id;
    IF v_role_class IS DISTINCT FROM 'tenant_control' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'tenant_role_bindings accept tenant_control roles only.';
    END IF;
    IF v_type NOT IN ('human', 'service_account') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Automation principals cannot receive tenant control-plane roles.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.tenant_role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_identity.tenant_role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_tenant_role_bindings_validate();
CREATE TRIGGER trg_16_revoked_at BEFORE INSERT OR UPDATE ON cob3_identity.tenant_role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_maintain_revoked_at();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.tenant_role_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'role_id', 'valid_from', 'grant_reason');
CREATE CONSTRAINT TRIGGER trg_81_last_tenant_admin AFTER UPDATE ON cob3_identity.tenant_role_bindings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_last_tenant_admin();

-- ---------------------------------------------------------------------------
-- authorization_grants and entries
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_authorization_grants_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_grantor_type    text := cob3_identity.principal_type_of(NEW.tenant_id, NEW.grantor_principal_id);
    v_grantee_type    text := cob3_identity.principal_type_of(NEW.tenant_id, NEW.grantee_principal_id);
    v_authorizer_type text;
    v_limit           timestamptz;
BEGIN
    IF TG_OP = 'INSERT' AND (NEW.status <> 'draft' OR NEW.authorized_at IS NOT NULL) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Grants are created as draft and activated by authorization.';
    END IF;
    -- Subtype guard: restricted_self for human/service; delegated human/service -> automation only.
    IF NEW.grant_type = 'restricted_self' AND v_grantee_type NOT IN ('human', 'service_account') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'restricted_self grants are for human or service account principals.';
    END IF;
    IF NEW.grant_type = 'delegated' AND (v_grantor_type NOT IN ('human', 'service_account') OR v_grantee_type <> 'automation') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'delegated grants go from a human or service account grantor to an automation grantee (no recursive delegation).';
    END IF;
    IF NEW.status = 'active' AND TG_OP = 'UPDATE' AND OLD.status = 'draft' THEN
        NEW.authorized_at := COALESCE(NEW.authorized_at, pg_catalog.now());
        IF NEW.authorized_by_principal_id IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Grant activation requires an authorizing principal.';
        END IF;
        v_authorizer_type := cob3_identity.principal_type_of(NEW.tenant_id, NEW.authorized_by_principal_id);
        IF v_authorizer_type NOT IN ('human', 'service_account') THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Grant authorizer must be a human or service account.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM cob3_identity.authorization_grant_permissions e
                        WHERE e.tenant_id = NEW.tenant_id AND e.organization_id = NEW.organization_id
                          AND e.authorization_grant_id = NEW.authorization_grant_id) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A grant cannot be authorized with an empty permission envelope.';
        END IF;
        -- Bounded by the lifetimes of both accounts.
        SELECT min(x.expires_at) INTO v_limit FROM (
            SELECT s.expires_at FROM cob3_identity.service_accounts s
             WHERE s.tenant_id = NEW.tenant_id AND s.principal_id IN (NEW.grantor_principal_id, NEW.grantee_principal_id)
            UNION ALL
            SELECT a.expires_at FROM cob3_identity.automation_profiles a
             WHERE a.tenant_id = NEW.tenant_id AND a.principal_id IN (NEW.grantor_principal_id, NEW.grantee_principal_id)) AS x;
        IF v_limit IS NOT NULL AND NEW.valid_until > v_limit THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Grant validity exceeds the lifetime of the grantor or grantee account.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.authorization_grants
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>draft', 'draft>active', 'draft>revoked', 'active>suspended', 'active>revoked', 'suspended>active', 'suspended>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_identity.authorization_grants
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_authorization_grants_validate();
CREATE TRIGGER trg_16_revoked_at BEFORE INSERT OR UPDATE ON cob3_identity.authorization_grants
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_maintain_revoked_at();
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_identity.authorization_grants
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status', 'revoked_at', 'revocation_reason');

CREATE FUNCTION cob3_identity.tg_grant_permissions_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid;
    v_org    uuid;
    v_gid    uuid;
    v_grant  cob3_identity.authorization_grants%ROWTYPE;
    v_perm   cob3_identity.permissions%ROWTYPE;
    v_scope_status text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_tenant := OLD.tenant_id; v_org := OLD.organization_id; v_gid := OLD.authorization_grant_id;
    ELSE
        v_tenant := NEW.tenant_id; v_org := NEW.organization_id; v_gid := NEW.authorization_grant_id;
    END IF;
    SELECT g.* INTO v_grant FROM cob3_identity.authorization_grants g
     WHERE g.tenant_id = v_tenant AND g.organization_id = v_org AND g.authorization_grant_id = v_gid
       FOR UPDATE;
    IF v_grant.status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = 'Grant entries may change only while the grant is draft; the authorized envelope is immutable.';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    SELECT p.* INTO v_perm FROM cob3_identity.permissions p
     WHERE p.tenant_id = NEW.tenant_id AND p.permission_id = NEW.permission_id;
    IF v_perm.status <> 'active' OR v_perm.permission_class <> 'organization' OR NOT v_perm.is_delegable THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Permission %s cannot be placed in a grant (must be active, organization-class and delegable).', v_perm.permission_code);
    END IF;
    IF v_grant.grant_type = 'delegated' AND (NOT v_perm.automation_allowed OR v_perm.is_identity_management) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Permission %s cannot be delegated to an automation.', v_perm.permission_code);
    END IF;
    SELECT s.status INTO v_scope_status FROM cob3_identity.access_scopes s
     WHERE s.tenant_id = NEW.tenant_id AND s.organization_id = NEW.organization_id AND s.scope_id = NEW.scope_id;
    IF v_scope_status <> 'active' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Grant entries require an active access scope.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_guard BEFORE INSERT OR UPDATE OR DELETE ON cob3_identity.authorization_grant_permissions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_grant_permissions_guard();

-- ---------------------------------------------------------------------------
-- principal_credentials and credential_permission_bindings
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_credentials_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_grant cob3_identity.authorization_grants%ROWTYPE;
    v_type  text := cob3_identity.principal_type_of(NEW.tenant_id, NEW.principal_id);
BEGIN
    SELECT g.* INTO v_grant FROM cob3_identity.authorization_grants g
     WHERE g.tenant_id = NEW.tenant_id AND g.organization_id = NEW.organization_id
       AND g.authorization_grant_id = NEW.authorization_grant_id
       FOR SHARE;
    IF v_grant.status <> 'active' OR v_grant.valid_until <= pg_catalog.now() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA',
            MESSAGE = 'Credentials can be issued only against an active, unexpired grant (draft/suspended/revoked/expired grants are rejected).';
    END IF;
    IF NEW.expires_at > v_grant.valid_until THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Credential expiry may not exceed the parent grant validity.';
    END IF;
    IF NOT ((NEW.credential_usage = 'personal_api' AND v_type = 'human')
            OR (NEW.credential_usage IN ('integration', 'provisioning') AND v_type = 'service_account')
            OR (NEW.credential_usage = 'automation')) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('credential_usage %s is not valid for a %s principal.', NEW.credential_usage, v_type);
    END IF;
    IF v_type = 'automation' AND NEW.credential_usage <> 'automation' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Automation principals may only hold automation-usage credentials.';
    END IF;
    IF NEW.status <> 'active' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Credentials are issued active.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.principal_credentials
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_identity.principal_credentials
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_credentials_validate();
CREATE TRIGGER trg_16_revoked_at BEFORE INSERT OR UPDATE ON cob3_identity.principal_credentials
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_maintain_revoked_at();
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_identity.principal_credentials
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'status', 'revoked_at', 'last_used_at', 'credential_name');
CREATE TRIGGER trg_60_gauge AFTER INSERT ON cob3_identity.principal_credentials
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_gauge_credentials();

-- Bindings are created atomically with their credential (same transaction)
-- and are append-only afterwards (rotation creates a new credential).
CREATE FUNCTION cob3_identity.tg_credential_bindings_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_identity.principal_credentials c
                    WHERE c.tenant_id = NEW.tenant_id AND c.organization_id = NEW.organization_id
                      AND c.credential_id = NEW.credential_id AND c.created_at = pg_catalog.now()) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = 'Credential permission bindings must be created in the same transaction as the credential; rotate to change the subset.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_validate BEFORE INSERT ON cob3_identity.credential_permission_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_credential_bindings_validate();

-- ---------------------------------------------------------------------------
-- action_approvals
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_action_approvals_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.decided_by_principal_id IS NOT NULL OR NEW.consumed_at IS NOT NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Approvals are created pending.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM cob3_identity.authorization_grants g
                        WHERE g.tenant_id = NEW.tenant_id AND g.organization_id = NEW.organization_id
                          AND g.authorization_grant_id = NEW.authorization_grant_id AND g.status = 'active') THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Approvals can be requested only under an active grant.';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.status = 'pending' AND NEW.status IN ('approved', 'rejected') THEN
        IF OLD.expires_at <= pg_catalog.now() THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Approval request has expired.';
        END IF;
        NEW.decided_at := COALESCE(NEW.decided_at, pg_catalog.now());
        IF cob3_identity.principal_type_of(NEW.tenant_id, NEW.decided_by_principal_id) IS DISTINCT FROM 'human' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Only a human principal can decide an action approval.';
        END IF;
    END IF;
    IF OLD.status = 'approved' AND NEW.status = 'consumed' THEN
        IF OLD.expires_at <= pg_catalog.now() THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Approval has expired and cannot be consumed.';
        END IF;
        NEW.consumed_at := pg_catalog.now();
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.action_approvals
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>pending', 'pending>approved', 'pending>rejected', 'pending>expired', 'approved>consumed', 'approved>expired');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_identity.action_approvals
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_action_approvals_validate();
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_identity.action_approvals
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'status', 'decided_by_principal_id', 'decided_at', 'consumed_at');

-- ---------------------------------------------------------------------------
-- Federation
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_identity_providers_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM cob3_tenant.assert_feature_enabled(NEW.tenant_id, 'sso.enabled');
        RETURN NEW;
    END IF;
    IF (NEW.issuer, NEW.protocol) IS DISTINCT FROM (OLD.issuer, OLD.protocol)
       AND (EXISTS (SELECT 1 FROM cob3_identity.external_identities e WHERE e.tenant_id = OLD.tenant_id AND e.identity_provider_id = OLD.identity_provider_id)
            OR EXISTS (SELECT 1 FROM cob3_identity.external_groups g WHERE g.tenant_id = OLD.tenant_id AND g.identity_provider_id = OLD.identity_provider_id)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = 'Issuer and protocol are immutable once external identities or groups exist; re-enroll instead.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.identity_providers
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', '>disabled', 'active>disabled', 'disabled>active');
CREATE TRIGGER trg_15_guard BEFORE INSERT OR UPDATE ON cob3_identity.identity_providers
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_identity_providers_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.identity_providers
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('provider_code');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.external_identities
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', '>disabled', 'active>disabled', 'disabled>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.external_identities
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'identity_provider_id', 'subject');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.external_groups
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', '>disabled', 'active>disabled', 'disabled>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.external_groups
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('identity_provider_id', 'provider_group_id');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.group_team_mappings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', '>disabled', 'active>disabled', 'disabled>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.group_team_mappings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('external_group_id', 'team_id');

-- ---------------------------------------------------------------------------
-- auth_sessions
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_auth_sessions_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_principal cob3_identity.principals%ROWTYPE;
    v_grant     cob3_identity.authorization_grants%ROWTYPE;
    v_cred      cob3_identity.principal_credentials%ROWTYPE;
    v_protocol  text;
    v_ext_ok    boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
            RAISE EXCEPTION USING ERRCODE = 'SKIMM', MESSAGE = 'Session revocation is terminal.';
        END IF;
        RETURN NEW;
    END IF;
    SELECT p.* INTO v_principal FROM cob3_identity.principals p
     WHERE p.tenant_id = NEW.tenant_id AND p.principal_id = NEW.principal_id;
    NEW.auth_version_at_issue := v_principal.auth_version;
    IF NEW.revoked_at IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Sessions are created unrevoked.';
    END IF;
    IF NEW.session_kind = 'interactive' AND v_principal.principal_type <> 'human' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Interactive sessions are for human principals only.';
    END IF;
    IF NEW.session_kind = 'noninteractive' THEN
        SELECT g.* INTO v_grant FROM cob3_identity.authorization_grants g
         WHERE g.tenant_id = NEW.tenant_id AND g.organization_id = NEW.organization_id
           AND g.authorization_grant_id = NEW.authorization_grant_id;
        IF v_grant.status <> 'active' OR NEW.expires_at > v_grant.valid_until THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = 'Noninteractive sessions require an active grant and may not outlive it.';
        END IF;
    END IF;
    IF NEW.authentication_method = 'api_key' THEN
        SELECT c.* INTO v_cred FROM cob3_identity.principal_credentials c
         WHERE c.tenant_id = NEW.tenant_id AND c.credential_id = NEW.credential_id;
        IF v_cred.status <> 'active' OR NEW.expires_at > v_cred.expires_at OR NEW.audience <> v_cred.audience THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = 'An API-key session must preserve the credential audience and may not outlive the credential.';
        END IF;
    ELSE
        SELECT ip.protocol, (e.status = 'active' AND ip.status = 'active')
          INTO v_protocol, v_ext_ok
          FROM cob3_identity.external_identities e
          JOIN cob3_identity.identity_providers ip
            ON ip.tenant_id = e.tenant_id AND ip.identity_provider_id = e.identity_provider_id
         WHERE e.tenant_id = NEW.tenant_id AND e.external_identity_id = NEW.external_identity_id;
        IF NOT COALESCE(v_ext_ok, false) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'External identity and its provider must be active.';
        END IF;
        IF NOT ((NEW.authentication_method = 'oidc' AND v_protocol = 'oidc')
                OR (NEW.authentication_method = 'saml' AND v_protocol = 'saml')
                OR (NEW.authentication_method = 'workload_identity' AND v_protocol = 'oidc')) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Authentication method does not match the identity provider protocol.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_identity.auth_sessions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_auth_sessions_validate();
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_identity.auth_sessions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'revoked_at', 'last_seen_at');
