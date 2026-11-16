-- =============================================================================
-- 40  CROSS-SCHEMA FOREIGN KEYS AND UNIFORM COMMON-COLUMN ENFORCEMENT
-- -----------------------------------------------------------------------------
-- Tenant tables were created before Identity tables; their Identity
-- references are added here (bootstrap order: tenant -> organization ->
-- principal; the tenant master never needs an Identity FK).
-- =============================================================================

ALTER TABLE cob3_tenant.tenant_contacts
    ADD CONSTRAINT tenant_contacts_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE cob3_tenant.subscription_changes
    ADD CONSTRAINT subscription_changes_requested_by_fk FOREIGN KEY (tenant_id, requested_by_principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    ADD CONSTRAINT subscription_changes_approved_by_fk FOREIGN KEY (tenant_id, approved_by_principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE cob3_tenant.organization_quota_allocations
    ADD CONSTRAINT organization_quota_allocations_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE cob3_tenant.usage_events
    ADD CONSTRAINT usage_events_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE cob3_tenant.usage_rollups
    ADD CONSTRAINT usage_rollups_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE cob3_tenant.quota_counters
    ADD CONSTRAINT quota_counters_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

-- ---------------------------------------------------------------------------
-- Uniform common-column rules for all 48 logical tables:
--   <table>_metadata_object_ck        jsonb_typeof(metadata) = 'object'
--   <table>_metadata_no_secrets_ck    heuristic: no top-level secret-named keys
--   <table>_row_version_positive_ck   row_version > 0
--   <table>_created_by_actor_ck       principal:<uuid> | system:<name>
--   <table>_updated_by_actor_ck       principal:<uuid> | system:<name>
--   trg_90_stamp_row                  trusted timestamp/actor/version stamping
--   trg_00_block_truncate             no TRUNCATE (retention is controlled)
-- ---------------------------------------------------------------------------
FOREACH _i_table IN ARRAY _i_logical_tables LOOP
    _i_schema := pg_catalog.split_part(_i_table, '.', 1);
    _i_name   := pg_catalog.split_part(_i_table, '.', 2);
    EXECUTE pg_catalog.format(
        'ALTER TABLE %1$I.%2$I'
        ' ADD CONSTRAINT %3$I CHECK (jsonb_typeof(metadata) = ''object''),'
        ' ADD CONSTRAINT %4$I CHECK (NOT (metadata ?| ARRAY[''password'', ''secret'', ''client_secret'', ''private_key'', ''api_key'', ''access_token'', ''refresh_token'', ''token''])),'
        ' ADD CONSTRAINT %5$I CHECK (row_version > 0),'
        ' ADD CONSTRAINT %6$I CHECK (created_by ~ %8$L),'
        ' ADD CONSTRAINT %7$I CHECK (updated_by ~ %8$L)',
        _i_schema, _i_name,
        _i_name || '_metadata_object_ck',
        _i_name || '_metadata_no_secrets_ck',
        _i_name || '_row_version_positive_ck',
        _i_name || '_created_by_actor_ck',
        _i_name || '_updated_by_actor_ck',
        '^(principal:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|system:[a-z0-9][a-z0-9_.:-]{0,200})$');
    EXECUTE pg_catalog.format(
        'CREATE TRIGGER trg_90_stamp_row BEFORE INSERT OR UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_stamp_row()',
        _i_schema, _i_name);
END LOOP;

FOREACH _i_table IN ARRAY (_i_logical_tables || _i_support_tables) LOOP
    EXECUTE pg_catalog.format(
        'CREATE TRIGGER trg_00_block_truncate BEFORE TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION cob3_identity.tg_block_truncate()',
        pg_catalog.split_part(_i_table, '.', 1), pg_catalog.split_part(_i_table, '.', 2));
END LOOP;

-- Append-only tables: no UPDATE or DELETE by anyone (including the owner,
-- unless a reviewed retention migration explicitly disables the trigger).
CREATE TRIGGER trg_05_append_only BEFORE UPDATE OR DELETE ON cob3_tenant.tenant_lifecycle_events
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_append_only();
CREATE TRIGGER trg_05_append_only BEFORE UPDATE OR DELETE ON cob3_tenant.usage_events
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_append_only();
CREATE TRIGGER trg_05_append_only BEFORE UPDATE OR DELETE ON cob3_identity.audit_events
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_append_only();
CREATE TRIGGER trg_05_append_only BEFORE UPDATE OR DELETE ON cob3_identity.credential_permission_bindings
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_append_only();
CREATE TRIGGER trg_05_append_only BEFORE UPDATE OR DELETE ON cob3_tenant.foundation_installations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_append_only();
