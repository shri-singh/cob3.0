-- =============================================================================
-- CORE IAM TEMPLATE SYNC (generic, product-independent)
-- -----------------------------------------------------------------------------
-- The single source of the core templates is inside the installer:
--   cob3_identity.core_permission_templates()  -- 20 generic permission codes
--   cob3_identity.core_role_templates()        -- tenant_administrator,
--                                                 organization_administrator,
--                                                 automation_creator, audit_reader
-- New tenants receive them automatically through bootstrap_tenant /
-- bootstrap_tenant_administration. Run THIS script only after a foundation
-- upgrade that adds core templates, to backfill existing tenants.
--
-- Behavior: idempotent. Missing permissions/roles/associations are added as
-- tenant-owned rows (never tenant_id NULL). Existing rows are never modified;
-- a definition conflict raises SQLSTATE SKINV and the whole run rolls back.
-- Requires: a login that can SET ROLE cob3_provisioner.
-- =============================================================================
BEGIN;

SET LOCAL ROLE cob3_provisioner;

DO $sync$
DECLARE
    r record;
    n integer := 0;
BEGIN
    FOR r IN SELECT t.tenant_id FROM cob3_tenant.tenants t
              WHERE t.status IN ('provisioning', 'active', 'suspended')
              ORDER BY t.tenant_id LOOP
        PERFORM cob3_identity.provision_tenant_iam_seed(r.tenant_id, 'system:core-template-sync');
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'Core IAM templates synchronized for % tenant(s).', n;
END
$sync$;

COMMIT;

-- Inspect the template contract (read-only):
--   SELECT * FROM cob3_identity.core_permission_templates();
--   SELECT * FROM cob3_identity.core_role_templates();
