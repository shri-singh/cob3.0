-- =============================================================================
-- OBS3 LIVE-SCHEMA INVENTORY (READ-ONLY)
-- -----------------------------------------------------------------------------
-- Step 0 of Observei_Live_Telemetry_Additive_Architecture_v1.md section 8 and
-- step 1 of COB3_Settings_Catalog_Workspace_Consolidated_Design_v1.md section 12:
-- export the ACTUAL obs3_* structure before any mapping/backfill/ALTER is
-- written. Screenshots do not establish types, keys, partitions or views.
--
-- * Reads ONLY system catalogs and planner estimates (pg_class.reltuples,
--   relation sizes). It never reads customer rows and never scans tables, so
--   it is safe during ingestion hours. It changes nothing.
-- * Run in DBeaver with "Execute script" (Alt+X): each numbered query returns
--   its own result tab. Export each tab to CSV and keep them with the
--   migration evidence (no customer payloads are included).
-- * Scope: every schema named obs3_* (legacy app schemas obs3_identity,
--   obs3_settings, obs3_workspace, obs3_memory, obs3_learning and the live
--   telemetry schemas obs3_aiops, obs3_core, obs3_cx, obs3_incidents, obs3_log,
--   obs3_ops, obs3_search, obs3_span, obs3_meta ...).
-- =============================================================================

-- 1. Relations: kind, partitioning, size, estimated rows, RLS, owner.
SELECT n.nspname AS schema_name, c.relname AS relation_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
                      WHEN 'm' THEN 'materialized view' WHEN 'f' THEN 'foreign table' END AS kind,
       c.relispartition AS is_partition,
       (SELECT pn.nspname || '.' || pc.relname FROM pg_inherits i JOIN pg_class pc ON pc.oid = i.inhparent
          JOIN pg_namespace pn ON pn.oid = pc.relnamespace WHERE i.inhrelid = c.oid LIMIT 1) AS partition_parent,
       CASE WHEN c.relkind IN ('r', 'p', 'm') THEN c.reltuples::bigint END AS estimated_rows,
       CASE WHEN c.relkind IN ('r', 'm') THEN pg_size_pretty(pg_total_relation_size(c.oid)) END AS total_size,
       c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS rls_forced,
       pg_get_userbyid(c.relowner) AS owner
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname LIKE 'obs3\_%' AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
 ORDER BY 1, c.relispartition, 2;

-- 2. Columns with exact types, nullability and defaults.
SELECT n.nspname AS schema_name, c.relname AS relation_name, a.attnum AS ordinal, a.attname AS column_name,
       format_type(a.atttypid, a.atttypmod) AS data_type, a.attnotnull AS not_null,
       pg_get_expr(d.adbin, d.adrelid) AS default_expr, a.attidentity AS identity, a.attgenerated AS generated
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
 WHERE n.nspname LIKE 'obs3\_%' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relispartition
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY 1, 2, 3;

-- 3. Constraints (PK, UNIQUE, FK, CHECK, EXCLUDE) with full definitions.
--    Confirms every ON CONFLICT target before scope columns are added.
SELECT n.nspname AS schema_name, c.relname AS relation_name, k.conname AS constraint_name,
       CASE k.contype WHEN 'p' THEN 'primary key' WHEN 'u' THEN 'unique' WHEN 'f' THEN 'foreign key'
                      WHEN 'c' THEN 'check' WHEN 'x' THEN 'exclusion' END AS constraint_type,
       pg_get_constraintdef(k.oid) AS definition, k.convalidated AS validated
  FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname LIKE 'obs3\_%' AND NOT c.relispartition
 ORDER BY 1, 2, 4, 3;

-- 4. Indexes (including partial/expression) and validity.
SELECT n.nspname AS schema_name, c.relname AS relation_name, ic.relname AS index_name,
       pg_get_indexdef(i.indexrelid) AS definition, i.indisunique AS is_unique, i.indisprimary AS is_primary,
       i.indisvalid AS is_valid, pg_size_pretty(pg_relation_size(i.indexrelid)) AS size
  FROM pg_index i
  JOIN pg_class c ON c.oid = i.indrelid
  JOIN pg_class ic ON ic.oid = i.indexrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname LIKE 'obs3\_%' AND NOT c.relispartition
 ORDER BY 1, 2, 3;

-- 5. Partition hierarchy with bounds (partition-safe ALTER/backfill planning).
SELECT pn.nspname AS parent_schema, p.relname AS parent, pg_get_partkeydef(p.oid) AS partition_key,
       cn.nspname AS child_schema, ch.relname AS child, pg_get_expr(ch.relpartbound, ch.oid) AS bound,
       ch.reltuples::bigint AS estimated_rows
  FROM pg_inherits i
  JOIN pg_class p ON p.oid = i.inhparent JOIN pg_namespace pn ON pn.oid = p.relnamespace
  JOIN pg_class ch ON ch.oid = i.inhrelid JOIN pg_namespace cn ON cn.oid = ch.relnamespace
 WHERE pn.nspname LIKE 'obs3\_%'
 ORDER BY 1, 2, 6;

-- 6. View and materialized-view definitions (scope can only be added to
--    their QUERY; an aggregate that already mixes organizations cannot be
--    secured by labelling it afterwards).
SELECT n.nspname AS schema_name, c.relname AS view_name,
       CASE c.relkind WHEN 'v' THEN 'view' ELSE 'materialized view' END AS kind,
       pg_get_viewdef(c.oid, true) AS definition
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname LIKE 'obs3\_%' AND c.relkind IN ('v', 'm')
 ORDER BY 1, 2;

-- 7. View/MV dependencies on base relations (what an ALTER would touch).
SELECT DISTINCT vn.nspname AS view_schema, v.relname AS view_name, bn.nspname AS base_schema, b.relname AS base_relation
  FROM pg_depend d
  JOIN pg_rewrite r ON r.oid = d.objid
  JOIN pg_class v ON v.oid = r.ev_class JOIN pg_namespace vn ON vn.oid = v.relnamespace
  JOIN pg_class b ON b.oid = d.refobjid JOIN pg_namespace bn ON bn.oid = b.relnamespace
 WHERE d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass AND v.oid <> b.oid
   AND (vn.nspname LIKE 'obs3\_%' OR bn.nspname LIKE 'obs3\_%')
 ORDER BY 1, 2, 3, 4;

-- 8. Triggers and RLS policies.
SELECT n.nspname AS schema_name, c.relname AS relation_name, 'trigger' AS object_type, t.tgname AS name,
       pg_get_triggerdef(t.oid) AS definition
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname LIKE 'obs3\_%' AND NOT t.tgisinternal
UNION ALL
SELECT p.schemaname, p.tablename, 'policy', p.policyname,
       p.cmd || ' TO ' || array_to_string(p.roles, ',') || ' USING (' || COALESCE(p.qual, 'true') || ') CHECK (' || COALESCE(p.with_check, '-') || ')'
  FROM pg_policies p
 WHERE p.schemaname LIKE 'obs3\_%'
 ORDER BY 1, 2, 3, 4;

-- 9. Grants (who reads/writes each relation today).
SELECT table_schema AS schema_name, table_name AS relation_name, grantee,
       string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
  FROM information_schema.role_table_grants
 WHERE table_schema LIKE 'obs3\_%'
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3;

-- 10. Scope/audit readiness (telemetry design section 4): which canonical
--     columns already exist on each base relation and with which type. A
--     numeric/text tenant_id must be preserved; canonical UUID scope is
--     added as platform_tenant_id / organization_id only after review.
SELECT n.nspname AS schema_name, c.relname AS relation_name,
       CASE c.relkind WHEN 'p' THEN 'partitioned table' ELSE 'table' END AS kind,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'tenant_id')          AS tenant_id,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'organization_id')    AS organization_id,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'platform_tenant_id') AS platform_tenant_id,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'created_at')         AS created_at,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'created_by')         AS created_by,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'updated_at')         AS updated_at,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'updated_by')         AS updated_by,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'metadata')           AS metadata,
       max(format_type(a.atttypid, a.atttypmod)) FILTER (WHERE a.attname = 'row_version')        AS row_version,
       bool_or(a.attname IN ('user_id', 'owner_user_id', 'changed_by', 'applied_by'))           AS has_legacy_user_refs,
       bool_or(a.attname IN ('target_type', 'target_id'))                                        AS has_free_form_targets,
       bool_or(a.attname IN ('scope_binding_id', 'source_connection_id', 'catalog_asset_id'))   AS has_mapping_columns
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
 WHERE n.nspname LIKE 'obs3\_%' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
 GROUP BY 1, 2, 3
 ORDER BY 1, 2;

-- 11. Functions/procedures in obs3 schemas (writers, upserts, DAG helpers).
SELECT n.nspname AS schema_name, p.proname AS routine_name, pg_get_function_identity_arguments(p.oid) AS arguments,
       CASE p.prokind WHEN 'f' THEN 'function' WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate' ELSE p.prokind::text END AS kind,
       p.prosecdef AS security_definer
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname LIKE 'obs3\_%'
 ORDER BY 1, 2;

-- 12. Operational baseline (no table scans): long transactions and dead tuples.
SELECT s.schemaname AS schema_name, s.relname AS relation_name, s.n_live_tup, s.n_dead_tup,
       s.last_autovacuum, s.last_autoanalyze, s.seq_scan, s.idx_scan
  FROM pg_stat_user_tables s
 WHERE s.schemaname LIKE 'obs3\_%'
 ORDER BY s.n_live_tup DESC NULLS LAST;
