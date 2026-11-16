-- =============================================================================
-- 00  PREFLIGHT, RERUN GUARD, WORKER ROLE AND SCHEMAS
-- -----------------------------------------------------------------------------
-- Implements COB3_Settings_Catalog_Workspace_Consolidated_Design_v1.md on top of
-- foundation 1.0.0. Everything up to the first CREATE is read-only; any failure
-- later rolls the whole statement back.
-- =============================================================================
DECLARE
    _m_component        CONSTANT text    := 'settings_catalog_workspace';
    _m_version          CONSTANT text    := '1.1.0';
    _m_checksum         CONSTANT text    := '@@MIGRATION_CHECKSUM@@';
    _m_server           integer := pg_catalog.current_setting('server_version_num')::integer;
    _m_saved_path       text    := pg_catalog.current_setting('search_path');
    _m_is_super         boolean;
    _m_can_createrole   boolean;
    _m_rec              record;
    _m_table            text;
    _m_schema           text;
    _m_name             text;
    _m_count            bigint;
    _m_tables           text[] := ARRAY[
        -- 2 Identity extension tables (section 4)
        'cob3_identity.principal_emails', 'cob3_identity.email_verification_challenges',
        -- 11 Settings tables
        'cob3_settings.setting_definitions', 'cob3_settings.setting_scopes', 'cob3_settings.setting_values',
        'cob3_settings.setting_change_events', 'cob3_settings.media_objects', 'cob3_settings.branding_profiles',
        'cob3_settings.contact_addresses', 'cob3_settings.notification_endpoints',
        'cob3_settings.notification_preferences', 'cob3_settings.integration_configurations',
        'cob3_settings.automation_policies',
        -- 10 Catalog tables
        'cob3_catalog.asset_types', 'cob3_catalog.domains', 'cob3_catalog.assets', 'cob3_catalog.asset_ownerships',
        'cob3_catalog.asset_external_identifiers', 'cob3_catalog.asset_locations', 'cob3_catalog.asset_relationships',
        'cob3_catalog.tags', 'cob3_catalog.asset_tags', 'cob3_catalog.asset_metadata_versions',
        -- 16 Workspace tables
        'cob3_workspace.projects', 'cob3_workspace.folders', 'cob3_workspace.artifacts', 'cob3_workspace.file_objects',
        'cob3_workspace.artifact_revisions', 'cob3_workspace.artifact_drafts', 'cob3_workspace.bookmarks',
        'cob3_workspace.recent_items', 'cob3_workspace.ui_sessions', 'cob3_workspace.interaction_journeys',
        'cob3_workspace.interaction_events', 'cob3_workspace.interaction_daily', 'cob3_workspace.report_schedules',
        'cob3_workspace.report_recipients', 'cob3_workspace.report_runs', 'cob3_workspace.report_deliveries'
    ];
    -- Append-only ("I") tables: no UPDATE/DELETE, row_version = 1, updated = created.
    _m_append_only      text[] := ARRAY[
        'cob3_settings.setting_change_events', 'cob3_catalog.asset_metadata_versions',
        'cob3_workspace.artifact_revisions', 'cob3_workspace.interaction_events'
    ];
BEGIN
    ---------------------------------------------------------------------------
    -- 0.1 Server version and foundation prerequisite
    ---------------------------------------------------------------------------
    IF _m_server < 150000 THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Migration 002 requires PostgreSQL 15 or later (server_version_num %s found).', _m_server);
    END IF;
    IF pg_catalog.to_regclass('cob3_tenant.foundation_installations') IS NULL
       OR NOT EXISTS (SELECT 1 FROM cob3_tenant.foundation_installations fi
                       WHERE fi.component = 'foundation' AND fi.version = '1.0.0') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = 'Syskriti foundation 1.0.0 is not installed in this database.',
            HINT = 'Run migrations/001_initial_foundation.sql (or INSTALL_FOUNDATION.sql) first. Nothing was changed.';
    END IF;

    ---------------------------------------------------------------------------
    -- 0.2 Rerun guard: verified no-op, or early failure without mutation
    ---------------------------------------------------------------------------
    SELECT fi.version, fi.script_checksum INTO _m_rec
      FROM cob3_tenant.foundation_installations fi
     WHERE fi.component = _m_component
     ORDER BY fi.installed_at DESC
     LIMIT 1;
    IF FOUND THEN
        IF _m_rec.version = _m_version AND _m_rec.script_checksum = _m_checksum THEN
            RAISE NOTICE 'Migration 002 (% %, checksum %...) is already applied in database %. Verified no-op: nothing was changed.',
                _m_component, _m_version, pg_catalog.left(_m_checksum, 12), pg_catalog.current_database();
            RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('A different %s installation exists (version %s, checksum %s). This migration (%s) will not overwrite it.',
                _m_component, _m_rec.version, pg_catalog.left(_m_rec.script_checksum, 12), _m_version),
            HINT = 'Apply a later ordered migration instead. Nothing was changed.';
    END IF;
    IF EXISTS (SELECT 1 FROM cob3_tenant.foundation_installations fi WHERE fi.component = 'catalog_integration') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = 'The separately invoked catalog integration template was already applied. Migration 002 supersedes it and expects the fail-closed foundation state.',
            HINT = 'Investigate the existing cob3_catalog objects. Nothing was changed.';
    END IF;
    FOR _m_rec IN SELECT s FROM (VALUES ('cob3_settings'), ('cob3_catalog'), ('cob3_workspace')) AS v(s) LOOP
        IF pg_catalog.to_regnamespace(_m_rec.s) IS NOT NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = pg_catalog.format('Schema %I already exists without a migration 002 record. Refusing to modify unknown objects.', _m_rec.s),
                HINT = 'Nothing was changed.';
        END IF;
    END LOOP;

    ---------------------------------------------------------------------------
    -- 0.3 Privileges of the migration role
    ---------------------------------------------------------------------------
    SELECT r.rolsuper, r.rolcreaterole INTO _m_is_super, _m_can_createrole
      FROM pg_catalog.pg_roles r WHERE r.rolname = current_user;
    IF NOT _m_is_super
       AND NOT pg_catalog.pg_has_role(current_user, 'cob3_owner', CASE WHEN _m_server >= 160000 THEN 'SET' ELSE 'MEMBER' END) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Migration role %I cannot SET ROLE cob3_owner.', current_user),
            HINT = 'Run as the role that installed the foundation, or GRANT cob3_owner TO <migration role>. Nothing was changed.';
    END IF;
    IF NOT pg_catalog.has_database_privilege(pg_catalog.current_database(), 'CREATE') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Migration role %I lacks CREATE privilege on database %I.', current_user, pg_catalog.current_database()),
            HINT = 'Nothing was changed.';
    END IF;
    SELECT r.rolsuper, r.rolbypassrls, r.rolcreaterole, r.rolcreatedb, r.rolreplication, r.rolcanlogin INTO _m_rec
      FROM pg_catalog.pg_roles r WHERE r.rolname = 'cob3_worker';
    IF FOUND THEN
        IF _m_rec.rolsuper OR _m_rec.rolbypassrls OR _m_rec.rolcreaterole OR _m_rec.rolcreatedb
           OR _m_rec.rolreplication OR _m_rec.rolcanlogin THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = 'Pre-existing role cob3_worker has unsafe attributes (LOGIN/SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION).',
                HINT = 'cob3_worker must be a NOLOGIN group role. Nothing was changed.';
        END IF;
    ELSIF NOT (_m_is_super OR _m_can_createrole) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Role cob3_worker does not exist and migration role %I has no CREATEROLE privilege.', current_user),
            HINT = 'Ask the DBA to run: CREATE ROLE cob3_worker NOLOGIN NOINHERIT; (no password). Nothing was changed.';
    END IF;

    ---------------------------------------------------------------------------
    -- 0.4 Existing foundation data that this migration must convert or refuse
    ---------------------------------------------------------------------------
    SELECT (SELECT pg_catalog.count(*) FROM cob3_identity.access_scopes WHERE scope_type IN ('domain', 'asset'))
         + (SELECT pg_catalog.count(*) FROM cob3_identity.team_domains) INTO _m_count;
    IF _m_count > 0 THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('%s domain/asset scope or team-domain rows exist although the fail-closed guards should have rejected them.', _m_count),
            HINT = 'Investigate before installing real Catalog foreign keys. Nothing was changed.';
    END IF;
    SELECT pg_catalog.count(*) INTO _m_count FROM cob3_identity.user_profiles WHERE avatar_uri IS NOT NULL;
    IF _m_count > 0 THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('%s user profiles still carry a legacy avatar_uri. Section 6.1 requires review/import into Settings media before conversion.', _m_count),
            HINT = 'Import reviewed avatars as media_objects (or clear avatar_uri) first. Nothing was changed.';
    END IF;

    ---------------------------------------------------------------------------
    -- 0.5 Mutations begin
    ---------------------------------------------------------------------------
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);

    -- Trusted background workers (report scheduler, AI runtime, connectors,
    -- search projectors). They act only inside an explicit tenant/organization
    -- worker scope (cob3_identity.set_worker_context) and never bypass RLS.
    IF pg_catalog.to_regrole('cob3_worker') IS NULL THEN
        CREATE ROLE cob3_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    CREATE SCHEMA cob3_settings AUTHORIZATION cob3_owner;
    CREATE SCHEMA cob3_catalog AUTHORIZATION cob3_owner;
    CREATE SCHEMA cob3_workspace AUTHORIZATION cob3_owner;

    SET LOCAL ROLE cob3_owner;
    REVOKE ALL ON SCHEMA cob3_settings, cob3_catalog, cob3_workspace FROM PUBLIC;
