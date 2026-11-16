-- =============================================================================
-- 20  cob3_tenant TABLES (21 logical tables + 2 documented support tables)
-- -----------------------------------------------------------------------------
-- Key shape follows the Tenant specification: entity PK is the entity UUID, and
-- every tenant-owned table also exposes UNIQUE (tenant_id, <entity_id>) for
-- tenant-qualified child FKs. Platform catalog rows require tenant_id IS NULL
-- AND organization_id IS NULL (not a wildcard: separate RLS applies).
-- Common checks (metadata object, row_version > 0, actor format, no secret
-- keys in metadata) are attached uniformly in section 40.
-- Cross-schema FKs into cob3_identity are added in section 40 after the
-- Identity tables exist.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Support table (not one of the 48 logical tables): installation/version record
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.foundation_installations (
    installation_id     uuid          NOT NULL DEFAULT gen_random_uuid(),
    component           varchar(64)   NOT NULL,
    version             varchar(32)   NOT NULL,
    script_checksum     varchar(64)   NOT NULL,
    installed_at        timestamptz   NOT NULL DEFAULT now(),
    installed_by        varchar(255)  NOT NULL DEFAULT session_user,
    server_version_num  integer       NOT NULL,
    notes               text          NULL,
    CONSTRAINT foundation_installations_pk PRIMARY KEY (installation_id),
    CONSTRAINT foundation_installations_component_version_uq UNIQUE (component, version),
    CONSTRAINT foundation_installations_component_ck CHECK (component ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT foundation_installations_checksum_ck CHECK (script_checksum ~ '^[0-9a-f]{64}$')
);

-- ---------------------------------------------------------------------------
-- 1. tenants
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.tenants (
    tenant_id          uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id    uuid          NULL,
    tenant_code        varchar(64)   NOT NULL,
    name               varchar(200)  NOT NULL,
    legal_name         varchar(255)  NULL,
    status             varchar(24)   NOT NULL DEFAULT 'provisioning',
    home_region        varchar(64)   NOT NULL,
    activated_at       timestamptz   NULL,
    suspended_at       timestamptz   NULL,
    closed_at          timestamptz   NULL,
    suspension_reason  text          NULL,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         varchar(255)  NOT NULL,
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    updated_by         varchar(255)  NOT NULL,
    metadata           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT tenants_pk PRIMARY KEY (tenant_id),
    CONSTRAINT tenants_tenant_code_uq UNIQUE (tenant_code),
    CONSTRAINT tenants_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT tenants_tenant_code_format_ck CHECK (tenant_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT tenants_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT tenants_legal_name_nonblank_ck CHECK (legal_name IS NULL OR length(btrim(legal_name)) > 0),
    CONSTRAINT tenants_status_ck CHECK (status IN ('provisioning', 'active', 'suspended', 'closing', 'closed')),
    CONSTRAINT tenants_home_region_format_ck CHECK (home_region ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT tenants_suspension_ck CHECK (
        (status = 'suspended') = (suspended_at IS NOT NULL)
        AND (status = 'suspended') = (suspension_reason IS NOT NULL)
        AND (suspension_reason IS NULL OR length(btrim(suspension_reason)) > 0)),
    CONSTRAINT tenants_closed_ck CHECK ((status = 'closed') = (closed_at IS NOT NULL)),
    CONSTRAINT tenants_active_requires_activation_ck CHECK (status <> 'active' OR activated_at IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- 2. tenant_contacts
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.tenant_contacts (
    tenant_contact_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          uuid          NOT NULL,
    organization_id    uuid          NULL,
    contact_type       varchar(20)   NOT NULL,
    name               varchar(200)  NOT NULL,
    email              varchar(320)  NOT NULL,
    phone              varchar(32)   NULL,
    principal_id       uuid          NULL,
    is_primary         boolean       NOT NULL DEFAULT false,
    status             varchar(16)   NOT NULL DEFAULT 'active',
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         varchar(255)  NOT NULL,
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    updated_by         varchar(255)  NOT NULL,
    metadata           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT tenant_contacts_pk PRIMARY KEY (tenant_contact_id),
    CONSTRAINT tenant_contacts_tenant_entity_uq UNIQUE (tenant_id, tenant_contact_id),
    CONSTRAINT tenant_contacts_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tenant_contacts_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT tenant_contacts_contact_type_ck CHECK (contact_type IN ('billing', 'technical', 'security', 'legal')),
    CONSTRAINT tenant_contacts_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT tenant_contacts_email_format_ck CHECK (email ~ '^[^@\s]+@[^@\s]+$'),
    CONSTRAINT tenant_contacts_status_ck CHECK (status IN ('active', 'inactive'))
);
CREATE UNIQUE INDEX tenant_contacts_primary_per_type_uix
    ON cob3_tenant.tenant_contacts (tenant_id, contact_type)
    WHERE is_primary AND status = 'active';
CREATE INDEX tenant_contacts_principal_ix ON cob3_tenant.tenant_contacts (tenant_id, principal_id);

-- ---------------------------------------------------------------------------
-- 3. tenant_lifecycle_events (append-only)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.tenant_lifecycle_events (
    tenant_lifecycle_event_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                  uuid          NOT NULL,
    organization_id            uuid          NULL,
    from_status                varchar(24)   NULL,
    to_status                  varchar(24)   NOT NULL,
    occurred_at                timestamptz   NOT NULL,
    reason                     text          NOT NULL,
    request_id                 uuid          NOT NULL,
    actor_principal_id         uuid          NULL,
    created_at                 timestamptz   NOT NULL DEFAULT now(),
    created_by                 varchar(255)  NOT NULL,
    updated_at                 timestamptz   NOT NULL DEFAULT now(),
    updated_by                 varchar(255)  NOT NULL,
    metadata                   jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                bigint        NOT NULL DEFAULT 1,
    CONSTRAINT tenant_lifecycle_events_pk PRIMARY KEY (tenant_lifecycle_event_id),
    CONSTRAINT tenant_lifecycle_events_tenant_entity_uq UNIQUE (tenant_id, tenant_lifecycle_event_id),
    CONSTRAINT tenant_lifecycle_events_request_uq UNIQUE (tenant_id, request_id),
    CONSTRAINT tenant_lifecycle_events_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tenant_lifecycle_events_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT tenant_lifecycle_events_from_status_ck CHECK (from_status IS NULL OR from_status IN ('provisioning', 'active', 'suspended', 'closing', 'closed')),
    CONSTRAINT tenant_lifecycle_events_to_status_ck CHECK (to_status IN ('provisioning', 'active', 'suspended', 'closing', 'closed')),
    CONSTRAINT tenant_lifecycle_events_changes_status_ck CHECK (from_status IS DISTINCT FROM to_status),
    CONSTRAINT tenant_lifecycle_events_reason_nonblank_ck CHECK (length(btrim(reason)) > 0),
    CONSTRAINT tenant_lifecycle_events_append_only_ck CHECK (row_version = 1 AND updated_at = created_at AND updated_by = created_by)
);

-- ---------------------------------------------------------------------------
-- 4. provisioning_jobs
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.provisioning_jobs (
    provisioning_job_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id            uuid          NOT NULL,
    organization_id      uuid          NULL,
    job_type             varchar(24)   NOT NULL,
    idempotency_key      varchar(128)  NOT NULL,
    status               varchar(20)   NOT NULL DEFAULT 'pending',
    attempt_count        integer       NOT NULL DEFAULT 0,
    started_at           timestamptz   NULL,
    completed_at         timestamptz   NULL,
    next_attempt_at      timestamptz   NULL,
    lease_expires_at     timestamptz   NULL,
    last_error_code      varchar(64)   NULL,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    created_by           varchar(255)  NOT NULL,
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    updated_by           varchar(255)  NOT NULL,
    metadata             jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version          bigint        NOT NULL DEFAULT 1,
    CONSTRAINT provisioning_jobs_pk PRIMARY KEY (provisioning_job_id),
    CONSTRAINT provisioning_jobs_tenant_entity_uq UNIQUE (tenant_id, provisioning_job_id),
    CONSTRAINT provisioning_jobs_idempotency_uq UNIQUE (tenant_id, job_type, idempotency_key),
    CONSTRAINT provisioning_jobs_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT provisioning_jobs_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT provisioning_jobs_job_type_ck CHECK (job_type IN ('onboard', 'suspend', 'resume', 'offboard')),
    CONSTRAINT provisioning_jobs_idempotency_key_nonblank_ck CHECK (length(btrim(idempotency_key)) > 0),
    CONSTRAINT provisioning_jobs_status_ck CHECK (status IN ('pending', 'running', 'succeeded', 'failed')),
    CONSTRAINT provisioning_jobs_attempt_count_ck CHECK (attempt_count >= 0),
    CONSTRAINT provisioning_jobs_running_lease_ck CHECK (status <> 'running' OR (lease_expires_at IS NOT NULL AND started_at IS NOT NULL)),
    CONSTRAINT provisioning_jobs_lease_only_running_ck CHECK (status = 'running' OR lease_expires_at IS NULL),
    CONSTRAINT provisioning_jobs_completed_ck CHECK ((status IN ('succeeded', 'failed')) = (completed_at IS NOT NULL))
);
CREATE INDEX provisioning_jobs_queue_ix ON cob3_tenant.provisioning_jobs (status, next_attempt_at);

-- ---------------------------------------------------------------------------
-- 5. plans (platform catalog)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.plans (
    plan_id          uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id        uuid          NULL,
    organization_id  uuid          NULL,
    plan_code        varchar(64)   NOT NULL,
    name             varchar(150)  NOT NULL,
    description      text          NULL,
    status           varchar(16)   NOT NULL DEFAULT 'draft',
    created_at       timestamptz   NOT NULL DEFAULT now(),
    created_by       varchar(255)  NOT NULL,
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    updated_by       varchar(255)  NOT NULL,
    metadata         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT plans_pk PRIMARY KEY (plan_id),
    CONSTRAINT plans_plan_code_uq UNIQUE (plan_code),
    CONSTRAINT plans_platform_scope_ck CHECK (tenant_id IS NULL AND organization_id IS NULL),
    CONSTRAINT plans_plan_code_format_ck CHECK (plan_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT plans_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT plans_status_ck CHECK (status IN ('draft', 'active', 'retired'))
);

-- ---------------------------------------------------------------------------
-- 6. plan_versions (platform catalog)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.plan_versions (
    plan_version_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id        uuid          NULL,
    organization_id  uuid          NULL,
    plan_id          uuid          NOT NULL,
    version_number   integer       NOT NULL,
    status           varchar(16)   NOT NULL DEFAULT 'draft',
    effective_from   timestamptz   NOT NULL,
    effective_until  timestamptz   NULL,
    published_at     timestamptz   NULL,
    terms_reference  varchar(255)  NULL,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    created_by       varchar(255)  NOT NULL,
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    updated_by       varchar(255)  NOT NULL,
    metadata         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT plan_versions_pk PRIMARY KEY (plan_version_id),
    CONSTRAINT plan_versions_plan_version_number_uq UNIQUE (plan_id, version_number),
    CONSTRAINT plan_versions_plan_fk FOREIGN KEY (plan_id)
        REFERENCES cob3_tenant.plans (plan_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT plan_versions_platform_scope_ck CHECK (tenant_id IS NULL AND organization_id IS NULL),
    CONSTRAINT plan_versions_version_number_ck CHECK (version_number > 0),
    CONSTRAINT plan_versions_status_ck CHECK (status IN ('draft', 'published', 'retired')),
    CONSTRAINT plan_versions_effective_window_ck CHECK (effective_until IS NULL OR effective_until > effective_from),
    CONSTRAINT plan_versions_published_at_ck CHECK ((status = 'draft') = (published_at IS NULL))
);

-- ---------------------------------------------------------------------------
-- 7. features (platform catalog)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.features (
    feature_id        uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id         uuid          NULL,
    organization_id   uuid          NULL,
    feature_code      varchar(128)  NOT NULL,
    name              varchar(150)  NOT NULL,
    description       text          NULL,
    value_type        varchar(16)   NOT NULL,
    unit_code         varchar(32)   NULL,
    measurement_kind  varchar(24)   NOT NULL,
    status            varchar(16)   NOT NULL DEFAULT 'active',
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        varchar(255)  NOT NULL,
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    updated_by        varchar(255)  NOT NULL,
    metadata          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version       bigint        NOT NULL DEFAULT 1,
    CONSTRAINT features_pk PRIMARY KEY (feature_id),
    CONSTRAINT features_feature_code_uq UNIQUE (feature_code),
    CONSTRAINT features_platform_scope_ck CHECK (tenant_id IS NULL AND organization_id IS NULL),
    CONSTRAINT features_feature_code_format_ck CHECK (feature_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT features_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT features_value_type_ck CHECK (value_type IN ('boolean', 'quota')),
    CONSTRAINT features_measurement_kind_ck CHECK (measurement_kind IN ('capability', 'gauge', 'counter')),
    CONSTRAINT features_unit_code_format_ck CHECK (unit_code IS NULL OR unit_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT features_shape_ck CHECK (
        (value_type = 'boolean' AND measurement_kind = 'capability' AND unit_code IS NULL)
        OR (value_type = 'quota' AND measurement_kind IN ('gauge', 'counter') AND unit_code IS NOT NULL)),
    CONSTRAINT features_status_ck CHECK (status IN ('active', 'retired'))
);

-- ---------------------------------------------------------------------------
-- 8. plan_entitlements (platform catalog)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.plan_entitlements (
    plan_entitlement_id  uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id            uuid           NULL,
    organization_id      uuid           NULL,
    plan_version_id      uuid           NOT NULL,
    feature_id           uuid           NOT NULL,
    is_enabled           boolean        NOT NULL DEFAULT false,
    limit_value          numeric(24,6)  NULL,
    is_unlimited         boolean        NOT NULL DEFAULT false,
    reset_period         varchar(24)    NOT NULL,
    created_at           timestamptz    NOT NULL DEFAULT now(),
    created_by           varchar(255)   NOT NULL,
    updated_at           timestamptz    NOT NULL DEFAULT now(),
    updated_by           varchar(255)   NOT NULL,
    metadata             jsonb          NOT NULL DEFAULT '{}'::jsonb,
    row_version          bigint         NOT NULL DEFAULT 1,
    CONSTRAINT plan_entitlements_pk PRIMARY KEY (plan_entitlement_id),
    CONSTRAINT plan_entitlements_version_feature_uq UNIQUE (plan_version_id, feature_id),
    CONSTRAINT plan_entitlements_plan_version_fk FOREIGN KEY (plan_version_id)
        REFERENCES cob3_tenant.plan_versions (plan_version_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT plan_entitlements_feature_fk FOREIGN KEY (feature_id)
        REFERENCES cob3_tenant.features (feature_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT plan_entitlements_platform_scope_ck CHECK (tenant_id IS NULL AND organization_id IS NULL),
    CONSTRAINT plan_entitlements_limit_nonnegative_ck CHECK (limit_value IS NULL OR limit_value >= 0),
    CONSTRAINT plan_entitlements_reset_period_ck CHECK (reset_period IN ('none', 'calendar_month', 'subscription_period')),
    CONSTRAINT plan_entitlements_shape_ck CHECK (
        (NOT is_enabled AND limit_value IS NULL AND NOT is_unlimited)
        OR (is_enabled AND is_unlimited AND limit_value IS NULL)
        OR (is_enabled AND NOT is_unlimited))
);
CREATE INDEX plan_entitlements_feature_ix ON cob3_tenant.plan_entitlements (feature_id);

-- ---------------------------------------------------------------------------
-- 9. plan_prices (platform catalog)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.plan_prices (
    plan_price_id             uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                 uuid          NULL,
    organization_id           uuid          NULL,
    plan_version_id           uuid          NOT NULL,
    price_code                varchar(64)   NOT NULL,
    currency_code             varchar(3)    NOT NULL,
    billing_interval          varchar(16)   NOT NULL,
    base_amount_minor         bigint        NOT NULL,
    effective_from            timestamptz   NOT NULL,
    effective_until           timestamptz   NULL,
    status                    varchar(16)   NOT NULL DEFAULT 'draft',
    provider_price_reference  varchar(255)  NULL,
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT plan_prices_pk PRIMARY KEY (plan_price_id),
    CONSTRAINT plan_prices_price_code_uq UNIQUE (price_code),
    CONSTRAINT plan_prices_version_price_uq UNIQUE (plan_version_id, plan_price_id),
    CONSTRAINT plan_prices_plan_version_fk FOREIGN KEY (plan_version_id)
        REFERENCES cob3_tenant.plan_versions (plan_version_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT plan_prices_platform_scope_ck CHECK (tenant_id IS NULL AND organization_id IS NULL),
    CONSTRAINT plan_prices_price_code_format_ck CHECK (price_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT plan_prices_currency_code_ck CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT plan_prices_billing_interval_ck CHECK (billing_interval IN ('month', 'year')),
    CONSTRAINT plan_prices_base_amount_ck CHECK (base_amount_minor >= 0),
    CONSTRAINT plan_prices_effective_window_ck CHECK (effective_until IS NULL OR effective_until > effective_from),
    CONSTRAINT plan_prices_status_ck CHECK (status IN ('draft', 'published', 'retired'))
);

-- ---------------------------------------------------------------------------
-- 10. billing_accounts
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.billing_accounts (
    billing_account_id           uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                    uuid          NOT NULL,
    organization_id              uuid          NULL,
    legal_name                   varchar(255)  NOT NULL,
    billing_email                varchar(320)  NOT NULL,
    billing_address              jsonb         NOT NULL,
    country_code                 varchar(2)    NOT NULL,
    provider_code                varchar(64)   NULL,
    provider_account_reference   varchar(128)  NULL,
    provider_customer_reference  varchar(255)  NULL,
    status                       varchar(16)   NOT NULL DEFAULT 'active',
    created_at                   timestamptz   NOT NULL DEFAULT now(),
    created_by                   varchar(255)  NOT NULL,
    updated_at                   timestamptz   NOT NULL DEFAULT now(),
    updated_by                   varchar(255)  NOT NULL,
    metadata                     jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                  bigint        NOT NULL DEFAULT 1,
    CONSTRAINT billing_accounts_pk PRIMARY KEY (billing_account_id),
    CONSTRAINT billing_accounts_tenant_entity_uq UNIQUE (tenant_id, billing_account_id),
    CONSTRAINT billing_accounts_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT billing_accounts_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT billing_accounts_legal_name_nonblank_ck CHECK (length(btrim(legal_name)) > 0),
    CONSTRAINT billing_accounts_billing_email_format_ck CHECK (billing_email ~ '^[^@\s]+@[^@\s]+$'),
    CONSTRAINT billing_accounts_address_object_ck CHECK (jsonb_typeof(billing_address) = 'object' AND billing_address <> '{}'::jsonb),
    CONSTRAINT billing_accounts_address_no_card_data_ck CHECK (NOT (billing_address ?| ARRAY['card', 'card_number', 'pan', 'cvv', 'cvc', 'expiry', 'iban'])),
    CONSTRAINT billing_accounts_country_code_ck CHECK (country_code ~ '^[A-Z]{2}$'),
    CONSTRAINT billing_accounts_provider_code_format_ck CHECK (provider_code IS NULL OR provider_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT billing_accounts_provider_all_or_none_ck CHECK (
        (provider_code IS NULL) = (provider_account_reference IS NULL)
        AND (provider_code IS NULL) = (provider_customer_reference IS NULL)),
    CONSTRAINT billing_accounts_status_ck CHECK (status IN ('active', 'inactive'))
);
CREATE UNIQUE INDEX billing_accounts_provider_customer_uix
    ON cob3_tenant.billing_accounts (provider_code, provider_account_reference, provider_customer_reference)
    WHERE provider_code IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 11. subscriptions
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.subscriptions (
    subscription_id                  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                        uuid          NOT NULL,
    organization_id                  uuid          NULL,
    billing_account_id               uuid          NOT NULL,
    status                           varchar(24)   NOT NULL DEFAULT 'pending',
    started_at                       timestamptz   NULL,
    trial_ends_at                    timestamptz   NULL,
    cancel_at                        timestamptz   NULL,
    ended_at                         timestamptz   NULL,
    provider_subscription_reference  varchar(255)  NULL,
    created_at                       timestamptz   NOT NULL DEFAULT now(),
    created_by                       varchar(255)  NOT NULL,
    updated_at                       timestamptz   NOT NULL DEFAULT now(),
    updated_by                       varchar(255)  NOT NULL,
    metadata                         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT subscriptions_pk PRIMARY KEY (subscription_id),
    CONSTRAINT subscriptions_tenant_entity_uq UNIQUE (tenant_id, subscription_id),
    CONSTRAINT subscriptions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscriptions_billing_account_fk FOREIGN KEY (tenant_id, billing_account_id)
        REFERENCES cob3_tenant.billing_accounts (tenant_id, billing_account_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscriptions_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT subscriptions_status_ck CHECK (status IN ('pending', 'trialing', 'active', 'past_due', 'paused', 'canceled', 'expired')),
    CONSTRAINT subscriptions_ended_ck CHECK ((status IN ('canceled', 'expired')) = (ended_at IS NOT NULL)),
    CONSTRAINT subscriptions_started_ck CHECK (status IN ('pending', 'canceled', 'expired') OR started_at IS NOT NULL),
    CONSTRAINT subscriptions_trial_ck CHECK (status <> 'trialing' OR trial_ends_at IS NOT NULL),
    CONSTRAINT subscriptions_trial_order_ck CHECK (trial_ends_at IS NULL OR started_at IS NULL OR trial_ends_at > started_at),
    CONSTRAINT subscriptions_end_order_ck CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at)
);
-- One live base subscription per tenant (v1).
CREATE UNIQUE INDEX subscriptions_one_live_per_tenant_uix
    ON cob3_tenant.subscriptions (tenant_id)
    WHERE status IN ('pending', 'trialing', 'active', 'past_due', 'paused');
CREATE INDEX subscriptions_tenant_status_ix ON cob3_tenant.subscriptions (tenant_id, status);
CREATE INDEX subscriptions_billing_account_ix ON cob3_tenant.subscriptions (tenant_id, billing_account_id);
CREATE INDEX subscriptions_provider_reference_ix ON cob3_tenant.subscriptions (provider_subscription_reference)
    WHERE provider_subscription_reference IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 12. subscription_periods
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.subscription_periods (
    subscription_period_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id               uuid          NOT NULL,
    organization_id         uuid          NULL,
    subscription_id         uuid          NOT NULL,
    billing_period_key      varchar(128)  NOT NULL,
    segment_number          integer       NOT NULL,
    plan_version_id         uuid          NOT NULL,
    plan_price_id           uuid          NOT NULL,
    period_start            timestamptz   NOT NULL,
    period_end              timestamptz   NOT NULL,
    currency_code           varchar(3)    NOT NULL,
    contract_amount_minor   bigint        NOT NULL,
    status                  varchar(16)   NOT NULL DEFAULT 'scheduled',
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT subscription_periods_pk PRIMARY KEY (subscription_period_id),
    CONSTRAINT subscription_periods_tenant_entity_uq UNIQUE (tenant_id, subscription_period_id),
    CONSTRAINT subscription_periods_segment_uq UNIQUE (tenant_id, subscription_id, billing_period_key, segment_number),
    CONSTRAINT subscription_periods_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscription_periods_subscription_fk FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES cob3_tenant.subscriptions (tenant_id, subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscription_periods_plan_price_fk FOREIGN KEY (plan_version_id, plan_price_id)
        REFERENCES cob3_tenant.plan_prices (plan_version_id, plan_price_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscription_periods_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT subscription_periods_billing_period_key_nonblank_ck CHECK (length(btrim(billing_period_key)) > 0),
    CONSTRAINT subscription_periods_segment_number_ck CHECK (segment_number > 0),
    CONSTRAINT subscription_periods_window_ck CHECK (period_end > period_start),
    CONSTRAINT subscription_periods_currency_code_ck CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT subscription_periods_amount_ck CHECK (contract_amount_minor >= 0),
    CONSTRAINT subscription_periods_status_ck CHECK (status IN ('scheduled', 'active', 'closed')),
    -- No overlapping effective contract segments within a subscription.
    CONSTRAINT subscription_periods_no_overlap_ex EXCLUDE USING gist (
        tenant_id WITH =, subscription_id WITH =, tstzrange(period_start, period_end, '[)') WITH &&)
);
CREATE INDEX subscription_periods_lookup_ix ON cob3_tenant.subscription_periods (tenant_id, subscription_id, period_start);
CREATE INDEX subscription_periods_plan_price_ix ON cob3_tenant.subscription_periods (plan_version_id, plan_price_id);

-- ---------------------------------------------------------------------------
-- 13. subscription_changes
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.subscription_changes (
    subscription_change_id     uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                  uuid          NOT NULL,
    organization_id            uuid          NULL,
    subscription_id            uuid          NOT NULL,
    change_type                varchar(24)   NOT NULL,
    target_plan_price_id       uuid          NULL,
    effective_at               timestamptz   NOT NULL,
    status                     varchar(20)   NOT NULL DEFAULT 'requested',
    requested_by_principal_id  uuid          NULL,
    approved_by_principal_id   uuid          NULL,
    approved_at                timestamptz   NULL,
    applied_at                 timestamptz   NULL,
    idempotency_key            varchar(128)  NOT NULL,
    reason                     text          NOT NULL,
    created_at                 timestamptz   NOT NULL DEFAULT now(),
    created_by                 varchar(255)  NOT NULL,
    updated_at                 timestamptz   NOT NULL DEFAULT now(),
    updated_by                 varchar(255)  NOT NULL,
    metadata                   jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                bigint        NOT NULL DEFAULT 1,
    CONSTRAINT subscription_changes_pk PRIMARY KEY (subscription_change_id),
    CONSTRAINT subscription_changes_tenant_entity_uq UNIQUE (tenant_id, subscription_change_id),
    CONSTRAINT subscription_changes_idempotency_uq UNIQUE (tenant_id, idempotency_key),
    CONSTRAINT subscription_changes_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscription_changes_subscription_fk FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES cob3_tenant.subscriptions (tenant_id, subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscription_changes_target_price_fk FOREIGN KEY (target_plan_price_id)
        REFERENCES cob3_tenant.plan_prices (plan_price_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT subscription_changes_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT subscription_changes_change_type_ck CHECK (change_type IN ('upgrade', 'downgrade', 'cancel', 'resume')),
    CONSTRAINT subscription_changes_target_ck CHECK ((change_type IN ('upgrade', 'downgrade')) = (target_plan_price_id IS NOT NULL)),
    CONSTRAINT subscription_changes_status_ck CHECK (status IN ('requested', 'approved', 'applied', 'rejected', 'canceled')),
    CONSTRAINT subscription_changes_approved_ck CHECK (status NOT IN ('approved', 'applied') OR approved_at IS NOT NULL),
    CONSTRAINT subscription_changes_approver_ck CHECK (approved_by_principal_id IS NULL OR approved_at IS NOT NULL),
    CONSTRAINT subscription_changes_applied_ck CHECK ((status = 'applied') = (applied_at IS NOT NULL)),
    CONSTRAINT subscription_changes_idempotency_key_nonblank_ck CHECK (length(btrim(idempotency_key)) > 0),
    CONSTRAINT subscription_changes_reason_nonblank_ck CHECK (length(btrim(reason)) > 0)
);
CREATE INDEX subscription_changes_subscription_ix ON cob3_tenant.subscription_changes (tenant_id, subscription_id, status);
CREATE INDEX subscription_changes_target_price_ix ON cob3_tenant.subscription_changes (target_plan_price_id);
CREATE INDEX subscription_changes_requested_by_ix ON cob3_tenant.subscription_changes (tenant_id, requested_by_principal_id);
CREATE INDEX subscription_changes_approved_by_ix ON cob3_tenant.subscription_changes (tenant_id, approved_by_principal_id);

-- ---------------------------------------------------------------------------
-- 14. tenant_entitlement_overrides
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.tenant_entitlement_overrides (
    tenant_entitlement_override_id  uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                       uuid           NOT NULL,
    organization_id                 uuid           NULL,
    feature_id                      uuid           NOT NULL,
    is_enabled                      boolean        NOT NULL,
    limit_value                     numeric(24,6)  NULL,
    is_unlimited                    boolean        NOT NULL DEFAULT false,
    reset_period                    varchar(24)    NOT NULL,
    valid_from                      timestamptz    NOT NULL,
    valid_until                     timestamptz    NOT NULL,
    status                          varchar(16)    NOT NULL DEFAULT 'draft',
    approved_by                     varchar(255)   NULL,
    approved_at                     timestamptz    NULL,
    reason                          text           NOT NULL,
    contract_reference              varchar(255)   NULL,
    created_at                      timestamptz    NOT NULL DEFAULT now(),
    created_by                      varchar(255)   NOT NULL,
    updated_at                      timestamptz    NOT NULL DEFAULT now(),
    updated_by                      varchar(255)   NOT NULL,
    metadata                        jsonb          NOT NULL DEFAULT '{}'::jsonb,
    row_version                     bigint         NOT NULL DEFAULT 1,
    CONSTRAINT tenant_entitlement_overrides_pk PRIMARY KEY (tenant_entitlement_override_id),
    CONSTRAINT tenant_entitlement_overrides_tenant_entity_uq UNIQUE (tenant_id, tenant_entitlement_override_id),
    CONSTRAINT tenant_entitlement_overrides_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tenant_entitlement_overrides_feature_fk FOREIGN KEY (feature_id)
        REFERENCES cob3_tenant.features (feature_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tenant_entitlement_overrides_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT tenant_entitlement_overrides_limit_nonnegative_ck CHECK (limit_value IS NULL OR limit_value >= 0),
    CONSTRAINT tenant_entitlement_overrides_reset_period_ck CHECK (reset_period IN ('none', 'calendar_month', 'subscription_period')),
    CONSTRAINT tenant_entitlement_overrides_shape_ck CHECK (
        (NOT is_enabled AND limit_value IS NULL AND NOT is_unlimited)
        OR (is_enabled AND is_unlimited AND limit_value IS NULL)
        OR (is_enabled AND NOT is_unlimited)),
    CONSTRAINT tenant_entitlement_overrides_window_ck CHECK (valid_until > valid_from),
    CONSTRAINT tenant_entitlement_overrides_status_ck CHECK (status IN ('draft', 'approved', 'revoked')),
    CONSTRAINT tenant_entitlement_overrides_approval_pair_ck CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
    CONSTRAINT tenant_entitlement_overrides_approved_ck CHECK (status <> 'approved' OR approved_by IS NOT NULL),
    CONSTRAINT tenant_entitlement_overrides_approved_by_format_ck CHECK (
        approved_by IS NULL OR approved_by ~ '^(principal:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|system:[a-z0-9][a-z0-9_.:-]{0,200})$'),
    CONSTRAINT tenant_entitlement_overrides_reason_nonblank_ck CHECK (length(btrim(reason)) > 0),
    -- No overlapping approved windows per tenant/feature.
    CONSTRAINT tenant_entitlement_overrides_no_overlap_ex EXCLUDE USING gist (
        tenant_id WITH =, feature_id WITH =, tstzrange(valid_from, valid_until, '[)') WITH &&)
        WHERE (status = 'approved')
);
CREATE INDEX tenant_entitlement_overrides_lookup_ix ON cob3_tenant.tenant_entitlement_overrides (tenant_id, feature_id, valid_from);
CREATE INDEX tenant_entitlement_overrides_feature_ix ON cob3_tenant.tenant_entitlement_overrides (feature_id);

-- ---------------------------------------------------------------------------
-- 15. organization_quota_allocations (organization-owned)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.organization_quota_allocations (
    organization_quota_allocation_id  uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                         uuid           NOT NULL,
    organization_id                   uuid           NOT NULL,
    feature_id                        uuid           NOT NULL,
    allocated_limit                   numeric(24,6)  NOT NULL,
    valid_from                        timestamptz    NOT NULL,
    valid_until                       timestamptz    NOT NULL,
    status                            varchar(16)    NOT NULL DEFAULT 'active',
    reason                            text           NOT NULL,
    created_at                        timestamptz    NOT NULL DEFAULT now(),
    created_by                        varchar(255)   NOT NULL,
    updated_at                        timestamptz    NOT NULL DEFAULT now(),
    updated_by                        varchar(255)   NOT NULL,
    metadata                          jsonb          NOT NULL DEFAULT '{}'::jsonb,
    row_version                       bigint         NOT NULL DEFAULT 1,
    CONSTRAINT organization_quota_allocations_pk PRIMARY KEY (organization_quota_allocation_id),
    CONSTRAINT organization_quota_allocations_tenant_entity_uq UNIQUE (tenant_id, organization_quota_allocation_id),
    CONSTRAINT organization_quota_allocations_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, organization_quota_allocation_id),
    CONSTRAINT organization_quota_allocations_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT organization_quota_allocations_feature_fk FOREIGN KEY (feature_id)
        REFERENCES cob3_tenant.features (feature_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT organization_quota_allocations_limit_ck CHECK (allocated_limit >= 0),
    CONSTRAINT organization_quota_allocations_window_ck CHECK (valid_until > valid_from),
    CONSTRAINT organization_quota_allocations_status_ck CHECK (status IN ('active', 'revoked')),
    CONSTRAINT organization_quota_allocations_reason_nonblank_ck CHECK (length(btrim(reason)) > 0),
    CONSTRAINT organization_quota_allocations_no_overlap_ex EXCLUDE USING gist (
        tenant_id WITH =, organization_id WITH =, feature_id WITH =, tstzrange(valid_from, valid_until, '[)') WITH &&)
        WHERE (status = 'active')
);
CREATE INDEX organization_quota_allocations_lookup_ix ON cob3_tenant.organization_quota_allocations (tenant_id, feature_id, organization_id);
CREATE INDEX organization_quota_allocations_feature_ix ON cob3_tenant.organization_quota_allocations (feature_id);

-- ---------------------------------------------------------------------------
-- 16. usage_events (organization-attributed, append-only, counter features)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.usage_events (
    usage_event_id          uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id               uuid           NOT NULL,
    organization_id         uuid           NULL,
    feature_id              uuid           NOT NULL,
    source_code             varchar(64)    NOT NULL,
    source_event_id         varchar(128)   NOT NULL,
    occurred_at             timestamptz    NOT NULL,
    received_at             timestamptz    NOT NULL DEFAULT now(),
    quantity                numeric(24,6)  NOT NULL,
    correction_of_event_id  uuid           NULL,
    request_id              uuid           NULL,
    created_at              timestamptz    NOT NULL DEFAULT now(),
    created_by              varchar(255)   NOT NULL,
    updated_at              timestamptz    NOT NULL DEFAULT now(),
    updated_by              varchar(255)   NOT NULL,
    metadata                jsonb          NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint         NOT NULL DEFAULT 1,
    CONSTRAINT usage_events_pk PRIMARY KEY (usage_event_id),
    CONSTRAINT usage_events_tenant_entity_uq UNIQUE (tenant_id, usage_event_id),
    CONSTRAINT usage_events_idempotency_uq UNIQUE (tenant_id, source_code, source_event_id),
    CONSTRAINT usage_events_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT usage_events_feature_fk FOREIGN KEY (feature_id)
        REFERENCES cob3_tenant.features (feature_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT usage_events_correction_fk FOREIGN KEY (tenant_id, correction_of_event_id)
        REFERENCES cob3_tenant.usage_events (tenant_id, usage_event_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT usage_events_source_code_format_ck CHECK (source_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT usage_events_source_event_id_nonblank_ck CHECK (length(btrim(source_event_id)) > 0),
    CONSTRAINT usage_events_quantity_sign_ck CHECK (
        (correction_of_event_id IS NULL AND quantity > 0)
        OR (correction_of_event_id IS NOT NULL AND quantity < 0)),
    CONSTRAINT usage_events_not_self_correction_ck CHECK (correction_of_event_id IS NULL OR correction_of_event_id <> usage_event_id),
    CONSTRAINT usage_events_append_only_ck CHECK (row_version = 1 AND updated_at = created_at AND updated_by = created_by)
);
CREATE INDEX usage_events_feature_time_ix ON cob3_tenant.usage_events (tenant_id, feature_id, occurred_at);
CREATE INDEX usage_events_organization_ix ON cob3_tenant.usage_events (tenant_id, organization_id);
CREATE INDEX usage_events_feature_ix ON cob3_tenant.usage_events (feature_id);
CREATE INDEX usage_events_correction_ix ON cob3_tenant.usage_events (tenant_id, correction_of_event_id)
    WHERE correction_of_event_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 17. usage_rollups (rebuildable projection)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.usage_rollups (
    usage_rollup_id      uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id            uuid           NOT NULL,
    organization_id      uuid           NULL,
    feature_id           uuid           NOT NULL,
    window_key           varchar(128)   NOT NULL,
    window_start         timestamptz    NOT NULL,
    window_end           timestamptz    NOT NULL,
    total_quantity       numeric(24,6)  NOT NULL DEFAULT 0,
    event_count          bigint         NOT NULL DEFAULT 0,
    computed_at          timestamptz    NOT NULL,
    calculation_version  integer        NOT NULL DEFAULT 1,
    created_at           timestamptz    NOT NULL DEFAULT now(),
    created_by           varchar(255)   NOT NULL,
    updated_at           timestamptz    NOT NULL DEFAULT now(),
    updated_by           varchar(255)   NOT NULL,
    metadata             jsonb          NOT NULL DEFAULT '{}'::jsonb,
    row_version          bigint         NOT NULL DEFAULT 1,
    CONSTRAINT usage_rollups_pk PRIMARY KEY (usage_rollup_id),
    CONSTRAINT usage_rollups_tenant_entity_uq UNIQUE (tenant_id, usage_rollup_id),
    CONSTRAINT usage_rollups_window_uq UNIQUE NULLS NOT DISTINCT (tenant_id, organization_id, feature_id, window_key),
    CONSTRAINT usage_rollups_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT usage_rollups_feature_fk FOREIGN KEY (feature_id)
        REFERENCES cob3_tenant.features (feature_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT usage_rollups_window_key_nonblank_ck CHECK (length(btrim(window_key)) > 0),
    CONSTRAINT usage_rollups_window_ck CHECK (window_end > window_start),
    CONSTRAINT usage_rollups_total_ck CHECK (total_quantity >= 0),
    CONSTRAINT usage_rollups_event_count_ck CHECK (event_count >= 0),
    CONSTRAINT usage_rollups_calculation_version_ck CHECK (calculation_version > 0)
);
CREATE INDEX usage_rollups_feature_ix ON cob3_tenant.usage_rollups (feature_id);

-- ---------------------------------------------------------------------------
-- 18. invoices
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.invoices (
    invoice_id                  uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                   uuid          NOT NULL,
    organization_id             uuid          NULL,
    billing_account_id          uuid          NOT NULL,
    subscription_id             uuid          NULL,
    invoice_number              varchar(64)   NULL,
    currency_code               varchar(3)    NOT NULL,
    status                      varchar(20)   NOT NULL DEFAULT 'draft',
    issued_at                   timestamptz   NULL,
    due_at                      timestamptz   NULL,
    subtotal_minor              bigint        NOT NULL DEFAULT 0,
    discount_minor              bigint        NOT NULL DEFAULT 0,
    tax_minor                   bigint        NOT NULL DEFAULT 0,
    total_minor                 bigint        NOT NULL DEFAULT 0,
    billing_snapshot            jsonb         NOT NULL,
    provider_invoice_reference  varchar(255)  NULL,
    created_at                  timestamptz   NOT NULL DEFAULT now(),
    created_by                  varchar(255)  NOT NULL,
    updated_at                  timestamptz   NOT NULL DEFAULT now(),
    updated_by                  varchar(255)  NOT NULL,
    metadata                    jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                 bigint        NOT NULL DEFAULT 1,
    CONSTRAINT invoices_pk PRIMARY KEY (invoice_id),
    CONSTRAINT invoices_tenant_entity_uq UNIQUE (tenant_id, invoice_id),
    CONSTRAINT invoices_invoice_number_uq UNIQUE (tenant_id, invoice_number),
    CONSTRAINT invoices_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT invoices_billing_account_fk FOREIGN KEY (tenant_id, billing_account_id)
        REFERENCES cob3_tenant.billing_accounts (tenant_id, billing_account_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT invoices_subscription_fk FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES cob3_tenant.subscriptions (tenant_id, subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT invoices_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT invoices_currency_code_ck CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT invoices_status_ck CHECK (status IN ('draft', 'open', 'paid', 'void', 'uncollectible')),
    CONSTRAINT invoices_amounts_nonnegative_ck CHECK (subtotal_minor >= 0 AND discount_minor >= 0 AND tax_minor >= 0 AND total_minor >= 0),
    CONSTRAINT invoices_discount_ck CHECK (discount_minor <= subtotal_minor),
    CONSTRAINT invoices_total_ck CHECK (total_minor = subtotal_minor - discount_minor + tax_minor),
    CONSTRAINT invoices_snapshot_object_ck CHECK (jsonb_typeof(billing_snapshot) = 'object'),
    CONSTRAINT invoices_issued_ck CHECK (status = 'draft' OR (invoice_number IS NOT NULL AND issued_at IS NOT NULL)),
    CONSTRAINT invoices_due_order_ck CHECK (due_at IS NULL OR issued_at IS NULL OR due_at >= issued_at),
    CONSTRAINT invoices_invoice_number_nonblank_ck CHECK (invoice_number IS NULL OR length(btrim(invoice_number)) > 0)
);
CREATE INDEX invoices_status_due_ix ON cob3_tenant.invoices (tenant_id, status, due_at);
CREATE INDEX invoices_billing_account_ix ON cob3_tenant.invoices (tenant_id, billing_account_id);
CREATE INDEX invoices_subscription_ix ON cob3_tenant.invoices (tenant_id, subscription_id);

-- ---------------------------------------------------------------------------
-- 19. invoice_lines
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.invoice_lines (
    invoice_line_id         uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id               uuid           NOT NULL,
    organization_id         uuid           NULL,
    invoice_id              uuid           NOT NULL,
    line_number             integer        NOT NULL,
    subscription_period_id  uuid           NULL,
    feature_id              uuid           NULL,
    description             text           NOT NULL,
    quantity                numeric(24,6)  NOT NULL,
    unit_price              numeric(20,8)  NOT NULL,
    line_subtotal_minor     bigint         NOT NULL,
    service_from            timestamptz    NULL,
    service_until           timestamptz    NULL,
    created_at              timestamptz    NOT NULL DEFAULT now(),
    created_by              varchar(255)   NOT NULL,
    updated_at              timestamptz    NOT NULL DEFAULT now(),
    updated_by              varchar(255)   NOT NULL,
    metadata                jsonb          NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint         NOT NULL DEFAULT 1,
    CONSTRAINT invoice_lines_pk PRIMARY KEY (invoice_line_id),
    CONSTRAINT invoice_lines_tenant_entity_uq UNIQUE (tenant_id, invoice_line_id),
    CONSTRAINT invoice_lines_line_number_uq UNIQUE (tenant_id, invoice_id, line_number),
    CONSTRAINT invoice_lines_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT invoice_lines_invoice_fk FOREIGN KEY (tenant_id, invoice_id)
        REFERENCES cob3_tenant.invoices (tenant_id, invoice_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT invoice_lines_subscription_period_fk FOREIGN KEY (tenant_id, subscription_period_id)
        REFERENCES cob3_tenant.subscription_periods (tenant_id, subscription_period_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT invoice_lines_feature_fk FOREIGN KEY (feature_id)
        REFERENCES cob3_tenant.features (feature_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT invoice_lines_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT invoice_lines_line_number_ck CHECK (line_number > 0),
    CONSTRAINT invoice_lines_description_nonblank_ck CHECK (length(btrim(description)) > 0),
    CONSTRAINT invoice_lines_amounts_nonnegative_ck CHECK (quantity >= 0 AND unit_price >= 0 AND line_subtotal_minor >= 0),
    CONSTRAINT invoice_lines_service_window_ck CHECK (
        (service_from IS NULL) = (service_until IS NULL)
        AND (service_until IS NULL OR service_until > service_from))
);
CREATE INDEX invoice_lines_subscription_period_ix ON cob3_tenant.invoice_lines (tenant_id, subscription_period_id);
CREATE INDEX invoice_lines_feature_ix ON cob3_tenant.invoice_lines (feature_id);

-- ---------------------------------------------------------------------------
-- 20. payment_transactions
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.payment_transactions (
    payment_transaction_id          uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                       uuid          NOT NULL,
    organization_id                 uuid          NULL,
    invoice_id                      uuid          NOT NULL,
    parent_transaction_id           uuid          NULL,
    transaction_type                varchar(20)   NOT NULL,
    status                          varchar(20)   NOT NULL DEFAULT 'pending',
    amount_minor                    bigint        NOT NULL,
    currency_code                   varchar(3)    NOT NULL,
    provider_code                   varchar(64)   NOT NULL,
    provider_account_reference      varchar(128)  NOT NULL,
    provider_transaction_reference  varchar(255)  NOT NULL,
    occurred_at                     timestamptz   NOT NULL,
    failure_code                    varchar(64)   NULL,
    created_at                      timestamptz   NOT NULL DEFAULT now(),
    created_by                      varchar(255)  NOT NULL,
    updated_at                      timestamptz   NOT NULL DEFAULT now(),
    updated_by                      varchar(255)  NOT NULL,
    metadata                        jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                     bigint        NOT NULL DEFAULT 1,
    CONSTRAINT payment_transactions_pk PRIMARY KEY (payment_transaction_id),
    CONSTRAINT payment_transactions_tenant_entity_uq UNIQUE (tenant_id, payment_transaction_id),
    CONSTRAINT payment_transactions_invoice_entity_uq UNIQUE (tenant_id, invoice_id, payment_transaction_id),
    CONSTRAINT payment_transactions_provider_uq UNIQUE (provider_code, provider_account_reference, provider_transaction_reference, transaction_type),
    CONSTRAINT payment_transactions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT payment_transactions_invoice_fk FOREIGN KEY (tenant_id, invoice_id)
        REFERENCES cob3_tenant.invoices (tenant_id, invoice_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Reversals must reference a transaction of the same tenant AND invoice.
    CONSTRAINT payment_transactions_parent_fk FOREIGN KEY (tenant_id, invoice_id, parent_transaction_id)
        REFERENCES cob3_tenant.payment_transactions (tenant_id, invoice_id, payment_transaction_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT payment_transactions_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT payment_transactions_type_ck CHECK (transaction_type IN ('payment', 'refund', 'chargeback')),
    CONSTRAINT payment_transactions_status_ck CHECK (status IN ('pending', 'succeeded', 'failed')),
    CONSTRAINT payment_transactions_amount_ck CHECK (amount_minor > 0),
    CONSTRAINT payment_transactions_currency_code_ck CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT payment_transactions_parent_shape_ck CHECK ((transaction_type = 'payment') = (parent_transaction_id IS NULL)),
    CONSTRAINT payment_transactions_not_self_parent_ck CHECK (parent_transaction_id IS NULL OR parent_transaction_id <> payment_transaction_id),
    CONSTRAINT payment_transactions_failure_code_ck CHECK (failure_code IS NULL OR status = 'failed'),
    CONSTRAINT payment_transactions_provider_code_format_ck CHECK (provider_code ~ '^[a-z0-9][a-z0-9_.-]*$')
);
CREATE INDEX payment_transactions_parent_ix ON cob3_tenant.payment_transactions (tenant_id, invoice_id, parent_transaction_id)
    WHERE parent_transaction_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 21. provider_events
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.provider_events (
    provider_event_id           uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id                   uuid          NOT NULL,
    organization_id             uuid          NULL,
    provider_code               varchar(64)   NOT NULL,
    provider_account_reference  varchar(128)  NOT NULL,
    external_event_id           varchar(255)  NOT NULL,
    event_type                  varchar(128)  NOT NULL,
    occurred_at                 timestamptz   NOT NULL,
    received_at                 timestamptz   NOT NULL DEFAULT now(),
    payload_digest              bytea         NOT NULL,
    status                      varchar(20)   NOT NULL DEFAULT 'received',
    attempt_count               integer       NOT NULL DEFAULT 0,
    lease_expires_at            timestamptz   NULL,
    processed_at                timestamptz   NULL,
    last_error_code             varchar(64)   NULL,
    created_at                  timestamptz   NOT NULL DEFAULT now(),
    created_by                  varchar(255)  NOT NULL,
    updated_at                  timestamptz   NOT NULL DEFAULT now(),
    updated_by                  varchar(255)  NOT NULL,
    metadata                    jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                 bigint        NOT NULL DEFAULT 1,
    CONSTRAINT provider_events_pk PRIMARY KEY (provider_event_id),
    CONSTRAINT provider_events_tenant_entity_uq UNIQUE (tenant_id, provider_event_id),
    CONSTRAINT provider_events_external_uq UNIQUE (provider_code, provider_account_reference, external_event_id),
    CONSTRAINT provider_events_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT provider_events_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT provider_events_provider_code_format_ck CHECK (provider_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT provider_events_payload_digest_ck CHECK (octet_length(payload_digest) = 32),
    CONSTRAINT provider_events_status_ck CHECK (status IN ('received', 'processing', 'processed', 'failed')),
    CONSTRAINT provider_events_attempt_count_ck CHECK (attempt_count >= 0),
    CONSTRAINT provider_events_processing_lease_ck CHECK (status <> 'processing' OR lease_expires_at IS NOT NULL),
    CONSTRAINT provider_events_processed_ck CHECK ((status = 'processed') = (processed_at IS NOT NULL))
);
CREATE INDEX provider_events_queue_ix ON cob3_tenant.provider_events (status, lease_expires_at);

-- ---------------------------------------------------------------------------
-- Support table (not one of the 48 logical tables): transactional hard-quota
-- counters for counter features. Maintained only by
-- cob3_tenant.record_usage_event / record_platform_usage_event under row locks,
-- so concurrent consumption cannot exceed a finite limit. Rebuildable from
-- usage_events; asynchronous usage_rollups are NOT used for enforcement.
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_tenant.quota_counters (
    quota_counter_id   uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          uuid           NOT NULL,
    organization_id    uuid           NULL,
    scope_kind         varchar(16)    NOT NULL,
    feature_id         uuid           NOT NULL,
    window_key         varchar(128)   NOT NULL,
    consumed_quantity  numeric(24,6)  NOT NULL DEFAULT 0,
    updated_at         timestamptz    NOT NULL DEFAULT now(),
    CONSTRAINT quota_counters_pk PRIMARY KEY (quota_counter_id),
    CONSTRAINT quota_counters_bucket_uq UNIQUE NULLS NOT DISTINCT (tenant_id, feature_id, window_key, scope_kind, organization_id),
    CONSTRAINT quota_counters_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT quota_counters_feature_fk FOREIGN KEY (feature_id)
        REFERENCES cob3_tenant.features (feature_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT quota_counters_scope_kind_ck CHECK (scope_kind IN ('tenant_total', 'organization')),
    CONSTRAINT quota_counters_scope_shape_ck CHECK ((scope_kind = 'tenant_total') = (organization_id IS NULL)),
    CONSTRAINT quota_counters_consumed_ck CHECK (consumed_quantity >= 0)
);
CREATE INDEX quota_counters_feature_ix ON cob3_tenant.quota_counters (feature_id);
CREATE INDEX quota_counters_organization_ix ON cob3_tenant.quota_counters (tenant_id, organization_id);
