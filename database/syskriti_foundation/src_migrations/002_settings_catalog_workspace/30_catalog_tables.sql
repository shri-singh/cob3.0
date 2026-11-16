-- =============================================================================
-- 30  cob3_catalog TABLES (10)
-- -----------------------------------------------------------------------------
-- asset_types is a platform registry (both scope IDs NULL). Every other table
-- is organization-owned: PK (tenant_id, entity_id) plus
-- UNIQUE (tenant_id, organization_id, entity_id) for scoped references.
-- domains/assets satisfy future_integrations/catalog_integration_contract.md.
-- =============================================================================

CREATE TABLE cob3_catalog.asset_types (
    asset_type_id      uuid          NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          uuid          NULL,
    organization_id    uuid          NULL,
    type_code          varchar(64)   NOT NULL,
    name               varchar(150)  NOT NULL,
    owning_module      varchar(32)   NOT NULL,
    attributes_schema  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    status             varchar(20)   NOT NULL DEFAULT 'active',
    -- Release-owned registry columns (addition to the design dictionary; never
    -- tenant-editable). They make module wiring data-driven instead of hiding
    -- security decisions in metadata.
    subtype_table           varchar(128)  NULL,   -- module row required at commit, e.g. cob3_workspace.projects
    read_permission_code    varchar(128)  NULL,   -- Identity permission for reading this asset type
    write_permission_code   varchar(128)  NULL,   -- Identity permission for changing it
    create_permission_code  varchar(128)  NULL,   -- organization-level creation permission
    owner_role_code         varchar(64)   NULL,   -- role bound to the creator on the exact asset scope
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         varchar(255)  NOT NULL,
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    updated_by         varchar(255)  NOT NULL,
    metadata           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT asset_types_pk PRIMARY KEY (asset_type_id),
    CONSTRAINT asset_types_subtype_table_ck CHECK (subtype_table IS NULL OR subtype_table ~ '^cob3_[a-z_]+\.[a-z_]+$'),
    CONSTRAINT asset_types_permission_codes_ck CHECK (
        COALESCE(read_permission_code, 'x') ~ '^[a-z0-9][a-z0-9_.-]*$'
        AND COALESCE(write_permission_code, 'x') ~ '^[a-z0-9][a-z0-9_.-]*$'
        AND COALESCE(create_permission_code, 'x') ~ '^[a-z0-9][a-z0-9_.-]*$'
        AND COALESCE(owner_role_code, 'x') ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT asset_types_code_uq UNIQUE (type_code),
    CONSTRAINT asset_types_platform_scope_ck CHECK (tenant_id IS NULL AND organization_id IS NULL),
    CONSTRAINT asset_types_code_format_ck CHECK (type_code ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT asset_types_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    -- 'ai' is added for the AI/agent modules (migration 003) next to the design's three owners.
    CONSTRAINT asset_types_owning_module_ck CHECK (owning_module IN ('catalog', 'workspace', 'ai', 'registered_product')),
    CONSTRAINT asset_types_attributes_schema_ck CHECK (jsonb_typeof(attributes_schema) = 'object'),
    CONSTRAINT asset_types_status_ck CHECK (status IN ('active', 'retired'))
);

CREATE TABLE cob3_catalog.domains (
    tenant_id         uuid          NOT NULL,
    domain_id         uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id   uuid          NOT NULL,
    domain_code       varchar(64)   NOT NULL,
    name              varchar(200)  NOT NULL,
    description       text          NULL,
    parent_domain_id  uuid          NULL,
    status            varchar(20)   NOT NULL DEFAULT 'active',
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        varchar(255)  NOT NULL,
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    updated_by        varchar(255)  NOT NULL,
    metadata          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version       bigint        NOT NULL DEFAULT 1,
    CONSTRAINT domains_pk PRIMARY KEY (tenant_id, domain_id),
    CONSTRAINT domains_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, domain_id),
    CONSTRAINT domains_code_uq UNIQUE (tenant_id, organization_id, domain_code),
    CONSTRAINT domains_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT domains_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT domains_parent_fk FOREIGN KEY (tenant_id, organization_id, parent_domain_id)
        REFERENCES cob3_catalog.domains (tenant_id, organization_id, domain_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT domains_code_format_ck CHECK (domain_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT domains_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT domains_not_own_parent_ck CHECK (parent_domain_id IS DISTINCT FROM domain_id),
    CONSTRAINT domains_status_ck CHECK (status IN ('active', 'archived'))
);
CREATE INDEX domains_parent_ix ON cob3_catalog.domains (tenant_id, organization_id, parent_domain_id) WHERE parent_domain_id IS NOT NULL;

CREATE TABLE cob3_catalog.assets (
    tenant_id           uuid          NOT NULL,
    asset_id            uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL,
    asset_type_id       uuid          NOT NULL,
    asset_code          varchar(128)  NOT NULL,
    name                varchar(255)  NOT NULL,
    description         text          NULL,
    domain_id           uuid          NULL,
    authorization_mode  varchar(16)   NOT NULL DEFAULT 'explicit',
    attributes          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    status              varchar(20)   NOT NULL DEFAULT 'draft',
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_by          varchar(255)  NOT NULL,
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    updated_by          varchar(255)  NOT NULL,
    metadata            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version         bigint        NOT NULL DEFAULT 1,
    CONSTRAINT assets_pk PRIMARY KEY (tenant_id, asset_id),
    CONSTRAINT assets_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, asset_id),
    CONSTRAINT assets_code_uq UNIQUE (tenant_id, organization_id, asset_code),
    CONSTRAINT assets_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT assets_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT assets_type_fk FOREIGN KEY (asset_type_id)
        REFERENCES cob3_catalog.asset_types (asset_type_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT assets_domain_fk FOREIGN KEY (tenant_id, organization_id, domain_id)
        REFERENCES cob3_catalog.domains (tenant_id, organization_id, domain_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT assets_code_format_ck CHECK (asset_code ~ '^[a-z0-9][a-z0-9_.:/-]*$'),
    CONSTRAINT assets_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT assets_authorization_mode_ck CHECK (authorization_mode IN ('explicit', 'governed')),
    CONSTRAINT assets_attributes_object_ck CHECK (jsonb_typeof(attributes) = 'object' AND pg_column_size(attributes) <= 65536),
    CONSTRAINT assets_status_ck CHECK (status IN ('draft', 'active', 'archived', 'deleted'))
);
CREATE INDEX assets_domain_status_ix ON cob3_catalog.assets (tenant_id, organization_id, domain_id, status);
CREATE INDEX assets_type_status_ix ON cob3_catalog.assets (tenant_id, organization_id, asset_type_id, status);
CREATE INDEX assets_type_ix ON cob3_catalog.assets (asset_type_id);

CREATE TABLE cob3_catalog.asset_ownerships (
    tenant_id           uuid          NOT NULL,
    asset_ownership_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL,
    asset_id            uuid          NOT NULL,
    principal_id        uuid          NULL,
    team_id             uuid          NULL,
    responsibility      varchar(20)   NOT NULL,
    is_primary          boolean       NOT NULL DEFAULT false,
    status              varchar(20)   NOT NULL DEFAULT 'active',
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_by          varchar(255)  NOT NULL,
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    updated_by          varchar(255)  NOT NULL,
    metadata            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version         bigint        NOT NULL DEFAULT 1,
    CONSTRAINT asset_ownerships_pk PRIMARY KEY (tenant_id, asset_ownership_id),
    CONSTRAINT asset_ownerships_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, asset_ownership_id),
    CONSTRAINT asset_ownerships_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_ownerships_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_ownerships_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_ownerships_principal_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_ownerships_team_fk FOREIGN KEY (tenant_id, organization_id, team_id)
        REFERENCES cob3_identity.teams (tenant_id, organization_id, team_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_ownerships_recipient_xor_ck CHECK ((principal_id IS NULL) <> (team_id IS NULL)),
    CONSTRAINT asset_ownerships_responsibility_ck CHECK (responsibility IN ('owner', 'steward', 'operator')),
    CONSTRAINT asset_ownerships_primary_owner_ck CHECK (NOT is_primary OR responsibility = 'owner'),
    CONSTRAINT asset_ownerships_status_ck CHECK (status IN ('active', 'revoked'))
);
CREATE UNIQUE INDEX asset_ownerships_principal_uix ON cob3_catalog.asset_ownerships (tenant_id, organization_id, asset_id, principal_id, responsibility)
    WHERE principal_id IS NOT NULL AND status = 'active';
CREATE UNIQUE INDEX asset_ownerships_team_uix ON cob3_catalog.asset_ownerships (tenant_id, organization_id, asset_id, team_id, responsibility)
    WHERE team_id IS NOT NULL AND status = 'active';
CREATE UNIQUE INDEX asset_ownerships_primary_uix ON cob3_catalog.asset_ownerships (tenant_id, organization_id, asset_id)
    WHERE responsibility = 'owner' AND is_primary AND status = 'active';
CREATE INDEX asset_ownerships_asset_ix ON cob3_catalog.asset_ownerships (tenant_id, organization_id, asset_id);
CREATE INDEX asset_ownerships_principal_ix ON cob3_catalog.asset_ownerships (tenant_id, organization_id, principal_id) WHERE principal_id IS NOT NULL;
CREATE INDEX asset_ownerships_team_ix ON cob3_catalog.asset_ownerships (tenant_id, organization_id, team_id) WHERE team_id IS NOT NULL;

CREATE TABLE cob3_catalog.asset_external_identifiers (
    tenant_id                     uuid          NOT NULL,
    asset_external_identifier_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id               uuid          NOT NULL,
    asset_id                      uuid          NOT NULL,
    source_system                 varchar(64)   NOT NULL,
    source_instance               varchar(128)  NOT NULL,
    external_id                   varchar(512)  NOT NULL,
    created_at                    timestamptz   NOT NULL DEFAULT now(),
    created_by                    varchar(255)  NOT NULL,
    updated_at                    timestamptz   NOT NULL DEFAULT now(),
    updated_by                    varchar(255)  NOT NULL,
    metadata                      jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                   bigint        NOT NULL DEFAULT 1,
    CONSTRAINT asset_external_identifiers_pk PRIMARY KEY (tenant_id, asset_external_identifier_id),
    CONSTRAINT asset_external_identifiers_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, asset_external_identifier_id),
    CONSTRAINT asset_external_identifiers_source_uq UNIQUE (tenant_id, organization_id, source_system, source_instance, external_id),
    CONSTRAINT asset_external_identifiers_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_external_identifiers_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_external_identifiers_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_external_identifiers_source_format_ck CHECK (source_system ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT asset_external_identifiers_instance_nonblank_ck CHECK (length(btrim(source_instance)) > 0),
    CONSTRAINT asset_external_identifiers_external_nonblank_ck CHECK (length(btrim(external_id)) > 0)
);
CREATE INDEX asset_external_identifiers_asset_ix ON cob3_catalog.asset_external_identifiers (tenant_id, organization_id, asset_id);

CREATE TABLE cob3_catalog.asset_locations (
    tenant_id          uuid          NOT NULL,
    asset_location_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id    uuid          NOT NULL,
    asset_id           uuid          NOT NULL,
    location_kind      varchar(24)   NOT NULL,
    uri                text          NOT NULL,
    is_primary         boolean       NOT NULL DEFAULT false,
    status             varchar(20)   NOT NULL DEFAULT 'active',
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         varchar(255)  NOT NULL,
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    updated_by         varchar(255)  NOT NULL,
    metadata           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT asset_locations_pk PRIMARY KEY (tenant_id, asset_location_id),
    CONSTRAINT asset_locations_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, asset_location_id),
    CONSTRAINT asset_locations_asset_entity_uq UNIQUE (tenant_id, organization_id, asset_id, asset_location_id),
    CONSTRAINT asset_locations_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_locations_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_locations_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_locations_kind_ck CHECK (location_kind IN ('app_route', 'external_url', 'documentation')),
    CONSTRAINT asset_locations_uri_ck CHECK (
        CASE location_kind
            WHEN 'app_route' THEN uri ~ '^/[^\s?#]*$'
            ELSE uri ~ '^https?://[^\s/@]+(/[^\s]*)?$'
        END
        AND uri !~* '(x-amz-signature|x-goog-signature|[?&](sig|signature|token|access_token|apikey|api_key|password)=)'),
    CONSTRAINT asset_locations_status_ck CHECK (status IN ('active', 'retired'))
);
CREATE UNIQUE INDEX asset_locations_primary_uix ON cob3_catalog.asset_locations (tenant_id, organization_id, asset_id, location_kind)
    WHERE is_primary AND status = 'active';

CREATE TABLE cob3_catalog.asset_relationships (
    tenant_id              uuid          NOT NULL,
    asset_relationship_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id        uuid          NOT NULL,
    source_asset_id        uuid          NOT NULL,
    target_asset_id        uuid          NOT NULL,
    relationship_type      varchar(32)   NOT NULL,
    evidence_reference     text          NULL,
    status                 varchar(20)   NOT NULL DEFAULT 'active',
    created_at             timestamptz   NOT NULL DEFAULT now(),
    created_by             varchar(255)  NOT NULL,
    updated_at             timestamptz   NOT NULL DEFAULT now(),
    updated_by             varchar(255)  NOT NULL,
    metadata               jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version            bigint        NOT NULL DEFAULT 1,
    CONSTRAINT asset_relationships_pk PRIMARY KEY (tenant_id, asset_relationship_id),
    CONSTRAINT asset_relationships_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, asset_relationship_id),
    CONSTRAINT asset_relationships_edge_uq UNIQUE (tenant_id, organization_id, source_asset_id, target_asset_id, relationship_type),
    CONSTRAINT asset_relationships_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_relationships_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_relationships_source_fk FOREIGN KEY (tenant_id, organization_id, source_asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_relationships_target_fk FOREIGN KEY (tenant_id, organization_id, target_asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_relationships_type_ck CHECK (relationship_type IN ('depends_on', 'derived_from', 'documents', 'related_to')),
    CONSTRAINT asset_relationships_not_self_ck CHECK (source_asset_id <> target_asset_id),
    CONSTRAINT asset_relationships_symmetric_order_ck CHECK (relationship_type <> 'related_to' OR source_asset_id < target_asset_id),
    CONSTRAINT asset_relationships_evidence_ck CHECK (evidence_reference IS NULL OR (length(btrim(evidence_reference)) > 0
        AND evidence_reference !~* '(x-amz-signature|[?&](sig|signature|token|access_token|apikey|api_key|password)=)')),
    CONSTRAINT asset_relationships_status_ck CHECK (status IN ('active', 'retired'))
);
CREATE INDEX asset_relationships_target_ix ON cob3_catalog.asset_relationships (tenant_id, organization_id, target_asset_id);

CREATE TABLE cob3_catalog.tags (
    tenant_id           uuid          NOT NULL,
    tag_id              uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL,
    tag_code            varchar(64)   NOT NULL,
    name                varchar(100)  NOT NULL,
    color               varchar(9)    NULL,
    visibility          varchar(16)   NOT NULL DEFAULT 'organization',
    owner_principal_id  uuid          NULL,
    status              varchar(20)   NOT NULL DEFAULT 'active',
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_by          varchar(255)  NOT NULL,
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    updated_by          varchar(255)  NOT NULL,
    metadata            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version         bigint        NOT NULL DEFAULT 1,
    CONSTRAINT tags_pk PRIMARY KEY (tenant_id, tag_id),
    CONSTRAINT tags_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, tag_id),
    CONSTRAINT tags_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tags_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tags_owner_fk FOREIGN KEY (tenant_id, organization_id, owner_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tags_code_format_ck CHECK (tag_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT tags_name_nonblank_ck CHECK (length(btrim(name)) > 0),
    CONSTRAINT tags_color_ck CHECK (color IS NULL OR color ~ '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$'),
    CONSTRAINT tags_visibility_ck CHECK (visibility IN ('organization', 'private')),
    CONSTRAINT tags_owner_shape_ck CHECK ((visibility = 'private') = (owner_principal_id IS NOT NULL)),
    CONSTRAINT tags_status_ck CHECK (status IN ('active', 'archived'))
);
CREATE UNIQUE INDEX tags_org_code_uix ON cob3_catalog.tags (tenant_id, organization_id, tag_code) WHERE visibility = 'organization';
CREATE UNIQUE INDEX tags_private_code_uix ON cob3_catalog.tags (tenant_id, organization_id, owner_principal_id, tag_code) WHERE visibility = 'private';

CREATE TABLE cob3_catalog.asset_tags (
    tenant_id                uuid          NOT NULL,
    asset_tag_id             uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id          uuid          NOT NULL,
    asset_id                 uuid          NOT NULL,
    tag_id                   uuid          NOT NULL,
    applied_by_principal_id  uuid          NOT NULL,
    confidence               numeric(5,4)  NULL,
    created_at               timestamptz   NOT NULL DEFAULT now(),
    created_by               varchar(255)  NOT NULL,
    updated_at               timestamptz   NOT NULL DEFAULT now(),
    updated_by               varchar(255)  NOT NULL,
    metadata                 jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version              bigint        NOT NULL DEFAULT 1,
    CONSTRAINT asset_tags_pk PRIMARY KEY (tenant_id, asset_tag_id),
    CONSTRAINT asset_tags_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, asset_tag_id),
    CONSTRAINT asset_tags_assignment_uq UNIQUE (tenant_id, organization_id, asset_id, tag_id),
    CONSTRAINT asset_tags_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_tags_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_tags_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_tags_tag_fk FOREIGN KEY (tenant_id, organization_id, tag_id)
        REFERENCES cob3_catalog.tags (tenant_id, organization_id, tag_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_tags_applied_by_fk FOREIGN KEY (tenant_id, organization_id, applied_by_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_tags_confidence_ck CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))
);
CREATE INDEX asset_tags_tag_ix ON cob3_catalog.asset_tags (tenant_id, organization_id, tag_id);
CREATE INDEX asset_tags_applied_by_ix ON cob3_catalog.asset_tags (tenant_id, organization_id, applied_by_principal_id);

CREATE TABLE cob3_catalog.asset_metadata_versions (
    tenant_id                  uuid          NOT NULL,
    asset_metadata_version_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id            uuid          NOT NULL,
    asset_id                   uuid          NOT NULL,
    version_number             bigint        NOT NULL,
    snapshot                   jsonb         NOT NULL,
    change_reason              text          NULL,
    created_at                 timestamptz   NOT NULL DEFAULT now(),
    created_by                 varchar(255)  NOT NULL,
    updated_at                 timestamptz   NOT NULL DEFAULT now(),
    updated_by                 varchar(255)  NOT NULL,
    metadata                   jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                bigint        NOT NULL DEFAULT 1,
    CONSTRAINT asset_metadata_versions_pk PRIMARY KEY (tenant_id, asset_metadata_version_id),
    CONSTRAINT asset_metadata_versions_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, asset_metadata_version_id),
    CONSTRAINT asset_metadata_versions_version_uq UNIQUE (tenant_id, organization_id, asset_id, version_number),
    CONSTRAINT asset_metadata_versions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_metadata_versions_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_metadata_versions_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT asset_metadata_versions_version_ck CHECK (version_number > 0),
    CONSTRAINT asset_metadata_versions_snapshot_ck CHECK (jsonb_typeof(snapshot) = 'object'),
    CONSTRAINT asset_metadata_versions_reason_ck CHECK (change_reason IS NULL OR length(btrim(change_reason)) > 0)
);
