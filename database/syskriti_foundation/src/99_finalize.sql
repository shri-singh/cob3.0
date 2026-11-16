-- =============================================================================
-- 99  CORE PLATFORM FEATURE DEFINITIONS, VERSION RECORD, SESSION RESTORE
-- -----------------------------------------------------------------------------
-- Only product-independent identity capacity features are seeded here: the
-- identity triggers enforce them. Plans, prices and product features (log
-- bytes, AI tokens, lineage, ...) are NOT seeded; see seeds/.
-- =============================================================================
PERFORM cob3_identity.set_system_context('system:foundation-installer');

INSERT INTO cob3_tenant.features
       (feature_code, name, description, value_type, unit_code, measurement_kind, status, created_by, updated_by)
VALUES ('organizations.max',    'Active organizations',        'Maximum active organizations per tenant',                                'quota',   'count', 'gauge',      'active', 'system:foundation-installer', 'system:foundation-installer'),
       ('humans.max',           'Active human principals',     'Distinct active human principals per tenant, counted once across organizations', 'quota', 'count', 'gauge', 'active', 'system:foundation-installer', 'system:foundation-installer'),
       ('service_accounts.max', 'Active service accounts',     'Active service-account principals',                                       'quota',   'count', 'gauge',      'active', 'system:foundation-installer', 'system:foundation-installer'),
       ('automations.max',      'Active automations',          'Active separate automation principals (tokens are not automations)',      'quota',   'count', 'gauge',      'active', 'system:foundation-installer', 'system:foundation-installer'),
       ('api_credentials.max',  'Active API credentials',      'Active unexpired API credentials, including personal and service tokens', 'quota',   'count', 'gauge',      'active', 'system:foundation-installer', 'system:foundation-installer'),
       ('automation.enabled',   'Automation capability',       'Entitlement to create and run automation identities',                     'boolean', NULL,    'capability', 'active', 'system:foundation-installer', 'system:foundation-installer'),
       ('sso.enabled',          'Enterprise SSO capability',   'Entitlement to configure enterprise identity providers',                  'boolean', NULL,    'capability', 'active', 'system:foundation-installer', 'system:foundation-installer');

INSERT INTO cob3_tenant.foundation_installations (component, version, script_checksum, server_version_num, notes)
VALUES ('foundation', _i_version, _i_checksum, _i_server,
        'Fresh install of cob3_tenant (21 tables) and cob3_identity (27 tables) plus 2 support tables. Catalog integration: NOT installed (fail closed).');

PERFORM cob3_identity.clear_request_context();

RESET ROLE;
PERFORM pg_catalog.set_config('search_path', _i_saved_path, true);

RAISE NOTICE 'Syskriti foundation % installed in database % (schemas cob3_tenant, cob3_identity). Catalog integration is not installed; domain/asset operations fail closed. Run VERIFY_FOUNDATION.sql next.',
    _i_version, pg_catalog.current_database();
END
