-- =============================================================================
-- OPTIONAL PRODUCT EXAMPLE -- Observei/Opsi
-- -----------------------------------------------------------------------------
-- NOT part of the core foundation and NOT run by INSTALL_FOUNDATION.sql.
-- Another Syskriti product must write its own seed file instead of copying
-- this one (see docs/platform-foundation/REUSE_IN_ANOTHER_PRODUCT.md).
--
-- Part A (platform catalog, cob3_commercial_admin):
--   product feature definitions from the Tenant specification section 10
--   and an UNPUBLISHED example plan (draft; not sellable until reviewed,
--   priced and published by commercial authority).
-- Part B (per-tenant IAM, cob3_provisioner):
--   Observei permission codes and roles from the Identity specification
--   section 7 for ONE tenant (edit v_tenant_code below).
--
-- Resource-dependent permissions (application/dashboard/incident/log/domain)
-- are registered but DENY at runtime until the Catalog integration provides a
-- trusted resolver for those resource types. Prices are illustrative zeros;
-- they are not researched market prices.
-- Requires: a login that can SET ROLE cob3_commercial_admin and cob3_provisioner.
-- Idempotent: safe to rerun.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Part A: platform catalog features (commercial authority)
-- ---------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE cob3_commercial_admin;
SELECT cob3_identity.set_system_context('system:observei-example-seed');

INSERT INTO cob3_tenant.features (feature_code, name, description, value_type, unit_code, measurement_kind, created_by, updated_by)
SELECT v.feature_code, v.name, v.description, v.value_type, v.unit_code, v.measurement_kind,
       'system:observei-example-seed', 'system:observei-example-seed'
  FROM (VALUES
        ('storage.bytes',        'Retained storage',        'Current retained chargeable storage (bytes, not GB/GiB)', 'quota',   'byte',    'gauge'),
        ('logs.ingested_bytes',  'Ingested log bytes',      'Ingested bytes in the contract billing cycle',            'quota',   'byte',    'counter'),
        ('ai.tokens',            'AI tokens',               'Metered AI tokens under defined provider accounting',     'quota',   'token',   'counter'),
        ('api.requests',         'API requests',            'Counted API requests per UTC calendar month',             'quota',   'request', 'counter'),
        ('lineage.enabled',      'Lineage capability',      'Entitlement to lineage features',                        'boolean', NULL,      'capability')
       ) AS v(feature_code, name, description, value_type, unit_code, measurement_kind)
 WHERE NOT EXISTS (SELECT 1 FROM cob3_tenant.features f WHERE f.feature_code = v.feature_code);

-- Example plan family + DRAFT version with entitlements (left unpublished).
INSERT INTO cob3_tenant.plans (plan_code, name, description, created_by, updated_by)
SELECT 'observei-standard-example', 'Observei Standard (EXAMPLE, unpublished)',
       'Illustrative plan; review, price and publish through commercial authority before use.',
       'system:observei-example-seed', 'system:observei-example-seed'
 WHERE NOT EXISTS (SELECT 1 FROM cob3_tenant.plans WHERE plan_code = 'observei-standard-example');

INSERT INTO cob3_tenant.plan_versions (plan_id, version_number, effective_from, created_by, updated_by)
SELECT p.plan_id, 1, now(), 'system:observei-example-seed', 'system:observei-example-seed'
  FROM cob3_tenant.plans p
 WHERE p.plan_code = 'observei-standard-example'
   AND NOT EXISTS (SELECT 1 FROM cob3_tenant.plan_versions v WHERE v.plan_id = p.plan_id AND v.version_number = 1);

INSERT INTO cob3_tenant.plan_entitlements (plan_version_id, feature_id, is_enabled, limit_value, is_unlimited, reset_period, created_by, updated_by)
SELECT v.plan_version_id, f.feature_id, e.is_enabled, e.limit_value, false, e.reset_period,
       'system:observei-example-seed', 'system:observei-example-seed'
  FROM (VALUES
        ('organizations.max',   true,  5::numeric,             'none'),
        ('humans.max',          true,  50,                     'none'),
        ('service_accounts.max',true,  20,                     'none'),
        ('automations.max',     true,  50,                     'none'),
        ('api_credentials.max', true,  200,                    'none'),
        ('storage.bytes',       true,  1099511627776,          'none'),
        ('logs.ingested_bytes', true,  536870912000,           'subscription_period'),
        ('ai.tokens',           true,  10000000,               'subscription_period'),
        ('api.requests',        true,  5000000,                'calendar_month'),
        ('automation.enabled',  true,  NULL,                   'none'),
        ('sso.enabled',         true,  NULL,                   'none'),
        ('lineage.enabled',     false, NULL,                   'none')
       ) AS e(feature_code, is_enabled, limit_value, reset_period)
  JOIN cob3_tenant.features f ON f.feature_code = e.feature_code
  JOIN cob3_tenant.plans p ON p.plan_code = 'observei-standard-example'
  JOIN cob3_tenant.plan_versions v ON v.plan_id = p.plan_id AND v.version_number = 1 AND v.status = 'draft'
 WHERE NOT EXISTS (SELECT 1 FROM cob3_tenant.plan_entitlements x
                    WHERE x.plan_version_id = v.plan_version_id AND x.feature_id = f.feature_id);
COMMIT;

-- ---------------------------------------------------------------------------
-- Part B: per-tenant Observei IAM permissions and roles (provisioning)
-- ---------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE cob3_provisioner;

DO $observei$
DECLARE
    v_tenant_code CONSTANT text := 'example-tenant';   -- <<< edit for the target tenant
    v_actor       CONSTANT text := 'system:observei-example-seed';
    v_tenant      uuid;
    p             record;
BEGIN
    SELECT t.tenant_id INTO v_tenant FROM cob3_tenant.tenants t WHERE t.tenant_code = v_tenant_code;
    IF v_tenant IS NULL THEN
        RAISE NOTICE 'OPTIONAL EXAMPLE: tenant % not found; Part B skipped.', v_tenant_code;
        RETURN;
    END IF;
    FOR p IN SELECT * FROM (VALUES
            ('application.read', 'application', 'read',   'Catalog application asset'),
            ('dashboard.read',   'dashboard',   'read',   'Dashboard asset'),
            ('dashboard.update', 'dashboard',   'update', 'Dashboard asset mutation'),
            ('incident.read',    'incident',    'read',   'Incident under authoritative application/domain scope'),
            ('incident.update',  'incident',    'update', 'Incident mutation'),
            ('incident.ingest',  'incident',    'ingest', 'Ingest incidents for an authorized application'),
            ('log.read',         'log',         'read',   'Logs under application/domain scope'),
            ('log.ingest',       'log',         'ingest', 'Ingest logs for an authorized application')
         ) AS x(code, resource_type, action, description) LOOP
        PERFORM cob3_identity.register_tenant_permission(v_tenant, p.code, p.resource_type, p.action, 'organization',
                                                         true, true, false, p.description, v_actor);
    END LOOP;
    PERFORM cob3_identity.register_tenant_role(v_tenant, 'viewer',            'Viewer',            'organization', NULL, v_actor);
    PERFORM cob3_identity.register_tenant_role(v_tenant, 'incident_operator', 'Incident operator', 'organization', NULL, v_actor);
    PERFORM cob3_identity.register_tenant_role(v_tenant, 'dashboard_editor',  'Dashboard editor',  'organization', NULL, v_actor);
    PERFORM cob3_identity.register_tenant_role(v_tenant, 'ingestion_writer',  'Ingestion writer',  'organization', NULL, v_actor);
    FOR p IN SELECT * FROM (VALUES
            ('viewer', 'domain.read'), ('viewer', 'application.read'), ('viewer', 'dashboard.read'),
            ('viewer', 'incident.read'), ('viewer', 'log.read'),
            ('incident_operator', 'domain.read'), ('incident_operator', 'application.read'),
            ('incident_operator', 'incident.read'), ('incident_operator', 'incident.update'), ('incident_operator', 'log.read'),
            ('dashboard_editor', 'dashboard.read'), ('dashboard_editor', 'dashboard.update'),
            ('ingestion_writer', 'application.read'), ('ingestion_writer', 'incident.ingest'), ('ingestion_writer', 'log.ingest')
         ) AS x(role_code, permission_code) LOOP
        PERFORM cob3_identity.add_role_permission(v_tenant, p.role_code, p.permission_code, v_actor);
    END LOOP;
    RAISE NOTICE 'OPTIONAL EXAMPLE: Observei IAM examples applied to tenant %.', v_tenant_code;
END
$observei$;

COMMIT;
