-- =============================================================================
-- 40  cob3_workspace TABLES (16)
-- -----------------------------------------------------------------------------
-- All organization-owned: PK (tenant_id, entity_id) plus
-- UNIQUE (tenant_id, organization_id, entity_id). Composite keys prove
-- same-project folders, same-artifact revisions, same-principal sessions,
-- same-session journeys and same-schedule recipients/runs.
-- =============================================================================

CREATE TABLE cob3_workspace.projects (
    tenant_id                        uuid          NOT NULL,
    project_id                       uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                  uuid          NOT NULL,
    asset_id                         uuid          NOT NULL,
    project_kind                     varchar(16)   NOT NULL,
    personal_owner_principal_id      uuid          NULL,
    default_automation_principal_id  uuid          NULL,
    icon_code                        varchar(64)   NULL,
    color                            varchar(9)    NULL,
    created_at                       timestamptz   NOT NULL DEFAULT now(),
    created_by                       varchar(255)  NOT NULL,
    updated_at                       timestamptz   NOT NULL DEFAULT now(),
    updated_by                       varchar(255)  NOT NULL,
    metadata                         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT projects_pk PRIMARY KEY (tenant_id, project_id),
    CONSTRAINT projects_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, project_id),
    CONSTRAINT projects_asset_uq UNIQUE (tenant_id, organization_id, asset_id),
    CONSTRAINT projects_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT projects_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT projects_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT projects_personal_owner_fk FOREIGN KEY (tenant_id, organization_id, personal_owner_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT projects_default_automation_fk FOREIGN KEY (tenant_id, organization_id, default_automation_principal_id)
        REFERENCES cob3_identity.automation_profiles (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT projects_kind_ck CHECK (project_kind IN ('personal', 'shared')),
    CONSTRAINT projects_personal_owner_ck CHECK ((project_kind = 'personal') = (personal_owner_principal_id IS NOT NULL)),
    CONSTRAINT projects_icon_ck CHECK (icon_code IS NULL OR icon_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT projects_color_ck CHECK (color IS NULL OR color ~ '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$')
);
CREATE INDEX projects_personal_owner_ix ON cob3_workspace.projects (tenant_id, organization_id, personal_owner_principal_id)
    WHERE personal_owner_principal_id IS NOT NULL;
CREATE INDEX projects_default_automation_ix ON cob3_workspace.projects (tenant_id, organization_id, default_automation_principal_id)
    WHERE default_automation_principal_id IS NOT NULL;

CREATE TABLE cob3_workspace.folders (
    tenant_id         uuid          NOT NULL,
    folder_id         uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id   uuid          NOT NULL,
    project_id        uuid          NOT NULL,
    parent_folder_id  uuid          NULL,
    name              varchar(200)  NOT NULL,
    sort_order        integer       NOT NULL DEFAULT 0,
    status            varchar(20)   NOT NULL DEFAULT 'active',
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        varchar(255)  NOT NULL,
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    updated_by        varchar(255)  NOT NULL,
    metadata          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version       bigint        NOT NULL DEFAULT 1,
    CONSTRAINT folders_pk PRIMARY KEY (tenant_id, folder_id),
    CONSTRAINT folders_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, folder_id),
    CONSTRAINT folders_project_entity_uq UNIQUE (tenant_id, organization_id, project_id, folder_id),
    CONSTRAINT folders_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT folders_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT folders_project_fk FOREIGN KEY (tenant_id, organization_id, project_id)
        REFERENCES cob3_workspace.projects (tenant_id, organization_id, project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT folders_parent_fk FOREIGN KEY (tenant_id, organization_id, project_id, parent_folder_id)
        REFERENCES cob3_workspace.folders (tenant_id, organization_id, project_id, folder_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT folders_name_ck CHECK (length(btrim(name)) > 0 AND name !~ '[/\\]'),
    CONSTRAINT folders_not_own_parent_ck CHECK (parent_folder_id IS DISTINCT FROM folder_id),
    CONSTRAINT folders_status_ck CHECK (status IN ('active', 'archived'))
);
CREATE UNIQUE INDEX folders_root_name_uix ON cob3_workspace.folders (tenant_id, organization_id, project_id, lower(btrim(name)))
    WHERE parent_folder_id IS NULL AND status = 'active';
CREATE UNIQUE INDEX folders_child_name_uix ON cob3_workspace.folders (tenant_id, organization_id, project_id, parent_folder_id, lower(btrim(name)))
    WHERE parent_folder_id IS NOT NULL AND status = 'active';
CREATE INDEX folders_parent_ix ON cob3_workspace.folders (tenant_id, organization_id, project_id, parent_folder_id);

CREATE TABLE cob3_workspace.file_objects (
    tenant_id                 uuid          NOT NULL,
    file_object_id            uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id           uuid          NOT NULL,
    uploaded_by_principal_id  uuid          NOT NULL,
    storage_provider          varchar(32)   NOT NULL,
    storage_container         varchar(255)  NOT NULL,
    object_key                text          NOT NULL,
    object_version            varchar(255)  NULL,
    filename                  varchar(255)  NOT NULL,
    mime_type                 varchar(128)  NOT NULL,
    size_bytes                bigint        NOT NULL,
    sha256                    bytea         NOT NULL,
    status                    varchar(20)   NOT NULL DEFAULT 'quarantined',
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT file_objects_pk PRIMARY KEY (tenant_id, file_object_id),
    CONSTRAINT file_objects_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, file_object_id),
    CONSTRAINT file_objects_location_uq UNIQUE NULLS NOT DISTINCT (storage_provider, storage_container, object_key, object_version),
    CONSTRAINT file_objects_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT file_objects_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT file_objects_uploader_fk FOREIGN KEY (tenant_id, organization_id, uploaded_by_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT file_objects_provider_format_ck CHECK (storage_provider ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT file_objects_container_nonblank_ck CHECK (length(btrim(storage_container)) > 0),
    CONSTRAINT file_objects_key_ck CHECK (length(btrim(object_key)) > 0 AND object_key !~* '^https?://' AND object_key !~* '(x-amz-signature|signature=|sig=|token=)'),
    CONSTRAINT file_objects_filename_ck CHECK (length(btrim(filename)) > 0 AND filename !~ '[/\\]'),
    CONSTRAINT file_objects_mime_ck CHECK (mime_type ~ '^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$'),
    CONSTRAINT file_objects_size_ck CHECK (size_bytes >= 0),
    CONSTRAINT file_objects_sha256_ck CHECK (octet_length(sha256) = 32),
    CONSTRAINT file_objects_status_ck CHECK (status IN ('quarantined', 'ready', 'rejected', 'deleted'))
);
CREATE INDEX file_objects_uploader_ix ON cob3_workspace.file_objects (tenant_id, organization_id, uploaded_by_principal_id);

CREATE TABLE cob3_workspace.artifacts (
    tenant_id               uuid          NOT NULL,
    artifact_id             uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NOT NULL,
    asset_id                uuid          NOT NULL,
    project_id              uuid          NOT NULL,
    folder_id               uuid          NULL,
    artifact_kind           varchar(32)   NOT NULL,
    current_revision_id     uuid          NULL,
    inherit_project_access  boolean       NOT NULL DEFAULT true,
    created_via             varchar(20)   NOT NULL,
    source_thread_asset_id  uuid          NULL,
    source_run_reference    varchar(255)  NULL,
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT artifacts_pk PRIMARY KEY (tenant_id, artifact_id),
    CONSTRAINT artifacts_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, artifact_id),
    CONSTRAINT artifacts_asset_uq UNIQUE (tenant_id, organization_id, asset_id),
    CONSTRAINT artifacts_project_entity_uq UNIQUE (tenant_id, organization_id, project_id, artifact_id),
    CONSTRAINT artifacts_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifacts_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifacts_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifacts_project_fk FOREIGN KEY (tenant_id, organization_id, project_id)
        REFERENCES cob3_workspace.projects (tenant_id, organization_id, project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifacts_folder_fk FOREIGN KEY (tenant_id, organization_id, project_id, folder_id)
        REFERENCES cob3_workspace.folders (tenant_id, organization_id, project_id, folder_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifacts_source_thread_fk FOREIGN KEY (tenant_id, organization_id, source_thread_asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- artifacts_current_revision_fk (deferrable) is added in 50_*.
    CONSTRAINT artifacts_kind_ck CHECK (artifact_kind IN ('dashboard', 'saved_query', 'report', 'document', 'visualization',
                                                          'notebook', 'prompt', 'workflow', 'external_link')),
    CONSTRAINT artifacts_created_via_ck CHECK (created_via IN ('manual', 'import', 'automation')),
    CONSTRAINT artifacts_run_reference_ck CHECK (source_run_reference IS NULL OR length(btrim(source_run_reference)) > 0)
);
CREATE INDEX artifacts_project_ix ON cob3_workspace.artifacts (tenant_id, organization_id, project_id, folder_id);
CREATE INDEX artifacts_source_thread_ix ON cob3_workspace.artifacts (tenant_id, organization_id, source_thread_asset_id)
    WHERE source_thread_asset_id IS NOT NULL;
CREATE INDEX artifacts_current_revision_ix ON cob3_workspace.artifacts (tenant_id, organization_id, artifact_id, current_revision_id);

CREATE TABLE cob3_workspace.artifact_revisions (
    tenant_id                  uuid          NOT NULL,
    artifact_revision_id       uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id            uuid          NOT NULL,
    artifact_id                uuid          NOT NULL,
    revision_number            bigint        NOT NULL,
    content_kind               varchar(16)   NOT NULL,
    definition                 jsonb         NULL,
    file_object_id             uuid          NULL,
    external_location_id       uuid          NULL,
    definition_schema_version  integer       NOT NULL,
    content_sha256             bytea         NOT NULL,
    change_note                text          NULL,
    author_principal_id        uuid          NOT NULL,
    created_at                 timestamptz   NOT NULL DEFAULT now(),
    created_by                 varchar(255)  NOT NULL,
    updated_at                 timestamptz   NOT NULL DEFAULT now(),
    updated_by                 varchar(255)  NOT NULL,
    metadata                   jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                bigint        NOT NULL DEFAULT 1,
    CONSTRAINT artifact_revisions_pk PRIMARY KEY (tenant_id, artifact_revision_id),
    CONSTRAINT artifact_revisions_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, artifact_revision_id),
    CONSTRAINT artifact_revisions_number_uq UNIQUE (tenant_id, organization_id, artifact_id, revision_number),
    CONSTRAINT artifact_revisions_artifact_entity_uq UNIQUE (tenant_id, organization_id, artifact_id, artifact_revision_id),
    CONSTRAINT artifact_revisions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_revisions_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_revisions_artifact_fk FOREIGN KEY (tenant_id, organization_id, artifact_id)
        REFERENCES cob3_workspace.artifacts (tenant_id, organization_id, artifact_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_revisions_file_fk FOREIGN KEY (tenant_id, organization_id, file_object_id)
        REFERENCES cob3_workspace.file_objects (tenant_id, organization_id, file_object_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_revisions_location_fk FOREIGN KEY (tenant_id, organization_id, external_location_id)
        REFERENCES cob3_catalog.asset_locations (tenant_id, organization_id, asset_location_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_revisions_author_fk FOREIGN KEY (tenant_id, organization_id, author_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_revisions_number_ck CHECK (revision_number > 0),
    CONSTRAINT artifact_revisions_schema_version_ck CHECK (definition_schema_version > 0),
    CONSTRAINT artifact_revisions_kind_ck CHECK (content_kind IN ('inline', 'file', 'external')),
    CONSTRAINT artifact_revisions_branch_ck CHECK (
           (content_kind = 'inline'   AND definition IS NOT NULL AND file_object_id IS NULL     AND external_location_id IS NULL)
        OR (content_kind = 'file'     AND definition IS NULL     AND file_object_id IS NOT NULL AND external_location_id IS NULL)
        OR (content_kind = 'external' AND definition IS NULL     AND file_object_id IS NULL     AND external_location_id IS NOT NULL)),
    CONSTRAINT artifact_revisions_definition_ck CHECK (definition IS NULL OR (jsonb_typeof(definition) = 'object' AND pg_column_size(definition) <= 4194304)),
    CONSTRAINT artifact_revisions_sha256_ck CHECK (octet_length(content_sha256) = 32),
    CONSTRAINT artifact_revisions_note_ck CHECK (change_note IS NULL OR length(btrim(change_note)) > 0)
);
CREATE INDEX artifact_revisions_artifact_ix ON cob3_workspace.artifact_revisions (tenant_id, organization_id, artifact_id, revision_number DESC);
CREATE INDEX artifact_revisions_file_ix ON cob3_workspace.artifact_revisions (tenant_id, organization_id, file_object_id) WHERE file_object_id IS NOT NULL;
CREATE INDEX artifact_revisions_location_ix ON cob3_workspace.artifact_revisions (tenant_id, organization_id, external_location_id) WHERE external_location_id IS NOT NULL;
CREATE INDEX artifact_revisions_author_ix ON cob3_workspace.artifact_revisions (tenant_id, organization_id, author_principal_id);

CREATE TABLE cob3_workspace.artifact_drafts (
    tenant_id          uuid          NOT NULL,
    artifact_draft_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id    uuid          NOT NULL,
    artifact_id        uuid          NOT NULL,
    principal_id       uuid          NOT NULL,
    base_revision_id   uuid          NULL,
    draft_definition   jsonb         NOT NULL,
    expires_at         timestamptz   NOT NULL,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         varchar(255)  NOT NULL,
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    updated_by         varchar(255)  NOT NULL,
    metadata           jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version        bigint        NOT NULL DEFAULT 1,
    CONSTRAINT artifact_drafts_pk PRIMARY KEY (tenant_id, artifact_draft_id),
    CONSTRAINT artifact_drafts_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, artifact_draft_id),
    CONSTRAINT artifact_drafts_owner_uq UNIQUE (tenant_id, organization_id, artifact_id, principal_id),
    CONSTRAINT artifact_drafts_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_drafts_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_drafts_artifact_fk FOREIGN KEY (tenant_id, organization_id, artifact_id)
        REFERENCES cob3_workspace.artifacts (tenant_id, organization_id, artifact_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_drafts_principal_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_drafts_base_fk FOREIGN KEY (tenant_id, organization_id, artifact_id, base_revision_id)
        REFERENCES cob3_workspace.artifact_revisions (tenant_id, organization_id, artifact_id, artifact_revision_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT artifact_drafts_definition_ck CHECK (jsonb_typeof(draft_definition) = 'object' AND pg_column_size(draft_definition) <= 1048576),
    CONSTRAINT artifact_drafts_expiry_ck CHECK (expires_at > created_at)
);
CREATE INDEX artifact_drafts_principal_ix ON cob3_workspace.artifact_drafts (tenant_id, organization_id, principal_id);
CREATE INDEX artifact_drafts_base_ix ON cob3_workspace.artifact_drafts (tenant_id, organization_id, artifact_id, base_revision_id)
    WHERE base_revision_id IS NOT NULL;
CREATE INDEX artifact_drafts_expiry_ix ON cob3_workspace.artifact_drafts (expires_at);

CREATE TABLE cob3_workspace.bookmarks (
    tenant_id         uuid          NOT NULL,
    bookmark_id       uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id   uuid          NOT NULL,
    principal_id      uuid          NOT NULL,
    target_asset_id   uuid          NULL,
    external_url      text          NULL,
    label             varchar(255)  NULL,
    position          integer       NOT NULL DEFAULT 0,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        varchar(255)  NOT NULL,
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    updated_by        varchar(255)  NOT NULL,
    metadata          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version       bigint        NOT NULL DEFAULT 1,
    CONSTRAINT bookmarks_pk PRIMARY KEY (tenant_id, bookmark_id),
    CONSTRAINT bookmarks_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, bookmark_id),
    CONSTRAINT bookmarks_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT bookmarks_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT bookmarks_principal_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT bookmarks_target_fk FOREIGN KEY (tenant_id, organization_id, target_asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT bookmarks_target_xor_ck CHECK ((target_asset_id IS NULL) <> (external_url IS NULL)),
    CONSTRAINT bookmarks_url_ck CHECK (external_url IS NULL OR (external_url ~ '^https://[^\s/@]+(/[^\s]*)?$'
        AND external_url !~* '[?&](sig|signature|token|access_token|apikey|api_key|password)=')),
    CONSTRAINT bookmarks_label_ck CHECK (label IS NULL OR length(btrim(label)) > 0)
);
CREATE UNIQUE INDEX bookmarks_asset_uix ON cob3_workspace.bookmarks (tenant_id, organization_id, principal_id, target_asset_id)
    WHERE target_asset_id IS NOT NULL;
CREATE INDEX bookmarks_principal_ix ON cob3_workspace.bookmarks (tenant_id, organization_id, principal_id, position);
CREATE INDEX bookmarks_target_ix ON cob3_workspace.bookmarks (tenant_id, organization_id, target_asset_id) WHERE target_asset_id IS NOT NULL;

CREATE TABLE cob3_workspace.recent_items (
    tenant_id         uuid          NOT NULL,
    recent_item_id    uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id   uuid          NOT NULL,
    principal_id      uuid          NOT NULL,
    target_asset_id   uuid          NOT NULL,
    last_route        varchar(512)  NULL,
    first_visited_at  timestamptz   NOT NULL,
    last_visited_at   timestamptz   NOT NULL,
    visit_count       bigint        NOT NULL DEFAULT 1,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        varchar(255)  NOT NULL,
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    updated_by        varchar(255)  NOT NULL,
    metadata          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version       bigint        NOT NULL DEFAULT 1,
    CONSTRAINT recent_items_pk PRIMARY KEY (tenant_id, recent_item_id),
    CONSTRAINT recent_items_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, recent_item_id),
    CONSTRAINT recent_items_target_uq UNIQUE (tenant_id, organization_id, principal_id, target_asset_id),
    CONSTRAINT recent_items_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT recent_items_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT recent_items_principal_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT recent_items_target_fk FOREIGN KEY (tenant_id, organization_id, target_asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT recent_items_route_ck CHECK (last_route IS NULL OR last_route ~ '^/[^\s?#]*$'),
    CONSTRAINT recent_items_window_ck CHECK (last_visited_at >= first_visited_at),
    CONSTRAINT recent_items_count_ck CHECK (visit_count > 0)
);
CREATE INDEX recent_items_principal_ix ON cob3_workspace.recent_items (tenant_id, organization_id, principal_id, last_visited_at DESC);
CREATE INDEX recent_items_target_ix ON cob3_workspace.recent_items (tenant_id, organization_id, target_asset_id);

CREATE TABLE cob3_workspace.ui_sessions (
    tenant_id           uuid          NOT NULL,
    ui_session_id       uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL,
    principal_id        uuid          NOT NULL,
    auth_session_id     uuid          NOT NULL,
    client_instance_id  uuid          NOT NULL,
    app_version         varchar(64)   NULL,
    started_at          timestamptz   NOT NULL,
    last_seen_at        timestamptz   NOT NULL,
    ended_at            timestamptz   NULL,
    expires_at          timestamptz   NOT NULL,
    state               jsonb         NOT NULL DEFAULT '{}'::jsonb,
    device_context      jsonb         NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_by          varchar(255)  NOT NULL,
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    updated_by          varchar(255)  NOT NULL,
    metadata            jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version         bigint        NOT NULL DEFAULT 1,
    CONSTRAINT ui_sessions_pk PRIMARY KEY (tenant_id, ui_session_id),
    CONSTRAINT ui_sessions_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, ui_session_id),
    CONSTRAINT ui_sessions_principal_entity_uq UNIQUE (tenant_id, organization_id, principal_id, ui_session_id),
    CONSTRAINT ui_sessions_client_uq UNIQUE (tenant_id, organization_id, principal_id, client_instance_id),
    CONSTRAINT ui_sessions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT ui_sessions_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT ui_sessions_principal_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT ui_sessions_auth_session_fk FOREIGN KEY (tenant_id, auth_session_id)
        REFERENCES cob3_identity.auth_sessions (tenant_id, session_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT ui_sessions_app_version_ck CHECK (app_version IS NULL OR length(btrim(app_version)) > 0),
    CONSTRAINT ui_sessions_window_ck CHECK (last_seen_at >= started_at AND expires_at > started_at
                                            AND (ended_at IS NULL OR ended_at >= started_at)),
    CONSTRAINT ui_sessions_state_ck CHECK (jsonb_typeof(state) = 'object' AND pg_column_size(state) <= 65536
        AND NOT (state ?| ARRAY['password', 'secret', 'access_token', 'refresh_token', 'token', 'session_handle'])),
    CONSTRAINT ui_sessions_device_ck CHECK (jsonb_typeof(device_context) = 'object' AND pg_column_size(device_context) <= 4096)
);
CREATE INDEX ui_sessions_auth_session_ix ON cob3_workspace.ui_sessions (tenant_id, auth_session_id);
CREATE INDEX ui_sessions_expiry_ix ON cob3_workspace.ui_sessions (expires_at);

CREATE TABLE cob3_workspace.interaction_journeys (
    tenant_id               uuid          NOT NULL,
    interaction_journey_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NOT NULL,
    principal_id            uuid          NOT NULL,
    ui_session_id           uuid          NOT NULL,
    journey_type            varchar(64)   NOT NULL,
    started_at              timestamptz   NOT NULL,
    ended_at                timestamptz   NULL,
    status                  varchar(20)   NOT NULL DEFAULT 'active',
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT interaction_journeys_pk PRIMARY KEY (tenant_id, interaction_journey_id),
    CONSTRAINT interaction_journeys_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, interaction_journey_id),
    CONSTRAINT interaction_journeys_session_entity_uq UNIQUE (tenant_id, organization_id, ui_session_id, interaction_journey_id),
    CONSTRAINT interaction_journeys_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_journeys_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Composite key proves the session belongs to the same principal.
    CONSTRAINT interaction_journeys_session_fk FOREIGN KEY (tenant_id, organization_id, principal_id, ui_session_id)
        REFERENCES cob3_workspace.ui_sessions (tenant_id, organization_id, principal_id, ui_session_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_journeys_type_ck CHECK (journey_type ~ '^[a-z][a-z0-9_.-]*$'),
    CONSTRAINT interaction_journeys_window_ck CHECK (ended_at IS NULL OR ended_at >= started_at),
    CONSTRAINT interaction_journeys_status_ck CHECK (status IN ('active', 'completed', 'abandoned'))
);
CREATE INDEX interaction_journeys_session_ix ON cob3_workspace.interaction_journeys (tenant_id, organization_id, principal_id, ui_session_id);

CREATE TABLE cob3_workspace.interaction_events (
    tenant_id               uuid          NOT NULL,
    interaction_event_id    uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NOT NULL,
    principal_id            uuid          NOT NULL,
    ui_session_id           uuid          NOT NULL,
    interaction_journey_id  uuid          NULL,
    client_event_id         uuid          NOT NULL,
    event_name              varchar(64)   NOT NULL,
    feature_code            varchar(128)  NULL,
    target_asset_id         uuid          NULL,
    occurred_at             timestamptz   NOT NULL,
    received_at             timestamptz   NOT NULL DEFAULT now(),
    active_seconds          integer       NOT NULL DEFAULT 0,
    properties              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT interaction_events_pk PRIMARY KEY (tenant_id, interaction_event_id),
    CONSTRAINT interaction_events_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, interaction_event_id),
    CONSTRAINT interaction_events_client_uq UNIQUE (tenant_id, organization_id, ui_session_id, client_event_id),
    CONSTRAINT interaction_events_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_events_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_events_session_fk FOREIGN KEY (tenant_id, organization_id, principal_id, ui_session_id)
        REFERENCES cob3_workspace.ui_sessions (tenant_id, organization_id, principal_id, ui_session_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_events_journey_fk FOREIGN KEY (tenant_id, organization_id, ui_session_id, interaction_journey_id)
        REFERENCES cob3_workspace.interaction_journeys (tenant_id, organization_id, ui_session_id, interaction_journey_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_events_target_fk FOREIGN KEY (tenant_id, organization_id, target_asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_events_name_ck CHECK (event_name ~ '^[a-z][a-z0-9_.-]*$'),
    CONSTRAINT interaction_events_feature_ck CHECK (feature_code IS NULL OR feature_code ~ '^[a-z][a-z0-9_.-]*$'),
    CONSTRAINT interaction_events_clock_ck CHECK (occurred_at <= received_at + interval '5 minutes'
                                                  AND occurred_at >= received_at - interval '7 days'),
    CONSTRAINT interaction_events_active_seconds_ck CHECK (active_seconds BETWEEN 0 AND 3600),
    CONSTRAINT interaction_events_properties_ck CHECK (jsonb_typeof(properties) = 'object' AND pg_column_size(properties) <= 8192
        AND NOT (properties ?| ARRAY['password', 'secret', 'token', 'access_token', 'sql', 'prompt', 'query']))
);
CREATE INDEX interaction_events_principal_ix ON cob3_workspace.interaction_events (tenant_id, organization_id, principal_id, occurred_at);
CREATE INDEX interaction_events_journey_ix ON cob3_workspace.interaction_events (tenant_id, organization_id, ui_session_id, interaction_journey_id)
    WHERE interaction_journey_id IS NOT NULL;
CREATE INDEX interaction_events_target_ix ON cob3_workspace.interaction_events (tenant_id, organization_id, target_asset_id)
    WHERE target_asset_id IS NOT NULL;
CREATE INDEX interaction_events_session_ix ON cob3_workspace.interaction_events (tenant_id, organization_id, principal_id, ui_session_id);

CREATE TABLE cob3_workspace.interaction_daily (
    tenant_id             uuid          NOT NULL,
    interaction_daily_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id       uuid          NOT NULL,
    principal_id          uuid          NOT NULL,
    day                   date          NOT NULL,
    feature_code          varchar(128)  NOT NULL,
    event_count           bigint        NOT NULL DEFAULT 0,
    active_seconds        bigint        NOT NULL DEFAULT 0,
    computed_at           timestamptz   NOT NULL,
    created_at            timestamptz   NOT NULL DEFAULT now(),
    created_by            varchar(255)  NOT NULL,
    updated_at            timestamptz   NOT NULL DEFAULT now(),
    updated_by            varchar(255)  NOT NULL,
    metadata              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version           bigint        NOT NULL DEFAULT 1,
    CONSTRAINT interaction_daily_pk PRIMARY KEY (tenant_id, interaction_daily_id),
    CONSTRAINT interaction_daily_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, interaction_daily_id),
    CONSTRAINT interaction_daily_grain_uq UNIQUE (tenant_id, organization_id, principal_id, day, feature_code),
    CONSTRAINT interaction_daily_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_daily_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_daily_principal_fk FOREIGN KEY (tenant_id, organization_id, principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT interaction_daily_feature_ck CHECK (feature_code ~ '^[a-z][a-z0-9_.-]*$'),
    CONSTRAINT interaction_daily_counts_ck CHECK (event_count >= 0 AND active_seconds BETWEEN 0 AND 86400)
);

CREATE TABLE cob3_workspace.report_schedules (
    tenant_id               uuid          NOT NULL,
    report_schedule_id      uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id         uuid          NOT NULL,
    artifact_id             uuid          NOT NULL,
    revision_policy         varchar(16)   NOT NULL,
    pinned_revision_id      uuid          NULL,
    execution_principal_id  uuid          NOT NULL,
    credential_id           uuid          NOT NULL,
    cron_expression         varchar(128)  NOT NULL,
    timezone                varchar(64)   NOT NULL,
    output_format           varchar(16)   NOT NULL,
    status                  varchar(20)   NOT NULL DEFAULT 'paused',
    next_run_at             timestamptz   NULL,
    misfire_policy          varchar(16)   NOT NULL DEFAULT 'skip',
    overlap_policy          varchar(16)   NOT NULL DEFAULT 'skip',
    created_at              timestamptz   NOT NULL DEFAULT now(),
    created_by              varchar(255)  NOT NULL,
    updated_at              timestamptz   NOT NULL DEFAULT now(),
    updated_by              varchar(255)  NOT NULL,
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version             bigint        NOT NULL DEFAULT 1,
    CONSTRAINT report_schedules_pk PRIMARY KEY (tenant_id, report_schedule_id),
    CONSTRAINT report_schedules_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, report_schedule_id),
    CONSTRAINT report_schedules_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_schedules_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_schedules_artifact_fk FOREIGN KEY (tenant_id, organization_id, artifact_id)
        REFERENCES cob3_workspace.artifacts (tenant_id, organization_id, artifact_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_schedules_pinned_fk FOREIGN KEY (tenant_id, organization_id, artifact_id, pinned_revision_id)
        REFERENCES cob3_workspace.artifact_revisions (tenant_id, organization_id, artifact_id, artifact_revision_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_schedules_executor_fk FOREIGN KEY (tenant_id, organization_id, execution_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_schedules_credential_fk FOREIGN KEY (tenant_id, organization_id, credential_id)
        REFERENCES cob3_identity.principal_credentials (tenant_id, organization_id, credential_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_schedules_policy_ck CHECK (revision_policy IN ('pinned', 'latest')),
    CONSTRAINT report_schedules_pinned_ck CHECK ((revision_policy = 'pinned') = (pinned_revision_id IS NOT NULL)),
    CONSTRAINT report_schedules_cron_ck CHECK (cron_expression ~ '^\S+(\s+\S+){4,5}$'),
    CONSTRAINT report_schedules_format_ck CHECK (output_format IN ('pdf', 'csv', 'xlsx', 'json')),
    CONSTRAINT report_schedules_status_ck CHECK (status IN ('active', 'paused', 'retired')),
    CONSTRAINT report_schedules_misfire_ck CHECK (misfire_policy IN ('skip', 'catch_up_once')),
    CONSTRAINT report_schedules_overlap_ck CHECK (overlap_policy IN ('skip', 'queue'))
);
CREATE INDEX report_schedules_artifact_ix ON cob3_workspace.report_schedules (tenant_id, organization_id, artifact_id, pinned_revision_id);
CREATE INDEX report_schedules_executor_ix ON cob3_workspace.report_schedules (tenant_id, organization_id, execution_principal_id);
CREATE INDEX report_schedules_credential_ix ON cob3_workspace.report_schedules (tenant_id, organization_id, credential_id);
CREATE INDEX report_schedules_due_ix ON cob3_workspace.report_schedules (status, next_run_at) WHERE status = 'active';

CREATE TABLE cob3_workspace.report_recipients (
    tenant_id                 uuid          NOT NULL,
    report_recipient_id       uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id           uuid          NOT NULL,
    report_schedule_id        uuid          NOT NULL,
    recipient_principal_id    uuid          NULL,
    notification_endpoint_id  uuid          NULL,
    delivery_mode             varchar(16)   NOT NULL DEFAULT 'link',
    status                    varchar(20)   NOT NULL DEFAULT 'active',
    created_at                timestamptz   NOT NULL DEFAULT now(),
    created_by                varchar(255)  NOT NULL,
    updated_at                timestamptz   NOT NULL DEFAULT now(),
    updated_by                varchar(255)  NOT NULL,
    metadata                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version               bigint        NOT NULL DEFAULT 1,
    CONSTRAINT report_recipients_pk PRIMARY KEY (tenant_id, report_recipient_id),
    CONSTRAINT report_recipients_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, report_recipient_id),
    CONSTRAINT report_recipients_schedule_entity_uq UNIQUE (tenant_id, organization_id, report_schedule_id, report_recipient_id),
    CONSTRAINT report_recipients_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_recipients_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_recipients_schedule_fk FOREIGN KEY (tenant_id, organization_id, report_schedule_id)
        REFERENCES cob3_workspace.report_schedules (tenant_id, organization_id, report_schedule_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_recipients_principal_fk FOREIGN KEY (tenant_id, organization_id, recipient_principal_id)
        REFERENCES cob3_identity.organization_memberships (tenant_id, organization_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_recipients_endpoint_fk FOREIGN KEY (tenant_id, notification_endpoint_id)
        REFERENCES cob3_settings.notification_endpoints (tenant_id, notification_endpoint_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- v1: internal recipients only; external-only recipients/attachments are rejected.
    CONSTRAINT report_recipients_internal_v1_ck CHECK (recipient_principal_id IS NOT NULL),
    CONSTRAINT report_recipients_mode_ck CHECK (delivery_mode IN ('link')),
    CONSTRAINT report_recipients_status_ck CHECK (status IN ('active', 'revoked'))
);
CREATE UNIQUE INDEX report_recipients_active_uix ON cob3_workspace.report_recipients (tenant_id, organization_id, report_schedule_id, recipient_principal_id)
    WHERE status = 'active';
CREATE INDEX report_recipients_principal_ix ON cob3_workspace.report_recipients (tenant_id, organization_id, recipient_principal_id);
CREATE INDEX report_recipients_endpoint_ix ON cob3_workspace.report_recipients (tenant_id, notification_endpoint_id) WHERE notification_endpoint_id IS NOT NULL;

CREATE TABLE cob3_workspace.report_runs (
    tenant_id             uuid          NOT NULL,
    report_run_id         uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id       uuid          NOT NULL,
    report_schedule_id    uuid          NOT NULL,
    artifact_revision_id  uuid          NOT NULL,
    scheduled_for         timestamptz   NOT NULL,
    status                varchar(20)   NOT NULL DEFAULT 'queued',
    started_at            timestamptz   NULL,
    completed_at          timestamptz   NULL,
    lease_expires_at      timestamptz   NULL,
    attempt_count         integer       NOT NULL DEFAULT 0,
    output_file_id        uuid          NULL,
    row_count             bigint        NULL,
    error_code            varchar(64)   NULL,
    correlation_id        varchar(128)  NOT NULL,
    data_access_manifest  jsonb         NOT NULL,
    created_at            timestamptz   NOT NULL DEFAULT now(),
    created_by            varchar(255)  NOT NULL,
    updated_at            timestamptz   NOT NULL DEFAULT now(),
    updated_by            varchar(255)  NOT NULL,
    metadata              jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version           bigint        NOT NULL DEFAULT 1,
    CONSTRAINT report_runs_pk PRIMARY KEY (tenant_id, report_run_id),
    CONSTRAINT report_runs_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, report_run_id),
    CONSTRAINT report_runs_schedule_instant_uq UNIQUE (tenant_id, organization_id, report_schedule_id, scheduled_for),
    CONSTRAINT report_runs_schedule_entity_uq UNIQUE (tenant_id, organization_id, report_schedule_id, report_run_id),
    CONSTRAINT report_runs_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_runs_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_runs_schedule_fk FOREIGN KEY (tenant_id, organization_id, report_schedule_id)
        REFERENCES cob3_workspace.report_schedules (tenant_id, organization_id, report_schedule_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_runs_revision_fk FOREIGN KEY (tenant_id, organization_id, artifact_revision_id)
        REFERENCES cob3_workspace.artifact_revisions (tenant_id, organization_id, artifact_revision_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_runs_output_fk FOREIGN KEY (tenant_id, organization_id, output_file_id)
        REFERENCES cob3_workspace.file_objects (tenant_id, organization_id, file_object_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_runs_status_ck CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'canceled')),
    CONSTRAINT report_runs_attempts_ck CHECK (attempt_count >= 0),
    CONSTRAINT report_runs_rows_ck CHECK (row_count IS NULL OR row_count >= 0),
    CONSTRAINT report_runs_success_ck CHECK (status <> 'succeeded' OR (completed_at IS NOT NULL AND output_file_id IS NOT NULL)),
    CONSTRAINT report_runs_failure_ck CHECK (status <> 'failed' OR (completed_at IS NOT NULL AND error_code IS NOT NULL)),
    CONSTRAINT report_runs_window_ck CHECK (completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at),
    CONSTRAINT report_runs_error_code_ck CHECK (error_code IS NULL OR error_code ~ '^[a-z0-9][a-z0-9_.-]*$'),
    CONSTRAINT report_runs_correlation_ck CHECK (length(btrim(correlation_id)) > 0),
    CONSTRAINT report_runs_manifest_ck CHECK (jsonb_typeof(data_access_manifest) = 'object' AND pg_column_size(data_access_manifest) <= 262144)
);
CREATE INDEX report_runs_schedule_ix ON cob3_workspace.report_runs (tenant_id, organization_id, report_schedule_id, scheduled_for DESC);
CREATE INDEX report_runs_revision_ix ON cob3_workspace.report_runs (tenant_id, organization_id, artifact_revision_id);
CREATE INDEX report_runs_output_ix ON cob3_workspace.report_runs (tenant_id, organization_id, output_file_id) WHERE output_file_id IS NOT NULL;
CREATE INDEX report_runs_runnable_ix ON cob3_workspace.report_runs (status, lease_expires_at) WHERE status IN ('queued', 'running');

CREATE TABLE cob3_workspace.report_deliveries (
    tenant_id                   uuid          NOT NULL,
    report_delivery_id          uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id             uuid          NOT NULL,
    report_run_id               uuid          NOT NULL,
    report_recipient_id         uuid          NOT NULL,
    status                      varchar(20)   NOT NULL DEFAULT 'pending',
    attempt_count               integer       NOT NULL DEFAULT 0,
    delivered_at                timestamptz   NULL,
    provider_message_reference  varchar(255)  NULL,
    last_error_code             varchar(64)   NULL,
    created_at                  timestamptz   NOT NULL DEFAULT now(),
    created_by                  varchar(255)  NOT NULL,
    updated_at                  timestamptz   NOT NULL DEFAULT now(),
    updated_by                  varchar(255)  NOT NULL,
    metadata                    jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                 bigint        NOT NULL DEFAULT 1,
    CONSTRAINT report_deliveries_pk PRIMARY KEY (tenant_id, report_delivery_id),
    CONSTRAINT report_deliveries_tenant_org_entity_uq UNIQUE (tenant_id, organization_id, report_delivery_id),
    CONSTRAINT report_deliveries_run_recipient_uq UNIQUE (tenant_id, organization_id, report_run_id, report_recipient_id),
    CONSTRAINT report_deliveries_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_deliveries_organization_fk FOREIGN KEY (tenant_id, organization_id)
        REFERENCES cob3_identity.organizations (tenant_id, organization_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_deliveries_run_fk FOREIGN KEY (tenant_id, organization_id, report_run_id)
        REFERENCES cob3_workspace.report_runs (tenant_id, organization_id, report_run_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_deliveries_recipient_fk FOREIGN KEY (tenant_id, organization_id, report_recipient_id)
        REFERENCES cob3_workspace.report_recipients (tenant_id, organization_id, report_recipient_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT report_deliveries_status_ck CHECK (status IN ('pending', 'sent', 'failed', 'skipped')),
    CONSTRAINT report_deliveries_attempts_ck CHECK (attempt_count >= 0),
    CONSTRAINT report_deliveries_sent_ck CHECK ((status = 'sent') = (delivered_at IS NOT NULL)),
    CONSTRAINT report_deliveries_error_ck CHECK (last_error_code IS NULL OR last_error_code ~ '^[a-z0-9][a-z0-9_.-]*$')
);
CREATE INDEX report_deliveries_recipient_ix ON cob3_workspace.report_deliveries (tenant_id, organization_id, report_recipient_id);
CREATE INDEX report_deliveries_pending_ix ON cob3_workspace.report_deliveries (status) WHERE status IN ('pending', 'failed');
