-- =============================================================================
-- 60  COMMON COLUMN RULES, GENERIC HELPERS AND TABLE TRIGGERS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Uniform common-column rules (same contract as foundation 40_*), plus
-- updated_at >= created_at. Append-only tables additionally get
-- trg_05_append_only and <table>_append_only_ck.
-- ---------------------------------------------------------------------------
FOREACH _m_table IN ARRAY _m_tables LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format(
        'ALTER TABLE %1$I.%2$I'
        ' ADD CONSTRAINT %3$I CHECK (jsonb_typeof(metadata) = ''object''),'
        ' ADD CONSTRAINT %4$I CHECK (NOT (metadata ?| ARRAY[''password'', ''secret'', ''client_secret'', ''private_key'', ''api_key'', ''access_token'', ''refresh_token'', ''token''])),'
        ' ADD CONSTRAINT %5$I CHECK (row_version > 0),'
        ' ADD CONSTRAINT %6$I CHECK (created_by ~ %9$L),'
        ' ADD CONSTRAINT %7$I CHECK (updated_by ~ %9$L),'
        ' ADD CONSTRAINT %8$I CHECK (updated_at >= created_at)',
        _m_schema, _m_name,
        _m_name || '_metadata_object_ck', _m_name || '_metadata_no_secrets_ck', _m_name || '_row_version_positive_ck',
        _m_name || '_created_by_actor_ck', _m_name || '_updated_by_actor_ck', _m_name || '_updated_after_created_ck',
        '^(principal:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|system:[a-z0-9][a-z0-9_.:-]{0,200})$');
    EXECUTE pg_catalog.format(
        'CREATE TRIGGER trg_90_stamp_row BEFORE INSERT OR UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_stamp_row()',
        _m_schema, _m_name);
    EXECUTE pg_catalog.format(
        'CREATE TRIGGER trg_00_block_truncate BEFORE TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION cob3_identity.tg_block_truncate()',
        _m_schema, _m_name);
END LOOP;

FOREACH _m_table IN ARRAY _m_append_only LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format(
        'ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (row_version = 1 AND updated_at = created_at AND updated_by = created_by)',
        _m_schema, _m_name, _m_name || '_append_only_ck');
    EXECUTE pg_catalog.format(
        'CREATE TRIGGER trg_05_append_only BEFORE UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_append_only()',
        _m_schema, _m_name);
END LOOP;

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.is_valid_timezone(p_timezone text)
    RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT p_timezone IS NOT NULL AND EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names z WHERE z.name = p_timezone)
$fn$;

-- Tree acyclicity within (tenant_id, organization_id). TG_ARGV[0] = id column,
-- TG_ARGV[1] = parent column. Serialized per table/tenant/organization with an
-- advisory lock; the walk then reads a fresh READ COMMITTED snapshot.
CREATE FUNCTION cob3_identity.tg_tree_no_cycle()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_new    jsonb := pg_catalog.to_jsonb(NEW);
    v_id     uuid  := (v_new ->> TG_ARGV[0])::uuid;
    v_parent uuid  := (v_new ->> TG_ARGV[1])::uuid;
    v_cycle  boolean;
BEGIN
    IF v_parent IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND v_parent IS NOT DISTINCT FROM (pg_catalog.to_jsonb(OLD) ->> TG_ARGV[1])::uuid THEN
        RETURN NEW;
    END IF;
    PERFORM cob3_identity.assert_isolation_safe();
    PERFORM cob3_identity.xact_lock(TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, NEW.tenant_id::text || ':' || NEW.organization_id::text);
    EXECUTE pg_catalog.format(
        'WITH RECURSIVE up(node, depth) AS ('
        '  SELECT $1::uuid, 0'
        '  UNION ALL'
        '  SELECT t.%2$I, up.depth + 1 FROM %3$I.%4$I t JOIN up ON t.%1$I = up.node'
        '   WHERE t.tenant_id = $2 AND t.organization_id = $3 AND t.%2$I IS NOT NULL AND up.depth < 100000)'
        ' SELECT EXISTS (SELECT 1 FROM up WHERE up.node = $4)',
        TG_ARGV[0], TG_ARGV[1], TG_TABLE_SCHEMA, TG_TABLE_NAME)
      INTO v_cycle USING v_parent, NEW.tenant_id, NEW.organization_id, v_id;
    IF v_cycle THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I: %s would create a hierarchy cycle.', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[1]);
    END IF;
    RETURN NEW;
END
$fn$;

-- Scan verdicts and similar lifecycle steps are system-only: allowed for a
-- worker scope or a trusted system context, never for an end-user request.
CREATE FUNCTION cob3_identity.ctx_is_system_writer()
    RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT cob3_identity.ctx_principal_id() IS NULL
       AND (cob3_identity.ctx_is_worker() OR cob3_identity.ctx_actor() LIKE 'system:%' OR cob3_identity.ctx_actor() IS NULL)
$fn$;

-- ===========================================================================
-- cob3_identity: principal_emails, email_verification_challenges, user_profiles
-- ===========================================================================
CREATE FUNCTION cob3_identity.tg_principal_emails_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF cob3_identity.principal_type_of(NEW.tenant_id, NEW.principal_id) IS DISTINCT FROM 'human' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'principal_emails belong to human principals only.';
        END IF;
    ELSIF OLD.verified_at IS NOT NULL
          AND (NEW.verified_at, NEW.verification_source) IS DISTINCT FROM (OLD.verified_at, OLD.verification_source) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM', MESSAGE = 'Verification evidence of an address is immutable; add a new address instead.';
    END IF;
    -- ASCII addresses must carry exactly the canonical key; non-ASCII domains
    -- carry the backend's IDNA form.
    IF NEW.email_address ~ '^[ -~]+$' AND NEW.email_key IS DISTINCT FROM cob3_identity.email_key(NEW.email_address) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'email_key must be the canonical key of email_address (trimmed, lower-case domain).';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_identity.principal_emails
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_identity.principal_emails
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_principal_emails_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.principal_emails
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'email_address', 'email_key');

CREATE FUNCTION cob3_identity.tg_principal_emails_sync()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    PERFORM cob3_identity.sync_profile_email(NEW.tenant_id, NEW.principal_id);
    RETURN NULL;
END
$fn$;
CREATE TRIGGER trg_80_profile_projection AFTER INSERT OR UPDATE ON cob3_identity.principal_emails
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_principal_emails_sync();

CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.email_verification_challenges
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_email_id', 'token_digest', 'expires_at');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_identity.email_verification_challenges
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('attempt_count');

CREATE FUNCTION cob3_identity.tg_email_challenges_terminal()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF (OLD.consumed_at IS NOT NULL OR OLD.revoked_at IS NOT NULL)
       AND (NEW.consumed_at, NEW.revoked_at) IS DISTINCT FROM (OLD.consumed_at, OLD.revoked_at) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'A consumed or revoked verification challenge is final.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_terminal BEFORE UPDATE ON cob3_identity.email_verification_challenges
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_email_challenges_terminal();

-- Avatar: ready principal-scope media owned by this profile principal (6.1).
CREATE FUNCTION cob3_identity.tg_user_profiles_avatar_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.avatar_media_id IS NULL
       OR (TG_OP = 'UPDATE' AND NEW.avatar_media_id IS NOT DISTINCT FROM OLD.avatar_media_id) THEN
        RETURN NEW;
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM cob3_settings.media_objects m
          JOIN cob3_settings.setting_scopes s ON s.tenant_id = m.tenant_id AND s.setting_scope_id = m.setting_scope_id
         WHERE m.tenant_id = NEW.tenant_id AND m.media_object_id = NEW.avatar_media_id
           AND m.status = 'ready' AND s.scope_type = 'principal' AND s.principal_id = NEW.principal_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'avatar_media_id must reference ready principal-scope media owned by this profile principal.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_16_avatar_validate BEFORE INSERT OR UPDATE OF avatar_media_id ON cob3_identity.user_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_user_profiles_avatar_validate();

-- ===========================================================================
-- cob3_settings
-- ===========================================================================

-- Light, deterministic subset of JSON Schema checked in the database (type,
-- enum, minimum/maximum, minLength/maxLength, pattern, maxItems). Full schema
-- validation remains an application-pinned validator. Returns NULL when valid.
CREATE FUNCTION cob3_settings.value_violation(p_value_type text, p_schema jsonb, p_value jsonb)
    RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_type    text := pg_catalog.jsonb_typeof(p_value);
    v_type_ok boolean;
BEGIN
    IF p_value IS NULL OR v_type = 'null' THEN
        RETURN 'value is null';
    END IF;
    v_type_ok := CASE p_value_type
                     WHEN 'boolean' THEN v_type = 'boolean'
                     WHEN 'integer' THEN v_type = 'number' AND p_value::text ~ '^-?[0-9]+$'
                     WHEN 'decimal' THEN v_type = 'number'
                     WHEN 'string'  THEN v_type = 'string'
                     WHEN 'array'   THEN v_type = 'array'
                     WHEN 'object'  THEN v_type = 'object'
                     ELSE false
                 END;
    IF NOT v_type_ok THEN
        RETURN pg_catalog.format('expected %s, got %s', p_value_type, v_type);
    END IF;
    IF p_schema ? 'enum' AND NOT (p_schema -> 'enum') @> pg_catalog.jsonb_build_array(p_value) THEN
        RETURN 'value not in enum';
    END IF;
    IF v_type = 'number' THEN
        IF p_schema ? 'minimum' AND (p_value #>> '{}')::numeric < (p_schema ->> 'minimum')::numeric THEN
            RETURN 'value below minimum';
        END IF;
        IF p_schema ? 'maximum' AND (p_value #>> '{}')::numeric > (p_schema ->> 'maximum')::numeric THEN
            RETURN 'value above maximum';
        END IF;
    ELSIF v_type = 'string' THEN
        IF p_schema ? 'maxLength' AND pg_catalog.length(p_value #>> '{}') > (p_schema ->> 'maxLength')::integer THEN
            RETURN 'string too long';
        END IF;
        IF p_schema ? 'minLength' AND pg_catalog.length(p_value #>> '{}') < (p_schema ->> 'minLength')::integer THEN
            RETURN 'string too short';
        END IF;
        IF p_schema ? 'pattern' AND (p_value #>> '{}') !~ (p_schema ->> 'pattern') THEN
            RETURN 'string does not match pattern';
        END IF;
    ELSIF v_type = 'array' THEN
        IF p_schema ? 'maxItems' AND pg_catalog.jsonb_array_length(p_value) > (p_schema ->> 'maxItems')::integer THEN
            RETURN 'too many items';
        END IF;
    END IF;
    RETURN NULL;
END
$fn$;

CREATE FUNCTION cob3_settings.tg_setting_definitions_validate()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_err text := cob3_settings.value_violation(NEW.value_type, NEW.validation_schema, NEW.default_value);
BEGIN
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Default of setting %s %s violates its own schema: %s.', NEW.setting_key, NEW.definition_version, v_err);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_settings.setting_definitions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', '>retired', 'active>retired');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_settings.setting_definitions
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_setting_definitions_validate();
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_settings.setting_definitions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'status');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_settings.setting_scopes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>archived', 'archived>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_settings.setting_scopes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('scope_type', 'principal_id', 'team_id', 'project_id');

-- Two-sided scope consistency for context children: tenant-qualified FK plus
-- exact organization equality including NULL; TG_ARGV = allowed scope types.
CREATE FUNCTION cob3_settings.tg_scope_consistency()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    s cob3_settings.setting_scopes%ROWTYPE;
BEGIN
    SELECT x.* INTO s FROM cob3_settings.setting_scopes x
     WHERE x.tenant_id = NEW.tenant_id AND x.setting_scope_id = NEW.setting_scope_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('%I.%I: unknown setting scope.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;
    IF s.organization_id IS DISTINCT FROM NEW.organization_id THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I: organization_id must equal the organization of its setting scope (including NULL).', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;
    IF NOT (s.scope_type = ANY (TG_ARGV)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I does not accept %s scopes.', TG_TABLE_SCHEMA, TG_TABLE_NAME, s.scope_type);
    END IF;
    IF TG_OP = 'INSERT' AND s.status <> 'active' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Setting scope is archived.';
    END IF;
    RETURN NEW;
END
$fn$;

CREATE TRIGGER trg_12_scope BEFORE INSERT OR UPDATE ON cob3_settings.setting_values
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_scope_consistency('tenant', 'organization', 'team', 'principal', 'principal_org', 'project');
CREATE TRIGGER trg_12_scope BEFORE INSERT ON cob3_settings.setting_change_events
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_scope_consistency('tenant', 'organization', 'team', 'principal', 'principal_org', 'project');
-- v1 media: profile/branding owners only (not project/principal_org).
CREATE TRIGGER trg_12_scope BEFORE INSERT OR UPDATE ON cob3_settings.media_objects
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_scope_consistency('tenant', 'organization', 'team', 'principal');
CREATE TRIGGER trg_12_scope BEFORE INSERT OR UPDATE ON cob3_settings.branding_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_scope_consistency('tenant', 'organization', 'team');
CREATE TRIGGER trg_12_scope BEFORE INSERT OR UPDATE ON cob3_settings.notification_endpoints
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_scope_consistency('tenant', 'organization', 'team', 'principal');
CREATE TRIGGER trg_12_scope BEFORE INSERT OR UPDATE ON cob3_settings.notification_preferences
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_scope_consistency('tenant', 'organization', 'team', 'principal', 'principal_org');
CREATE TRIGGER trg_12_scope BEFORE INSERT OR UPDATE ON cob3_settings.integration_configurations
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_scope_consistency('tenant', 'organization', 'team');
FOREACH _m_name IN ARRAY ARRAY['setting_values', 'media_objects', 'branding_profiles', 'notification_endpoints',
                               'notification_preferences', 'integration_configurations'] LOOP
    EXECUTE pg_catalog.format(
        'CREATE TRIGGER trg_20_scope_immutable BEFORE UPDATE ON cob3_settings.%I FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns(''setting_scope_id'')',
        _m_name);
END LOOP;

-- setting_values: definition/scope/type/lock rules (design 7.2).
CREATE FUNCTION cob3_settings.tg_setting_values_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    d   cob3_settings.setting_definitions%ROWTYPE;
    s   cob3_settings.setting_scopes%ROWTYPE;
    v_err text;
BEGIN
    SELECT x.* INTO d FROM cob3_settings.setting_definitions x WHERE x.setting_definition_id = NEW.setting_definition_id;
    SELECT x.* INTO s FROM cob3_settings.setting_scopes x WHERE x.tenant_id = NEW.tenant_id AND x.setting_scope_id = NEW.setting_scope_id;
    IF TG_OP = 'UPDATE' AND NEW.setting_definition_id <> OLD.setting_definition_id THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM', MESSAGE = 'setting_values.setting_definition_id is immutable.';
    END IF;
    IF d.status <> 'active' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Setting %s version %s is not active.', d.setting_key, d.definition_version);
    END IF;
    IF NOT (s.scope_type = ANY (d.allowed_scopes)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Setting %s cannot be set at %s scope.', d.setting_key, s.scope_type);
    END IF;
    v_err := cob3_settings.value_violation(d.value_type, d.validation_schema, NEW.value);
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Invalid value for %s: %s.', d.setting_key, v_err);
    END IF;
    IF NEW.is_locked AND (NOT d.lockable OR s.scope_type NOT IN ('tenant', 'organization')) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Setting %s cannot be locked at %s scope.', d.setting_key, s.scope_type);
    END IF;
    -- A parent lock stops new lower-level overrides (existing ones are ignored by the resolver).
    IF s.scope_type <> 'tenant' AND EXISTS (
            SELECT 1 FROM cob3_settings.setting_values v
              JOIN cob3_settings.setting_scopes ps ON ps.tenant_id = v.tenant_id AND ps.setting_scope_id = v.setting_scope_id
             WHERE v.tenant_id = NEW.tenant_id AND v.setting_definition_id = NEW.setting_definition_id
               AND v.is_locked AND ps.scope_type = 'tenant') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Setting %s is locked at tenant scope.', d.setting_key);
    END IF;
    IF s.scope_type NOT IN ('tenant', 'organization') AND s.organization_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM cob3_settings.setting_values v
              JOIN cob3_settings.setting_scopes ps ON ps.tenant_id = v.tenant_id AND ps.setting_scope_id = v.setting_scope_id
             WHERE v.tenant_id = NEW.tenant_id AND v.setting_definition_id = NEW.setting_definition_id
               AND v.is_locked AND ps.scope_type = 'organization' AND ps.organization_id = s.organization_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Setting %s is locked at organization scope.', d.setting_key);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_settings.setting_values
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_setting_values_validate();

-- Every set/reset/lock/unlock writes one append-only change event.
CREATE FUNCTION cob3_settings.tg_setting_values_history()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_row     cob3_settings.setting_values%ROWTYPE := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    v_key     text;
    v_op      text;
    v_request uuid := COALESCE(cob3_identity.ctx_uuid('cob3.request_id'), gen_random_uuid());
    v_actor   text := COALESCE(cob3_identity.ctx_actor(), v_row.updated_by);
BEGIN
    SELECT d.setting_key INTO v_key FROM cob3_settings.setting_definitions d WHERE d.setting_definition_id = v_row.setting_definition_id;
    v_op := CASE
              WHEN TG_OP = 'DELETE' THEN 'reset'
              WHEN TG_OP = 'INSERT' THEN CASE WHEN NEW.is_locked THEN 'lock' ELSE 'set' END
              WHEN NEW.is_locked AND NOT OLD.is_locked THEN 'lock'
              WHEN OLD.is_locked AND NOT NEW.is_locked THEN 'unlock'
              ELSE 'set'
            END;
    IF TG_OP = 'UPDATE' AND v_op = 'set' AND NEW.value IS NOT DISTINCT FROM OLD.value THEN
        RETURN NULL;
    END IF;
    INSERT INTO cob3_settings.setting_change_events
           (tenant_id, organization_id, setting_scope_id, setting_key, operation, old_value, new_value, request_id,
            occurred_at, created_by, updated_by)
    VALUES (v_row.tenant_id, v_row.organization_id, v_row.setting_scope_id, v_key, v_op,
            CASE WHEN TG_OP <> 'INSERT' THEN OLD.value END,
            CASE WHEN TG_OP <> 'DELETE' THEN NEW.value END,
            v_request, pg_catalog.now(), v_actor, v_actor);
    RETURN NULL;
END
$fn$;
CREATE TRIGGER trg_80_history AFTER INSERT OR UPDATE OR DELETE ON cob3_settings.setting_values
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_setting_values_history();

-- media_objects: immutable location/content, scan verdicts system-only.
CREATE FUNCTION cob3_settings.tg_media_lifecycle()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF ((TG_OP = 'INSERT' AND NEW.status <> 'quarantined')
        OR (TG_OP = 'UPDATE' AND OLD.status = 'quarantined' AND NEW.status IN ('ready', 'rejected')))
       AND NOT cob3_identity.ctx_is_system_writer() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA',
            MESSAGE = pg_catalog.format('%I.%I: uploads start quarantined; only the trusted scanner sets ready/rejected.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_settings.media_objects
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>quarantined', '>ready', 'quarantined>ready', 'quarantined>rejected', 'ready>deleted', 'rejected>deleted', 'quarantined>deleted');
CREATE TRIGGER trg_11_lifecycle BEFORE INSERT OR UPDATE OF status ON cob3_settings.media_objects
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_media_lifecycle();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_settings.media_objects
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('uploaded_by_principal_id', 'storage_provider', 'storage_container',
        'object_key', 'object_version', 'original_filename', 'mime_type', 'size_bytes', 'sha256', 'width_px', 'height_px');

-- branding_profiles: ready same-scope media; theme-token allowlist.
CREATE FUNCTION cob3_settings.tg_branding_profiles_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_bad text;
BEGIN
    IF EXISTS (SELECT 1 FROM cob3_settings.media_objects m
                WHERE m.tenant_id = NEW.tenant_id AND m.media_object_id IN (NEW.logo_media_id, NEW.favicon_media_id)
                  AND m.status <> 'ready') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Branding media must be ready (scanned and approved).';
    END IF;
    SELECT pg_catalog.string_agg(t.key, ', ') INTO v_bad
      FROM pg_catalog.jsonb_each(NEW.theme_tokens) AS t
     WHERE t.key !~ '^[a-z][a-z0-9_.-]{0,63}$'
        OR pg_catalog.jsonb_typeof(t.value) NOT IN ('string', 'number')
        OR (t.value #>> '{}') ~* '(;|\{|\}|<|>|url\(|expression\(|javascript:|@import)'
        OR pg_catalog.length(t.value #>> '{}') > 200;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Rejected theme tokens (allowlisted names and plain scalar values only): ' || v_bad;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_settings.branding_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_branding_profiles_validate();

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_settings.contact_addresses
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_settings.contact_addresses
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('team_id', 'purpose', 'email_address', 'email_key');

-- notification_endpoints: owner/scope compatibility (design 5).
CREATE FUNCTION cob3_settings.tg_notification_endpoints_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    s cob3_settings.setting_scopes%ROWTYPE;
    c cob3_settings.contact_addresses%ROWTYPE;
BEGIN
    SELECT x.* INTO s FROM cob3_settings.setting_scopes x WHERE x.tenant_id = NEW.tenant_id AND x.setting_scope_id = NEW.setting_scope_id;
    IF NEW.principal_email_id IS NOT NULL THEN
        IF s.scope_type <> 'principal' OR NOT EXISTS (
               SELECT 1 FROM cob3_identity.principal_emails e
                WHERE e.tenant_id = NEW.tenant_id AND e.principal_email_id = NEW.principal_email_id
                  AND e.principal_id = s.principal_id) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A personal email endpoint must use the scope principal''s own address.';
        END IF;
    END IF;
    IF NEW.contact_address_id IS NOT NULL THEN
        SELECT x.* INTO c FROM cob3_settings.contact_addresses x
         WHERE x.tenant_id = NEW.tenant_id AND x.contact_address_id = NEW.contact_address_id;
        IF s.scope_type NOT IN ('organization', 'team') OR c.organization_id <> s.organization_id
           OR c.team_id IS DISTINCT FROM s.team_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A mailbox endpoint must belong to the contact address''s own organization/team scope.';
        END IF;
    END IF;
    IF NEW.endpoint_type = 'in_app'
       AND (s.scope_type <> 'principal' OR cob3_identity.principal_type_of(NEW.tenant_id, s.principal_id) IS DISTINCT FROM 'human') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'In-app endpoints require a human principal scope.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_settings.notification_endpoints
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>disabled', 'disabled>active');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_settings.notification_endpoints
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_notification_endpoints_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_settings.notification_endpoints
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('endpoint_type', 'principal_email_id', 'contact_address_id', 'webhook_url');

-- notification_preferences: timezone, endpoint compatibility, mandatory security.
CREATE FUNCTION cob3_settings.tg_notification_preferences_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    s  cob3_settings.setting_scopes%ROWTYPE;
    es cob3_settings.setting_scopes%ROWTYPE;
    e  cob3_settings.notification_endpoints%ROWTYPE;
BEGIN
    IF NOT cob3_identity.is_valid_timezone(NEW.timezone) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown IANA timezone %L.', NEW.timezone);
    END IF;
    SELECT x.* INTO s FROM cob3_settings.setting_scopes x WHERE x.tenant_id = NEW.tenant_id AND x.setting_scope_id = NEW.setting_scope_id;
    IF NEW.category_code = 'security' AND NOT NEW.enabled AND s.scope_type IN ('team', 'principal', 'principal_org') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Mandatory security notifications cannot be disabled by a lower-level preference.';
    END IF;
    IF NEW.destination_endpoint_id IS NOT NULL THEN
        SELECT x.* INTO e FROM cob3_settings.notification_endpoints x
         WHERE x.tenant_id = NEW.tenant_id AND x.notification_endpoint_id = NEW.destination_endpoint_id;
        SELECT x.* INTO es FROM cob3_settings.setting_scopes x WHERE x.tenant_id = e.tenant_id AND x.setting_scope_id = e.setting_scope_id;
        IF e.endpoint_type <> NEW.channel_type THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Destination endpoint type must match the preference channel.';
        END IF;
        -- Same owner scope, or a principal_org override using that principal's own endpoint.
        IF NOT (es.setting_scope_id = s.setting_scope_id
                OR (s.scope_type = 'principal_org' AND es.scope_type = 'principal' AND es.principal_id = s.principal_id)) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Destination endpoint belongs to another owner scope.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_settings.notification_preferences
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_notification_preferences_validate();

-- integration_configurations: SSO only at tenant scope with a matching provider.
CREATE FUNCTION cob3_settings.tg_integration_configurations_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_scope_type text;
    v_protocol   text;
BEGIN
    SELECT x.scope_type INTO v_scope_type FROM cob3_settings.setting_scopes x
     WHERE x.tenant_id = NEW.tenant_id AND x.setting_scope_id = NEW.setting_scope_id;
    IF NEW.adapter_type IN ('oidc', 'saml') THEN
        SELECT p.protocol INTO v_protocol FROM cob3_identity.identity_providers p
         WHERE p.tenant_id = NEW.tenant_id AND p.identity_provider_id = NEW.identity_provider_id;
        IF v_scope_type <> 'tenant' OR v_protocol IS DISTINCT FROM NEW.adapter_type THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = 'SSO configuration requires tenant scope and an Identity provider with the same protocol.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_settings.integration_configurations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>draft', 'draft>active', 'draft>retired', 'active>retired');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_settings.integration_configurations
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_integration_configurations_validate();
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_settings.integration_configurations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status', 'last_verified_at');
CREATE TRIGGER trg_21_immutable BEFORE UPDATE ON cob3_settings.integration_configurations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('integration_code', 'configuration_version', 'adapter_type');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_settings.automation_policies
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>draft', 'draft>active', 'draft>retired', 'active>retired');
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_settings.automation_policies
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status');
CREATE TRIGGER trg_21_immutable BEFORE UPDATE ON cob3_settings.automation_policies
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('policy_version');

-- ===========================================================================
-- cob3_catalog
-- ===========================================================================
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_catalog.asset_types
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>retired', 'retired>active');
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_catalog.asset_types
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'status', 'name');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_catalog.domains
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>archived', 'archived>active');
CREATE TRIGGER trg_15_no_cycle BEFORE INSERT OR UPDATE OF parent_domain_id ON cob3_catalog.domains
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_tree_no_cycle('domain_id', 'parent_domain_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_catalog.domains
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('domain_code');

CREATE FUNCTION cob3_catalog.type_of_asset(p_tenant_id uuid, p_asset_id uuid)
    RETURNS cob3_catalog.asset_types
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT t.* FROM cob3_catalog.assets a JOIN cob3_catalog.asset_types t ON t.asset_type_id = a.asset_type_id
     WHERE a.tenant_id = p_tenant_id AND a.asset_id = p_asset_id
$fn$;

-- Raise unless the asset exists in the same organization and has the given type.
CREATE FUNCTION cob3_catalog.assert_asset_type(p_tenant_id uuid, p_organization_id uuid, p_asset_id uuid, p_type_code text)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF p_asset_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_catalog.assets a JOIN cob3_catalog.asset_types t ON t.asset_type_id = a.asset_type_id
            WHERE a.tenant_id = p_tenant_id AND a.organization_id = p_organization_id AND a.asset_id = p_asset_id
              AND t.type_code = p_type_code) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Asset %s is not a %s asset of this organization.', p_asset_id, p_type_code);
    END IF;
END
$fn$;

CREATE FUNCTION cob3_catalog.tg_assets_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    t cob3_catalog.asset_types%ROWTYPE;
BEGIN
    SELECT x.* INTO t FROM cob3_catalog.asset_types x WHERE x.asset_type_id = NEW.asset_type_id;
    IF TG_OP = 'INSERT' AND t.status <> 'active' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Asset type %s is retired.', t.type_code);
    END IF;
    -- Workspace and AI resources are private by default: explicit ACL only in v1.
    IF t.owning_module IN ('workspace', 'ai') AND NEW.authorization_mode <> 'explicit' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%s assets must use authorization_mode = explicit.', t.type_code);
    END IF;
    IF NEW.domain_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.domain_id IS DISTINCT FROM OLD.domain_id)
       AND NOT EXISTS (SELECT 1 FROM cob3_catalog.domains d
                        WHERE d.tenant_id = NEW.tenant_id AND d.organization_id = NEW.organization_id
                          AND d.domain_id = NEW.domain_id AND d.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Asset domain must be an active domain of the same organization.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_catalog.assets
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>draft', '>active', 'draft>active', 'draft>deleted', 'active>archived', 'archived>active', 'archived>deleted');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_catalog.assets
    FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_assets_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_catalog.assets
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_type_id', 'asset_code');

-- Immutable metadata history: one version per tracked change (asset row lock
-- serializes allocation). Access-classification changes are also audited.
CREATE FUNCTION cob3_catalog.tg_assets_history()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_snapshot jsonb := pg_catalog.jsonb_build_object(
        'asset_type_id', NEW.asset_type_id, 'asset_code', NEW.asset_code, 'name', NEW.name,
        'description', NEW.description, 'domain_id', NEW.domain_id, 'authorization_mode', NEW.authorization_mode,
        'attributes', NEW.attributes, 'status', NEW.status);
    v_actor    text := COALESCE(cob3_identity.ctx_actor(), NEW.updated_by);
BEGIN
    IF TG_OP = 'UPDATE' AND v_snapshot = pg_catalog.jsonb_build_object(
        'asset_type_id', OLD.asset_type_id, 'asset_code', OLD.asset_code, 'name', OLD.name,
        'description', OLD.description, 'domain_id', OLD.domain_id, 'authorization_mode', OLD.authorization_mode,
        'attributes', OLD.attributes, 'status', OLD.status) THEN
        RETURN NULL;
    END IF;
    INSERT INTO cob3_catalog.asset_metadata_versions
           (tenant_id, organization_id, asset_id, version_number, snapshot, change_reason, created_by, updated_by)
    SELECT NEW.tenant_id, NEW.organization_id, NEW.asset_id, COALESCE(pg_catalog.max(v.version_number), 0) + 1, v_snapshot,
           NULLIF(pg_catalog.btrim(pg_catalog.current_setting('cob3.change_reason', true)), ''), v_actor, v_actor
      FROM cob3_catalog.asset_metadata_versions v
     WHERE v.tenant_id = NEW.tenant_id AND v.organization_id = NEW.organization_id AND v.asset_id = NEW.asset_id;
    IF TG_OP = 'UPDATE' AND (NEW.authorization_mode, NEW.domain_id) IS DISTINCT FROM (OLD.authorization_mode, OLD.domain_id) THEN
        PERFORM cob3_identity.write_audit_event(
            NEW.tenant_id, NEW.organization_id, cob3_identity.ctx_principal_id(), v_actor,
            'catalog.asset_access_classification_changed', 'asset', NEW.asset_id, 'success', NULL,
            pg_catalog.jsonb_build_object('old_authorization_mode', OLD.authorization_mode, 'new_authorization_mode', NEW.authorization_mode,
                                          'old_domain_id', OLD.domain_id, 'new_domain_id', NEW.domain_id),
            NULL, NULL, NULL, cob3_identity.ctx_session_id(), cob3_identity.ctx_credential_id());
    END IF;
    RETURN NULL;
END
$fn$;
CREATE TRIGGER trg_80_history AFTER INSERT OR UPDATE ON cob3_catalog.assets
    FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_assets_history();

-- Commit-time completeness (deferred): active assets have a primary owner;
-- assets of types with a subtype table have their module row; active saved
-- artifacts have a current committed revision.
CREATE FUNCTION cob3_catalog.assert_asset_complete(p_tenant_id uuid, p_organization_id uuid, p_asset_id uuid)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    a      cob3_catalog.assets%ROWTYPE;
    t      cob3_catalog.asset_types%ROWTYPE;
    v_ok   boolean;
BEGIN
    SELECT x.* INTO a FROM cob3_catalog.assets x
     WHERE x.tenant_id = p_tenant_id AND x.organization_id = p_organization_id AND x.asset_id = p_asset_id;
    IF NOT FOUND OR a.status = 'deleted' THEN
        RETURN;
    END IF;
    SELECT x.* INTO t FROM cob3_catalog.asset_types x WHERE x.asset_type_id = a.asset_type_id;
    IF a.status = 'active' AND NOT EXISTS (
           SELECT 1 FROM cob3_catalog.asset_ownerships o
            WHERE o.tenant_id = a.tenant_id AND o.organization_id = a.organization_id AND o.asset_id = a.asset_id
              AND o.responsibility = 'owner' AND o.is_primary AND o.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Active asset %s (%s) requires an active primary owner.', a.asset_code, t.type_code);
    END IF;
    IF t.subtype_table IS NOT NULL THEN
        EXECUTE pg_catalog.format('SELECT EXISTS (SELECT 1 FROM %s x WHERE x.tenant_id = $1 AND x.organization_id = $2 AND x.asset_id = $3)',
                                  pg_catalog.to_regclass(t.subtype_table))
           INTO v_ok USING a.tenant_id, a.organization_id, a.asset_id;
        IF NOT v_ok THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Asset %s of type %s has no %s row at commit.', a.asset_code, t.type_code, t.subtype_table);
        END IF;
    END IF;
    IF t.type_code = 'saved_artifact' AND a.status = 'active' AND NOT EXISTS (
           SELECT 1 FROM cob3_workspace.artifacts w
            WHERE w.tenant_id = a.tenant_id AND w.organization_id = a.organization_id AND w.asset_id = a.asset_id
              AND w.current_revision_id IS NOT NULL) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Active artifact %s requires a current committed revision.', a.asset_code);
    END IF;
END
$fn$;

CREATE FUNCTION cob3_catalog.tg_asset_complete_deferred()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_row jsonb := pg_catalog.to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
BEGIN
    PERFORM cob3_catalog.assert_asset_complete((v_row ->> 'tenant_id')::uuid, (v_row ->> 'organization_id')::uuid,
                                               (v_row ->> 'asset_id')::uuid);
    RETURN NULL;
END
$fn$;
CREATE CONSTRAINT TRIGGER trg_95_complete AFTER INSERT OR UPDATE ON cob3_catalog.assets
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_asset_complete_deferred();
CREATE CONSTRAINT TRIGGER trg_95_complete AFTER UPDATE OR DELETE ON cob3_catalog.asset_ownerships
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_asset_complete_deferred();
CREATE CONSTRAINT TRIGGER trg_95_complete AFTER INSERT OR UPDATE ON cob3_workspace.artifacts
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_asset_complete_deferred();

-- asset_ownerships: user-managed Workspace resources need a human primary owner.
CREATE FUNCTION cob3_catalog.tg_asset_ownerships_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    t cob3_catalog.asset_types%ROWTYPE := cob3_catalog.type_of_asset(NEW.tenant_id, NEW.asset_id);
BEGIN
    IF NEW.is_primary AND t.owning_module = 'workspace'
       AND (NEW.principal_id IS NULL OR cob3_identity.principal_type_of(NEW.tenant_id, NEW.principal_id) <> 'human') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Workspace resources require a human primary owner.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_catalog.asset_ownerships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_catalog.asset_ownerships
    FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_asset_ownerships_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_catalog.asset_ownerships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'principal_id', 'team_id', 'responsibility');

CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_catalog.asset_external_identifiers
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_catalog.asset_locations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>retired');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_catalog.asset_locations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'location_kind', 'uri');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_catalog.asset_relationships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>retired');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_catalog.asset_relationships
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('source_asset_id', 'target_asset_id', 'relationship_type');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_catalog.tags
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>archived', 'archived>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_catalog.tags
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('tag_code', 'visibility', 'owner_principal_id');

CREATE FUNCTION cob3_catalog.tg_asset_tags_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    g cob3_catalog.tags%ROWTYPE;
BEGIN
    SELECT x.* INTO g FROM cob3_catalog.tags x WHERE x.tenant_id = NEW.tenant_id AND x.tag_id = NEW.tag_id;
    IF g.status <> 'active' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Tag is archived.';
    END IF;
    IF g.visibility = 'private' AND g.owner_principal_id <> NEW.applied_by_principal_id THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Only the owner may apply a private tag.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_catalog.asset_tags
    FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_asset_tags_validate();
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_catalog.asset_tags
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'confidence');

-- ===========================================================================
-- cob3_workspace
-- ===========================================================================
CREATE FUNCTION cob3_workspace.tg_projects_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    PERFORM cob3_catalog.assert_asset_type(NEW.tenant_id, NEW.organization_id, NEW.asset_id, 'workspace_project');
    IF NEW.project_kind = 'personal' THEN
        IF cob3_identity.principal_type_of(NEW.tenant_id, NEW.personal_owner_principal_id) <> 'human' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A personal project belongs to a human member.';
        END IF;
        -- At most one live personal project per principal and organization.
        PERFORM cob3_identity.assert_isolation_safe();
        PERFORM cob3_identity.xact_lock('workspace.personal_project',
                                        NEW.tenant_id::text || ':' || NEW.organization_id::text || ':' || NEW.personal_owner_principal_id::text);
        IF EXISTS (SELECT 1 FROM cob3_workspace.projects p
                     JOIN cob3_catalog.assets a ON a.tenant_id = p.tenant_id AND a.asset_id = p.asset_id
                    WHERE p.tenant_id = NEW.tenant_id AND p.organization_id = NEW.organization_id
                      AND p.personal_owner_principal_id = NEW.personal_owner_principal_id
                      AND p.project_id <> NEW.project_id AND a.status IN ('draft', 'active')) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'This member already has a live personal project in the organization.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_workspace.projects
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_projects_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.projects
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'project_kind', 'personal_owner_principal_id');
CREATE CONSTRAINT TRIGGER trg_95_complete AFTER INSERT ON cob3_workspace.projects
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_catalog.tg_asset_complete_deferred();

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_workspace.folders
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>archived', 'archived>active');
CREATE TRIGGER trg_15_no_cycle BEFORE INSERT OR UPDATE OF parent_folder_id ON cob3_workspace.folders
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_tree_no_cycle('folder_id', 'parent_folder_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.folders
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('project_id');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_workspace.file_objects
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>quarantined', '>ready', 'quarantined>ready', 'quarantined>rejected', 'ready>deleted', 'rejected>deleted', 'quarantined>deleted');
CREATE TRIGGER trg_11_lifecycle BEFORE INSERT OR UPDATE OF status ON cob3_workspace.file_objects
    FOR EACH ROW EXECUTE FUNCTION cob3_settings.tg_media_lifecycle();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.file_objects
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('uploaded_by_principal_id', 'storage_provider', 'storage_container',
        'object_key', 'object_version', 'filename', 'mime_type', 'size_bytes', 'sha256');

CREATE FUNCTION cob3_workspace.tg_artifacts_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM cob3_catalog.assert_asset_type(NEW.tenant_id, NEW.organization_id, NEW.asset_id, 'saved_artifact');
    END IF;
    IF NEW.source_thread_asset_id IS NOT NULL
       AND (TG_OP = 'INSERT' OR NEW.source_thread_asset_id IS DISTINCT FROM OLD.source_thread_asset_id) THEN
        PERFORM cob3_catalog.assert_asset_type(NEW.tenant_id, NEW.organization_id, NEW.source_thread_asset_id, 'conversation');
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_workspace.artifacts
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_artifacts_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.artifacts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'project_id', 'created_via', 'source_run_reference');

-- artifact_revisions: serialized sequence, ready file, same-asset location.
CREATE FUNCTION cob3_workspace.tg_artifact_revisions_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_asset uuid;
    v_next  bigint;
BEGIN
    -- Lock the artifact: revision allocation and head advance are serialized.
    SELECT a.asset_id INTO v_asset FROM cob3_workspace.artifacts a
     WHERE a.tenant_id = NEW.tenant_id AND a.organization_id = NEW.organization_id AND a.artifact_id = NEW.artifact_id
       FOR UPDATE;
    SELECT COALESCE(pg_catalog.max(r.revision_number), 0) + 1 INTO v_next FROM cob3_workspace.artifact_revisions r
     WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id AND r.artifact_id = NEW.artifact_id;
    IF NEW.revision_number <> v_next THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Next revision of this artifact is %s, not %s (stale head).', v_next, NEW.revision_number);
    END IF;
    IF NEW.file_object_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_workspace.file_objects f
            WHERE f.tenant_id = NEW.tenant_id AND f.file_object_id = NEW.file_object_id AND f.status = 'ready') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Revision file must be a ready (scanned) file object.';
    END IF;
    IF NEW.external_location_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_catalog.asset_locations l
            WHERE l.tenant_id = NEW.tenant_id AND l.organization_id = NEW.organization_id
              AND l.asset_location_id = NEW.external_location_id AND l.asset_id = v_asset AND l.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'External location must be an active location of this artifact''s own asset.';
    END IF;
    IF cob3_identity.ctx_principal_id() IS NOT NULL AND NEW.author_principal_id <> cob3_identity.ctx_principal_id() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'author_principal_id must be the authenticated principal.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_workspace.artifact_revisions
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_artifact_revisions_validate();

CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.artifact_drafts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('artifact_id', 'principal_id');

-- Personal pointers belong to human members.
CREATE FUNCTION cob3_workspace.tg_personal_owner_human()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF cob3_identity.principal_type_of(NEW.tenant_id, NEW.principal_id) IS DISTINCT FROM 'human' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I rows belong to human members only.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;
    RETURN NEW;
END
$fn$;
FOREACH _m_name IN ARRAY ARRAY['bookmarks', 'recent_items', 'ui_sessions', 'artifact_drafts'] LOOP
    EXECUTE pg_catalog.format(
        'CREATE TRIGGER trg_14_human BEFORE INSERT ON cob3_workspace.%I FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_personal_owner_human()',
        _m_name);
END LOOP;
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.bookmarks
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.recent_items
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'target_asset_id', 'first_visited_at');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_workspace.recent_items
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('visit_count');

-- ui_sessions: bound to an interactive Identity session of the same principal/org.
CREATE FUNCTION cob3_workspace.tg_ui_sessions_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_identity.auth_sessions s
                    WHERE s.tenant_id = NEW.tenant_id AND s.session_id = NEW.auth_session_id
                      AND s.principal_id = NEW.principal_id AND s.organization_id = NEW.organization_id
                      AND s.session_kind = 'interactive') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'ui_sessions must reference an interactive Identity session of the same principal and organization.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_workspace.ui_sessions
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_ui_sessions_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.ui_sessions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'auth_session_id', 'client_instance_id', 'started_at');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_workspace.interaction_journeys
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>completed', 'active>abandoned');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.interaction_journeys
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'ui_session_id', 'journey_type', 'started_at');

CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.interaction_daily
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('principal_id', 'day', 'feature_code');

-- report_schedules: timezone and credential of the execution principal.
CREATE FUNCTION cob3_workspace.tg_report_schedules_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT cob3_identity.is_valid_timezone(NEW.timezone) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown IANA timezone %L.', NEW.timezone);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cob3_identity.principal_credentials c
                    WHERE c.tenant_id = NEW.tenant_id AND c.organization_id = NEW.organization_id
                      AND c.credential_id = NEW.credential_id AND c.principal_id = NEW.execution_principal_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The schedule credential must belong to the execution principal in this organization.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_workspace.report_schedules
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>paused', '>active', 'active>paused', 'paused>active', 'active>retired', 'paused>retired');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_workspace.report_schedules
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_report_schedules_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.report_schedules
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('artifact_id');

-- report_recipients: endpoint owned by the recipient or a same-org mailbox.
CREATE FUNCTION cob3_workspace.tg_report_recipients_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    s cob3_settings.setting_scopes%ROWTYPE;
BEGIN
    IF NEW.notification_endpoint_id IS NOT NULL THEN
        SELECT x.* INTO s FROM cob3_settings.notification_endpoints e
          JOIN cob3_settings.setting_scopes x ON x.tenant_id = e.tenant_id AND x.setting_scope_id = e.setting_scope_id
         WHERE e.tenant_id = NEW.tenant_id AND e.notification_endpoint_id = NEW.notification_endpoint_id AND e.status = 'active';
        IF NOT FOUND OR NOT ((s.scope_type = 'principal' AND s.principal_id = NEW.recipient_principal_id)
                             OR (s.scope_type IN ('organization', 'team') AND s.organization_id = NEW.organization_id)) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = 'Recipient endpoint must be the recipient''s own active endpoint or an approved mailbox of this organization.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_workspace.report_recipients
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE OF notification_endpoint_id ON cob3_workspace.report_recipients
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_report_recipients_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.report_recipients
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('report_schedule_id', 'recipient_principal_id', 'delivery_mode');

-- report_runs: resolved revision belongs to the schedule's artifact; ready output.
CREATE FUNCTION cob3_workspace.tg_report_runs_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' AND NOT EXISTS (
           SELECT 1 FROM cob3_workspace.report_schedules s
             JOIN cob3_workspace.artifact_revisions r
               ON r.tenant_id = s.tenant_id AND r.organization_id = s.organization_id AND r.artifact_id = s.artifact_id
            WHERE s.tenant_id = NEW.tenant_id AND s.organization_id = NEW.organization_id
              AND s.report_schedule_id = NEW.report_schedule_id AND r.artifact_revision_id = NEW.artifact_revision_id
              AND (s.revision_policy = 'latest' OR s.pinned_revision_id = NEW.artifact_revision_id)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'Run revision must belong to the schedule''s artifact (and equal the pinned revision when pinned).';
    END IF;
    IF NEW.output_file_id IS NOT NULL AND NEW.status = 'succeeded' AND NOT EXISTS (
           SELECT 1 FROM cob3_workspace.file_objects f
            WHERE f.tenant_id = NEW.tenant_id AND f.file_object_id = NEW.output_file_id AND f.status = 'ready') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A succeeded run needs a ready private output file.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_workspace.report_runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>queued', 'queued>running', 'queued>canceled', 'running>succeeded', 'running>failed', 'running>canceled',
        'running>queued', 'failed>queued');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_workspace.report_runs
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_report_runs_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.report_runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('report_schedule_id', 'artifact_revision_id', 'scheduled_for',
                                                                     'correlation_id', 'data_access_manifest');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_workspace.report_runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('attempt_count');

-- report_deliveries: run and recipient share the schedule; run succeeded.
CREATE FUNCTION cob3_workspace.tg_report_deliveries_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (
           SELECT 1 FROM cob3_workspace.report_runs r
             JOIN cob3_workspace.report_recipients rc
               ON rc.tenant_id = r.tenant_id AND rc.organization_id = r.organization_id AND rc.report_schedule_id = r.report_schedule_id
            WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id
              AND r.report_run_id = NEW.report_run_id AND rc.report_recipient_id = NEW.report_recipient_id
              AND r.status = 'succeeded' AND rc.status = 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'Deliveries need a succeeded run and an active recipient of the same schedule.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_workspace.report_deliveries
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>pending', 'pending>sent', 'pending>failed', 'pending>skipped', 'failed>pending', 'failed>skipped');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_workspace.report_deliveries
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_report_deliveries_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_workspace.report_deliveries
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('report_run_id', 'report_recipient_id');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_workspace.report_deliveries
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('attempt_count');
