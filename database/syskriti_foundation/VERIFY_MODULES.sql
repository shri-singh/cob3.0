-- =============================================================================
-- SYSKRITI FOUNDATION -- READ-ONLY VERIFICATION OF ORDERED MIGRATIONS 002/003
-- -----------------------------------------------------------------------------
-- One SELECT statement over system catalogs and the installation record. Safe
-- to run at any time in DBeaver/pgAdmin/psql; it changes nothing. Run
-- VERIFY_FOUNDATION.sql for the 1.0.0 foundation itself.
-- status: PASS | FAIL | PENDING (migration not applied yet) | INFO
-- Presence checks only: security BEHAVIOUR is proven by tests/test_10_* and
-- tests/test_11_* under the real non-owner roles.
-- =============================================================================
WITH expected (component, schema_name, tables) AS (
    VALUES ('settings_catalog_workspace', 'cob3_settings', 11), ('settings_catalog_workspace', 'cob3_catalog', 10),
           ('settings_catalog_workspace', 'cob3_workspace', 16),
           ('ai_agent_state', 'cob3_agent', 14), ('ai_agent_state', 'cob3_ai_runtime', 14), ('ai_agent_state', 'cob3_copilot', 7),
           ('ai_agent_state', 'cob3_memory', 6), ('ai_agent_state', 'cob3_learning', 8), ('ai_agent_state', 'cob3_llmobs', 10),
           ('ai_agent_state', 'cob3_ai_lineage', 2), ('ai_agent_state', 'cob3_connectors', 6)
),
installed AS (
    SELECT CASE WHEN pg_catalog.to_regclass('cob3_tenant.foundation_installations') IS NOT NULL THEN
               (SELECT pg_catalog.array_agg(x::text) FROM pg_catalog.unnest(pg_catalog.xpath('//row/c/text()', pg_catalog.query_to_xml(
                    'SELECT component || '' '' || version AS c FROM cob3_tenant.foundation_installations', false, false, ''))) AS x)
           END AS components
),
module_tables AS (
    SELECT n.nspname AS schema_name, c.relname AS table_name, c.oid, c.relrowsecurity, c.relforcerowsecurity, c.relowner
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'r'
       AND (n.nspname IN (SELECT schema_name FROM expected)
            OR (n.nspname, c.relname) IN (('cob3_identity', 'principal_emails'), ('cob3_identity', 'email_verification_challenges')))
),
checks (sort_key, check_name, status, detail) AS (
    SELECT 10, 'component settings_catalog_workspace',
           CASE WHEN 'settings_catalog_workspace 1.1.0' = ANY (COALESCE(i.components, ARRAY[]::text[])) THEN 'PASS' ELSE 'PENDING' END,
           COALESCE(pg_catalog.array_to_string(i.components, ', '), 'foundation not installed')
      FROM installed i
    UNION ALL
    SELECT 11, 'component ai_agent_state',
           CASE WHEN 'ai_agent_state 1.2.0' = ANY (COALESCE(i.components, ARRAY[]::text[])) THEN 'PASS' ELSE 'PENDING' END,
           'requires settings_catalog_workspace 1.1.0'
      FROM installed i
    UNION ALL
    SELECT 20, 'tables per schema ' || e.schema_name,
           CASE WHEN COUNT(t.oid) = e.tables THEN 'PASS' WHEN COUNT(t.oid) = 0 THEN 'PENDING' ELSE 'FAIL' END,
           COUNT(t.oid)::text || '/' || e.tables::text
      FROM expected e LEFT JOIN module_tables t ON t.schema_name = e.schema_name
     GROUP BY e.schema_name, e.tables
    UNION ALL
    SELECT 30, 'RLS enabled and forced',
           CASE WHEN COUNT(*) FILTER (WHERE NOT (relrowsecurity AND relforcerowsecurity)) = 0 THEN 'PASS' ELSE 'FAIL' END,
           (COUNT(*) FILTER (WHERE relrowsecurity AND relforcerowsecurity))::text || '/' || COUNT(*)::text || ' module tables'
      FROM module_tables
    UNION ALL
    SELECT 31, 'owned by cob3_owner',
           CASE WHEN COUNT(*) FILTER (WHERE pg_catalog.pg_get_userbyid(relowner) <> 'cob3_owner') = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(CASE WHEN pg_catalog.pg_get_userbyid(relowner) <> 'cob3_owner' THEN schema_name || '.' || table_name END, ', '), 'all')
      FROM module_tables
    UNION ALL
    SELECT 32, 'owner policy on every table',
           CASE WHEN COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                     WHERE p.schemaname = t.schema_name AND p.tablename = t.table_name AND 'cob3_owner' = ANY (p.roles))) = 0 THEN 'PASS' ELSE 'FAIL' END,
           'presence only'
      FROM module_tables t
    UNION ALL
    SELECT 33, 'runtime policies without a predicate',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(p.schemaname || '.' || p.tablename || '.' || p.policyname, ', '), 'none')
      FROM pg_catalog.pg_policies p
     WHERE (p.schemaname IN (SELECT schema_name FROM expected) OR p.tablename IN ('principal_emails', 'email_verification_challenges'))
       AND 'cob3_runtime' = ANY (p.roles) AND p.permissive = 'PERMISSIVE' AND (p.qual = 'true' OR p.with_check = 'true')
    UNION ALL
    SELECT 40, 'mandatory columns (tenant/org/created/updated/metadata/row_version)',
           CASE WHEN COUNT(*) FILTER (WHERE m.n <> 8) = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(CASE WHEN m.n <> 8 THEN m.t END, ', '), 'all tables have all eight')
      FROM (SELECT t.schema_name || '.' || t.table_name AS t,
                   (SELECT COUNT(*) FROM pg_catalog.pg_attribute a WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
                       AND a.attname IN ('tenant_id', 'organization_id', 'created_at', 'created_by', 'updated_at', 'updated_by',
                                         'metadata', 'row_version')) AS n
              FROM module_tables t) m
    UNION ALL
    SELECT 41, 'stamping and truncate-guard triggers',
           CASE WHEN COUNT(*) FILTER (WHERE NOT (EXISTS (SELECT 1 FROM pg_catalog.pg_trigger g WHERE g.tgrelid = t.oid AND g.tgname = 'trg_90_stamp_row')
                                               AND EXISTS (SELECT 1 FROM pg_catalog.pg_trigger g WHERE g.tgrelid = t.oid AND g.tgname = 'trg_00_block_truncate'))) = 0
                THEN 'PASS' ELSE 'FAIL' END,
           COUNT(*)::text || ' module tables checked'
      FROM module_tables t
    UNION ALL
    SELECT 42, 'append-only tables are guarded',
           'INFO',
           (SELECT COUNT(*) FROM pg_catalog.pg_trigger g JOIN module_tables t ON t.oid = g.tgrelid WHERE g.tgname = 'trg_05_append_only')::text
           || ' tables with trg_05_append_only (002: 4, 003: 31)'
    UNION ALL
    SELECT 50, 'foreign keys covered by an index',
           CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(c.conrelid::regclass::text || '.' || c.conname, ', '), 'all cob3_* foreign keys indexed')
      FROM pg_catalog.pg_constraint c
     WHERE c.contype = 'f' AND c.connamespace::regnamespace::text LIKE 'cob3\_%'
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                        WHERE i.indrelid = c.conrelid
                          AND (i.indkey::int2[])[0:pg_catalog.array_length(c.conkey, 1) - 1] @> c.conkey
                          AND (i.indkey::int2[])[0:pg_catalog.array_length(c.conkey, 1) - 1] <@ c.conkey)
    UNION ALL
    SELECT 60, 'Identity -> Catalog foreign keys installed',
           CASE WHEN COUNT(*) = 3 THEN 'PASS' WHEN COUNT(*) = 0 THEN 'PENDING' ELSE 'FAIL' END,
           COALESCE(pg_catalog.string_agg(c.conname, ', ' ORDER BY c.conname), 'none')
      FROM pg_catalog.pg_constraint c
     WHERE c.conname IN ('access_scopes_domain_fk', 'access_scopes_asset_fk', 'team_domains_domain_fk') AND c.convalidated
    UNION ALL
    SELECT 61, 'role cob3_worker is an unprivileged group role',
           CASE WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = 'cob3_worker') THEN 'PENDING'
                WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = 'cob3_worker'
                              AND NOT (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolcanlogin OR r.rolreplication))
                THEN 'PASS' ELSE 'FAIL' END,
           'grant it to worker LOGIN roles; never grant cob3_owner'
    UNION ALL
    SELECT 70, 'legacy obs3_* schemas present (untouched by these migrations)',
           'INFO',
           COALESCE((SELECT pg_catalog.string_agg(n.nspname, ', ' ORDER BY n.nspname) FROM pg_catalog.pg_namespace n WHERE n.nspname LIKE 'obs3\_%'),
                    'none in this database')
)
SELECT sort_key, check_name, status, detail FROM checks ORDER BY sort_key, check_name;
