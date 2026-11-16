-- =============================================================================
-- SYSKRITI FOUNDATION -- READ-ONLY VERIFICATION REPORT
-- -----------------------------------------------------------------------------
-- One SELECT statement; it reads only system catalogs (and the version table
-- through query_to_xml when it exists). Safe to run in DBeaver/pgAdmin/psql
-- at any time, including before installation. It changes nothing.
--
-- status values:
--   PASS     structural expectation met
--   FAIL     expectation not met -- investigate before use
--   WARN     not wrong by itself but needs a human decision
--   PENDING  intentionally unavailable (Catalog integration not installed)
--   INFO     facts for the record
-- A PASS on policies/triggers means the objects EXIST with the expected
-- shape. It does not prove they are secure; behavior is proven by the test
-- suite (database/syskriti_foundation/tests) run under non-owner roles.
-- =============================================================================
WITH RECURSIVE expected (schema_name, table_name, kind) AS (
    VALUES
    ('cob3_tenant', 'tenants', 'logical'), ('cob3_tenant', 'tenant_contacts', 'logical'),
    ('cob3_tenant', 'tenant_lifecycle_events', 'logical'), ('cob3_tenant', 'provisioning_jobs', 'logical'),
    ('cob3_tenant', 'plans', 'logical'), ('cob3_tenant', 'plan_versions', 'logical'), ('cob3_tenant', 'features', 'logical'),
    ('cob3_tenant', 'plan_entitlements', 'logical'), ('cob3_tenant', 'plan_prices', 'logical'),
    ('cob3_tenant', 'billing_accounts', 'logical'), ('cob3_tenant', 'subscriptions', 'logical'),
    ('cob3_tenant', 'subscription_periods', 'logical'), ('cob3_tenant', 'subscription_changes', 'logical'),
    ('cob3_tenant', 'tenant_entitlement_overrides', 'logical'), ('cob3_tenant', 'organization_quota_allocations', 'logical'),
    ('cob3_tenant', 'usage_events', 'logical'), ('cob3_tenant', 'usage_rollups', 'logical'), ('cob3_tenant', 'invoices', 'logical'),
    ('cob3_tenant', 'invoice_lines', 'logical'), ('cob3_tenant', 'payment_transactions', 'logical'),
    ('cob3_tenant', 'provider_events', 'logical'),
    ('cob3_identity', 'organizations', 'logical'), ('cob3_identity', 'principals', 'logical'),
    ('cob3_identity', 'user_profiles', 'logical'), ('cob3_identity', 'service_accounts', 'logical'),
    ('cob3_identity', 'automation_profiles', 'logical'), ('cob3_identity', 'organization_memberships', 'logical'),
    ('cob3_identity', 'teams', 'logical'), ('cob3_identity', 'team_memberships', 'logical'),
    ('cob3_identity', 'team_membership_sources', 'logical'), ('cob3_identity', 'team_domains', 'logical'),
    ('cob3_identity', 'permissions', 'logical'), ('cob3_identity', 'roles', 'logical'),
    ('cob3_identity', 'role_permissions', 'logical'), ('cob3_identity', 'access_scopes', 'logical'),
    ('cob3_identity', 'role_bindings', 'logical'), ('cob3_identity', 'tenant_role_bindings', 'logical'),
    ('cob3_identity', 'authorization_grants', 'logical'), ('cob3_identity', 'authorization_grant_permissions', 'logical'),
    ('cob3_identity', 'principal_credentials', 'logical'), ('cob3_identity', 'credential_permission_bindings', 'logical'),
    ('cob3_identity', 'action_approvals', 'logical'), ('cob3_identity', 'identity_providers', 'logical'),
    ('cob3_identity', 'external_identities', 'logical'), ('cob3_identity', 'external_groups', 'logical'),
    ('cob3_identity', 'group_team_mappings', 'logical'), ('cob3_identity', 'auth_sessions', 'logical'),
    ('cob3_identity', 'audit_events', 'logical'),
    ('cob3_tenant', 'foundation_installations', 'support'), ('cob3_tenant', 'quota_counters', 'support')
),
runtime_tables (table_name) AS (
    -- tables the runtime role is expected to read through at least one runtime policy
    SELECT e.table_name FROM expected e
     WHERE e.table_name NOT IN ('provisioning_jobs', 'provider_events', 'quota_counters', 'foundation_installations')
),
tbl AS (
    SELECT n.nspname AS schema_name, c.relname AS table_name, c.oid, c.relrowsecurity, c.relforcerowsecurity,
           pg_catalog.pg_get_userbyid(c.relowner) AS owner_name
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('cob3_tenant', 'cob3_identity') AND c.relkind IN ('r', 'p')
       -- Tables added to cob3_identity by ordered migration 002 are verified by
       -- VERIFY_MODULES.sql, not counted against the 1.0.0 foundation shape.
       AND (n.nspname, c.relname) NOT IN (('cob3_identity', 'principal_emails'), ('cob3_identity', 'email_verification_challenges'))
),
installed AS (
    SELECT CASE WHEN pg_catalog.to_regclass('cob3_tenant.foundation_installations') IS NOT NULL THEN
               (pg_catalog.xpath('/row/v/text()', pg_catalog.query_to_xml(
                   'select version || '' / '' || script_checksum || '' / '' || installed_at::text || '' / by '' || installed_by as v
                      from cob3_tenant.foundation_installations where component = ''foundation''
                     order by installed_at desc limit 1', false, true, '')))[1]::text
           END AS foundation,
           CASE WHEN pg_catalog.to_regclass('cob3_tenant.foundation_installations') IS NOT NULL THEN
               (pg_catalog.xpath('/row/v/text()', pg_catalog.query_to_xml(
                   'select count(*) as v from cob3_tenant.foundation_installations where component = ''catalog_integration''',
                   false, true, '')))[1]::text
           END AS catalog_rows
),
fn AS (
    SELECT p.oid, p.proname, n.nspname, p.prosecdef, p.proconfig
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('cob3_tenant', 'cob3_identity')
),
fk AS (
    SELECT k.oid, k.conrelid, k.conname, k.conkey, k.convalidated
      FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_namespace n ON n.oid = k.connamespace
     WHERE n.nspname IN ('cob3_tenant', 'cob3_identity') AND k.contype = 'f'
),
foundation_roles (rolname) AS (VALUES ('cob3_owner'), ('cob3_runtime'), ('cob3_provisioner'), ('cob3_commercial_admin')),
-- Explicit, privilege-bearing role memberships (transitive). Superusers'
-- implicit membership is ignored, and on PostgreSQL 16+ admin-only grants
-- (INHERIT FALSE, SET FALSE, e.g. the automatic CREATEROLE creator grant)
-- confer no privileges and are ignored as well.
edge (member, roleid) AS (
    SELECT am.member, am.roleid
      FROM pg_catalog.pg_auth_members am
     WHERE COALESCE((pg_catalog.to_jsonb(am) ->> 'inherit_option')::boolean, true)
        OR COALESCE((pg_catalog.to_jsonb(am) ->> 'set_option')::boolean, true)
),
membership (member, roleid) AS (
    SELECT e.member, e.roleid FROM edge e
    UNION
    SELECT m.member, e.roleid FROM membership m JOIN edge e ON e.member = m.roleid
),
role_holders AS (
    SELECT r.oid, r.rolname, r.rolsuper, r.rolbypassrls, r.rolcanlogin,
           bool_or(fr.rolname = 'cob3_owner')            AS in_owner,
           bool_or(fr.rolname = 'cob3_runtime')          AS in_runtime,
           bool_or(fr.rolname = 'cob3_provisioner')      AS in_provisioner,
           bool_or(fr.rolname = 'cob3_commercial_admin') AS in_commercial
      FROM pg_catalog.pg_roles r
      JOIN membership m ON m.member = r.oid
      JOIN pg_catalog.pg_roles fr ON fr.oid = m.roleid AND fr.rolname IN (SELECT rolname FROM foundation_roles)
     WHERE r.rolname NOT IN (SELECT rolname FROM foundation_roles)
     GROUP BY r.oid, r.rolname, r.rolsuper, r.rolbypassrls, r.rolcanlogin
),
checks AS (
    SELECT 10 AS ord, 'installation record' AS check_name,
           CASE WHEN i.foundation IS NULL THEN 'FAIL' ELSE 'PASS' END AS status,
           COALESCE('foundation ' || i.foundation, 'cob3_tenant.foundation_installations missing or empty: foundation not installed') AS detail
      FROM installed i
    UNION ALL
    SELECT 20, 'postgresql version',
           CASE WHEN pg_catalog.current_setting('server_version_num')::int >= 150000 THEN 'PASS' ELSE 'FAIL' END,
           'server ' || pg_catalog.current_setting('server_version') || ' (minimum 15; tested on 18.1)'
    UNION ALL
    SELECT 30, 'extension btree_gist',
           CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'btree_gist') THEN 'PASS' ELSE 'FAIL' END,
           COALESCE((SELECT 'installed in schema ' || n.nspname || ' version ' || e.extversion
                       FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
                      WHERE e.extname = 'btree_gist'), 'not installed (required by overlap exclusion constraints)')
    UNION ALL
    SELECT 40, 'expected tables present',
           CASE WHEN COUNT(*) FILTER (WHERE t.oid IS NULL) = 0 THEN 'PASS' ELSE 'FAIL' END,
           (COUNT(*) FILTER (WHERE t.oid IS NOT NULL AND e.kind = 'logical'))::text || '/48 logical, '
           || (COUNT(*) FILTER (WHERE t.oid IS NOT NULL AND e.kind = 'support'))::text || '/2 support'
           || COALESCE('; missing: ' || pg_catalog.string_agg(CASE WHEN t.oid IS NULL THEN e.schema_name || '.' || e.table_name END, ', '), '')
      FROM expected e LEFT JOIN tbl t ON t.schema_name = e.schema_name AND t.table_name = e.table_name
    UNION ALL
    SELECT 41, 'unexpected tables in foundation schemas',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'WARN' END,
           COALESCE(pg_catalog.string_agg(t.schema_name || '.' || t.table_name, ', '), 'none')
      FROM tbl t LEFT JOIN expected e ON e.schema_name = t.schema_name AND e.table_name = t.table_name
     WHERE e.table_name IS NULL
    UNION ALL
    SELECT 50, 'RLS enabled and forced',
           CASE WHEN COUNT(*) FILTER (WHERE NOT (t.relrowsecurity AND t.relforcerowsecurity)) = 0 AND COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END,
           (COUNT(*) FILTER (WHERE t.relrowsecurity AND t.relforcerowsecurity))::text || '/' || COUNT(*)::text || ' tables'
           || COALESCE('; not forced: ' || pg_catalog.string_agg(CASE WHEN NOT (t.relrowsecurity AND t.relforcerowsecurity) THEN t.table_name END, ', '), '')
      FROM tbl t
    UNION ALL
    SELECT 51, 'owner policy on every table',
           CASE WHEN COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                     WHERE p.schemaname = t.schema_name AND p.tablename = t.table_name AND 'cob3_owner' = ANY (p.roles))) = 0
                     AND COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END,
           'trusted routine/migration context; presence only'
      FROM tbl t
    UNION ALL
    SELECT 52, 'runtime policies present',
           CASE WHEN COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                     WHERE p.tablename = r.table_name AND 'cob3_runtime' = ANY (p.roles))) = 0 THEN 'PASS' ELSE 'FAIL' END,
           (SELECT COUNT(*) FROM pg_catalog.pg_policies p WHERE p.schemaname IN ('cob3_tenant', 'cob3_identity'))::text
           || ' policies total; presence only -- security behavior is validated by tests under non-owner roles'
      FROM runtime_tables r
    UNION ALL
    SELECT 53, 'policies with unconditional runtime access',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(p.tablename || '.' || p.policyname, ', '), 'none (every runtime policy has a predicate)')
      FROM pg_catalog.pg_policies p
     WHERE p.schemaname IN ('cob3_tenant', 'cob3_identity') AND 'cob3_runtime' = ANY (p.roles)
       AND (p.qual = 'true' OR p.with_check = 'true')
    UNION ALL
    SELECT 60, 'stamping and truncate-guard triggers',
           CASE WHEN (SELECT COUNT(*) FROM pg_catalog.pg_trigger g JOIN tbl t ON t.oid = g.tgrelid WHERE g.tgname = 'trg_90_stamp_row') = 48
                 AND (SELECT COUNT(*) FROM pg_catalog.pg_trigger g JOIN tbl t ON t.oid = g.tgrelid WHERE g.tgname = 'trg_00_block_truncate') = 50
                THEN 'PASS' ELSE 'FAIL' END,
           (SELECT COUNT(*) FROM pg_catalog.pg_trigger g JOIN tbl t ON t.oid = g.tgrelid WHERE g.tgname = 'trg_90_stamp_row')::text || '/48 stamp, '
           || (SELECT COUNT(*) FROM pg_catalog.pg_trigger g JOIN tbl t ON t.oid = g.tgrelid WHERE g.tgname = 'trg_00_block_truncate')::text || '/50 truncate guards, '
           || (SELECT COUNT(*) FROM pg_catalog.pg_trigger g JOIN tbl t ON t.oid = g.tgrelid WHERE NOT g.tgisinternal)::text || ' user triggers total'
    UNION ALL
    SELECT 61, 'append-only triggers',
           CASE WHEN COUNT(*) = 5 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(t.table_name, ', ' ORDER BY t.table_name), 'none')
      FROM pg_catalog.pg_trigger g JOIN tbl t ON t.oid = g.tgrelid WHERE g.tgname = 'trg_05_append_only'
    UNION ALL
    SELECT 62, 'deferred integrity triggers',
           CASE WHEN COUNT(*) FILTER (WHERE g.tgdeferrable AND g.tginitdeferred) = 7 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(t.table_name || '.' || g.tgname, ', ' ORDER BY t.table_name), 'none')
      FROM pg_catalog.pg_trigger g JOIN tbl t ON t.oid = g.tgrelid
     WHERE g.tgname IN ('trg_80_exactly_one_subtype', 'trg_80_lifecycle_recorded', 'trg_81_last_tenant_admin')
    UNION ALL
    SELECT 63, 'deferred self-membership foreign keys',
           CASE WHEN COUNT(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(k.conname, ', '), 'none')
      FROM pg_catalog.pg_constraint k
     WHERE k.conname IN ('service_accounts_self_membership_fk', 'automation_profiles_self_membership_fk')
       AND k.condeferrable AND k.condeferred
    UNION ALL
    SELECT 70, 'overlap exclusion constraints',
           CASE WHEN COUNT(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(k.conname, ', ' ORDER BY k.conname), 'none')
      FROM pg_catalog.pg_constraint k JOIN tbl t ON t.oid = k.conrelid WHERE k.contype = 'x'
    UNION ALL
    SELECT 71, 'key partial unique indexes',
           CASE WHEN COUNT(*) = 6 THEN 'PASS' ELSE 'FAIL' END,
           COUNT(*)::text || '/6: ' || COALESCE(pg_catalog.string_agg(c.relname, ', ' ORDER BY c.relname), '')
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
     WHERE i.indisunique AND c.relname IN ('subscriptions_one_live_per_tenant_uix', 'authorization_grants_one_active_delegated_uix',
           'role_bindings_active_principal_uix', 'tenant_role_bindings_active_uix', 'tenant_contacts_primary_per_type_uix',
           'billing_accounts_provider_customer_uix')
    UNION ALL
    SELECT 72, 'constraints by type',
           'INFO',
           pg_catalog.string_agg(x.contype || '=' || x.n, ', ' ORDER BY x.contype)
      FROM (SELECT k.contype::text AS contype, COUNT(*)::text AS n
              FROM pg_catalog.pg_constraint k JOIN tbl t ON t.oid = k.conrelid GROUP BY k.contype) x
    UNION ALL
    SELECT 73, 'unvalidated (NOT VALID) constraints',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(fk.conname, ', '), 'none')
      FROM fk WHERE NOT fk.convalidated
    UNION ALL
    SELECT 74, 'foreign keys with covering index',
           CASE WHEN COUNT(*) FILTER (WHERE NOT covered) = 0 THEN 'PASS' ELSE 'WARN' END,
           (COUNT(*) FILTER (WHERE covered))::text || '/' || COUNT(*)::text
           || COALESCE('; uncovered: ' || pg_catalog.string_agg(CASE WHEN NOT covered THEN conname END, ', '), '')
      FROM (SELECT fk.conname, EXISTS (
                SELECT 1 FROM pg_catalog.pg_index i
                 WHERE i.indrelid = fk.conrelid
                   AND (i.indkey::int2[])[0:pg_catalog.array_length(fk.conkey, 1) - 1] @> fk.conkey
                   AND (i.indkey::int2[])[0:pg_catalog.array_length(fk.conkey, 1) - 1] <@ fk.conkey) AS covered
              FROM fk) x
    UNION ALL
    SELECT 80, 'object ownership',
           CASE WHEN COUNT(*) FILTER (WHERE t.owner_name <> 'cob3_owner') = 0 AND COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END,
           'all tables owned by cob3_owner: ' || (COUNT(*) FILTER (WHERE t.owner_name <> 'cob3_owner') = 0)::text
      FROM tbl t
    UNION ALL
    SELECT 81, 'functions executable by PUBLIC',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(fn.proname, ', '), 'none')
      FROM fn WHERE pg_catalog.has_function_privilege('public', fn.oid, 'EXECUTE')
    UNION ALL
    SELECT 82, 'SECURITY DEFINER functions with pinned search_path',
           CASE WHEN COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(COALESCE(fn.proconfig, '{}')) s
                                                         WHERE s = 'search_path=pg_catalog, pg_temp')) = 0 THEN 'PASS' ELSE 'FAIL' END,
           (COUNT(*))::text || ' SECURITY DEFINER functions; all owned by cob3_owner'
      FROM fn WHERE fn.prosecdef
    UNION ALL
    SELECT 90, 'foundation roles and attributes',
           CASE WHEN COUNT(r.rolname) = 4 AND COUNT(*) FILTER (WHERE r.rolsuper OR r.rolbypassrls OR r.rolcreaterole
                                                             OR r.rolcreatedb OR r.rolreplication) = 0
                THEN 'PASS' ELSE 'FAIL' END,
           pg_catalog.string_agg(f.rolname || CASE WHEN r.rolname IS NULL THEN ' (MISSING)'
                                                   WHEN r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication THEN ' (UNSAFE)'
                                                   WHEN r.rolcanlogin THEN ' (login)' ELSE ' (nologin)' END, ', ')
      FROM foundation_roles f LEFT JOIN pg_catalog.pg_roles r ON r.rolname = f.rolname
    UNION ALL
    SELECT 91, 'unsafe members of runtime roles',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(h.rolname, ', '),
                    'none (no runtime/provisioner/commercial member is superuser, BYPASSRLS or also holds cob3_owner)')
      FROM role_holders h
     WHERE (h.in_runtime OR h.in_provisioner OR h.in_commercial)
       AND (h.rolsuper OR h.rolbypassrls OR h.in_owner)
    UNION ALL
    SELECT 92, 'logins holding more than one foundation role',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'WARN' END,
           COALESCE(pg_catalog.string_agg(h.rolname, ', '), 'none')
      FROM role_holders h
     WHERE h.rolcanlogin AND (h.in_runtime::int + h.in_provisioner::int + h.in_commercial::int) > 1
    UNION ALL
    SELECT 95, 'role holders (explicit memberships)',
           'INFO',
           COALESCE(pg_catalog.string_agg(h.rolname || ' -> '
               || pg_catalog.concat_ws('+', CASE WHEN h.in_owner THEN 'owner' END, CASE WHEN h.in_runtime THEN 'runtime' END,
                                       CASE WHEN h.in_provisioner THEN 'provisioner' END, CASE WHEN h.in_commercial THEN 'commercial' END),
               ', ' ORDER BY h.rolname), 'none')
      FROM role_holders h
    UNION ALL
    SELECT 93, 'secret digest columns hidden from runtime',
           CASE WHEN pg_catalog.to_regclass('cob3_identity.principal_credentials') IS NULL
                     OR pg_catalog.to_regrole('cob3_runtime') IS NULL THEN 'FAIL'
                WHEN NOT pg_catalog.has_column_privilege('cob3_runtime', 'cob3_identity.principal_credentials', 'secret_digest', 'SELECT')
                     AND NOT pg_catalog.has_column_privilege('cob3_runtime', 'cob3_identity.auth_sessions', 'session_handle_digest', 'SELECT')
                     AND NOT pg_catalog.has_column_privilege('cob3_runtime', 'cob3_identity.auth_sessions', 'refresh_token_digest', 'SELECT')
                THEN 'PASS' ELSE 'FAIL' END,
           'principal_credentials.secret_digest, auth_sessions.session_handle_digest/refresh_token_digest'
    UNION ALL
    SELECT 94, 'runtime cannot write audit or usage directly',
           CASE WHEN pg_catalog.to_regrole('cob3_runtime') IS NULL OR pg_catalog.to_regclass('cob3_identity.audit_events') IS NULL THEN 'FAIL'
                WHEN NOT pg_catalog.has_table_privilege('cob3_runtime', 'cob3_identity.audit_events', 'INSERT, UPDATE, DELETE, TRUNCATE')
                     AND NOT pg_catalog.has_table_privilege('cob3_runtime', 'cob3_tenant.usage_events', 'INSERT, UPDATE, DELETE, TRUNCATE')
                     AND NOT pg_catalog.has_table_privilege('cob3_runtime', 'cob3_identity.authorization_grants', 'INSERT, UPDATE, DELETE')
                     AND NOT pg_catalog.has_table_privilege('cob3_runtime', 'cob3_identity.principal_credentials', 'INSERT, UPDATE, DELETE')
                THEN 'PASS' ELSE 'FAIL' END,
           'audit/usage/grants/credentials are written only through SECURITY DEFINER routines'
    UNION ALL
    SELECT 100, 'core platform feature definitions',
           CASE WHEN pg_catalog.to_regclass('cob3_tenant.features') IS NULL THEN 'FAIL' ELSE 'INFO' END,
           'expected core features: organizations.max, humans.max, service_accounts.max, automations.max, api_credentials.max, automation.enabled, sso.enabled (seeded by installer; plans/prices are never seeded)'
    UNION ALL
    SELECT 200, 'catalog integration',
           'PENDING',
           CASE WHEN pg_catalog.to_regnamespace('cob3_catalog') IS NULL THEN 'schema cob3_catalog absent; ' ELSE 'schema cob3_catalog exists; ' END
           || 'catalog_integration records: ' || COALESCE(i.catalog_rows, '0')
           || '; Catalog FKs installed: '
           || (SELECT COUNT(*) FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_class c ON c.oid = k.confrelid
                 JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE k.contype = 'f' AND n.nspname = 'cob3_catalog')::text
           || '. Domain/asset scopes, team_domains and resource-dependent authorization FAIL CLOSED until future_integrations/catalog_integration.sql.template is applied.'
      FROM installed i
     WHERE COALESCE(i.catalog_rows, '0') = '0'
    UNION ALL
    SELECT 200, 'catalog integration', 'PASS', 'catalog_integration component recorded (' || i.catalog_rows || ' rows)'
      FROM installed i WHERE COALESCE(i.catalog_rows, '0') <> '0'
)
SELECT ord, check_name, status, detail
  FROM checks
 ORDER BY ord, check_name;
