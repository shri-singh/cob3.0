-- =============================================================================
-- 00  PREFLIGHT, RERUN GUARD AND SCHEMAS
-- -----------------------------------------------------------------------------
-- Implements COB3_AI_Agent_State_Design_v1.md (66 tables) plus the scope
-- mapping control table of Observei_Live_Telemetry_Additive_Architecture_v1.md
-- section 3.2, placed in cob3_connectors (it maps connector connections to
-- canonical scope; live obs3_* telemetry schemas are NOT touched).
-- =============================================================================
DECLARE
    _m_component        CONSTANT text    := 'ai_agent_state';
    _m_version          CONSTANT text    := '1.2.0';
    _m_checksum         CONSTANT text    := '@@MIGRATION_CHECKSUM@@';
    _m_server           integer := pg_catalog.current_setting('server_version_num')::integer;
    _m_saved_path       text    := pg_catalog.current_setting('search_path');
    _m_is_super         boolean;
    _m_rec              record;
    _m_def              text[];
    _m_table            text;
    _m_schema           text;
    _m_name             text;
    _m_schemas          CONSTANT text[] := ARRAY['cob3_agent', 'cob3_ai_runtime', 'cob3_copilot', 'cob3_memory',
                                                 'cob3_learning', 'cob3_llmobs', 'cob3_ai_lineage', 'cob3_connectors'];
    _m_tables           text[] := ARRAY[]::text[];   -- filled while creating tables
    -- Design marks "I": append-only/immutable after creation.
    _m_append_only      CONSTANT text[] := ARRAY[
        'cob3_agent.agent_revisions', 'cob3_agent.prompt_versions', 'cob3_agent.tool_revisions',
        'cob3_agent.tool_permission_requirements', 'cob3_agent.skill_versions', 'cob3_agent.skill_files',
        'cob3_agent.agent_tool_bindings', 'cob3_agent.agent_skill_bindings', 'cob3_agent.releases',
        'cob3_ai_runtime.execution_contexts', 'cob3_ai_runtime.run_events', 'cob3_ai_runtime.context_assemblies',
        'cob3_ai_runtime.context_sources', 'cob3_ai_runtime.checkpoints', 'cob3_ai_runtime.checkpoint_writes',
        'cob3_copilot.messages', 'cob3_copilot.message_attachments',
        'cob3_memory.item_revisions', 'cob3_memory.access_events',
        'cob3_learning.feedback', 'cob3_learning.annotations', 'cob3_learning.dataset_versions', 'cob3_learning.examples',
        'cob3_learning.evaluation_results',
        'cob3_llmobs.policy_versions', 'cob3_llmobs.invocation_attempts', 'cob3_llmobs.model_prices',
        'cob3_llmobs.usage_charges', 'cob3_llmobs.guardrail_events',
        'cob3_ai_lineage.nodes', 'cob3_ai_lineage.edges'
    ];
BEGIN
    IF _m_server < 150000 THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Migration 003 requires PostgreSQL 15 or later (server_version_num %s found).', _m_server);
    END IF;
    IF pg_catalog.to_regclass('cob3_tenant.foundation_installations') IS NULL
       OR NOT EXISTS (SELECT 1 FROM cob3_tenant.foundation_installations fi WHERE fi.component = 'foundation' AND fi.version = '1.0.0')
       OR NOT EXISTS (SELECT 1 FROM cob3_tenant.foundation_installations fi WHERE fi.component = 'settings_catalog_workspace' AND fi.version = '1.1.0') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = 'Migration 003 requires foundation 1.0.0 and migration 002 (settings_catalog_workspace 1.1.0).',
            HINT = 'Apply migrations/001 and migrations/002 first. Nothing was changed.';
    END IF;

    SELECT fi.version, fi.script_checksum INTO _m_rec
      FROM cob3_tenant.foundation_installations fi
     WHERE fi.component = _m_component
     ORDER BY fi.installed_at DESC
     LIMIT 1;
    IF FOUND THEN
        IF _m_rec.version = _m_version AND _m_rec.script_checksum = _m_checksum THEN
            RAISE NOTICE 'Migration 003 (% %, checksum %...) is already applied in database %. Verified no-op: nothing was changed.',
                _m_component, _m_version, pg_catalog.left(_m_checksum, 12), pg_catalog.current_database();
            RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('A different %s installation exists (version %s, checksum %s). This migration (%s) will not overwrite it.',
                _m_component, _m_rec.version, pg_catalog.left(_m_rec.script_checksum, 12), _m_version),
            HINT = 'Apply a later ordered migration instead. Nothing was changed.';
    END IF;
    FOREACH _m_schema IN ARRAY _m_schemas LOOP
        IF pg_catalog.to_regnamespace(_m_schema) IS NOT NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = pg_catalog.format('Schema %I already exists without a migration 003 record. Refusing to modify unknown objects.', _m_schema),
                HINT = 'Legacy obs3_* schemas are never touched; investigate the existing cob3 schema. Nothing was changed.';
        END IF;
    END LOOP;
    SELECT r.rolsuper INTO _m_is_super FROM pg_catalog.pg_roles r WHERE r.rolname = current_user;
    IF NOT _m_is_super
       AND NOT pg_catalog.pg_has_role(current_user, 'cob3_owner', CASE WHEN _m_server >= 160000 THEN 'SET' ELSE 'MEMBER' END) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Migration role %I cannot SET ROLE cob3_owner.', current_user),
            HINT = 'Run as the role that installed the foundation. Nothing was changed.';
    END IF;
    IF NOT pg_catalog.has_database_privilege(pg_catalog.current_database(), 'CREATE') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Migration role %I lacks CREATE privilege on database %I.', current_user, pg_catalog.current_database());
    END IF;

    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);
    FOREACH _m_schema IN ARRAY _m_schemas LOOP
        EXECUTE pg_catalog.format('CREATE SCHEMA %I AUTHORIZATION cob3_owner', _m_schema);
    END LOOP;
    SET LOCAL ROLE cob3_owner;
    FOREACH _m_schema IN ARRAY _m_schemas LOOP
        EXECUTE pg_catalog.format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', _m_schema);
    END LOOP;
