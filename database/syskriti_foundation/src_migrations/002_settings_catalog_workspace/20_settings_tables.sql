-- =============================================================================
-- 20  cob3_settings TABLES (11)
-- -----------------------------------------------------------------------------
-- Scope classes: platform (setting_definitions: tenant_id/organization_id NULL),
-- context (tenant required, organization per declared scope owner).
-- Context children reference setting_scopes through a tenant-qualified FK; a
-- trigger proves organization equality including NULL (MATCH SIMPLE would not).
-- =============================================================================

CREATE TABLE cob3_settings.setting_definitions (
    setting_definition_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id              uuid          NULL,
    organization_id        uuid          NULL,
    setting_key            varchar(128)  NOT NULL,
    definition_version     integer       NOT NULL,
    value_type             varchar(16)   NOT NULL,
    default_value          jsonb         NOT NULL,
    validation_schema      jsonb         NOT NULL,
    allowed_scopes         text[]        NOT NULL,
    category               varchar(24)   NOT NULL,
    user_overridable       boolean       NOT NULL DEFAULT false,
    lockable               boolean       NOT NULL DEFAULT false,
    status                 varchar(20)   NOT NULL DEFAULT 'active',
    created_at             timestamptz   NOT NULL DEFAULT now(),
    created_by             varchar(255)  NOT NULL,
    updated_at             timestamptz   NOT NULL DEFAULT now(),
    updated_by             varchar(255)  NOT NULL,
    metadata               jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version            bigint        NOT NULL DEFAULT 1,
    CONSTRAINT setting_definitions_pk PRIMARY KEY (setting_definition_id),
    CONSTRAINT setting_definitions_key_version_uq UNIQUE (setting_key, definition_version),
    CONSTRAINT setting_definitions_platform_scope_ck CHECK (tenant_id IS NULL AND organization_id IS NULL),
    CONSTRAINT setting_definitions_key_format_ck CHECK (setting_key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
    CONSTRAINT setting_definitions_version_ck CHECK (definition_version > 0),
    CONSTRAINT setting_definitions_value_type_ck CHECK (value_type IN ('boolean', 'integer', 'decimal', 'string', 'array', 'object')),
    CONSTRAINT setting_definitions_default_type_ck CHECK (
        CASE value_type
            WHEN 'boolean' THEN jsonb_typeof(default_value) = 'boolean'
            WHEN 'integer' THEN jsonb_typeof(default_value) = 'number' AND default_value::text ~ '^-?[0-9]+$'
            WHEN 'decimal' THEN jsonb_typeof(default_value) = 'number'
            WHEN 'string'  THEN jsonb_typeof(default_value) = 'string'
            WHEN 'array'   THEN jsonb_typeof(default_value) = 'array'
            WHEN 'object'  THEN jsonb_typeof(default_value) = 'object'
        END),
    CONSTRAINT setting_definitions_schema_object_ck CHECK (jsonb_typeof(validation_schema) = 'object'),
    CONSTRAINT setting_definitions_allowed_scopes_ck CHECK (
        cardinality(allowed_scopes) > 0
        AND allowed_scopes <@ ARRAY['tenant', 'organization', 'team', 'principal', 'principal_org', 'project']::text[]),
    CONSTRAINT setting_definitions_overridable_ck CHECK (user_overridable OR NOT (allowed_scopes && ARRAY['principal', 'principal_org']::text[])),
    CONSTRAINT setting_definitions_lockable_ck CHECK (NOT lockable OR allowed_scopes && ARRAY['tenant', 'organization']::text[]),
    CONSTRAINT setting_definitions_category_ck CHECK (category IN ('appearance', 'localization', 'navigation', 'accessibility',
                                                                   'workspace', 'notification', 'data_display')),
    CONSTRAINT setting_definitions_status_ck CHECK (status IN ('active', 'retired'))
);
CREATE UNIQUE INDEX setting_definitions_active_key_uix ON cob3_settings.setting_definitions (setting_key) WHERE status = 'active';

CREATE TABLE cob3_settings.setting_scopes (
    tenant_id         uuid          NOT NULL,
    setting_scope_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id   uuid          NULL,
    scope_type        varchar(24)   NOT NULL,
    principal_id      uuid          NULL,
    team_id           uuid          NULL,
    project_id        uuid          NULL,
    status            varchar(20)   NOT NULL DEFAULT 'active',
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        varchar(255)  NOT NULL,
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    updated_by        varchar(255)  NOT NULL,
    metadata          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version       bigint        NOT NULL DEFAULT 1,
    CONSTRAINT setting_scopes_pk PRIMARY KEY (tenant_id, setting_scope_id),
    CONSTRAINT setting_scopes_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_scopes_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_scopes_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Enforced only when organization and principal are both set (principal_org scope).
    CONSTRAINT setting_scopes_principal_membership_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_scopes_team_fk FOREIGN KEY (tenant_id, organization_id, team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- setting_scopes_project_fk -> cob3_workspace.projects is added in 50_* (deferrable).
    CONSTRAINT setting_scopes_type_ck CHECK (scope_type IN ('tenant', 'organization', 'team', 'principal', 'principal_org', 'project')),
    CONSTRAINT setting_scopes_shape_ck CHECK (
           (scope_type = 'tenant'        AND organization_id IS NULL     AND principal_id IS NULL     AND team_id IS NULL     AND project_id IS NULL)
        OR (scope_type = 'organization'  AND organization_id IS NOT NULL AND principal_id IS NULL     AND team_id IS NULL     AND project_id IS NULL)
        OR (scope_type = 'team'          AND organization_id IS NOT NULL AND principal_id IS NULL     AND team_id IS NOT NULL AND project_id IS NULL)
        OR (scope_type = 'principal'     AND organization_id IS NULL     AND principal_id IS NOT NULL AND team_id IS NULL     AND project_id IS NULL)
        OR (scope_type = 'principal_org' AND organization_id IS NOT NULL AND principal_id IS NOT NULL AND team_id IS NULL     AND project_id IS NULL)
        OR (scope_type = 'project'       AND organization_id IS NOT NULL AND principal_id IS NULL     AND team_id IS NULL     AND project_id IS NOT NULL)),
    CONSTRAINT setting_scopes_status_ck CHECK (status IN ('active', 'archived'))
);
-- One logical scope per subject (archived scopes keep their identity).
CREATE UNIQUE INDEX setting_scopes_tenant_uix        ON cob3_settings.setting_scopes (tenant_id) WHERE scope_type = 'tenant';
CREATE UNIQUE INDEX setting_scopes_organization_uix  ON cob3_settings.setting_scopes (tenant_id, organization_id) WHERE scope_type = 'organization';
CREATE UNIQUE INDEX setting_scopes_team_uix          ON cob3_settings.setting_scopes (tenant_id, organization_id, team_id) WHERE scope_type = 'team';
CREATE UNIQUE INDEX setting_scopes_principal_uix     ON cob3_settings.setting_scopes (tenant_id, principal_id) WHERE scope_type = 'principal';
CREATE UNIQUE INDEX setting_scopes_principal_org_uix ON cob3_settings.setting_scopes (tenant_id, organization_id, principal_id) WHERE scope_type = 'principal_org';
CREATE UNIQUE INDEX setting_scopes_project_uix       ON cob3_settings.setting_scopes (tenant_id, organization_id, project_id) WHERE scope_type = 'project';

CREATE TABLE cob3_settings.setting_values (
    tenant_id              uuid          NOT NULL,
    setting_value_id       uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id        uuid          NULL,
    setting_scope_id       uuid          NOT NULL,
    setting_definition_id  uuid          NOT NULL,
    value                  jsonb         NOT NULL,
    is_locked              boolean       NOT NULL DEFAULT false,
    change_reason          text          NULL,
    created_at             timestamptz   NOT NULL DEFAULT now(),
    created_by             varchar(255)  NOT NULL,
    updated_at             timestamptz   NOT NULL DEFAULT now(),
    updated_by             varchar(255)  NOT NULL,
    metadata               jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version            bigint        NOT NULL DEFAULT 1,
    CONSTRAINT setting_values_pk PRIMARY KEY (tenant_id, setting_value_id),
    CONSTRAINT setting_values_scope_definition_uq UNIQUE (tenant_id, setting_scope_id, setting_definition_id),
    CONSTRAINT setting_values_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_values_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_values_scope_fk FOREIGN KEY (tenant_id, setting_scope_id)
        REFERENCES cob3_settings.setting_scopes (tenant_id, setting_scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_values_definition_fk FOREIGN KEY (setting_definition_id)
        REFERENCES cob3_settings.setting_definitions (setting_definition_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_values_not_json_null_ck CHECK (jsonb_typeof(value) <> 'null'),
    CONSTRAINT setting_values_size_ck CHECK (pg_column_size(value) <= 16384),
    CONSTRAINT setting_values_reason_nonblank_ck CHECK (change_reason IS NULL OR length(btrim(change_reason)) > 0),
    CONSTRAINT setting_values_lock_reason_ck CHECK (NOT is_locked OR change_reason IS NOT NULL)
);
CREATE INDEX setting_values_definition_ix ON cob3_settings.setting_values (setting_definition_id);

CREATE TABLE cob3_settings.setting_change_events (
    tenant_id                 uuid          NOT NULL,
    setting_change_event_id   uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id           uuid          NULL,
    setting_scope_id          uuid          NOT NULL,
    setting_key               varchar(128)  NOT NULL,
    operation                 varchar(20)   NOT NULL,
    old_value                 jsonb         NULL,
    new_value                 jsonb         NULL,
    request_id                uuid          NOT NULL,
    occurred_at               timestamptz   NOT NULL DEFAULT now(),
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT setting_change_events_pk PRIMARY KEY (tenant_id, setting_change_event_id),
    CONSTRAINT setting_change_events_request_uq UNIQUE (tenant_id, request_id, setting_scope_id, setting_key),
    CONSTRAINT setting_change_events_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_change_events_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_change_events_scope_fk FOREIGN KEY (tenant_id, setting_scope_id)
        REFERENCES cob3_settings.setting_scopes (tenant_id, setting_scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT setting_change_events_operation_ck CHECK (operation IN ('set', 'reset', 'lock', 'unlock'))
);
CREATE INDEX setting_change_events_scope_ix ON cob3_settings.setting_change_events (tenant_id, setting_scope_id, occurred_at);

CREATE TABLE cob3_settings.media_objects (
    tenant_id                 uuid          NOT NULL,
    media_object_id           uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id           uuid          NULL,
    setting_scope_id          uuid          NOT NULL,
    uploaded_by_principal_id  uuid          NOT NULL,
    storage_provider          varchar(32)   NOT NULL,
    storage_container         varchar(255)  NOT NULL,
    object_key                text          NOT NULL,
    object_version            varchar(255)  NULL,
    original_filename         varchar(255)  NULL,
    mime_type                 varchar(128)  NOT NULL,
    size_bytes                bigint        NOT NULL,
    sha256                    bytea         NOT NULL,
    width_px                  integer       NULL,
    height_px                 integer       NULL,
    status                    varchar(20)   NOT NULL DEFAULT 'quarantined',
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT media_objects_pk PRIMARY KEY (tenant_id, media_object_id),
    CONSTRAINT media_objects_scope_entity_uq UNIQUE (tenant_id, setting_scope_id, media_object_id),
    CONSTRAINT media_objects_location_uq UNIQUE NULLS NOT DISTINCT (storage_provider, storage_container, object_key, object_version),
    CONSTRAINT media_objects_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT media_objects_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT media_objects_scope_fk FOREIGN KEY (tenant_id, setting_scope_id)
        REFERENCES cob3_settings.setting_scopes (tenant_id, setting_scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT media_objects_uploader_fk FOREIGN KEY (tenant_id, uploaded_by_principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT media_objects_provider_format_ck CHECK (storage_provider ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT media_objects_container_nonblank_ck CHECK (length(btrim(storage_container)) > 0),
    CONSTRAINT media_objects_key_ck CHECK (length(btrim(object_key)) > 0 AND object_key !~* '^https?://' AND object_key !~* '(x-amz-signature|signature=|sig=|token=)'),
    CONSTRAINT media_objects_filename_ck CHECK (original_filename IS NULL OR (length(btrim(original_filename)) > 0 AND original_filename !~ '[/\\]')),
    CONSTRAINT media_objects_mime_ck CHECK (mime_type ~ '^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$'),
    CONSTRAINT media_objects_size_ck CHECK (size_bytes >= 0),
    CONSTRAINT media_objects_sha256_ck CHECK (octet_length(sha256) = 32),
    CONSTRAINT media_objects_dimensions_ck CHECK ((width_px IS NULL OR width_px > 0) AND (height_px IS NULL OR height_px > 0)
                                                  AND ((width_px IS NULL) = (height_px IS NULL))),
    CONSTRAINT media_objects_status_ck CHECK (status IN ('quarantined', 'ready', 'rejected', 'deleted'))
);
CREATE INDEX media_objects_uploader_ix ON cob3_settings.media_objects (tenant_id, uploaded_by_principal_id);

CREATE TABLE cob3_settings.branding_profiles (
    tenant_id            uuid          NOT NULL,
    branding_profile_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id      uuid          NULL,
    setting_scope_id     uuid          NOT NULL,
    display_name         varchar(200)  NULL,
    logo_media_id        uuid          NULL,
    favicon_media_id     uuid          NULL,
    theme_tokens         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    support_url          text          NULL,
    support_email        varchar(320)  NULL,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    created_by           varchar(255)  NOT NULL,
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    updated_by           varchar(255)  NOT NULL,
    metadata             jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version          bigint        NOT NULL DEFAULT 1,
    CONSTRAINT branding_profiles_pk PRIMARY KEY (tenant_id, branding_profile_id),
    CONSTRAINT branding_profiles_scope_uq UNIQUE (tenant_id, setting_scope_id),
    CONSTRAINT branding_profiles_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT branding_profiles_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT branding_profiles_scope_fk FOREIGN KEY (tenant_id, setting_scope_id)
        REFERENCES cob3_settings.setting_scopes (tenant_id, setting_scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Same-scope media: the composite key proves the media belongs to this scope.
    CONSTRAINT branding_profiles_logo_fk FOREIGN KEY (tenant_id, setting_scope_id, logo_media_id)
        REFERENCES cob3_settings.media_objects (tenant_id, setting_scope_id, media_object_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT branding_profiles_favicon_fk FOREIGN KEY (tenant_id, setting_scope_id, favicon_media_id)
        REFERENCES cob3_settings.media_objects (tenant_id, setting_scope_id, media_object_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT branding_profiles_display_name_ck CHECK (display_name IS NULL OR length(btrim(display_name)) > 0),
    CONSTRAINT branding_profiles_theme_object_ck CHECK (jsonb_typeof(theme_tokens) = 'object' AND pg_column_size(theme_tokens) <= 16384),
    CONSTRAINT branding_profiles_support_url_ck CHECK (support_url IS NULL OR (support_url ~ '^https://[^\s/@]+(/[^\s]*)?$')),
    CONSTRAINT branding_profiles_support_email_ck CHECK (support_email IS NULL OR support_email ~ '^[^@\s]+@[^@\s]+$')
);

CREATE TABLE cob3_settings.contact_addresses (
    tenant_id                 uuid          NOT NULL,
    contact_address_id        uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id           uuid          NOT NULL,
    team_id                   uuid          NULL,
    purpose                   varchar(24)   NOT NULL,
    email_address             varchar(320)  NOT NULL,
    email_key                 varchar(320)  NOT NULL,
    verification_method       varchar(24)   NULL,
    verified_at               timestamptz   NULL,
    verified_by_principal_id  uuid          NULL,
    status                    varchar(20)   NOT NULL DEFAULT 'active',
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT contact_addresses_pk PRIMARY KEY (tenant_id, contact_address_id),
    CONSTRAINT contact_addresses_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, contact_address_id),
    CONSTRAINT contact_addresses_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT contact_addresses_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT contact_addresses_team_fk FOREIGN KEY (tenant_id, organization_id, team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT contact_addresses_verifier_fk FOREIGN KEY (tenant_id, organization_id, verified_by_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT contact_addresses_purpose_ck CHECK (purpose IN ('support', 'security', 'operations', 'reports')),
    CONSTRAINT contact_addresses_address_format_ck CHECK (email_address ~ '^[^@\s]+@[^@\s]+$' AND email_address = btrim(email_address)),
    CONSTRAINT contact_addresses_key_format_ck CHECK (email_key ~ '^[^@\s]+@[^@\s]+$'
        AND split_part(email_key, '@', -1) = lower(split_part(email_key, '@', -1))),
    CONSTRAINT contact_addresses_method_ck CHECK (verification_method IN ('trusted_directory', 'provider_verified', 'admin_attested')),
    CONSTRAINT contact_addresses_verification_pair_ck CHECK ((verified_at IS NULL) = (verification_method IS NULL)),
    CONSTRAINT contact_addresses_attestation_ck CHECK (verification_method IS DISTINCT FROM 'admin_attested' OR verified_by_principal_id IS NOT NULL),
    CONSTRAINT contact_addresses_verifier_ck CHECK (verified_by_principal_id IS NULL OR verified_at IS NOT NULL),
    CONSTRAINT contact_addresses_status_ck CHECK (status IN ('active', 'revoked'))
);
CREATE UNIQUE INDEX contact_addresses_org_uix  ON cob3_settings.contact_addresses (tenant_id, organization_id, purpose, email_key) WHERE team_id IS NULL;
CREATE UNIQUE INDEX contact_addresses_team_uix ON cob3_settings.contact_addresses (tenant_id, organization_id, team_id, purpose, email_key) WHERE team_id IS NOT NULL;

CREATE TABLE cob3_settings.notification_endpoints (
    tenant_id                 uuid          NOT NULL,
    notification_endpoint_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id           uuid          NULL,
    setting_scope_id          uuid          NOT NULL,
    endpoint_type             varchar(16)   NOT NULL,
    principal_email_id        uuid          NULL,
    contact_address_id        uuid          NULL,
    webhook_url               text          NULL,
    secret_reference          varchar(512)  NULL,
    status                    varchar(20)   NOT NULL DEFAULT 'active',
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT notification_endpoints_pk PRIMARY KEY (tenant_id, notification_endpoint_id),
    CONSTRAINT notification_endpoints_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_endpoints_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_endpoints_scope_fk FOREIGN KEY (tenant_id, setting_scope_id)
        REFERENCES cob3_settings.setting_scopes (tenant_id, setting_scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_endpoints_principal_email_fk FOREIGN KEY (tenant_id, principal_email_id)
        REFERENCES cob3_identity.principal_emails (tenant_id, principal_email_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_endpoints_contact_fk FOREIGN KEY (tenant_id, organization_id, contact_address_id)
        REFERENCES cob3_settings.contact_addresses (tenant_id, organization_id, contact_address_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_endpoints_type_ck CHECK (endpoint_type IN ('email', 'in_app', 'webhook')),
    CONSTRAINT notification_endpoints_shape_ck CHECK (
           (endpoint_type = 'email'   AND (principal_email_id IS NULL) <> (contact_address_id IS NULL) AND webhook_url IS NULL AND secret_reference IS NULL)
        OR (endpoint_type = 'in_app'  AND principal_email_id IS NULL AND contact_address_id IS NULL AND webhook_url IS NULL AND secret_reference IS NULL)
        OR (endpoint_type = 'webhook' AND principal_email_id IS NULL AND contact_address_id IS NULL AND webhook_url IS NOT NULL)),
    CONSTRAINT notification_endpoints_contact_org_ck CHECK (contact_address_id IS NULL OR organization_id IS NOT NULL),
    CONSTRAINT notification_endpoints_webhook_url_ck CHECK (webhook_url IS NULL OR (
        webhook_url ~ '^https://[^\s/@]+(/[^\s]*)?$' AND webhook_url !~* '[?&](token|key|secret|signature|sig|password|apikey|api_key)=')),
    CONSTRAINT notification_endpoints_secret_ref_ck CHECK (secret_reference IS NULL OR secret_reference ~ '^[a-z][a-z0-9+.-]*://[^\s]+$'),
    CONSTRAINT notification_endpoints_status_ck CHECK (status IN ('active', 'disabled'))
);
CREATE INDEX notification_endpoints_scope_ix ON cob3_settings.notification_endpoints (tenant_id, setting_scope_id);
CREATE INDEX notification_endpoints_principal_email_ix ON cob3_settings.notification_endpoints (tenant_id, principal_email_id) WHERE principal_email_id IS NOT NULL;
CREATE INDEX notification_endpoints_contact_ix ON cob3_settings.notification_endpoints (tenant_id, organization_id, contact_address_id) WHERE contact_address_id IS NOT NULL;

CREATE TABLE cob3_settings.notification_preferences (
    tenant_id                   uuid          NOT NULL,
    notification_preference_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id             uuid          NULL,
    setting_scope_id            uuid          NOT NULL,
    category_code               varchar(64)   NOT NULL,
    channel_type                varchar(16)   NOT NULL,
    enabled                     boolean       NOT NULL DEFAULT true,
    delivery_mode               varchar(16)   NOT NULL DEFAULT 'immediate',
    quiet_start                 time          NULL,
    quiet_end                   time          NULL,
    timezone                    varchar(64)   NOT NULL,
    destination_endpoint_id     uuid          NULL,
    created_at                  timestamptz   NOT NULL DEFAULT now(),
    created_by                  varchar(255)  NOT NULL,
    updated_at                  timestamptz   NOT NULL DEFAULT now(),
    updated_by                  varchar(255)  NOT NULL,
    metadata                    jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                 bigint        NOT NULL DEFAULT 1,
    CONSTRAINT notification_preferences_pk PRIMARY KEY (tenant_id, notification_preference_id),
    CONSTRAINT notification_preferences_scope_category_uq UNIQUE (tenant_id, setting_scope_id, category_code, channel_type),
    CONSTRAINT notification_preferences_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_preferences_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_preferences_scope_fk FOREIGN KEY (tenant_id, setting_scope_id)
        REFERENCES cob3_settings.setting_scopes (tenant_id, setting_scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_preferences_endpoint_fk FOREIGN KEY (tenant_id, destination_endpoint_id)
        REFERENCES cob3_settings.notification_endpoints (tenant_id, notification_endpoint_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT notification_preferences_category_format_ck CHECK (category_code ~ '^[a-z][a-z0-9_.-]*$'),
    CONSTRAINT notification_preferences_channel_ck CHECK (channel_type IN ('email', 'in_app', 'webhook')),
    CONSTRAINT notification_preferences_delivery_ck CHECK (delivery_mode IN ('immediate', 'daily_digest', 'weekly_digest')),
    CONSTRAINT notification_preferences_quiet_pair_ck CHECK ((quiet_start IS NULL) = (quiet_end IS NULL)),
    CONSTRAINT notification_preferences_quiet_distinct_ck CHECK (quiet_start IS NULL OR quiet_start <> quiet_end)
);
CREATE INDEX notification_preferences_endpoint_ix ON cob3_settings.notification_preferences (tenant_id, destination_endpoint_id)
    WHERE destination_endpoint_id IS NOT NULL;

CREATE TABLE cob3_settings.integration_configurations (
    tenant_id                     uuid          NOT NULL,
    integration_configuration_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id               uuid          NULL,
    setting_scope_id              uuid          NOT NULL,
    integration_code              varchar(64)   NOT NULL,
    configuration_version         integer       NOT NULL,
    adapter_type                  varchar(32)   NOT NULL,
    identity_provider_id          uuid          NULL,
    configuration                 jsonb         NOT NULL,
    secret_reference              varchar(512)  NULL,
    status                        varchar(20)   NOT NULL DEFAULT 'draft',
    last_verified_at              timestamptz   NULL,
    created_at                    timestamptz   NOT NULL DEFAULT now(),
    created_by                    varchar(255)  NOT NULL,
    updated_at                    timestamptz   NOT NULL DEFAULT now(),
    updated_by                    varchar(255)  NOT NULL,
    metadata                      jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                   bigint        NOT NULL DEFAULT 1,
    CONSTRAINT integration_configurations_pk PRIMARY KEY (tenant_id, integration_configuration_id),
    CONSTRAINT integration_configurations_version_uq UNIQUE (tenant_id, setting_scope_id, integration_code, configuration_version),
    CONSTRAINT integration_configurations_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT integration_configurations_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT integration_configurations_scope_fk FOREIGN KEY (tenant_id, setting_scope_id)
        REFERENCES cob3_settings.setting_scopes (tenant_id, setting_scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT integration_configurations_idp_fk FOREIGN KEY (tenant_id, identity_provider_id)
        REFERENCES cob3_identity.identity_providers (tenant_id, identity_provider_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT integration_configurations_code_format_ck CHECK (integration_code ~ '^[a-z][a-z0-9_.-]*$'),
    CONSTRAINT integration_configurations_version_ck CHECK (configuration_version > 0),
    -- Settings design adapters plus the AI design's provider/tool/exporter/connector adapters.
    CONSTRAINT integration_configurations_adapter_ck CHECK (adapter_type IN (
        'oidc', 'saml', 'smtp', 'email_api', 'webhook', 'product_adapter',
        'model_provider', 'tool_endpoint', 'telemetry_exporter', 'connector', 'training_provider')),
    CONSTRAINT integration_configurations_sso_idp_ck CHECK ((adapter_type IN ('oidc', 'saml')) = (identity_provider_id IS NOT NULL)),
    CONSTRAINT integration_configurations_config_object_ck CHECK (jsonb_typeof(configuration) = 'object' AND pg_column_size(configuration) <= 65536),
    CONSTRAINT integration_configurations_config_no_secrets_ck CHECK (NOT (configuration ?| ARRAY['password', 'secret', 'client_secret', 'private_key',
                                                                                                 'api_key', 'access_token', 'refresh_token', 'token'])),
    CONSTRAINT integration_configurations_secret_ref_ck CHECK (secret_reference IS NULL OR secret_reference ~ '^[a-z][a-z0-9+.-]*://[^\s]+$'),
    CONSTRAINT integration_configurations_status_ck CHECK (status IN ('draft', 'active', 'retired'))
);
CREATE UNIQUE INDEX integration_configurations_active_uix
    ON cob3_settings.integration_configurations (tenant_id, setting_scope_id, integration_code) WHERE status = 'active';
CREATE INDEX integration_configurations_idp_ix ON cob3_settings.integration_configurations (tenant_id, identity_provider_id)
    WHERE identity_provider_id IS NOT NULL;

CREATE TABLE cob3_settings.automation_policies (
    tenant_id                        uuid          NOT NULL,
    automation_policy_id             uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                  uuid          NULL,
    policy_version                   integer       NOT NULL,
    allow_automation                 boolean       NOT NULL DEFAULT false,
    max_grant_lifetime_seconds       integer       NOT NULL,
    max_credential_lifetime_seconds  integer       NOT NULL,
    require_approval_for_writes      boolean       NOT NULL DEFAULT true,
    allow_external_delivery          boolean       NOT NULL DEFAULT false,
    status                           varchar(20)   NOT NULL DEFAULT 'draft',
    created_at                       timestamptz   NOT NULL DEFAULT now(),
    created_by                       varchar(255)  NOT NULL,
    updated_at                       timestamptz   NOT NULL DEFAULT now(),
    updated_by                       varchar(255)  NOT NULL,
    metadata                         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT automation_policies_pk PRIMARY KEY (tenant_id, automation_policy_id),
    CONSTRAINT automation_policies_version_uq UNIQUE NULLS NOT DISTINCT (tenant_id, organization_id, policy_version),
    CONSTRAINT automation_policies_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT automation_policies_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT automation_policies_version_ck CHECK (policy_version > 0),
    CONSTRAINT automation_policies_lifetimes_ck CHECK (max_grant_lifetime_seconds > 0 AND max_credential_lifetime_seconds > 0),
    CONSTRAINT automation_policies_status_ck CHECK (status IN ('draft', 'active', 'retired'))
);
CREATE UNIQUE INDEX automation_policies_active_uix
    ON cob3_settings.automation_policies (tenant_id, organization_id) NULLS NOT DISTINCT WHERE status = 'active';
CREATE INDEX automation_policies_organization_ix ON cob3_settings.automation_policies (tenant_id, organization_id) WHERE organization_id IS NOT NULL;

-- FK lookup indexes for nullable organization references and same-scope media.
CREATE INDEX setting_values_organization_ix ON cob3_settings.setting_values (tenant_id, organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX setting_change_events_organization_ix ON cob3_settings.setting_change_events (tenant_id, organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX media_objects_organization_ix ON cob3_settings.media_objects (tenant_id, organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX branding_profiles_organization_ix ON cob3_settings.branding_profiles (tenant_id, organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX branding_profiles_logo_ix ON cob3_settings.branding_profiles (tenant_id, setting_scope_id, logo_media_id) WHERE logo_media_id IS NOT NULL;
CREATE INDEX branding_profiles_favicon_ix ON cob3_settings.branding_profiles (tenant_id, setting_scope_id, favicon_media_id) WHERE favicon_media_id IS NOT NULL;
CREATE INDEX contact_addresses_verifier_ix ON cob3_settings.contact_addresses (tenant_id, organization_id, verified_by_principal_id)
    WHERE verified_by_principal_id IS NOT NULL;
CREATE INDEX notification_endpoints_organization_ix ON cob3_settings.notification_endpoints (tenant_id, organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX notification_preferences_organization_ix ON cob3_settings.notification_preferences (tenant_id, organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX integration_configurations_organization_ix ON cob3_settings.integration_configurations (tenant_id, organization_id) WHERE organization_id IS NOT NULL;
