-- =============================================================================
-- 30  cob3_identity TABLES (27 logical tables)
-- -----------------------------------------------------------------------------
-- Key shape follows the Identity specification: PK (tenant_id, <entity_id>);
-- organization-owned tables also expose UNIQUE (tenant_id, organization_id,
-- <entity_id>) for scoped child references. All same-tenant references carry
-- tenant_id; references to organization-owned rows carry tenant_id AND
-- organization_id. Tables are created in dependency order (not inventory order).
-- Catalog references (team_domains.domain_id, access_scopes.domain_id/asset_id)
-- are deliberately NOT foreign keys yet: cob3_catalog does not exist. They are
-- guarded fail-closed by triggers (section 50/70) until the separately invoked
-- Catalog integration installs and validates real FKs.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. organizations
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.organizations (
    tenant_id               uuid          NOT NULL,
    organization_id         uuid          NOT NULL,
    organization_code       varchar(64)   NOT NULL,
    name                    varchar(200)  NOT NULL,
    legal_name              varchar(255)  NULL,
    description             text          NULL,
    parent_organization_id  uuid          NULL,
    status                  varchar(20)   NOT NULL DEFAULT 'active',
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT organizations_pk PRIMARY KEY (tenant_id, organization_id),
    CONSTRAINT organizations_code_uq UNIQUE (tenant_id, organization_code),
    CONSTRAINT organizations_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT organizations_parent_fk FOREIGN KEY (tenant_id, parent_organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT organizations_code_format_ck CHECK (organization_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT organizations_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT organizations_not_own_parent_ck CHECK (parent_organization_id IS NULL OR parent_organization_id <> organization_id),
    CONSTRAINT organizations_status_ck CHECK (status IN ('active', 'suspended', 'archived'))
);
CREATE INDEX organizations_parent_ix ON cob3_identity.organizations (tenant_id, parent_organization_id);

-- ---------------------------------------------------------------------------
-- 2. principals
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.principals (
    tenant_id              uuid          NOT NULL,
    principal_id           uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id        uuid          NULL,
    principal_type         varchar(20)   NOT NULL,
    principal_code         varchar(128)  NOT NULL,
    display_name           varchar(200)  NOT NULL,
    status                 varchar(20)   NOT NULL DEFAULT 'active',
    auth_version           bigint        NOT NULL DEFAULT 1,
    last_authenticated_at  timestamptz   NULL,
    created_at             timestamptz   NOT NULL DEFAULT now(),
    created_by             varchar(255)  NOT NULL,
    updated_at             timestamptz   NOT NULL DEFAULT now(),
    updated_by             varchar(255)  NOT NULL,
    metadata               jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version            bigint        NOT NULL DEFAULT 1,
    CONSTRAINT principals_pk PRIMARY KEY (tenant_id, principal_id),
    CONSTRAINT principals_code_uq UNIQUE (tenant_id, principal_code),
    CONSTRAINT principals_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT principals_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT principals_type_ck CHECK (principal_type IN ('human', 'service_account', 'automation')),
    CONSTRAINT principals_code_format_ck CHECK (principal_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT principals_display_name_nonblank_ck CHECK (length(btrim(display_name)) > 0),
    CONSTRAINT principals_status_ck CHECK (status IN ('active', 'suspended', 'disabled')),
    CONSTRAINT principals_auth_version_ck CHECK (auth_version > 0)
);
CREATE INDEX principals_type_status_ix ON cob3_identity.principals (tenant_id, principal_type, status);

-- ---------------------------------------------------------------------------
-- 3. user_profiles (human subtype)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.user_profiles (
    tenant_id          uuid          NOT NULL,
    principal_id       uuid          NOT NULL,
    organization_id    uuid          NULL,
    email              varchar(320)  NULL,
    email_verified_at  timestamptz   NULL,
    given_name         varchar(100)  NULL,
    family_name        varchar(100)  NULL,
    job_title          varchar(150)  NULL,
    avatar_uri         text          NULL,
    description        text          NULL,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         varchar(255)  NOT NULL,
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    updated_by         varchar(255)  NOT NULL,
    metadata           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT user_profiles_pk PRIMARY KEY (tenant_id, principal_id),
    CONSTRAINT user_profiles_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT user_profiles_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT user_profiles_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT user_profiles_email_verified_ck CHECK (email_verified_at IS NULL OR email IS NOT NULL),
    CONSTRAINT user_profiles_email_format_ck CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+$')
);
CREATE INDEX user_profiles_email_ix ON cob3_identity.user_profiles (tenant_id, lower(email)) WHERE email IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 6. organization_memberships (created before subtypes that reference it)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.organization_memberships (
    tenant_id                   uuid          NOT NULL,
    organization_membership_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id             uuid          NOT NULL,
    principal_id                uuid          NOT NULL,
    membership_type             varchar(20)   NOT NULL,
    status                      varchar(20)   NOT NULL DEFAULT 'invited',
    valid_from                  timestamptz   NOT NULL DEFAULT now(),
    valid_until                 timestamptz   NULL,
    joined_at                   timestamptz   NULL,
    revoked_at                  timestamptz   NULL,
    created_at                  timestamptz   NOT NULL DEFAULT now(),
    created_by                  varchar(255)  NOT NULL,
    updated_at                  timestamptz   NOT NULL DEFAULT now(),
    updated_by                  varchar(255)  NOT NULL,
    metadata                    jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                 bigint        NOT NULL DEFAULT 1,
    CONSTRAINT organization_memberships_pk PRIMARY KEY (tenant_id, organization_membership_id),
    CONSTRAINT organization_memberships_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, organization_membership_id),
    CONSTRAINT organization_memberships_principal_uq UNIQUE (tenant_id, organization_id, principal_id),
    CONSTRAINT organization_memberships_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT organization_memberships_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT organization_memberships_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT organization_memberships_type_ck CHECK (membership_type IN ('employee', 'contractor', 'guest', 'service', 'automation')),
    CONSTRAINT organization_memberships_status_ck CHECK (status IN ('invited', 'active', 'suspended', 'revoked')),
    CONSTRAINT organization_memberships_window_ck CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT organization_memberships_revoked_ck CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
    CONSTRAINT organization_memberships_joined_ck CHECK (status <> 'active' OR joined_at IS NOT NULL)
);
CREATE INDEX organization_memberships_principal_status_ix ON cob3_identity.organization_memberships (tenant_id, principal_id, status);

-- ---------------------------------------------------------------------------
-- 4. service_accounts (service subtype, organization-owned)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.service_accounts (
    tenant_id             uuid          NOT NULL,
    principal_id          uuid          NOT NULL,
    organization_id       uuid          NOT NULL,
    creator_principal_id  uuid          NOT NULL,
    owner_principal_id    uuid          NOT NULL,
    purpose               text          NOT NULL,
    expires_at            timestamptz   NULL,
    created_at            timestamptz   NOT NULL DEFAULT now(),
    created_by            varchar(255)  NOT NULL,
    updated_at            timestamptz   NOT NULL DEFAULT now(),
    updated_by            varchar(255)  NOT NULL,
    metadata              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version           bigint        NOT NULL DEFAULT 1,
    CONSTRAINT service_accounts_pk PRIMARY KEY (tenant_id, principal_id),
    CONSTRAINT service_accounts_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, principal_id),
    CONSTRAINT service_accounts_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT service_accounts_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT service_accounts_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT service_accounts_creator_membership_fk FOREIGN KEY (tenant_id, organization_id, creator_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT service_accounts_owner_membership_fk FOREIGN KEY (tenant_id, organization_id, owner_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- The account itself must be a member of its owning organization; deferred
    -- so principal, subtype and membership can be created in any order.
    CONSTRAINT service_accounts_self_membership_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT service_accounts_purpose_nonblank_ck CHECK (length(btrim(purpose)) > 0),
    CONSTRAINT service_accounts_expiry_ck CHECK (expires_at IS NULL OR expires_at > created_at),
    CONSTRAINT service_accounts_not_self_created_ck CHECK (creator_principal_id <> principal_id)
);
CREATE INDEX service_accounts_owner_ix ON cob3_identity.service_accounts (tenant_id, organization_id, owner_principal_id);
CREATE INDEX service_accounts_creator_ix ON cob3_identity.service_accounts (tenant_id, organization_id, creator_principal_id);

-- ---------------------------------------------------------------------------
-- 5. automation_profiles (automation subtype, organization-owned)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.automation_profiles (
    tenant_id             uuid          NOT NULL,
    principal_id          uuid          NOT NULL,
    organization_id       uuid          NOT NULL,
    creator_principal_id  uuid          NOT NULL,
    owner_principal_id    uuid          NOT NULL,
    purpose               text          NOT NULL,
    automation_category   varchar(24)   NOT NULL,
    creation_method       varchar(24)   NOT NULL,
    expires_at            timestamptz   NULL,
    created_at            timestamptz   NOT NULL DEFAULT now(),
    created_by            varchar(255)  NOT NULL,
    updated_at            timestamptz   NOT NULL DEFAULT now(),
    updated_by            varchar(255)  NOT NULL,
    metadata              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version           bigint        NOT NULL DEFAULT 1,
    CONSTRAINT automation_profiles_pk PRIMARY KEY (tenant_id, principal_id),
    CONSTRAINT automation_profiles_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, principal_id),
    CONSTRAINT automation_profiles_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT automation_profiles_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT automation_profiles_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT automation_profiles_creator_membership_fk FOREIGN KEY (tenant_id, organization_id, creator_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT automation_profiles_owner_membership_fk FOREIGN KEY (tenant_id, organization_id, owner_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT automation_profiles_self_membership_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT automation_profiles_purpose_nonblank_ck CHECK (length(btrim(purpose)) > 0),
    CONSTRAINT automation_profiles_category_ck CHECK (automation_category IN ('assistant', 'agent', 'notification', 'workflow')),
    CONSTRAINT automation_profiles_creation_method_ck CHECK (creation_method IN ('portal', 'api', 'provisioning')),
    CONSTRAINT automation_profiles_expiry_ck CHECK (expires_at IS NULL OR expires_at > created_at),
    CONSTRAINT automation_profiles_not_self_created_ck CHECK (creator_principal_id <> principal_id)
);
CREATE INDEX automation_profiles_owner_ix ON cob3_identity.automation_profiles (tenant_id, organization_id, owner_principal_id);
CREATE INDEX automation_profiles_creator_ix ON cob3_identity.automation_profiles (tenant_id, organization_id, creator_principal_id);

-- ---------------------------------------------------------------------------
-- 7. teams
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.teams (
    tenant_id        uuid          NOT NULL,
    team_id          uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL,
    team_code        varchar(64)   NOT NULL,
    name             varchar(200)  NOT NULL,
    description      text          NULL,
    team_type        varchar(24)   NOT NULL,
    parent_team_id   uuid          NULL,
    status           varchar(20)   NOT NULL DEFAULT 'active',
    created_at       timestamptz   NOT NULL DEFAULT now(),
    created_by       varchar(255)  NOT NULL,
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    updated_by       varchar(255)  NOT NULL,
    metadata         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT teams_pk PRIMARY KEY (tenant_id, team_id),
    CONSTRAINT teams_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, team_id),
    CONSTRAINT teams_code_uq UNIQUE (tenant_id, organization_id, team_code),
    CONSTRAINT teams_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT teams_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT teams_parent_fk FOREIGN KEY (tenant_id, organization_id, parent_team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT teams_code_format_ck CHECK (team_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT teams_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT teams_type_ck CHECK (team_type IN ('department', 'functional', 'project', 'support', 'security')),
    CONSTRAINT teams_not_own_parent_ck CHECK (parent_team_id IS NULL OR parent_team_id <> team_id),
    CONSTRAINT teams_status_ck CHECK (status IN ('active', 'suspended', 'archived'))
);
CREATE INDEX teams_parent_ix ON cob3_identity.teams (tenant_id, organization_id, parent_team_id);

-- ---------------------------------------------------------------------------
-- 8. team_memberships
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.team_memberships (
    tenant_id           uuid          NOT NULL,
    team_membership_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL,
    team_id             uuid          NOT NULL,
    principal_id        uuid          NOT NULL,
    membership_role     varchar(20)   NOT NULL DEFAULT 'member',
    status              varchar(20)   NOT NULL DEFAULT 'active',
    valid_from          timestamptz   NOT NULL DEFAULT now(),
    valid_until         timestamptz   NULL,
    revoked_at          timestamptz   NULL,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_by          varchar(255)  NOT NULL,
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    updated_by          varchar(255)  NOT NULL,
    metadata            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version         bigint        NOT NULL DEFAULT 1,
    CONSTRAINT team_memberships_pk PRIMARY KEY (tenant_id, team_membership_id),
    CONSTRAINT team_memberships_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, team_membership_id),
    CONSTRAINT team_memberships_principal_uq UNIQUE (tenant_id, organization_id, team_id, principal_id),
    CONSTRAINT team_memberships_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT team_memberships_team_fk FOREIGN KEY (tenant_id, organization_id, team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT team_memberships_org_membership_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT team_memberships_role_ck CHECK (membership_role IN ('member', 'maintainer', 'owner')),
    CONSTRAINT team_memberships_status_ck CHECK (status IN ('active', 'suspended', 'revoked')),
    CONSTRAINT team_memberships_window_ck CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT team_memberships_revoked_ck CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))
);
CREATE INDEX team_memberships_principal_status_ix ON cob3_identity.team_memberships (tenant_id, organization_id, principal_id, status);
CREATE INDEX team_memberships_team_status_ix ON cob3_identity.team_memberships (tenant_id, organization_id, team_id, status);

-- ---------------------------------------------------------------------------
-- 22. identity_providers
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.identity_providers (
    tenant_id                uuid          NOT NULL,
    identity_provider_id     uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id          uuid          NULL,
    provider_code            varchar(64)   NOT NULL,
    name                     varchar(150)  NOT NULL,
    protocol                 varchar(16)   NOT NULL,
    issuer                   text          NOT NULL,
    configuration_reference  varchar(255)  NOT NULL,
    status                   varchar(20)   NOT NULL DEFAULT 'active',
    created_at               timestamptz   NOT NULL DEFAULT now(),
    created_by               varchar(255)  NOT NULL,
    updated_at               timestamptz   NOT NULL DEFAULT now(),
    updated_by               varchar(255)  NOT NULL,
    metadata                 jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version              bigint        NOT NULL DEFAULT 1,
    CONSTRAINT identity_providers_pk PRIMARY KEY (tenant_id, identity_provider_id),
    CONSTRAINT identity_providers_code_uq UNIQUE (tenant_id, provider_code),
    CONSTRAINT identity_providers_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT identity_providers_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT identity_providers_code_format_ck CHECK (provider_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT identity_providers_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT identity_providers_protocol_ck CHECK (protocol IN ('oidc', 'saml')),
    CONSTRAINT identity_providers_issuer_nonblank_ck CHECK (length(btrim(issuer)) > 0),
    CONSTRAINT identity_providers_configuration_reference_nonblank_ck CHECK (length(btrim(configuration_reference)) > 0),
    CONSTRAINT identity_providers_status_ck CHECK (status IN ('active', 'disabled'))
);

-- ---------------------------------------------------------------------------
-- 24. external_groups
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.external_groups (
    tenant_id             uuid          NOT NULL,
    external_group_id     uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id       uuid          NULL,
    identity_provider_id  uuid          NOT NULL,
    provider_group_id     varchar(255)  NOT NULL,
    display_name          varchar(255)  NOT NULL,
    status                varchar(20)   NOT NULL DEFAULT 'active',
    last_synced_at        timestamptz   NULL,
    created_at            timestamptz   NOT NULL DEFAULT now(),
    created_by            varchar(255)  NOT NULL,
    updated_at            timestamptz   NOT NULL DEFAULT now(),
    updated_by            varchar(255)  NOT NULL,
    metadata              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version           bigint        NOT NULL DEFAULT 1,
    CONSTRAINT external_groups_pk PRIMARY KEY (tenant_id, external_group_id),
    CONSTRAINT external_groups_provider_group_uq UNIQUE (tenant_id, identity_provider_id, provider_group_id),
    CONSTRAINT external_groups_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT external_groups_provider_fk FOREIGN KEY (tenant_id, identity_provider_id)
        REFERENCES cob3_identity.identity_providers (tenant_id, identity_provider_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT external_groups_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT external_groups_provider_group_id_nonblank_ck CHECK (length(btrim(provider_group_id)) > 0),
    CONSTRAINT external_groups_display_name_nonblank_ck CHECK (length(btrim(display_name)) > 0),
    CONSTRAINT external_groups_status_ck CHECK (status IN ('active', 'disabled'))
);
CREATE INDEX external_groups_provider_status_ix ON cob3_identity.external_groups (tenant_id, identity_provider_id, status);

-- ---------------------------------------------------------------------------
-- 25. group_team_mappings
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.group_team_mappings (
    tenant_id                      uuid          NOT NULL,
    group_team_mapping_id          uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                uuid          NOT NULL,
    external_group_id              uuid          NOT NULL,
    team_id                        uuid          NOT NULL,
    allow_membership_provisioning  boolean       NOT NULL DEFAULT false,
    status                         varchar(20)   NOT NULL DEFAULT 'active',
    created_at                     timestamptz   NOT NULL DEFAULT now(),
    created_by                     varchar(255)  NOT NULL,
    updated_at                     timestamptz   NOT NULL DEFAULT now(),
    updated_by                     varchar(255)  NOT NULL,
    metadata                       jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                    bigint        NOT NULL DEFAULT 1,
    CONSTRAINT group_team_mappings_pk PRIMARY KEY (tenant_id, group_team_mapping_id),
    CONSTRAINT group_team_mappings_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, group_team_mapping_id),
    CONSTRAINT group_team_mappings_group_team_uq UNIQUE (tenant_id, organization_id, external_group_id, team_id),
    CONSTRAINT group_team_mappings_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT group_team_mappings_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT group_team_mappings_external_group_fk FOREIGN KEY (tenant_id, external_group_id)
        REFERENCES cob3_identity.external_groups (tenant_id, external_group_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT group_team_mappings_team_fk FOREIGN KEY (tenant_id, organization_id, team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT group_team_mappings_status_ck CHECK (status IN ('active', 'disabled'))
);
CREATE INDEX group_team_mappings_group_status_ix ON cob3_identity.group_team_mappings (tenant_id, external_group_id, status);
CREATE INDEX group_team_mappings_team_ix ON cob3_identity.group_team_mappings (tenant_id, organization_id, team_id);

-- ---------------------------------------------------------------------------
-- 9. team_membership_sources
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.team_membership_sources (
    tenant_id                  uuid          NOT NULL,
    team_membership_source_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id            uuid          NOT NULL,
    team_membership_id         uuid          NOT NULL,
    source_type                varchar(20)   NOT NULL,
    group_team_mapping_id      uuid          NULL,
    status                     varchar(20)   NOT NULL DEFAULT 'active',
    valid_from                 timestamptz   NOT NULL DEFAULT now(),
    valid_until                timestamptz   NULL,
    revoked_at                 timestamptz   NULL,
    created_at                 timestamptz   NOT NULL DEFAULT now(),
    created_by                 varchar(255)  NOT NULL,
    updated_at                 timestamptz   NOT NULL DEFAULT now(),
    updated_by                 varchar(255)  NOT NULL,
    metadata                   jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                bigint        NOT NULL DEFAULT 1,
    CONSTRAINT team_membership_sources_pk PRIMARY KEY (tenant_id, team_membership_source_id),
    CONSTRAINT team_membership_sources_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, team_membership_source_id),
    CONSTRAINT team_membership_sources_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT team_membership_sources_membership_fk FOREIGN KEY (tenant_id, organization_id, team_membership_id)
        REFERENCES cob3_identity.team_memberships (tenant_id, organization_id, team_membership_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT team_membership_sources_mapping_fk FOREIGN KEY (tenant_id, organization_id, group_team_mapping_id)
        REFERENCES cob3_identity.group_team_mappings (tenant_id, organization_id, group_team_mapping_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT team_membership_sources_type_ck CHECK (source_type IN ('manual', 'external_group')),
    CONSTRAINT team_membership_sources_mapping_shape_ck CHECK (
        (source_type = 'manual' AND group_team_mapping_id IS NULL)
        OR (source_type = 'external_group' AND group_team_mapping_id IS NOT NULL)),
    CONSTRAINT team_membership_sources_status_ck CHECK (status IN ('active', 'revoked')),
    CONSTRAINT team_membership_sources_window_ck CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT team_membership_sources_revoked_ck CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))
);
CREATE UNIQUE INDEX team_membership_sources_active_manual_uix
    ON cob3_identity.team_membership_sources (tenant_id, organization_id, team_membership_id)
    WHERE status = 'active' AND source_type = 'manual';
CREATE UNIQUE INDEX team_membership_sources_active_group_uix
    ON cob3_identity.team_membership_sources (tenant_id, organization_id, team_membership_id, group_team_mapping_id)
    WHERE status = 'active' AND source_type = 'external_group';
CREATE INDEX team_membership_sources_membership_status_ix
    ON cob3_identity.team_membership_sources (tenant_id, organization_id, team_membership_id, status);
CREATE INDEX team_membership_sources_mapping_ix
    ON cob3_identity.team_membership_sources (tenant_id, organization_id, group_team_mapping_id);

-- ---------------------------------------------------------------------------
-- 10. team_domains (Catalog-dependent; writes fail closed until integration)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.team_domains (
    tenant_id            uuid          NOT NULL,
    team_domain_id       uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id      uuid          NOT NULL,
    team_id              uuid          NOT NULL,
    domain_id            uuid          NOT NULL,
    responsibility_type  varchar(24)   NOT NULL,
    status               varchar(20)   NOT NULL DEFAULT 'active',
    created_at           timestamptz   NOT NULL DEFAULT now(),
    created_by           varchar(255)  NOT NULL,
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    updated_by           varchar(255)  NOT NULL,
    metadata             jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version          bigint        NOT NULL DEFAULT 1,
    CONSTRAINT team_domains_pk PRIMARY KEY (tenant_id, team_domain_id),
    CONSTRAINT team_domains_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, team_domain_id),
    CONSTRAINT team_domains_team_domain_uq UNIQUE (tenant_id, organization_id, team_id, domain_id),
    CONSTRAINT team_domains_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT team_domains_team_fk FOREIGN KEY (tenant_id, organization_id, team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- PENDING Catalog FK: (tenant_id, organization_id, domain_id) -> cob3_catalog.domains
    CONSTRAINT team_domains_responsibility_ck CHECK (responsibility_type IN ('owner', 'steward', 'operator', 'contributor')),
    CONSTRAINT team_domains_status_ck CHECK (status IN ('active', 'suspended', 'revoked'))
);
CREATE INDEX team_domains_domain_status_ix ON cob3_identity.team_domains (tenant_id, organization_id, domain_id, status);

-- ---------------------------------------------------------------------------
-- 11. permissions (tenant-owned; seeded per tenant by provisioning routines)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.permissions (
    tenant_id               uuid          NOT NULL,
    permission_id           uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NULL,
    permission_code         varchar(128)  NOT NULL,
    resource_type           varchar(64)   NOT NULL,
    action                  varchar(64)   NOT NULL,
    description             text          NULL,
    permission_class        varchar(20)   NOT NULL,
    is_delegable            boolean       NOT NULL DEFAULT false,
    automation_allowed      boolean       NOT NULL DEFAULT false,
    is_identity_management  boolean       NOT NULL DEFAULT false,
    status                  varchar(20)   NOT NULL DEFAULT 'active',
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT permissions_pk PRIMARY KEY (tenant_id, permission_id),
    CONSTRAINT permissions_code_uq UNIQUE (tenant_id, permission_code),
    CONSTRAINT permissions_resource_action_uq UNIQUE (tenant_id, resource_type, action),
    CONSTRAINT permissions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT permissions_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT permissions_code_format_ck CHECK (permission_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT permissions_resource_type_format_ck CHECK (resource_type ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT permissions_action_format_ck CHECK (action ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT permissions_class_ck CHECK (permission_class IN ('tenant_control', 'organization')),
    CONSTRAINT permissions_automation_not_iam_ck CHECK (NOT (automation_allowed AND is_identity_management)),
    CONSTRAINT permissions_tenant_control_not_automation_ck CHECK (permission_class <> 'tenant_control' OR NOT automation_allowed),
    CONSTRAINT permissions_status_ck CHECK (status IN ('active', 'deprecated'))
);

-- ---------------------------------------------------------------------------
-- 12. roles
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.roles (
    tenant_id        uuid          NOT NULL,
    role_id          uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id  uuid          NULL,
    role_code        varchar(64)   NOT NULL,
    name             varchar(150)  NOT NULL,
    description      text          NULL,
    role_class       varchar(20)   NOT NULL,
    is_system        boolean       NOT NULL DEFAULT false,
    status           varchar(20)   NOT NULL DEFAULT 'active',
    created_at       timestamptz   NOT NULL DEFAULT now(),
    created_by       varchar(255)  NOT NULL,
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    updated_by       varchar(255)  NOT NULL,
    metadata         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT roles_pk PRIMARY KEY (tenant_id, role_id),
    CONSTRAINT roles_code_uq UNIQUE (tenant_id, role_code),
    CONSTRAINT roles_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT roles_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT roles_code_format_ck CHECK (role_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT roles_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT roles_class_ck CHECK (role_class IN ('tenant_control', 'organization')),
    CONSTRAINT roles_status_ck CHECK (status IN ('active', 'disabled', 'archived'))
);

-- ---------------------------------------------------------------------------
-- 13. role_permissions
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.role_permissions (
    tenant_id           uuid          NOT NULL,
    role_permission_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id     uuid          NULL,
    role_id             uuid          NOT NULL,
    permission_id       uuid          NOT NULL,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_by          varchar(255)  NOT NULL,
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    updated_by          varchar(255)  NOT NULL,
    metadata            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version         bigint        NOT NULL DEFAULT 1,
    CONSTRAINT role_permissions_pk PRIMARY KEY (tenant_id, role_permission_id),
    CONSTRAINT role_permissions_role_permission_uq UNIQUE (tenant_id, role_id, permission_id),
    CONSTRAINT role_permissions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_permissions_role_fk FOREIGN KEY (tenant_id, role_id)
        REFERENCES cob3_identity.roles (tenant_id, role_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_permissions_permission_fk FOREIGN KEY (tenant_id, permission_id)
        REFERENCES cob3_identity.permissions (tenant_id, permission_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_permissions_scope_ck CHECK (organization_id IS NULL)
);
CREATE INDEX role_permissions_permission_role_ix ON cob3_identity.role_permissions (tenant_id, permission_id, role_id);

-- ---------------------------------------------------------------------------
-- 14. access_scopes (domain/asset targets fail closed until Catalog exists)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.access_scopes (
    tenant_id                 uuid          NOT NULL,
    scope_id                  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id           uuid          NOT NULL,
    scope_type                varchar(20)   NOT NULL,
    domain_id                 uuid          NULL,
    asset_id                  uuid          NULL,
    include_contained_assets  boolean       NOT NULL DEFAULT false,
    status                    varchar(20)   NOT NULL DEFAULT 'active',
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT access_scopes_pk PRIMARY KEY (tenant_id, scope_id),
    CONSTRAINT access_scopes_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, scope_id),
    CONSTRAINT access_scopes_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT access_scopes_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- PENDING Catalog FKs: (tenant_id, organization_id, domain_id) -> cob3_catalog.domains,
    --                      (tenant_id, organization_id, asset_id)  -> cob3_catalog.assets
    CONSTRAINT access_scopes_type_ck CHECK (scope_type IN ('organization', 'domain', 'asset')),
    CONSTRAINT access_scopes_target_shape_ck CHECK (
        (scope_type = 'organization' AND domain_id IS NULL AND asset_id IS NULL)
        OR (scope_type = 'domain' AND domain_id IS NOT NULL AND asset_id IS NULL)
        OR (scope_type = 'asset' AND asset_id IS NOT NULL AND domain_id IS NULL AND NOT include_contained_assets)),
    CONSTRAINT access_scopes_status_ck CHECK (status IN ('active', 'disabled'))
);
CREATE UNIQUE INDEX access_scopes_organization_uix
    ON cob3_identity.access_scopes (tenant_id, organization_id, include_contained_assets)
    WHERE scope_type = 'organization';
CREATE UNIQUE INDEX access_scopes_domain_uix
    ON cob3_identity.access_scopes (tenant_id, organization_id, domain_id, include_contained_assets)
    WHERE scope_type = 'domain';
CREATE UNIQUE INDEX access_scopes_asset_uix
    ON cob3_identity.access_scopes (tenant_id, organization_id, asset_id)
    WHERE scope_type = 'asset';
CREATE INDEX access_scopes_domain_ix ON cob3_identity.access_scopes (tenant_id, organization_id, domain_id) WHERE domain_id IS NOT NULL;
CREATE INDEX access_scopes_asset_ix ON cob3_identity.access_scopes (tenant_id, organization_id, asset_id) WHERE asset_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 15. role_bindings (organization-class roles only)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.role_bindings (
    tenant_id           uuid          NOT NULL,
    role_binding_id     uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL,
    role_id             uuid          NOT NULL,
    scope_id            uuid          NOT NULL,
    principal_id        uuid          NULL,
    team_id             uuid          NULL,
    status              varchar(20)   NOT NULL DEFAULT 'active',
    valid_from          timestamptz   NOT NULL DEFAULT now(),
    valid_until         timestamptz   NULL,
    revoked_at          timestamptz   NULL,
    grant_reason        text          NOT NULL,
    approval_reference  varchar(255)  NULL,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_by          varchar(255)  NOT NULL,
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    updated_by          varchar(255)  NOT NULL,
    metadata            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version         bigint        NOT NULL DEFAULT 1,
    CONSTRAINT role_bindings_pk PRIMARY KEY (tenant_id, role_binding_id),
    CONSTRAINT role_bindings_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, role_binding_id),
    CONSTRAINT role_bindings_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_bindings_role_fk FOREIGN KEY (tenant_id, role_id)
        REFERENCES cob3_identity.roles (tenant_id, role_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_bindings_scope_fk FOREIGN KEY (tenant_id, organization_id, scope_id)
        REFERENCES cob3_identity.access_scopes (tenant_id, organization_id, scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_bindings_principal_membership_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_bindings_team_fk FOREIGN KEY (tenant_id, organization_id, team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT role_bindings_recipient_xor_ck CHECK ((principal_id IS NULL) <> (team_id IS NULL)),
    CONSTRAINT role_bindings_status_ck CHECK (status IN ('active', 'revoked')),
    CONSTRAINT role_bindings_window_ck CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT role_bindings_revoked_ck CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
    CONSTRAINT role_bindings_grant_reason_nonblank_ck CHECK (length(btrim(grant_reason)) > 0)
);
CREATE UNIQUE INDEX role_bindings_active_principal_uix
    ON cob3_identity.role_bindings (tenant_id, organization_id, principal_id, role_id, scope_id)
    WHERE status = 'active' AND principal_id IS NOT NULL;
CREATE UNIQUE INDEX role_bindings_active_team_uix
    ON cob3_identity.role_bindings (tenant_id, organization_id, team_id, role_id, scope_id)
    WHERE status = 'active' AND team_id IS NOT NULL;
CREATE INDEX role_bindings_principal_status_ix ON cob3_identity.role_bindings (tenant_id, organization_id, principal_id, status) WHERE principal_id IS NOT NULL;
CREATE INDEX role_bindings_team_status_ix ON cob3_identity.role_bindings (tenant_id, organization_id, team_id, status) WHERE team_id IS NOT NULL;
CREATE INDEX role_bindings_scope_role_ix ON cob3_identity.role_bindings (tenant_id, organization_id, scope_id, role_id);
CREATE INDEX role_bindings_role_ix ON cob3_identity.role_bindings (tenant_id, role_id);
CREATE INDEX role_bindings_principal_fk_ix ON cob3_identity.role_bindings (tenant_id, organization_id, principal_id);
CREATE INDEX role_bindings_team_fk_ix ON cob3_identity.role_bindings (tenant_id, organization_id, team_id);

-- ---------------------------------------------------------------------------
-- 16. tenant_role_bindings (tenant control plane; no org data access)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.tenant_role_bindings (
    tenant_id               uuid          NOT NULL,
    tenant_role_binding_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NULL,
    principal_id            uuid          NOT NULL,
    role_id                 uuid          NOT NULL,
    status                  varchar(20)   NOT NULL DEFAULT 'active',
    valid_from              timestamptz   NOT NULL DEFAULT now(),
    valid_until             timestamptz   NULL,
    revoked_at              timestamptz   NULL,
    grant_reason            text          NOT NULL,
    approval_reference      varchar(255)  NULL,
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT tenant_role_bindings_pk PRIMARY KEY (tenant_id, tenant_role_binding_id),
    CONSTRAINT tenant_role_bindings_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tenant_role_bindings_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tenant_role_bindings_role_fk FOREIGN KEY (tenant_id, role_id)
        REFERENCES cob3_identity.roles (tenant_id, role_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tenant_role_bindings_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT tenant_role_bindings_status_ck CHECK (status IN ('active', 'revoked')),
    CONSTRAINT tenant_role_bindings_window_ck CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT tenant_role_bindings_revoked_ck CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
    CONSTRAINT tenant_role_bindings_grant_reason_nonblank_ck CHECK (length(btrim(grant_reason)) > 0)
);
CREATE UNIQUE INDEX tenant_role_bindings_active_uix
    ON cob3_identity.tenant_role_bindings (tenant_id, principal_id, role_id)
    WHERE status = 'active';
CREATE INDEX tenant_role_bindings_principal_status_ix ON cob3_identity.tenant_role_bindings (tenant_id, principal_id, status);
CREATE INDEX tenant_role_bindings_role_ix ON cob3_identity.tenant_role_bindings (tenant_id, role_id);

-- ---------------------------------------------------------------------------
-- 17. authorization_grants (approved immutable ceiling)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.authorization_grants (
    tenant_id                   uuid          NOT NULL,
    authorization_grant_id      uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id             uuid          NOT NULL,
    grantor_principal_id        uuid          NOT NULL,
    grantee_principal_id        uuid          NOT NULL,
    grant_type                  varchar(24)   NOT NULL,
    status                      varchar(20)   NOT NULL DEFAULT 'draft',
    valid_from                  timestamptz   NOT NULL DEFAULT now(),
    valid_until                 timestamptz   NOT NULL,
    authorized_by_principal_id  uuid          NULL,
    authorized_at               timestamptz   NULL,
    revoked_at                  timestamptz   NULL,
    revocation_reason           text          NULL,
    grant_reason                text          NOT NULL,
    created_at                  timestamptz   NOT NULL DEFAULT now(),
    created_by                  varchar(255)  NOT NULL,
    updated_at                  timestamptz   NOT NULL DEFAULT now(),
    updated_by                  varchar(255)  NOT NULL,
    metadata                    jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                 bigint        NOT NULL DEFAULT 1,
    CONSTRAINT authorization_grants_pk PRIMARY KEY (tenant_id, authorization_grant_id),
    CONSTRAINT authorization_grants_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, authorization_grant_id),
    CONSTRAINT authorization_grants_grantee_uq UNIQUE (tenant_id, organization_id, authorization_grant_id, grantee_principal_id),
    CONSTRAINT authorization_grants_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT authorization_grants_grantor_membership_fk FOREIGN KEY (tenant_id, organization_id, grantor_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT authorization_grants_grantee_membership_fk FOREIGN KEY (tenant_id, organization_id, grantee_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT authorization_grants_authorizer_membership_fk FOREIGN KEY (tenant_id, organization_id, authorized_by_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT authorization_grants_type_ck CHECK (grant_type IN ('restricted_self', 'delegated')),
    CONSTRAINT authorization_grants_status_ck CHECK (status IN ('draft', 'active', 'suspended', 'revoked')),
    CONSTRAINT authorization_grants_window_ck CHECK (valid_until > valid_from),
    CONSTRAINT authorization_grants_type_shape_ck CHECK (
        (grant_type = 'restricted_self' AND grantor_principal_id = grantee_principal_id)
        OR (grant_type = 'delegated' AND grantor_principal_id <> grantee_principal_id)),
    CONSTRAINT authorization_grants_revoked_ck CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
    CONSTRAINT authorization_grants_authorization_pair_ck CHECK ((authorized_by_principal_id IS NULL) = (authorized_at IS NULL)),
    CONSTRAINT authorization_grants_authorized_states_ck CHECK (status NOT IN ('active', 'suspended') OR authorized_at IS NOT NULL),
    CONSTRAINT authorization_grants_grant_reason_nonblank_ck CHECK (length(btrim(grant_reason)) > 0)
);
-- At most one active delegated grant per automation per organization.
CREATE UNIQUE INDEX authorization_grants_one_active_delegated_uix
    ON cob3_identity.authorization_grants (tenant_id, organization_id, grantee_principal_id)
    WHERE grant_type = 'delegated' AND status = 'active';
CREATE INDEX authorization_grants_grantor_status_ix ON cob3_identity.authorization_grants (tenant_id, organization_id, grantor_principal_id, status);
CREATE INDEX authorization_grants_grantee_status_ix ON cob3_identity.authorization_grants (tenant_id, organization_id, grantee_principal_id, status);
CREATE INDEX authorization_grants_authorizer_ix ON cob3_identity.authorization_grants (tenant_id, organization_id, authorized_by_principal_id);

-- ---------------------------------------------------------------------------
-- 18. authorization_grant_permissions (explicit permission + scope entries)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.authorization_grant_permissions (
    tenant_id                          uuid          NOT NULL,
    authorization_grant_permission_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                    uuid          NOT NULL,
    authorization_grant_id             uuid          NOT NULL,
    permission_id                      uuid          NOT NULL,
    scope_id                           uuid          NOT NULL,
    requires_human_approval            boolean       NOT NULL DEFAULT false,
    created_at                         timestamptz   NOT NULL DEFAULT now(),
    created_by                         varchar(255)  NOT NULL,
    updated_at                         timestamptz   NOT NULL DEFAULT now(),
    updated_by                         varchar(255)  NOT NULL,
    metadata                           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT authorization_grant_permissions_pk PRIMARY KEY (tenant_id, authorization_grant_permission_id),
    CONSTRAINT authorization_grant_permissions_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, authorization_grant_permission_id),
    CONSTRAINT authorization_grant_permissions_entry_uq UNIQUE (tenant_id, organization_id, authorization_grant_id, permission_id, scope_id),
    CONSTRAINT authorization_grant_permissions_grant_entry_uq UNIQUE (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id),
    CONSTRAINT authorization_grant_permissions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT authorization_grant_permissions_grant_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id)
        REFERENCES cob3_identity.authorization_grants (tenant_id, organization_id, authorization_grant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT authorization_grant_permissions_permission_fk FOREIGN KEY (tenant_id, permission_id)
        REFERENCES cob3_identity.permissions (tenant_id, permission_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT authorization_grant_permissions_scope_fk FOREIGN KEY (tenant_id, organization_id, scope_id)
        REFERENCES cob3_identity.access_scopes (tenant_id, organization_id, scope_id) ON UPDATE RESTRICT ON DELETE RESTRICT
);
CREATE INDEX authorization_grant_permissions_scope_ix ON cob3_identity.authorization_grant_permissions (tenant_id, organization_id, scope_id);
CREATE INDEX authorization_grant_permissions_permission_ix ON cob3_identity.authorization_grant_permissions (tenant_id, permission_id);

-- ---------------------------------------------------------------------------
-- 19. principal_credentials (API keys; tokens remain credentials)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.principal_credentials (
    tenant_id               uuid          NOT NULL,
    credential_id           uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NOT NULL,
    principal_id            uuid          NOT NULL,
    authorization_grant_id  uuid          NOT NULL,
    credential_name         varchar(150)  NOT NULL,
    credential_usage        varchar(24)   NOT NULL,
    public_identifier       varchar(64)   NOT NULL,
    secret_digest           bytea         NOT NULL,
    digest_algorithm        varchar(32)   NOT NULL,
    audience                varchar(255)  NOT NULL,
    status                  varchar(20)   NOT NULL DEFAULT 'active',
    expires_at              timestamptz   NOT NULL,
    last_used_at            timestamptz   NULL,
    revoked_at              timestamptz   NULL,
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT principal_credentials_pk PRIMARY KEY (tenant_id, credential_id),
    CONSTRAINT principal_credentials_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, credential_id),
    CONSTRAINT principal_credentials_public_identifier_uq UNIQUE (tenant_id, public_identifier),
    CONSTRAINT principal_credentials_grant_credential_uq UNIQUE (tenant_id, organization_id, authorization_grant_id, credential_id),
    CONSTRAINT principal_credentials_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT principal_credentials_principal_membership_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- The credential's principal must be the grantee of its grant.
    CONSTRAINT principal_credentials_grant_grantee_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id, principal_id)
        REFERENCES cob3_identity.authorization_grants (tenant_id, organization_id, authorization_grant_id, grantee_principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT principal_credentials_name_nonblank_ck CHECK (length(btrim(credential_name)) > 0),
    CONSTRAINT principal_credentials_usage_ck CHECK (credential_usage IN ('personal_api', 'integration', 'automation', 'provisioning')),
    CONSTRAINT principal_credentials_public_identifier_format_ck CHECK (public_identifier ~ '^[A-Za-z0-9_-]{8,64}$'),
    CONSTRAINT principal_credentials_secret_digest_ck CHECK (octet_length(secret_digest) >= 32),
    CONSTRAINT principal_credentials_digest_algorithm_format_ck CHECK (digest_algorithm ~ '^[a-z0-9][a-z0-9_.:-]*$'),
    CONSTRAINT principal_credentials_audience_nonblank_ck CHECK (length(btrim(audience)) > 0),
    CONSTRAINT principal_credentials_status_ck CHECK (status IN ('active', 'revoked')),
    CONSTRAINT principal_credentials_revoked_ck CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
    CONSTRAINT principal_credentials_expiry_ck CHECK (expires_at > created_at)
);
CREATE INDEX principal_credentials_principal_status_ix ON cob3_identity.principal_credentials (tenant_id, organization_id, principal_id, status);
CREATE INDEX principal_credentials_grant_status_ix ON cob3_identity.principal_credentials (tenant_id, organization_id, authorization_grant_id, status);
CREATE INDEX principal_credentials_grant_principal_ix ON cob3_identity.principal_credentials (tenant_id, organization_id, authorization_grant_id, principal_id);

-- ---------------------------------------------------------------------------
-- 20. credential_permission_bindings (credential subset of grant entries)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.credential_permission_bindings (
    tenant_id                          uuid          NOT NULL,
    credential_permission_binding_id   uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                    uuid          NOT NULL,
    credential_id                      uuid          NOT NULL,
    authorization_grant_id             uuid          NOT NULL,
    authorization_grant_permission_id  uuid          NOT NULL,
    created_at                         timestamptz   NOT NULL DEFAULT now(),
    created_by                         varchar(255)  NOT NULL,
    updated_at                         timestamptz   NOT NULL DEFAULT now(),
    updated_by                         varchar(255)  NOT NULL,
    metadata                           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT credential_permission_bindings_pk PRIMARY KEY (tenant_id, credential_permission_binding_id),
    CONSTRAINT credential_permission_bindings_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, credential_permission_binding_id),
    CONSTRAINT credential_permission_bindings_entry_uq UNIQUE (tenant_id, organization_id, credential_id, authorization_grant_permission_id),
    CONSTRAINT credential_permission_bindings_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Same-grant integrity: both parents are reached through the same grant id.
    CONSTRAINT credential_permission_bindings_credential_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id, credential_id)
        REFERENCES cob3_identity.principal_credentials (tenant_id, organization_id, authorization_grant_id, credential_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT credential_permission_bindings_grant_entry_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id)
        REFERENCES cob3_identity.authorization_grant_permissions (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT credential_permission_bindings_append_only_ck CHECK (row_version = 1 AND updated_at = created_at AND updated_by = created_by)
);
CREATE INDEX credential_permission_bindings_credential_ix ON cob3_identity.credential_permission_bindings (tenant_id, organization_id, authorization_grant_id, credential_id);
CREATE INDEX credential_permission_bindings_entry_ix ON cob3_identity.credential_permission_bindings (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id);

-- ---------------------------------------------------------------------------
-- 21. action_approvals (single-use exact-action approvals)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.action_approvals (
    tenant_id                          uuid          NOT NULL,
    action_approval_id                 uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                    uuid          NOT NULL,
    authorization_grant_id             uuid          NOT NULL,
    authorization_grant_permission_id  uuid          NOT NULL,
    requesting_principal_id            uuid          NOT NULL,
    request_id                         uuid          NOT NULL,
    target_type                        varchar(64)   NOT NULL,
    target_id                          uuid          NOT NULL,
    action_digest                      bytea         NOT NULL,
    status                             varchar(20)   NOT NULL DEFAULT 'pending',
    decided_by_principal_id            uuid          NULL,
    decided_at                         timestamptz   NULL,
    expires_at                         timestamptz   NOT NULL,
    consumed_at                        timestamptz   NULL,
    created_at                         timestamptz   NOT NULL DEFAULT now(),
    created_by                         varchar(255)  NOT NULL,
    updated_at                         timestamptz   NOT NULL DEFAULT now(),
    updated_by                         varchar(255)  NOT NULL,
    metadata                           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT action_approvals_pk PRIMARY KEY (tenant_id, action_approval_id),
    CONSTRAINT action_approvals_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, action_approval_id),
    CONSTRAINT action_approvals_request_uq UNIQUE (tenant_id, request_id),
    CONSTRAINT action_approvals_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT action_approvals_grant_entry_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id)
        REFERENCES cob3_identity.authorization_grant_permissions (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Requesting principal must be the grant grantee.
    CONSTRAINT action_approvals_grant_grantee_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id, requesting_principal_id)
        REFERENCES cob3_identity.authorization_grants (tenant_id, organization_id, authorization_grant_id, grantee_principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT action_approvals_requester_membership_fk FOREIGN KEY (tenant_id, organization_id, requesting_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT action_approvals_decider_membership_fk FOREIGN KEY (tenant_id, organization_id, decided_by_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT action_approvals_target_type_format_ck CHECK (target_type ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT action_approvals_digest_ck CHECK (octet_length(action_digest) = 32),
    CONSTRAINT action_approvals_status_ck CHECK (status IN ('pending', 'approved', 'rejected', 'consumed', 'expired')),
    CONSTRAINT action_approvals_expiry_ck CHECK (expires_at > created_at),
    CONSTRAINT action_approvals_consumed_ck CHECK ((status = 'consumed') = (consumed_at IS NOT NULL)),
    CONSTRAINT action_approvals_decision_pair_ck CHECK ((decided_by_principal_id IS NULL) = (decided_at IS NULL)),
    CONSTRAINT action_approvals_decided_states_ck CHECK (status NOT IN ('approved', 'rejected', 'consumed') OR decided_at IS NOT NULL),
    CONSTRAINT action_approvals_approver_not_requester_ck CHECK (decided_by_principal_id IS NULL OR decided_by_principal_id <> requesting_principal_id)
);
CREATE INDEX action_approvals_status_expiry_ix ON cob3_identity.action_approvals (tenant_id, organization_id, status, expires_at);
CREATE INDEX action_approvals_grant_entry_ix ON cob3_identity.action_approvals (tenant_id, organization_id, authorization_grant_id, authorization_grant_permission_id);
CREATE INDEX action_approvals_grant_requester_ix ON cob3_identity.action_approvals (tenant_id, organization_id, authorization_grant_id, requesting_principal_id);
CREATE INDEX action_approvals_requester_ix ON cob3_identity.action_approvals (tenant_id, organization_id, requesting_principal_id);
CREATE INDEX action_approvals_decider_ix ON cob3_identity.action_approvals (tenant_id, organization_id, decided_by_principal_id);

-- ---------------------------------------------------------------------------
-- 23. external_identities
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.external_identities (
    tenant_id             uuid          NOT NULL,
    external_identity_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id       uuid          NULL,
    principal_id          uuid          NOT NULL,
    identity_provider_id  uuid          NOT NULL,
    subject               varchar(255)  NOT NULL,
    status                varchar(20)   NOT NULL DEFAULT 'active',
    last_seen_at          timestamptz   NULL,
    created_at            timestamptz   NOT NULL DEFAULT now(),
    created_by            varchar(255)  NOT NULL,
    updated_at            timestamptz   NOT NULL DEFAULT now(),
    updated_by            varchar(255)  NOT NULL,
    metadata              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version           bigint        NOT NULL DEFAULT 1,
    CONSTRAINT external_identities_pk PRIMARY KEY (tenant_id, external_identity_id),
    CONSTRAINT external_identities_subject_uq UNIQUE (tenant_id, identity_provider_id, subject),
    -- Supports session FKs that must match both identity and principal.
    CONSTRAINT external_identities_principal_entity_uq UNIQUE (tenant_id, external_identity_id, principal_id),
    CONSTRAINT external_identities_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT external_identities_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT external_identities_provider_fk FOREIGN KEY (tenant_id, identity_provider_id)
        REFERENCES cob3_identity.identity_providers (tenant_id, identity_provider_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT external_identities_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT external_identities_subject_nonblank_ck CHECK (length(btrim(subject)) > 0),
    CONSTRAINT external_identities_status_ck CHECK (status IN ('active', 'disabled'))
);
CREATE INDEX external_identities_principal_ix ON cob3_identity.external_identities (tenant_id, principal_id);

-- ---------------------------------------------------------------------------
-- 26. auth_sessions
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.auth_sessions (
    tenant_id               uuid          NOT NULL,
    session_id              uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NULL,
    principal_id            uuid          NOT NULL,
    session_kind            varchar(20)   NOT NULL,
    authentication_method   varchar(24)   NOT NULL,
    external_identity_id    uuid          NULL,
    authorization_grant_id  uuid          NULL,
    credential_id           uuid          NULL,
    session_handle_digest   bytea         NOT NULL,
    refresh_token_digest    bytea         NULL,
    audience                varchar(255)  NOT NULL,
    auth_version_at_issue   bigint        NOT NULL,
    authenticated_at        timestamptz   NOT NULL,
    expires_at              timestamptz   NOT NULL,
    revoked_at              timestamptz   NULL,
    last_seen_at            timestamptz   NULL,
    ip_address              inet          NULL,
    user_agent              text          NULL,
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT auth_sessions_pk PRIMARY KEY (tenant_id, session_id),
    CONSTRAINT auth_sessions_handle_uq UNIQUE (tenant_id, session_handle_digest),
    CONSTRAINT auth_sessions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT auth_sessions_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT auth_sessions_org_membership_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT auth_sessions_external_identity_fk FOREIGN KEY (tenant_id, external_identity_id, principal_id)
        REFERENCES cob3_identity.external_identities (tenant_id, external_identity_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT auth_sessions_grant_grantee_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id, principal_id)
        REFERENCES cob3_identity.authorization_grants (tenant_id, organization_id, authorization_grant_id, grantee_principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT auth_sessions_credential_fk FOREIGN KEY (tenant_id, organization_id, authorization_grant_id, credential_id)
        REFERENCES cob3_identity.principal_credentials (tenant_id, organization_id, authorization_grant_id, credential_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT auth_sessions_kind_ck CHECK (session_kind IN ('interactive', 'noninteractive')),
    CONSTRAINT auth_sessions_method_ck CHECK (authentication_method IN ('oidc', 'saml', 'api_key', 'workload_identity')),
    CONSTRAINT auth_sessions_handle_digest_ck CHECK (octet_length(session_handle_digest) >= 32),
    CONSTRAINT auth_sessions_refresh_digest_ck CHECK (refresh_token_digest IS NULL OR octet_length(refresh_token_digest) >= 32),
    CONSTRAINT auth_sessions_audience_nonblank_ck CHECK (length(btrim(audience)) > 0),
    CONSTRAINT auth_sessions_expiry_ck CHECK (expires_at > authenticated_at),
    CONSTRAINT auth_sessions_auth_version_ck CHECK (auth_version_at_issue > 0),
    CONSTRAINT auth_sessions_interactive_shape_ck CHECK (
        session_kind <> 'interactive'
        OR (authorization_grant_id IS NULL AND credential_id IS NULL AND authentication_method IN ('oidc', 'saml'))),
    CONSTRAINT auth_sessions_noninteractive_shape_ck CHECK (
        session_kind <> 'noninteractive'
        OR (organization_id IS NOT NULL AND authorization_grant_id IS NOT NULL)),
    CONSTRAINT auth_sessions_method_shape_ck CHECK (
        (authentication_method = 'api_key' AND credential_id IS NOT NULL AND external_identity_id IS NULL)
        OR (authentication_method <> 'api_key' AND credential_id IS NULL AND external_identity_id IS NOT NULL))
);
CREATE INDEX auth_sessions_principal_expiry_ix ON cob3_identity.auth_sessions (tenant_id, principal_id, expires_at);
CREATE INDEX auth_sessions_grant_ix ON cob3_identity.auth_sessions (tenant_id, organization_id, authorization_grant_id);
CREATE INDEX auth_sessions_credential_ix ON cob3_identity.auth_sessions (tenant_id, organization_id, credential_id);
CREATE INDEX auth_sessions_org_principal_ix ON cob3_identity.auth_sessions (tenant_id, organization_id, principal_id);
CREATE INDEX auth_sessions_external_identity_ix ON cob3_identity.auth_sessions (tenant_id, external_identity_id, principal_id);
CREATE INDEX auth_sessions_grant_principal_ix ON cob3_identity.auth_sessions (tenant_id, organization_id, authorization_grant_id, principal_id);
CREATE INDEX auth_sessions_grant_credential_ix ON cob3_identity.auth_sessions (tenant_id, organization_id, authorization_grant_id, credential_id);

-- ---------------------------------------------------------------------------
-- 27. audit_events (append-only; PK includes future partition key)
-- ---------------------------------------------------------------------------
CREATE TABLE cob3_identity.audit_events (
    tenant_id                          uuid          NOT NULL,
    audit_event_id                     uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                    uuid          NULL,
    occurred_at                        timestamptz   NOT NULL,
    actor_principal_id                 uuid          NULL,
    actor_identifier                   varchar(255)  NOT NULL,
    on_behalf_of_principal_id          uuid          NULL,
    initiating_principal_id            uuid          NULL,
    credential_id                      uuid          NULL,
    session_id                         uuid          NULL,
    authorization_grant_id             uuid          NULL,
    authorization_grant_permission_id  uuid          NULL,
    action_approval_id                 uuid          NULL,
    action                             varchar(128)  NOT NULL,
    target_type                        varchar(64)   NOT NULL,
    target_id                          uuid          NULL,
    outcome                            varchar(20)   NOT NULL,
    reason_code                        varchar(64)   NULL,
    request_id                         uuid          NULL,
    correlation_id                     varchar(128)  NULL,
    ip_address                         inet          NULL,
    details                            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    created_at                         timestamptz   NOT NULL DEFAULT now(),
    created_by                         varchar(255)  NOT NULL,
    updated_at                         timestamptz   NOT NULL DEFAULT now(),
    updated_by                         varchar(255)  NOT NULL,
    metadata                           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT audit_events_pk PRIMARY KEY (tenant_id, occurred_at, audit_event_id),
    CONSTRAINT audit_events_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT audit_events_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT audit_events_action_format_ck CHECK (action ~ '^[a-z0-9][a-z0-9_.:-]*$'),
    CONSTRAINT audit_events_target_type_format_ck CHECK (target_type ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT audit_events_actor_identifier_nonblank_ck CHECK (length(btrim(actor_identifier)) > 0),
    CONSTRAINT audit_events_outcome_ck CHECK (outcome IN ('success', 'denied', 'failure')),
    CONSTRAINT audit_events_details_object_ck CHECK (jsonb_typeof(details) = 'object'),
    CONSTRAINT audit_events_details_no_secret_keys_ck CHECK (NOT (details ?| ARRAY['password', 'secret', 'client_secret', 'private_key', 'api_key', 'access_token', 'refresh_token', 'token', 'authorization'])),
    CONSTRAINT audit_events_append_only_ck CHECK (row_version = 1 AND updated_at = created_at AND updated_by = created_by)
);
CREATE INDEX audit_events_org_time_ix ON cob3_identity.audit_events (tenant_id, organization_id, occurred_at DESC);
CREATE INDEX audit_events_actor_time_ix ON cob3_identity.audit_events (tenant_id, actor_principal_id, occurred_at DESC);
CREATE INDEX audit_events_request_ix ON cob3_identity.audit_events (tenant_id, request_id);
