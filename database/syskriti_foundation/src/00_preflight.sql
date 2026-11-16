-- =============================================================================
-- 00  PREFLIGHT, RERUN GUARD, ROLES, EXTENSION AND SCHEMAS
-- -----------------------------------------------------------------------------
-- Everything up to the first CREATE statement is read-only. If any preflight
-- check fails, the installer raises before mutating anything. Because the whole
-- installer is one DO statement, any later failure also rolls back completely.
-- =============================================================================
DECLARE
    _i_version          CONSTANT text    := '1.0.0';
    _i_checksum         CONSTANT text    := '@@INSTALLER_CHECKSUM@@';
    _i_min_server       CONSTANT integer := 150000;
    _i_server           integer := pg_catalog.current_setting('server_version_num')::integer;
    _i_saved_path       text    := pg_catalog.current_setting('search_path');
    _i_is_super         boolean;
    _i_can_createrole   boolean;
    _i_ext_installed    boolean;
    _i_rec              record;
    _i_role             record;
    _i_table            text;
    _i_schema           text;
    _i_name             text;
    _i_logical_tables   text[] := ARRAY[
        -- 21 Tenant tables (COB3_Tenant_Schema_Summary_v1.md section 4)
        'cob3_tenant.tenants', 'cob3_tenant.tenant_contacts', 'cob3_tenant.tenant_lifecycle_events',
        'cob3_tenant.provisioning_jobs', 'cob3_tenant.plans', 'cob3_tenant.plan_versions',
        'cob3_tenant.features', 'cob3_tenant.plan_entitlements', 'cob3_tenant.plan_prices',
        'cob3_tenant.billing_accounts', 'cob3_tenant.subscriptions', 'cob3_tenant.subscription_periods',
        'cob3_tenant.subscription_changes', 'cob3_tenant.tenant_entitlement_overrides',
        'cob3_tenant.organization_quota_allocations', 'cob3_tenant.usage_events', 'cob3_tenant.usage_rollups',
        'cob3_tenant.invoices', 'cob3_tenant.invoice_lines', 'cob3_tenant.payment_transactions',
        'cob3_tenant.provider_events',
        -- 27 Identity tables (COP3_Identity_Consolidated_Schema_v1.md section 4)
        'cob3_identity.organizations', 'cob3_identity.principals', 'cob3_identity.user_profiles',
        'cob3_identity.service_accounts', 'cob3_identity.automation_profiles',
        'cob3_identity.organization_memberships', 'cob3_identity.teams', 'cob3_identity.team_memberships',
        'cob3_identity.team_membership_sources', 'cob3_identity.team_domains', 'cob3_identity.permissions',
        'cob3_identity.roles', 'cob3_identity.role_permissions', 'cob3_identity.access_scopes',
        'cob3_identity.role_bindings', 'cob3_identity.tenant_role_bindings', 'cob3_identity.authorization_grants',
        'cob3_identity.authorization_grant_permissions', 'cob3_identity.principal_credentials',
        'cob3_identity.credential_permission_bindings', 'cob3_identity.action_approvals',
        'cob3_identity.identity_providers', 'cob3_identity.external_identities', 'cob3_identity.external_groups',
        'cob3_identity.group_team_mappings', 'cob3_identity.auth_sessions', 'cob3_identity.audit_events'
    ];
    _i_support_tables   text[] := ARRAY['cob3_tenant.foundation_installations', 'cob3_tenant.quota_counters'];
BEGIN
    ---------------------------------------------------------------------------
    -- 0.1 PostgreSQL version
    ---------------------------------------------------------------------------
    IF _i_server < _i_min_server THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Syskriti foundation requires PostgreSQL 15 or later (server_version_num %s found).', _i_server),
            HINT = 'UNIQUE NULLS NOT DISTINCT and PostgreSQL 15 role/privilege semantics are required.';
    END IF;

    ---------------------------------------------------------------------------
    -- 0.2 Rerun guard: verified no-op, or early failure without mutation
    ---------------------------------------------------------------------------
    IF pg_catalog.to_regnamespace('cob3_tenant') IS NOT NULL
       OR pg_catalog.to_regnamespace('cob3_identity') IS NOT NULL THEN
        IF pg_catalog.to_regclass('cob3_tenant.foundation_installations') IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = 'Schema cob3_tenant or cob3_identity already exists but has no foundation installation record. Refusing to modify unknown objects.',
                HINT = 'Install into a database without these schemas, or investigate the existing objects. Nothing was changed.';
        END IF;
        SELECT fi.version, fi.script_checksum
          INTO _i_rec
          FROM cob3_tenant.foundation_installations fi
         WHERE fi.component = 'foundation'
         ORDER BY fi.installed_at DESC
         LIMIT 1;
        IF FOUND AND _i_rec.version = _i_version AND _i_rec.script_checksum = _i_checksum THEN
            RAISE NOTICE 'Syskriti foundation % (checksum %...) is already installed in database %. Verified no-op: nothing was changed.',
                _i_version, pg_catalog.left(_i_checksum, 12), pg_catalog.current_database();
            RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('A different Syskriti foundation installation exists (installed version %s, checksum %s). This fresh installer (version %s) will not overwrite it.',
                COALESCE(_i_rec.version, '<none>'), COALESCE(pg_catalog.left(_i_rec.script_checksum, 12), '<none>'), _i_version),
            HINT = 'Apply ordered upgrade migrations instead of the fresh installer. Nothing was changed.';
    END IF;

    ---------------------------------------------------------------------------
    -- 0.3 Installer privileges
    ---------------------------------------------------------------------------
    SELECT r.rolsuper, r.rolcreaterole
      INTO _i_is_super, _i_can_createrole
      FROM pg_catalog.pg_roles r
     WHERE r.rolname = current_user;

    IF NOT pg_catalog.has_database_privilege(pg_catalog.current_database(), 'CREATE') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKPRE',
            MESSAGE = pg_catalog.format('Installer role %I lacks CREATE privilege on database %I.', current_user, pg_catalog.current_database()),
            HINT = 'Run as the database owner or grant CREATE ON DATABASE to the migration role. Nothing was changed.';
    END IF;

    FOR _i_rec IN
        SELECT v.rolname
          FROM (VALUES ('cob3_owner'), ('cob3_runtime'), ('cob3_provisioner'), ('cob3_commercial_admin')) AS v(rolname)
    LOOP
        SELECT r.rolsuper, r.rolbypassrls, r.rolcreaterole, r.rolcreatedb, r.rolreplication
          INTO _i_role
          FROM pg_catalog.pg_roles r
         WHERE r.rolname = _i_rec.rolname;
        IF FOUND THEN
            IF _i_role.rolsuper OR _i_role.rolbypassrls OR _i_role.rolcreaterole
               OR _i_role.rolcreatedb OR _i_role.rolreplication THEN
                RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                    MESSAGE = pg_catalog.format('Pre-existing role %I has unsafe attributes (SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION).', _i_rec.rolname),
                    HINT = 'Foundation roles must be NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION. Nothing was changed.';
            END IF;
        ELSIF NOT (_i_is_super OR _i_can_createrole) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = pg_catalog.format('Role %I does not exist and installer role %I has no CREATEROLE privilege.', _i_rec.rolname, current_user),
                HINT = 'Ask the DBA to pre-provision: CREATE ROLE cob3_owner NOLOGIN NOINHERIT; CREATE ROLE cob3_runtime NOLOGIN NOINHERIT; CREATE ROLE cob3_provisioner NOLOGIN NOINHERIT; CREATE ROLE cob3_commercial_admin NOLOGIN NOINHERIT; GRANT cob3_owner TO <migration role>; (no passwords). Nothing was changed.';
        END IF;
    END LOOP;

    IF pg_catalog.to_regrole('cob3_owner') IS NOT NULL AND NOT _i_is_super THEN
        IF NOT pg_catalog.pg_has_role(current_user, 'cob3_owner', CASE WHEN _i_server >= 160000 THEN 'SET' ELSE 'MEMBER' END)
           AND NOT pg_catalog.pg_has_role(current_user, 'cob3_owner', 'USAGE WITH ADMIN OPTION')
           AND NOT (_i_can_createrole AND _i_server < 160000) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = pg_catalog.format('Installer role %I cannot SET ROLE cob3_owner and cannot grant it to itself.', current_user),
                HINT = 'GRANT cob3_owner TO <migration role>; Nothing was changed.';
        END IF;
    END IF;

    ---------------------------------------------------------------------------
    -- 0.4 Extension btree_gist (required for tenant-qualified exclusion
    --     constraints that prevent overlapping contract/override/allocation
    --     windows). Installed into schema public as a documented exception.
    ---------------------------------------------------------------------------
    _i_ext_installed := EXISTS (SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = 'btree_gist');
    IF NOT _i_ext_installed THEN
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions a WHERE a.name = 'btree_gist') THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = 'Required extension btree_gist is not available on this server.',
                HINT = 'Install the PostgreSQL contrib package (or enable btree_gist on the managed service). The installer never omits the overlap invariants. Nothing was changed.';
        END IF;
        IF pg_catalog.to_regnamespace('public') IS NULL
           OR NOT pg_catalog.has_schema_privilege('public', 'CREATE') THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = 'btree_gist is not installed and the installer cannot create it in schema public.',
                HINT = 'Ask the DBA to run: CREATE EXTENSION btree_gist; in this database. Nothing was changed.';
        END IF;
        IF NOT _i_is_super AND NOT EXISTS (
               SELECT 1 FROM pg_catalog.pg_available_extension_versions v
                WHERE v.name = 'btree_gist' AND v.trusted) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKPRE',
                MESSAGE = 'btree_gist is not installed, is not a trusted extension here, and the installer is not a superuser.',
                HINT = 'Ask the DBA to run: CREATE EXTENSION btree_gist; in this database. Nothing was changed.';
        END IF;
    END IF;

    ---------------------------------------------------------------------------
    -- 0.5 Mutations begin. Pin a safe search_path for the remainder of the
    --     installer; every object reference below is schema-qualified.
    ---------------------------------------------------------------------------
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);

    IF NOT _i_ext_installed THEN
        CREATE EXTENSION btree_gist SCHEMA public;
    END IF;

    IF pg_catalog.to_regrole('cob3_owner') IS NULL THEN
        CREATE ROLE cob3_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
    IF pg_catalog.to_regrole('cob3_runtime') IS NULL THEN
        CREATE ROLE cob3_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
    IF pg_catalog.to_regrole('cob3_provisioner') IS NULL THEN
        CREATE ROLE cob3_provisioner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
    IF pg_catalog.to_regrole('cob3_commercial_admin') IS NULL THEN
        CREATE ROLE cob3_commercial_admin NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT _i_is_super
       AND NOT pg_catalog.pg_has_role(current_user, 'cob3_owner', CASE WHEN _i_server >= 160000 THEN 'SET' ELSE 'MEMBER' END) THEN
        GRANT cob3_owner TO CURRENT_USER;
    END IF;

    CREATE SCHEMA cob3_tenant AUTHORIZATION cob3_owner;
    CREATE SCHEMA cob3_identity AUTHORIZATION cob3_owner;

    -- All remaining objects are created by, and therefore owned by, cob3_owner.
    SET LOCAL ROLE cob3_owner;

    REVOKE ALL ON SCHEMA cob3_tenant, cob3_identity FROM PUBLIC;
    -- Per-schema default privileges can only ADD; removing the built-in PUBLIC
    -- EXECUTE default must be done role-wide for the owner role. cob3_owner owns
    -- nothing outside these two schemas, so this is scoped to the foundation.
    ALTER DEFAULT PRIVILEGES FOR ROLE cob3_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE cob3_owner REVOKE USAGE ON TYPES FROM PUBLIC;
