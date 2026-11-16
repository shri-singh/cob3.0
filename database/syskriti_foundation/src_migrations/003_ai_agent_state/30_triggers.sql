-- =============================================================================
-- 30  COMMON RULES, GENERIC AI HELPERS AND TABLE TRIGGERS
-- =============================================================================

-- Uniform mandatory-column rules (design section 3) and append-only contract.
FOREACH _m_table IN ARRAY _m_tables LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format(
        'ALTER TABLE %1$I.%2$I'
        ' ADD CONSTRAINT %3$I CHECK (jsonb_typeof(metadata) = ''object'' AND pg_column_size(metadata) <= 16384),'
        ' ADD CONSTRAINT %4$I CHECK (NOT (metadata ?| ARRAY[''password'', ''secret'', ''client_secret'', ''private_key'', ''api_key'', ''access_token'', ''refresh_token'', ''token''])),'
        ' ADD CONSTRAINT %5$I CHECK (row_version > 0),'
        ' ADD CONSTRAINT %6$I CHECK (created_by ~ %9$L),'
        ' ADD CONSTRAINT %7$I CHECK (updated_by ~ %9$L),'
        ' ADD CONSTRAINT %8$I CHECK (updated_at >= created_at)',
        _m_schema, _m_name,
        _m_name || '_metadata_object_ck', _m_name || '_metadata_no_secrets_ck', _m_name || '_row_version_positive_ck',
        _m_name || '_created_by_actor_ck', _m_name || '_updated_by_actor_ck', _m_name || '_updated_after_created_ck',
        '^(principal:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|system:[a-z0-9][a-z0-9_.:-]{0,140})$');
    EXECUTE pg_catalog.format('CREATE TRIGGER trg_90_stamp_row BEFORE INSERT OR UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_stamp_row()',
                              _m_schema, _m_name);
    EXECUTE pg_catalog.format('CREATE TRIGGER trg_00_block_truncate BEFORE TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION cob3_identity.tg_block_truncate()',
                              _m_schema, _m_name);
END LOOP;
FOREACH _m_table IN ARRAY _m_append_only LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (row_version = 1 AND updated_at = created_at AND updated_by = created_by)',
                              _m_schema, _m_name, _m_name || '_append_only_ck');
    EXECUTE pg_catalog.format('CREATE TRIGGER trg_05_append_only BEFORE UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_append_only()',
                              _m_schema, _m_name);
END LOOP;

-- ---------------------------------------------------------------------------
-- Generic helpers (cob3_ai_lineage hosts the shared AI trigger functions)
-- ---------------------------------------------------------------------------
-- TG_ARGV[0]: Catalog asset type code required for NEW.asset_id.
CREATE FUNCTION cob3_ai_lineage.tg_asset_type()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    PERFORM cob3_catalog.assert_asset_type(NEW.tenant_id, NEW.organization_id, NEW.asset_id, TG_ARGV[0]);
    RETURN NEW;
END
$fn$;

-- Sealed manifests: a child may only be inserted in the same transaction that
-- created its immutable parent. TG_ARGV: parent table, parent id column, child column.
CREATE FUNCTION cob3_ai_lineage.tg_sealed()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_same boolean;
BEGIN
    EXECUTE pg_catalog.format('SELECT p.created_at = pg_catalog.now() FROM %s p WHERE p.tenant_id = $1 AND p.organization_id = $2 AND p.%I = $3',
                              TG_ARGV[0], TG_ARGV[1])
       INTO v_same USING NEW.tenant_id, NEW.organization_id, (pg_catalog.to_jsonb(NEW) ->> TG_ARGV[2])::uuid;
    IF NOT COALESCE(v_same, false) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = pg_catalog.format('%I.%I rows are sealed with their %s; create them in the same transaction.', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0]);
    END IF;
    RETURN NEW;
END
$fn$;

-- TG_ARGV[0]: principal column; TG_ARGV[1..]: allowed principal types.
CREATE FUNCTION cob3_ai_lineage.tg_principal_type()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_id   uuid := (pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0])::uuid;
    v_type text;
BEGIN
    IF v_id IS NULL THEN
        RETURN NEW;
    END IF;
    v_type := cob3_identity.principal_type_of(NEW.tenant_id, v_id);
    IF NOT (v_type = ANY (TG_ARGV[1:])) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I.%s must be a %s principal (got %s).', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0],
                                        pg_catalog.array_to_string(TG_ARGV[1:], ' or '), COALESCE(v_type, 'unknown'));
    END IF;
    RETURN NEW;
END
$fn$;

-- Settings integration reference: same tenant, tenant-level or SAME organization
-- scope, active, and one of the allowed adapter types (TG_ARGV).
CREATE FUNCTION cob3_ai_lineage.tg_integration_ref()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.integration_configuration_id IS NULL
       OR (TG_OP = 'UPDATE' AND NEW.integration_configuration_id IS NOT DISTINCT FROM OLD.integration_configuration_id) THEN
        RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cob3_settings.integration_configurations c
                    WHERE c.tenant_id = NEW.tenant_id AND c.integration_configuration_id = NEW.integration_configuration_id
                      AND (c.organization_id IS NULL OR c.organization_id = NEW.organization_id)
                      AND c.status = 'active' AND c.adapter_type = ANY (TG_ARGV)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I: integration configuration must be an active %s configuration of this tenant/organization.',
                                        TG_TABLE_SCHEMA, TG_TABLE_NAME, pg_catalog.array_to_string(TG_ARGV, '/'));
    END IF;
    RETURN NEW;
END
$fn$;

-- Monotonic fencing token per parent. TG_ARGV[0]: parent column.
CREATE FUNCTION cob3_ai_lineage.tg_fencing_monotonic()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_max bigint;
BEGIN
    PERFORM cob3_identity.xact_lock(TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0]);
    EXECUTE pg_catalog.format('SELECT pg_catalog.max(x.fencing_token) FROM %I.%I x WHERE x.tenant_id = $1 AND x.organization_id = $2 AND x.%I = $3',
                              TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0])
       INTO v_max USING NEW.tenant_id, NEW.organization_id, (pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0])::uuid;
    IF v_max IS NOT NULL AND NEW.fencing_token <= v_max THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I: fencing token %s is not greater than the current generation %s.', TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.fencing_token, v_max);
    END IF;
    RETURN NEW;
END
$fn$;

-- Gapless per-parent sequence allocated under a parent row lock.
-- TG_ARGV: parent table, parent id column, child parent column, sequence column.
CREATE FUNCTION cob3_ai_lineage.tg_sequence_next()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_parent uuid := (pg_catalog.to_jsonb(NEW) ->> TG_ARGV[2])::uuid;
    v_next   bigint;
BEGIN
    EXECUTE pg_catalog.format('SELECT 1 FROM %s p WHERE p.tenant_id = $1 AND p.organization_id = $2 AND p.%I = $3 FOR UPDATE',
                              TG_ARGV[0], TG_ARGV[1]) USING NEW.tenant_id, NEW.organization_id, v_parent;
    EXECUTE pg_catalog.format('SELECT COALESCE(pg_catalog.max(x.%1$I), 0) + 1 FROM %2$I.%3$I x WHERE x.tenant_id = $1 AND x.organization_id = $2 AND x.%4$I = $3',
                              TG_ARGV[3], TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[2])
       INTO v_next USING NEW.tenant_id, NEW.organization_id, v_parent;
    IF (pg_catalog.to_jsonb(NEW) ->> TG_ARGV[3])::bigint <> v_next THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I: next %s is %s.', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[3], v_next);
    END IF;
    RETURN NEW;
END
$fn$;

-- Ready Workspace file whose scanned checksum/size match the declared ones.
-- TG_ARGV: file column, hex sha256 column ('' = none), size column ('' = none).
CREATE FUNCTION cob3_ai_lineage.tg_file_ready()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_row jsonb := pg_catalog.to_jsonb(NEW);
    f     cob3_workspace.file_objects%ROWTYPE;
BEGIN
    SELECT x.* INTO f FROM cob3_workspace.file_objects x
     WHERE x.tenant_id = NEW.tenant_id AND x.organization_id = NEW.organization_id AND x.file_object_id = (v_row ->> TG_ARGV[0])::uuid;
    IF NOT FOUND OR f.status <> 'ready'
       OR (TG_ARGV[1] <> '' AND pg_catalog.encode(f.sha256, 'hex') <> v_row ->> TG_ARGV[1])
       OR (TG_ARGV[2] <> '' AND f.size_bytes <> (v_row ->> TG_ARGV[2])::bigint) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('%I.%I: referenced file must be ready and match the declared checksum/size.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;
    RETURN NEW;
END
$fn$;

-- Authenticated actor equality: in an end-user context the named column must be
-- the context principal (no writing on behalf of others). TG_ARGV[0]: column.
CREATE FUNCTION cob3_ai_lineage.tg_actor_is_context()
    RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF cob3_identity.ctx_principal_id() IS NOT NULL
       AND (pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0])::uuid IS DISTINCT FROM cob3_identity.ctx_principal_id() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
            MESSAGE = pg_catalog.format('%I.%I.%s must be the authenticated principal.', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0]);
    END IF;
    RETURN NEW;
END
$fn$;

-- Latest release decision for a versioned target ('publish' | 'revoke' | NULL).
CREATE FUNCTION cob3_agent.release_state(p_tenant_id uuid, p_organization_id uuid, p_kind text, p_target_id uuid)
    RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT r.action FROM cob3_agent.releases r
     WHERE r.tenant_id = p_tenant_id AND r.organization_id = p_organization_id
       AND CASE p_kind WHEN 'agent_revision' THEN r.agent_revision_id
                       WHEN 'skill_version'  THEN r.skill_version_id
                       WHEN 'prompt_version' THEN r.prompt_version_id END = p_target_id
     ORDER BY r.created_at DESC, r.release_id DESC
     LIMIT 1
$fn$;

-- Current pointers may only reference a published version. TG_ARGV: pointer column, release kind.
CREATE FUNCTION cob3_agent.tg_pointer_published()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_new uuid := (pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0])::uuid;
BEGIN
    IF v_new IS NOT NULL AND (TG_OP = 'INSERT' OR v_new IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) ->> TG_ARGV[0])::uuid)
       AND cob3_agent.release_state(NEW.tenant_id, NEW.organization_id, TG_ARGV[1], v_new) IS DISTINCT FROM 'publish' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA',
            MESSAGE = pg_catalog.format('%I.%I.%s must reference a published %s (record a release first).', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0], TG_ARGV[1]);
    END IF;
    RETURN NEW;
END
$fn$;

-- ===========================================================================
-- cob3_agent
-- ===========================================================================
CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_agent.agents FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('agent');
CREATE TRIGGER trg_17_published BEFORE INSERT OR UPDATE OF current_revision_id ON cob3_agent.agents
    FOR EACH ROW EXECUTE FUNCTION cob3_agent.tg_pointer_published('current_revision_id', 'agent_revision');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_agent.agents
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'agent_key');

CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_agent.prompt_templates FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('prompt');
CREATE TRIGGER trg_17_published BEFORE INSERT OR UPDATE OF current_version_id ON cob3_agent.prompt_templates
    FOR EACH ROW EXECUTE FUNCTION cob3_agent.tg_pointer_published('current_version_id', 'prompt_version');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_agent.prompt_templates
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'template_key');

CREATE TRIGGER trg_12_integration BEFORE INSERT OR UPDATE ON cob3_agent.model_deployments
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_integration_ref('model_provider');
-- Identity/configuration immutable: changes are a replacement deployment. enabled is the live kill switch.
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_agent.model_deployments
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'enabled');

CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_agent.tools FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('tool');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_agent.tools
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'tool_key');
CREATE TRIGGER trg_12_integration BEFORE INSERT ON cob3_agent.tool_revisions
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_integration_ref('tool_endpoint', 'webhook', 'product_adapter');

CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_agent.skills FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('skill');
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_agent.skills
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>draft', 'draft>active', 'active>archived', 'draft>archived', 'archived>active');
CREATE TRIGGER trg_17_published BEFORE INSERT OR UPDATE OF current_version_id ON cob3_agent.skills
    FOR EACH ROW EXECUTE FUNCTION cob3_agent.tg_pointer_published('current_version_id', 'skill_version');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_agent.skills
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'skill_key');

CREATE TRIGGER trg_13_sealed BEFORE INSERT ON cob3_agent.tool_permission_requirements
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_sealed('cob3_agent.tool_revisions', 'tool_revision_id', 'tool_revision_id');
CREATE TRIGGER trg_13_sealed BEFORE INSERT ON cob3_agent.skill_files
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_sealed('cob3_agent.skill_versions', 'skill_version_id', 'skill_version_id');
CREATE TRIGGER trg_14_file BEFORE INSERT ON cob3_agent.skill_files
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_file_ready('file_object_id', 'sha256', 'size_bytes');
CREATE TRIGGER trg_13_sealed BEFORE INSERT ON cob3_agent.agent_tool_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_sealed('cob3_agent.agent_revisions', 'agent_revision_id', 'agent_revision_id');
CREATE TRIGGER trg_13_sealed BEFORE INSERT ON cob3_agent.agent_skill_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_sealed('cob3_agent.agent_revisions', 'agent_revision_id', 'agent_revision_id');

-- Binding approval may only restrict: a tool that requires approval keeps it.
CREATE FUNCTION cob3_agent.tg_agent_tool_bindings_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT NEW.requires_approval AND EXISTS (
           SELECT 1 FROM cob3_agent.tool_revisions t
            WHERE t.tenant_id = NEW.tenant_id AND t.organization_id = NEW.organization_id
              AND t.tool_revision_id = NEW.tool_revision_id AND t.requires_approval) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A binding cannot drop the approval requirement of its tool revision.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_agent.agent_tool_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_agent.tg_agent_tool_bindings_validate();

-- Releases: serialized per target; publish only unpublished, revoke only
-- published; publishing an agent revision needs its prompt and bound skills
-- published; the parent pointer moves atomically in the same statement.
CREATE FUNCTION cob3_agent.tg_releases_apply()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_kind   text := CASE WHEN NEW.agent_revision_id IS NOT NULL THEN 'agent_revision'
                          WHEN NEW.skill_version_id IS NOT NULL THEN 'skill_version' ELSE 'prompt_version' END;
    v_target uuid := COALESCE(NEW.agent_revision_id, NEW.skill_version_id, NEW.prompt_version_id);
    v_state  text;
BEGIN
    IF cob3_identity.ctx_principal_id() IS NOT NULL AND NEW.approved_by_principal_id <> cob3_identity.ctx_principal_id() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'approved_by_principal_id must be the authenticated approver.';
    END IF;
    PERFORM cob3_identity.xact_lock('agent.release', v_target::text);
    v_state := cob3_agent.release_state(NEW.tenant_id, NEW.organization_id, v_kind, v_target);
    IF NEW.action = 'publish' AND v_state = 'publish' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Target is already published.';
    ELSIF NEW.action = 'revoke' AND v_state IS DISTINCT FROM 'publish' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Only a published target can be revoked.';
    END IF;
    IF NEW.action = 'publish' AND v_kind = 'agent_revision' THEN
        IF (SELECT cob3_agent.release_state(r.tenant_id, r.organization_id, 'prompt_version', r.prompt_version_id)
              FROM cob3_agent.agent_revisions r
             WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id AND r.agent_revision_id = v_target)
           IS DISTINCT FROM 'publish'
           OR EXISTS (SELECT 1 FROM cob3_agent.agent_skill_bindings b
                       WHERE b.tenant_id = NEW.tenant_id AND b.organization_id = NEW.organization_id AND b.agent_revision_id = v_target
                         AND cob3_agent.release_state(b.tenant_id, b.organization_id, 'skill_version', b.skill_version_id)
                             IS DISTINCT FROM 'publish') THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Publish the pinned prompt version and bound skill versions first.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_apply BEFORE INSERT ON cob3_agent.releases
    FOR EACH ROW EXECUTE FUNCTION cob3_agent.tg_releases_apply();

CREATE FUNCTION cob3_agent.tg_releases_move_pointer()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_actor text := COALESCE(cob3_identity.ctx_actor(), NEW.created_by);
BEGIN
    IF NEW.agent_revision_id IS NOT NULL THEN
        UPDATE cob3_agent.agents a
           SET current_revision_id = CASE WHEN NEW.action = 'publish' THEN NEW.agent_revision_id END, updated_by = v_actor
          FROM cob3_agent.agent_revisions r
         WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id AND r.agent_revision_id = NEW.agent_revision_id
           AND a.tenant_id = r.tenant_id AND a.organization_id = r.organization_id AND a.agent_id = r.agent_id
           AND (NEW.action = 'publish' OR a.current_revision_id = NEW.agent_revision_id);
    ELSIF NEW.skill_version_id IS NOT NULL THEN
        UPDATE cob3_agent.skills s
           SET current_version_id = CASE WHEN NEW.action = 'publish' THEN NEW.skill_version_id END, updated_by = v_actor
          FROM cob3_agent.skill_versions v
         WHERE v.tenant_id = NEW.tenant_id AND v.organization_id = NEW.organization_id AND v.skill_version_id = NEW.skill_version_id
           AND s.tenant_id = v.tenant_id AND s.organization_id = v.organization_id AND s.skill_id = v.skill_id
           AND (NEW.action = 'publish' OR s.current_version_id = NEW.skill_version_id);
    ELSE
        UPDATE cob3_agent.prompt_templates p
           SET current_version_id = CASE WHEN NEW.action = 'publish' THEN NEW.prompt_version_id END, updated_by = v_actor
          FROM cob3_agent.prompt_versions v
         WHERE v.tenant_id = NEW.tenant_id AND v.organization_id = NEW.organization_id AND v.prompt_version_id = NEW.prompt_version_id
           AND p.tenant_id = v.tenant_id AND p.organization_id = v.organization_id AND p.prompt_template_id = v.prompt_template_id
           AND (NEW.action = 'publish' OR p.current_version_id = NEW.prompt_version_id);
    END IF;
    RETURN NULL;
END
$fn$;
CREATE TRIGGER trg_80_move_pointer AFTER INSERT ON cob3_agent.releases
    FOR EACH ROW EXECUTE FUNCTION cob3_agent.tg_releases_move_pointer();

-- ===========================================================================
-- cob3_ai_runtime
-- ===========================================================================
-- Execution contexts are evidence and ceilings (design section 4).
CREATE FUNCTION cob3_ai_runtime.tg_execution_contexts_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    s cob3_identity.auth_sessions%ROWTYPE;
    c cob3_identity.principal_credentials%ROWTYPE;
    p cob3_ai_runtime.execution_contexts%ROWTYPE;
BEGIN
    IF NEW.auth_session_id IS NOT NULL THEN
        SELECT x.* INTO s FROM cob3_identity.auth_sessions x WHERE x.tenant_id = NEW.tenant_id AND x.session_id = NEW.auth_session_id;
        IF s.principal_id <> NEW.execution_principal_id OR s.organization_id IS DISTINCT FROM NEW.organization_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The session must belong to the execution principal in this organization.';
        END IF;
        IF s.session_kind = 'interactive' AND (NEW.initiator_principal_id <> NEW.execution_principal_id OR NEW.grant_id IS NOT NULL) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'An interactive context runs as its own human initiator without a delegated grant.';
        END IF;
        IF s.session_kind <> 'interactive' AND s.authorization_grant_id IS DISTINCT FROM NEW.grant_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A federated session context must carry the session''s grant.';
        END IF;
    ELSIF NEW.credential_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A noninteractive context needs a credential or a bounded federated session.';
    END IF;
    IF NEW.credential_id IS NOT NULL THEN
        SELECT x.* INTO c FROM cob3_identity.principal_credentials x
         WHERE x.tenant_id = NEW.tenant_id AND x.organization_id = NEW.organization_id AND x.credential_id = NEW.credential_id;
        IF c.principal_id <> NEW.execution_principal_id OR c.authorization_grant_id IS DISTINCT FROM NEW.grant_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The credential must belong to the execution principal and its approved grant.';
        END IF;
    END IF;
    IF NEW.parent_context_id IS NOT NULL THEN
        SELECT x.* INTO p FROM cob3_ai_runtime.execution_contexts x
         WHERE x.tenant_id = NEW.tenant_id AND x.organization_id = NEW.organization_id AND x.execution_context_id = NEW.parent_context_id;
        -- Child contexts narrow: same principals and grant, earlier expiry, subset ceiling, no re-delegation.
        IF p.execution_principal_id <> NEW.execution_principal_id OR p.initiator_principal_id <> NEW.initiator_principal_id
           OR p.grant_id IS DISTINCT FROM NEW.grant_id OR NEW.valid_until > p.valid_until
           OR NOT (p.authority_ceiling @> NEW.authority_ceiling) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A child context must keep the same principals and grant and narrow expiry and ceiling.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_ai_runtime.execution_contexts
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_runtime.tg_execution_contexts_validate();

CREATE FUNCTION cob3_ai_runtime.tg_runs_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_ctx_parent uuid;
BEGIN
    IF NEW.trigger_kind <> 'evaluation'
       AND cob3_agent.release_state(NEW.tenant_id, NEW.organization_id, 'agent_revision', NEW.agent_revision_id) IS DISTINCT FROM 'publish' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Runs pin a published agent revision (unpublished revisions only for evaluation runs).';
    END IF;
    IF NEW.trigger_kind IN ('interactive', 'evaluation') AND cob3_identity.ctx_principal_id() IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cob3_ai_runtime.execution_contexts c
                        WHERE c.tenant_id = NEW.tenant_id AND c.organization_id = NEW.organization_id
                          AND c.execution_context_id = NEW.execution_context_id AND c.auth_session_id IS NOT NULL) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Interactive/evaluation triggers require a session-backed execution context.';
    END IF;
    IF NEW.thread_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM cob3_copilot.threads t
            WHERE t.tenant_id = NEW.tenant_id AND t.organization_id = NEW.organization_id
              AND t.thread_id = NEW.thread_id AND t.status <> 'active') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Archived threads accept no new runs.';
    END IF;
    IF NEW.parent_run_id IS NOT NULL THEN
        SELECT c.parent_context_id INTO v_ctx_parent FROM cob3_ai_runtime.execution_contexts c
         WHERE c.tenant_id = NEW.tenant_id AND c.organization_id = NEW.organization_id AND c.execution_context_id = NEW.execution_context_id;
        IF NOT EXISTS (SELECT 1 FROM cob3_ai_runtime.runs pr
                        WHERE pr.tenant_id = NEW.tenant_id AND pr.organization_id = NEW.organization_id AND pr.run_id = NEW.parent_run_id
                          AND (pr.execution_context_id = NEW.execution_context_id OR pr.execution_context_id = v_ctx_parent)) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A child run uses its parent''s context or a narrower child of it.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>queued',
        'queued>running', 'queued>cancellation_requested', 'queued>cancelled', 'queued>expired',
        'running>waiting_input', 'running>waiting_approval', 'waiting_input>running', 'waiting_approval>running',
        'running>cancellation_requested', 'waiting_input>cancellation_requested', 'waiting_approval>cancellation_requested',
        'cancellation_requested>cancelled', 'cancellation_requested>succeeded', 'cancellation_requested>failed',
        'running>succeeded', 'running>failed', 'running>expired', 'waiting_input>expired', 'waiting_approval>expired');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_ai_runtime.runs FOR EACH ROW EXECUTE FUNCTION cob3_ai_runtime.tg_runs_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_ai_runtime.runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('execution_context_id', 'agent_revision_id', 'application_environment_id',
        'thread_id', 'branch_id', 'parent_run_id', 'trigger_kind', 'idempotency_key', 'deadline_at', 'input_payload_id');
-- Terminal outcomes are immutable history; retries are new attempts.
CREATE TRIGGER trg_21_terminal_freeze BEFORE UPDATE ON cob3_ai_runtime.runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'queued,running,waiting_input,waiting_approval,cancellation_requested');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.run_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>queued', '>running',
        'queued>running', 'queued>lost', 'running>succeeded', 'running>failed', 'running>lost');
CREATE TRIGGER trg_14_worker BEFORE INSERT ON cob3_ai_runtime.run_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_principal_type('worker_principal_id', 'service_account');
CREATE TRIGGER trg_15_fencing BEFORE INSERT ON cob3_ai_runtime.run_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_fencing_monotonic('run_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_ai_runtime.run_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('run_id', 'attempt_number', 'worker_principal_id', 'fencing_token');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.run_steps
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>pending', '>running',
        'pending>running', 'pending>skipped', 'pending>failed', 'running>waiting', 'waiting>running', 'running>succeeded',
        'running>failed', 'running>unknown', 'waiting>failed', 'unknown>succeeded', 'unknown>failed');
-- Same step key with a different input hash is an error: identity is immutable.
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_ai_runtime.run_steps
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('run_id', 'step_key', 'parent_step_id', 'kind', 'input_sha256');

CREATE TRIGGER trg_15_sequence BEFORE INSERT ON cob3_ai_runtime.run_events
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_sequence_next('cob3_ai_runtime.runs', 'run_id', 'run_id', 'sequence');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.payloads
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>available', '>quarantined',
        'available>quarantined', 'quarantined>available', 'available>purged', 'quarantined>purged');
CREATE TRIGGER trg_14_file BEFORE INSERT ON cob3_ai_runtime.payloads
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_file_ready('file_object_id', 'sha256', 'size_bytes');
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_ai_runtime.payloads
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'status', 'expires_at');

-- Checkpoint parent: same run and namespace (FK) and strictly earlier step.
CREATE FUNCTION cob3_ai_runtime.tg_checkpoints_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.parent_checkpoint_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_ai_runtime.checkpoints p
            WHERE p.tenant_id = NEW.tenant_id AND p.organization_id = NEW.organization_id
              AND p.checkpoint_id = NEW.parent_checkpoint_id AND p.step_number < NEW.step_number) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A checkpoint parent must be an earlier step of the same run and namespace.';
    END IF;
    IF NEW.branch_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_ai_runtime.runs r
            WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id
              AND r.run_id = NEW.run_id AND r.branch_id = NEW.branch_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A checkpoint branch must be its run''s branch.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_ai_runtime.checkpoints
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_runtime.tg_checkpoints_validate();

-- Tool actions: tool step, tool bound to the run's pinned agent revision,
-- approval required by tool/binding before 'ready'.
CREATE FUNCTION cob3_ai_runtime.tg_tool_actions_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_requires boolean;
BEGIN
    SELECT b.requires_approval INTO v_requires
      FROM cob3_ai_runtime.run_steps st
      JOIN cob3_ai_runtime.runs r ON r.tenant_id = st.tenant_id AND r.organization_id = st.organization_id AND r.run_id = st.run_id
      JOIN cob3_agent.agent_tool_bindings b
        ON b.tenant_id = r.tenant_id AND b.organization_id = r.organization_id
       AND b.agent_revision_id = r.agent_revision_id AND b.tool_revision_id = NEW.tool_revision_id
     WHERE st.tenant_id = NEW.tenant_id AND st.organization_id = NEW.organization_id AND st.step_id = NEW.step_id AND st.kind = 'tool';
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'A tool action needs a tool step and a tool revision bound to the run''s pinned agent revision.';
    END IF;
    IF NEW.status IN ('ready', 'executing') AND v_requires AND NEW.approval_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'This tool action requires an Identity action approval before dispatch.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.tool_actions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>proposed',
        'proposed>awaiting_approval', 'proposed>ready', 'awaiting_approval>ready', 'awaiting_approval>failed',
        'ready>executing', 'executing>succeeded', 'executing>failed', 'executing>unknown', 'unknown>succeeded', 'unknown>failed',
        'proposed>failed');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_ai_runtime.tool_actions
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_runtime.tg_tool_actions_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_ai_runtime.tool_actions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('step_id', 'tool_revision_id', 'arguments_payload_id',
        'arguments_sha256', 'target_manifest', 'idempotency_key');

CREATE FUNCTION cob3_ai_runtime.tg_tool_attempts_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_ai_runtime.tool_actions a
                     JOIN cob3_ai_runtime.run_steps st ON st.tenant_id = a.tenant_id AND st.organization_id = a.organization_id AND st.step_id = a.step_id
                     JOIN cob3_ai_runtime.run_attempts ra ON ra.tenant_id = st.tenant_id AND ra.organization_id = st.organization_id AND ra.run_id = st.run_id
                    WHERE a.tenant_id = NEW.tenant_id AND a.organization_id = NEW.organization_id
                      AND a.tool_action_id = NEW.tool_action_id AND ra.run_attempt_id = NEW.run_attempt_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The executing run attempt must belong to the action''s run.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.tool_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>prepared',
        'prepared>sent', 'prepared>failed', 'sent>succeeded', 'sent>failed', 'sent>unknown', 'unknown>succeeded', 'unknown>failed');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_ai_runtime.tool_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_runtime.tg_tool_attempts_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_ai_runtime.tool_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('tool_action_id', 'attempt_number', 'run_attempt_id', 'started_at');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.interrupts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>pending',
        'pending>resolved', 'pending>expired', 'pending>cancelled');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_ai_runtime.interrupts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('run_id', 'step_id', 'checkpoint_id', 'kind',
        'request_payload_id', 'approval_id', 'expires_at');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_ai_runtime.outbox
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>pending',
        'pending>leased', 'leased>delivered', 'leased>pending', 'leased>failed', 'failed>pending');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_ai_runtime.outbox
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('run_id', 'event_key', 'event_type', 'payload');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_ai_runtime.outbox
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('attempt_count', 'fencing_token');

-- ===========================================================================
-- cob3_copilot
-- ===========================================================================
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_copilot.threads
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>archived', 'archived>active');
CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_copilot.threads FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('conversation');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_copilot.threads
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id');

CREATE TRIGGER trg_15_no_cycle BEFORE INSERT OR UPDATE OF parent_branch_id ON cob3_copilot.branches
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_tree_no_cycle('branch_id', 'parent_branch_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_copilot.branches
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('thread_id', 'parent_branch_id', 'fork_message_id');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_copilot.branches
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('state_version');

-- Messages: conversational role is separate from the actual author and run.
CREATE FUNCTION cob3_copilot.tg_messages_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    r record;
BEGIN
    IF NEW.run_id IS NOT NULL THEN
        SELECT x.thread_id, c.execution_principal_id INTO r
          FROM cob3_ai_runtime.runs x
          JOIN cob3_ai_runtime.execution_contexts c
            ON c.tenant_id = x.tenant_id AND c.organization_id = x.organization_id AND c.execution_context_id = x.execution_context_id
         WHERE x.tenant_id = NEW.tenant_id AND x.organization_id = NEW.organization_id AND x.run_id = NEW.run_id;
        IF r.thread_id IS DISTINCT FROM NEW.thread_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A message run must belong to the same thread.';
        END IF;
        IF NEW.role = 'assistant' AND NEW.author_principal_id IS NOT NULL AND NEW.author_principal_id <> r.execution_principal_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'An assistant message author must be the run''s execution principal.';
        END IF;
    END IF;
    IF NEW.role = 'user' AND cob3_identity.ctx_principal_id() IS NOT NULL AND NEW.author_principal_id <> cob3_identity.ctx_principal_id() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'User messages are authored by the authenticated principal.';
    END IF;
    IF NEW.role IN ('assistant', 'tool', 'system') AND cob3_identity.ctx_principal_id() IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Assistant, tool and system messages are written by the trusted runtime only.';
    END IF;
    IF NEW.tool_action_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_ai_runtime.tool_actions a
             JOIN cob3_ai_runtime.run_steps st ON st.tenant_id = a.tenant_id AND st.organization_id = a.organization_id AND st.step_id = a.step_id
            WHERE a.tenant_id = NEW.tenant_id AND a.organization_id = NEW.organization_id
              AND a.tool_action_id = NEW.tool_action_id AND st.run_id = NEW.run_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A tool message must reference an action of its own run.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_copilot.messages FOR EACH ROW EXECUTE FUNCTION cob3_copilot.tg_messages_validate();
CREATE TRIGGER trg_16_sequence BEFORE INSERT ON cob3_copilot.messages
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_sequence_next('cob3_copilot.branches', 'branch_id', 'branch_id', 'sequence');

CREATE TRIGGER trg_14_file BEFORE INSERT ON cob3_copilot.message_attachments
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_file_ready('file_object_id', '', '');
CREATE TRIGGER trg_14_human BEFORE INSERT ON cob3_copilot.thread_preferences
    FOR EACH ROW EXECUTE FUNCTION cob3_workspace.tg_personal_owner_human();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_copilot.thread_preferences
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('thread_id', 'principal_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_copilot.search_documents
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('message_id', 'chunk_index', 'index_version');

CREATE FUNCTION cob3_copilot.tg_suggestions_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_ai_runtime.runs r
                    WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id
                      AND r.run_id = NEW.run_id AND r.thread_id = NEW.thread_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A suggestion''s thread must be its run''s thread.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_copilot.suggestions
    FOR EACH ROW EXECUTE FUNCTION cob3_copilot.tg_suggestions_validate();

-- ===========================================================================
-- cob3_memory
-- ===========================================================================
CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_memory.containers FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('memory_container');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_memory.containers
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'scope_kind', 'owner_principal_id', 'team_id', 'project_id');

-- Approval is a controlled review: the current revision must carry a reviewer.
CREATE FUNCTION cob3_memory.tg_items_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') AND NOT EXISTS (
           SELECT 1 FROM cob3_memory.item_revisions r
            WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id
              AND r.memory_revision_id = NEW.current_revision_id AND r.reviewer_principal_id IS NOT NULL) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Approving a memory requires a reviewed current revision.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_memory.items
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>candidate',
        'candidate>approved', 'candidate>rejected', 'candidate>retracted', 'approved>superseded', 'approved>retracted', 'superseded>retracted');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_memory.items FOR EACH ROW EXECUTE FUNCTION cob3_memory.tg_items_validate();
CREATE TRIGGER trg_16_no_cycle BEFORE INSERT OR UPDATE OF superseded_by_id ON cob3_memory.items
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_tree_no_cycle('memory_id', 'superseded_by_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_memory.items
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('container_id', 'memory_kind', 'valid_from');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_memory.consolidation_jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>queued',
        'queued>running', 'running>proposed', 'running>failed', 'proposed>completed', 'proposed>failed', 'queued>failed');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_memory.working_state
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('run_id', 'namespace', 'state_key');

-- ===========================================================================
-- cob3_learning
-- ===========================================================================
-- Feedback provenance: human vs evaluator vs imported stays distinguishable.
CREATE FUNCTION cob3_learning.tg_feedback_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_type text := cob3_identity.principal_type_of(NEW.tenant_id, NEW.author_principal_id);
BEGIN
    IF (NEW.source_kind = 'human' AND v_type <> 'human')
       OR (NEW.source_kind = 'evaluator' AND v_type NOT IN ('service_account', 'automation')) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Feedback source kind must match the author principal type.';
    END IF;
    IF NEW.source_kind = 'imported' AND cob3_identity.ctx_principal_id() IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Imported feedback is written by a trusted ingestion worker only.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_14_actor BEFORE INSERT ON cob3_learning.feedback
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_actor_is_context('author_principal_id');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_learning.feedback FOR EACH ROW EXECUTE FUNCTION cob3_learning.tg_feedback_validate();
CREATE TRIGGER trg_14_actor BEFORE INSERT ON cob3_learning.annotations
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_actor_is_context('author_principal_id');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_learning.datasets
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>draft',
        'draft>active', 'active>quarantined', 'quarantined>active', 'active>archived', 'quarantined>archived', 'draft>archived');
CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_learning.datasets FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('ai_dataset');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_learning.datasets
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'purpose');

CREATE FUNCTION cob3_learning.dataset_purpose(p_tenant_id uuid, p_organization_id uuid, p_dataset_version_id uuid)
    RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT d.purpose FROM cob3_learning.dataset_versions v
      JOIN cob3_learning.datasets d ON d.tenant_id = v.tenant_id AND d.organization_id = v.organization_id AND d.dataset_id = v.dataset_id
     WHERE v.tenant_id = p_tenant_id AND v.organization_id = p_organization_id AND v.dataset_version_id = p_dataset_version_id
$fn$;

-- Purpose-specific example shape; evaluation and training never mix.
CREATE FUNCTION cob3_learning.tg_examples_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_purpose text := cob3_learning.dataset_purpose(NEW.tenant_id, NEW.organization_id, NEW.dataset_version_id);
BEGIN
    IF v_purpose = 'evaluation' AND NOT ((NEW.expected_payload_id IS NOT NULL OR NEW.rubric IS NOT NULL)
                                         AND NEW.chosen_payload_id IS NULL AND NEW.rejected_payload_id IS NULL) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Evaluation examples need expected output or rubric and no preference pair.';
    ELSIF v_purpose = 'training' AND NOT (NEW.chosen_payload_id IS NOT NULL AND NEW.expected_payload_id IS NULL AND NEW.rubric IS NULL) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Training examples need a chosen answer and no evaluation fields.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_13_sealed BEFORE INSERT ON cob3_learning.examples
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_sealed('cob3_learning.dataset_versions', 'dataset_version_id', 'dataset_version_id');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_learning.examples FOR EACH ROW EXECUTE FUNCTION cob3_learning.tg_examples_validate();

CREATE FUNCTION cob3_learning.tg_purpose_is()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF cob3_learning.dataset_purpose(NEW.tenant_id, NEW.organization_id, NEW.dataset_version_id) IS DISTINCT FROM TG_ARGV[0] THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('%I.%I requires a %s dataset version.', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0]);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_learning.evaluation_runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>queued', 'queued>running', 'running>completed', 'running>failed', 'queued>failed');
CREATE TRIGGER trg_15_purpose BEFORE INSERT ON cob3_learning.evaluation_runs FOR EACH ROW EXECUTE FUNCTION cob3_learning.tg_purpose_is('evaluation');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_learning.evaluation_runs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('dataset_version_id', 'agent_revision_id', 'runtime_run_id', 'evaluator_config');

CREATE FUNCTION cob3_learning.tg_evaluation_results_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cob3_learning.evaluation_runs r
                     JOIN cob3_learning.examples e
                       ON e.tenant_id = r.tenant_id AND e.organization_id = r.organization_id AND e.dataset_version_id = r.dataset_version_id
                    WHERE r.tenant_id = NEW.tenant_id AND r.organization_id = NEW.organization_id
                      AND r.evaluation_run_id = NEW.evaluation_run_id AND e.example_id = NEW.example_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The example must belong to the evaluation run''s frozen dataset version.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_learning.evaluation_results
    FOR EACH ROW EXECUTE FUNCTION cob3_learning.tg_evaluation_results_validate();

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_learning.training_jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>queued', 'queued>exporting', 'exporting>training',
        'training>succeeded', 'training>failed', 'exporting>failed', 'queued>cancelled', 'exporting>cancelled', 'training>cancelled',
        'succeeded>quarantined');
CREATE TRIGGER trg_12_integration BEFORE INSERT OR UPDATE ON cob3_learning.training_jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_integration_ref('training_provider', 'model_provider');
CREATE TRIGGER trg_15_purpose BEFORE INSERT ON cob3_learning.training_jobs FOR EACH ROW EXECUTE FUNCTION cob3_learning.tg_purpose_is('training');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_learning.training_jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('dataset_version_id', 'runtime_run_id', 'base_model_deployment_id',
        'integration_configuration_id', 'hyperparameters');

-- ===========================================================================
-- cob3_llmobs
-- ===========================================================================
CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_llmobs.applications FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('ai_application');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_llmobs.applications
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'application_key');
CREATE TRIGGER trg_12_integration BEFORE INSERT OR UPDATE ON cob3_llmobs.application_environments
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_integration_ref('telemetry_exporter');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_llmobs.application_environments
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('application_id', 'environment_key');

-- Native invocations: the step's run uses the declared execution context.
CREATE FUNCTION cob3_llmobs.tg_invocations_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.run_step_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_ai_runtime.run_steps st
             JOIN cob3_ai_runtime.runs r ON r.tenant_id = st.tenant_id AND r.organization_id = st.organization_id AND r.run_id = st.run_id
            WHERE st.tenant_id = NEW.tenant_id AND st.organization_id = NEW.organization_id AND st.step_id = NEW.run_step_id
              AND st.kind = 'model' AND r.execution_context_id = NEW.execution_context_id
              AND r.application_environment_id = NEW.application_environment_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'A native invocation needs a model step whose run uses this execution context and environment.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_llmobs.invocations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>pending', '>running', '>succeeded', '>failed', '>cancelled', '>unknown',
        'pending>running', 'running>succeeded', 'running>failed', 'running>cancelled', 'running>unknown', 'pending>cancelled',
        'unknown>succeeded', 'unknown>failed');
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_llmobs.invocations FOR EACH ROW EXECUTE FUNCTION cob3_llmobs.tg_invocations_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_llmobs.invocations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('application_environment_id', 'run_step_id', 'execution_context_id',
        'source_system', 'source_call_id', 'started_at', 'policy_version_id');

-- Charges: currency/dimension agree with the applied rate; adjustments target
-- an earlier charge of the same attempt and currency.
CREATE FUNCTION cob3_llmobs.tg_usage_charges_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.model_price_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_llmobs.model_prices p
            WHERE p.tenant_id = NEW.tenant_id AND p.organization_id = NEW.organization_id AND p.model_price_id = NEW.model_price_id
              AND p.currency = NEW.currency AND p.price_dimension = NEW.price_dimension) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The applied rate must have the charge''s currency and price dimension.';
    END IF;
    IF NEW.adjusts_charge_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_llmobs.usage_charges c
            WHERE c.tenant_id = NEW.tenant_id AND c.organization_id = NEW.organization_id AND c.usage_charge_id = NEW.adjusts_charge_id
              AND c.invocation_attempt_id = NEW.invocation_attempt_id AND c.currency = NEW.currency
              AND c.price_dimension = NEW.price_dimension) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'An adjustment must target a charge of the same attempt, dimension and currency.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_llmobs.usage_charges FOR EACH ROW EXECUTE FUNCTION cob3_llmobs.tg_usage_charges_validate();

CREATE FUNCTION cob3_llmobs.tg_guardrail_events_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.run_id IS NOT NULL AND NEW.invocation_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_llmobs.invocations i
             JOIN cob3_ai_runtime.run_steps st ON st.tenant_id = i.tenant_id AND st.organization_id = i.organization_id AND st.step_id = i.run_step_id
            WHERE i.tenant_id = NEW.tenant_id AND i.organization_id = NEW.organization_id
              AND i.invocation_id = NEW.invocation_id AND st.run_id = NEW.run_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Guardrail run and invocation must be coherent.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_llmobs.guardrail_events FOR EACH ROW EXECUTE FUNCTION cob3_llmobs.tg_guardrail_events_validate();

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_llmobs.review_tasks
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>open', '>assigned',
        'open>assigned', 'assigned>open', 'assigned>resolved', 'open>cancelled', 'assigned>cancelled');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_llmobs.review_tasks
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('target_node_id', 'reason_codes');

-- Holds: only release fields change; release actor = authenticated principal.
CREATE TRIGGER trg_14_placer BEFORE INSERT ON cob3_llmobs.retention_holds
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_actor_is_context('placed_by_principal_id');
CREATE TRIGGER trg_14_releaser BEFORE UPDATE ON cob3_llmobs.retention_holds
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_actor_is_context('released_by_principal_id');
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_llmobs.retention_holds
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('', '', 'released_at', 'released_by_principal_id');

-- ===========================================================================
-- cob3_ai_lineage: controlled polymorphic registry (design section 11)
-- ===========================================================================
-- Release-owned kind registry: node_kind -> backing table and id column.
CREATE FUNCTION cob3_ai_lineage.node_kind_backing(p_node_kind text, OUT relation text, OUT id_column text)
    LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT v.rel, v.col FROM (VALUES
        ('agent_revision',    'cob3_agent.agent_revisions',        'agent_revision_id'),
        ('prompt_version',    'cob3_agent.prompt_versions',        'prompt_version_id'),
        ('tool_revision',     'cob3_agent.tool_revisions',         'tool_revision_id'),
        ('skill_version',     'cob3_agent.skill_versions',         'skill_version_id'),
        ('skill_file',        'cob3_agent.skill_files',            'skill_file_id'),
        ('run',               'cob3_ai_runtime.runs',              'run_id'),
        ('run_step',          'cob3_ai_runtime.run_steps',         'step_id'),
        ('payload',           'cob3_ai_runtime.payloads',          'payload_id'),
        ('message',           'cob3_copilot.messages',             'message_id'),
        ('memory_revision',   'cob3_memory.item_revisions',        'memory_revision_id'),
        ('dataset_version',   'cob3_learning.dataset_versions',    'dataset_version_id'),
        ('example',           'cob3_learning.examples',            'example_id'),
        ('evaluation_result', 'cob3_learning.evaluation_results',  'evaluation_result_id'),
        ('feedback',          'cob3_learning.feedback',            'feedback_id'),
        ('invocation',        'cob3_llmobs.invocations',           'invocation_id'),
        ('artifact_revision', 'cob3_workspace.artifact_revisions', 'artifact_revision_id'),
        ('catalog_asset',     'cob3_catalog.assets',               'asset_id')
    ) AS v(kind, rel, col)
     WHERE v.kind = p_node_kind
$fn$;

CREATE FUNCTION cob3_ai_lineage.tg_nodes_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    b    record;
    v_ok boolean;
BEGIN
    SELECT * INTO b FROM cob3_ai_lineage.node_kind_backing(NEW.node_kind);
    IF b.relation IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown lineage node kind %L.', NEW.node_kind);
    END IF;
    EXECUTE pg_catalog.format('SELECT EXISTS (SELECT 1 FROM %s x WHERE x.tenant_id = $1 AND x.organization_id = $2 AND x.%I = $3)',
                              b.relation, b.id_column)
       INTO v_ok USING NEW.tenant_id, NEW.organization_id, NEW.entity_id;
    IF NOT v_ok THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Lineage node %s %s has no backing row in this organization.', NEW.node_kind, NEW.entity_id);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_ai_lineage.nodes FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_nodes_validate();

-- No derivation ancestry cycles; shedding source permissions (provenance_only)
-- needs reviewed export authority, never caller choice.
CREATE FUNCTION cob3_ai_lineage.tg_edges_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_cycle boolean;
BEGIN
    IF NEW.dependency_kind = 'provenance_only' AND cob3_identity.ctx_principal_id() IS NOT NULL
       AND NOT cob3_identity.ctx_has_org_permission('ai.dataset.export') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'provenance_only edges require reviewed declassification/export authority.';
    END IF;
    IF NEW.relation <> 'supersedes' THEN
        PERFORM cob3_identity.assert_isolation_safe();
        PERFORM cob3_identity.xact_lock('ai_lineage.edges', NEW.tenant_id::text || ':' || NEW.organization_id::text);
        WITH RECURSIVE down(node, depth) AS (
            SELECT NEW.derived_node_id, 0
            UNION
            SELECT e.derived_node_id, d.depth + 1
              FROM cob3_ai_lineage.edges e JOIN down d ON e.source_node_id = d.node
             WHERE e.tenant_id = NEW.tenant_id AND e.organization_id = NEW.organization_id
               AND e.relation <> 'supersedes' AND d.depth < 100000)
        SELECT EXISTS (SELECT 1 FROM down WHERE node = NEW.source_node_id) INTO v_cycle;
        IF v_cycle THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'This edge would create a derivation ancestry cycle.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_validate BEFORE INSERT ON cob3_ai_lineage.edges FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_edges_validate();

-- ===========================================================================
-- cob3_connectors
-- ===========================================================================
CREATE FUNCTION cob3_connectors.tg_connections_validate()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.auth_session_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM cob3_identity.auth_sessions s
            WHERE s.tenant_id = NEW.tenant_id AND s.session_id = NEW.auth_session_id AND s.principal_id = NEW.execution_principal_id
              AND s.organization_id = NEW.organization_id AND s.authorization_grant_id = NEW.grant_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A connection session must belong to the execution principal under the same grant.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_11_asset_type BEFORE INSERT ON cob3_connectors.connections
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_asset_type('connector_connection');
CREATE TRIGGER trg_12_integration BEFORE INSERT OR UPDATE ON cob3_connectors.connections
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_integration_ref('connector', 'product_adapter');
CREATE TRIGGER trg_14_executor BEFORE INSERT ON cob3_connectors.connections
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_principal_type('execution_principal_id', 'service_account', 'automation');
CREATE TRIGGER trg_15_validate BEFORE INSERT OR UPDATE ON cob3_connectors.connections
    FOR EACH ROW EXECUTE FUNCTION cob3_connectors.tg_connections_validate();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_connectors.connections
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('asset_id', 'execution_principal_id', 'provider');

CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_connectors.sync_cursors
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('connection_id', 'stream_key');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_connectors.jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>queued', 'queued>running', 'queued>cancelled',
        'running>succeeded', 'running>failed', 'running>cancelled', 'running>reconciliation_required', 'running>queued',
        'reconciliation_required>succeeded', 'reconciliation_required>failed', 'failed>queued');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_connectors.jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('connection_id', 'sync_cursor_id', 'operation', 'idempotency_key',
        'window_start', 'window_end');

CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_connectors.job_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>running', 'running>succeeded', 'running>failed', 'running>lost');
CREATE TRIGGER trg_14_worker BEFORE INSERT ON cob3_connectors.job_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_principal_type('worker_principal_id', 'service_account');
CREATE TRIGGER trg_15_fencing BEFORE INSERT ON cob3_connectors.job_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_ai_lineage.tg_fencing_monotonic('connector_job_id');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_connectors.job_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('connector_job_id', 'attempt_number', 'worker_principal_id',
        'fencing_token', 'started_at');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_connectors.job_attempts
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('record_count');

-- Records: stale provider versions never overwrite newer state.
CREATE FUNCTION cob3_connectors.tg_records_ordering()
    RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF OLD.source_updated_at IS NOT NULL AND (NEW.source_updated_at IS NULL OR NEW.source_updated_at < OLD.source_updated_at) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Stale provider version: source_updated_at may not move backwards.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_15_ordering BEFORE UPDATE ON cob3_connectors.records FOR EACH ROW EXECUTE FUNCTION cob3_connectors.tg_records_ordering();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_connectors.records
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('connection_id', 'stream_key', 'kind', 'external_id');
CREATE TRIGGER trg_25_nondecreasing BEFORE UPDATE ON cob3_connectors.records
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('last_seen_at');

-- Scope bindings (telemetry design 3.2): immutable once active; activation by
-- the authenticated approver; corrections = retire + new mapping_version.
CREATE FUNCTION cob3_connectors.tg_scope_bindings_activation()
    RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'active' AND (TG_OP = 'INSERT' OR OLD.status <> 'active') THEN
        IF cob3_identity.ctx_principal_id() IS NOT NULL AND NEW.approved_by_principal_id IS DISTINCT FROM cob3_identity.ctx_principal_id() THEN
            RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Activation is recorded by the authenticated approver.';
        END IF;
        NEW.approved_at := COALESCE(NEW.approved_at, pg_catalog.now());
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_connectors.source_scope_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>draft', 'draft>active', 'draft>retired', 'active>retired');
CREATE TRIGGER trg_11_activation BEFORE INSERT OR UPDATE ON cob3_connectors.source_scope_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_connectors.tg_scope_bindings_activation();
CREATE TRIGGER trg_20_freeze BEFORE UPDATE ON cob3_connectors.source_scope_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status', 'valid_until');
