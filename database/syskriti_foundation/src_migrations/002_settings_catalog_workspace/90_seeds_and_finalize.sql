-- =============================================================================
-- 90  RELEASE-OWNED REGISTRY SEEDS, IAM TEMPLATE BACKFILL, COMMENTS, RECORD
-- -----------------------------------------------------------------------------
-- Platform registries (asset_types, setting_definitions) are product-release
-- data, not tenant data. Tenant IAM rows are only ever created per tenant.
-- =============================================================================
PERFORM cob3_identity.set_system_context('system:migration-002');

INSERT INTO cob3_catalog.asset_types
       (type_code, name, owning_module, attributes_schema, subtype_table, read_permission_code, write_permission_code,
        create_permission_code, owner_role_code, created_by, updated_by)
VALUES ('application',       'Application',        'catalog',   '{}', NULL, NULL, NULL, NULL, NULL, 'system:migration-002', 'system:migration-002'),
       ('dataset',           'Dataset',            'catalog',   '{}', NULL, NULL, NULL, NULL, NULL, 'system:migration-002', 'system:migration-002'),
       ('dashboard',         'Dashboard',          'catalog',   '{}', NULL, NULL, NULL, NULL, NULL, 'system:migration-002', 'system:migration-002'),
       ('document',          'Document',           'catalog',   '{}', NULL, NULL, NULL, NULL, NULL, 'system:migration-002', 'system:migration-002'),
       ('portal',            'Portal',             'catalog',   '{}', NULL, NULL, NULL, NULL, NULL, 'system:migration-002', 'system:migration-002'),
       ('workflow',          'Workflow',           'catalog',   '{}', NULL, NULL, NULL, NULL, NULL, 'system:migration-002', 'system:migration-002'),
       ('workspace_project', 'Workspace project',  'workspace', '{}', 'cob3_workspace.projects',
        'project.read', 'project.update', 'project.create', 'workspace_owner', 'system:migration-002', 'system:migration-002'),
       ('saved_artifact',    'Saved artifact',     'workspace', '{}', 'cob3_workspace.artifacts',
        'artifact.read', 'artifact.update', NULL, 'workspace_owner', 'system:migration-002', 'system:migration-002');

-- Starter settings registry (design 7.1). value_type + validation_schema are
-- enforced by cob3_settings.value_violation; product releases add keys by
-- reviewed migrations. navigation.role_navigation / workspace.default_artifact_id
-- receive the legacy obs3_settings / saved_artifact.is_default data.
INSERT INTO cob3_settings.setting_definitions
       (setting_key, definition_version, value_type, default_value, validation_schema, allowed_scopes, category,
        user_overridable, lockable, created_by, updated_by)
SELECT d.k, 1, d.t, d.dv::jsonb, d.vs::jsonb, d.sc, d.cat, d.uo, d.lk, 'system:migration-002', 'system:migration-002'
  FROM (VALUES
    ('ui.theme',                      'string',  '"system"',      '{"enum":["system","light","dark"]}',
     ARRAY['tenant','organization','team','principal','principal_org'], 'appearance', true, true),
    ('ui.density',                    'string',  '"comfortable"', '{"enum":["comfortable","compact"]}',
     ARRAY['tenant','organization','principal','principal_org'], 'appearance', true, false),
    ('ui.font_scale',                 'decimal', '1',             '{"minimum":0.75,"maximum":2}',
     ARRAY['principal'], 'accessibility', true, false),
    ('ui.reduce_motion',              'boolean', 'false',         '{}',
     ARRAY['tenant','organization','principal'], 'accessibility', true, false),
    ('ui.high_contrast',              'boolean', 'false',         '{}',
     ARRAY['principal'], 'accessibility', true, false),
    ('locale.language',               'string',  '"en"',          '{"pattern":"^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$","maxLength":35}',
     ARRAY['tenant','organization','principal','principal_org'], 'localization', true, true),
    ('locale.timezone',               'string',  '"UTC"',         '{"maxLength":64,"pattern":"^[A-Za-z0-9_+/-]+$"}',
     ARRAY['tenant','organization','principal','principal_org'], 'localization', true, true),
    ('locale.date_format',            'string',  '"iso"',         '{"enum":["iso","us","eu"]}',
     ARRAY['tenant','organization','principal','principal_org'], 'localization', true, false),
    ('locale.number_format',          'string',  '"en-US"',       '{"pattern":"^[a-z]{2}-[A-Z]{2}$"}',
     ARRAY['tenant','organization','principal','principal_org'], 'localization', true, false),
    ('navigation.home_asset_id',      'string',  '""',            '{"pattern":"^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$"}',
     ARRAY['organization','team','principal','principal_org'], 'navigation', true, false),
    ('navigation.pinned_routes',      'array',   '[]',            '{"maxItems":20}',
     ARRAY['principal','principal_org'], 'navigation', true, false),
    ('navigation.sidebar_order',      'array',   '[]',            '{"maxItems":50}',
     ARRAY['organization','team','principal','principal_org'], 'navigation', true, false),
    ('navigation.role_navigation',    'object',  '{}',            '{}',
     ARRAY['tenant','organization','team'], 'navigation', false, true),
    ('display.page_size',             'integer', '50',            '{"minimum":10,"maximum":500}',
     ARRAY['tenant','organization','principal','principal_org'], 'data_display', true, false),
    ('display.default_time_range',    'string',  '"24h"',         '{"enum":["15m","1h","6h","24h","7d","30d"]}',
     ARRAY['tenant','organization','team','principal','principal_org','project'], 'data_display', true, false),
    ('display.chart_palette',         'string',  '"default"',     '{"enum":["default","colorblind","monochrome"]}',
     ARRAY['tenant','organization','principal','principal_org'], 'data_display', true, false),
    ('workspace.default_save_format', 'string',  '"dashboard"',   '{"enum":["dashboard","saved_query","report","document","notebook"]}',
     ARRAY['organization','principal','principal_org','project'], 'workspace', true, false),
    ('workspace.default_artifact_id', 'string',  '""',            '{"pattern":"^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$"}',
     ARRAY['principal_org','project'], 'workspace', true, false)
  ) AS d(k, t, dv, vs, sc, cat, uo, lk);

-- Existing tenants receive the new module permissions and roles (idempotent;
-- a conflicting pre-existing definition aborts the migration for review).
FOR _m_rec IN SELECT t.tenant_id FROM cob3_tenant.tenants t ORDER BY t.tenant_id LOOP
    PERFORM cob3_identity.provision_tenant_iam_seed(_m_rec.tenant_id, 'system:migration-002');
END LOOP;
PERFORM cob3_identity.set_system_context('system:migration-002');

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------
COMMENT ON SCHEMA cob3_settings IS 'Preferences, branding, media metadata, notification destinations, adapter configuration and restrictive policies (migration 002).';
COMMENT ON SCHEMA cob3_catalog IS 'Business domains and canonical resource registry: identity, accountability, metadata, locations and semantic links (migration 002).';
COMMENT ON SCHEMA cob3_workspace IS 'Projects, folders, artifact content/revisions, drafts, personal pointers, UI state, scheduled reports and UI telemetry (migration 002).';
FOR _m_rec IN SELECT * FROM (VALUES
    ('cob3_identity.principal_emails',              'Authoritative human contact addresses; SSO subject remains the login identity. Same address may belong to several principals; never merged.'),
    ('cob3_identity.email_verification_challenges', 'Short-lived proof-of-control challenges; only digests are stored. Use issue_/consume_email_verification.'),
    ('cob3_settings.setting_definitions',           'Platform registry of supported settings (versioned, typed, validated); not a free-form preference bag.'),
    ('cob3_settings.setting_scopes',                'Typed subject that settings apply to: tenant, organization, team, principal, principal_org or project.'),
    ('cob3_settings.setting_values',                'Validated explicit override per scope and definition; deleting the row means inherit.'),
    ('cob3_settings.setting_change_events',         'Append-only settings change history written by trigger.'),
    ('cob3_settings.media_objects',                 'Private object-storage metadata for avatars/logos; bytes stay in object storage; scanner sets ready.'),
    ('cob3_settings.branding_profiles',             'Brand identity per tenant/organization/team scope with allowlisted theme tokens.'),
    ('cob3_settings.contact_addresses',             'Organization/team operational mailboxes; human emails stay in Identity, billing email in Tenant.'),
    ('cob3_settings.notification_endpoints',        'Verified notification destinations, separate from preferences.'),
    ('cob3_settings.notification_preferences',      'Per category/channel notification, digest and quiet-hour choices.'),
    ('cob3_settings.integration_configurations',    'Versioned non-secret adapter configuration and secret references; active versions are immutable.'),
    ('cob3_settings.automation_policies',           'Restrictive upper bounds on delegated execution (AND/MIN/OR composition); grants nothing.'),
    ('cob3_catalog.asset_types',                    'Release-owned registry of resource families, module ownership and permission wiring.'),
    ('cob3_catalog.domains',                        'Canonical business domain master referenced by Identity team_domains and access_scopes.'),
    ('cob3_catalog.assets',                         'Canonical resource identity and access classification (explicit or governed).'),
    ('cob3_catalog.asset_ownerships',               'Accountability and stewardship; never an ACL.'),
    ('cob3_catalog.asset_external_identifiers',     'Trusted external ID mappings; immutable after creation.'),
    ('cob3_catalog.asset_locations',                'Stable routes/links; never bearer or presigned URLs.'),
    ('cob3_catalog.asset_relationships',            'Typed semantic/lineage links; no ACL inheritance along edges.'),
    ('cob3_catalog.tags',                           'Shared or private labels; no authorization effect.'),
    ('cob3_catalog.asset_tags',                     'Tag assignments to registered assets.'),
    ('cob3_catalog.asset_metadata_versions',        'Append-only Catalog metadata history written by trigger on assets.'),
    ('cob3_workspace.projects',                     'Personal/shared project container, one explicit Catalog asset each.'),
    ('cob3_workspace.folders',                      'Folder tree inside a project; no independent ACL in v1.'),
    ('cob3_workspace.artifacts',                    'Workspace content root (one Catalog asset); content lives in revisions.'),
    ('cob3_workspace.file_objects',                 'Private object-storage records for uploads and report outputs.'),
    ('cob3_workspace.artifact_revisions',           'Append-only saved content history; head advanced by commit_artifact_revision.'),
    ('cob3_workspace.artifact_drafts',              'Per-principal autosave state, separate from committed revisions.'),
    ('cob3_workspace.bookmarks',                    'Personal pointers; not an access grant.'),
    ('cob3_workspace.recent_items',                 'Personal recent activity; not a resource master.'),
    ('cob3_workspace.ui_sessions',                  'Short-lived UI state bound to an interactive Identity session; no auth secrets.'),
    ('cob3_workspace.interaction_journeys',         'Optional grouped UI workflow analytics (replaces legacy trajectory).'),
    ('cob3_workspace.interaction_events',           'Append-only UI telemetry; never billing or security audit.'),
    ('cob3_workspace.interaction_daily',            'Rebuildable daily UI usage projection.'),
    ('cob3_workspace.report_schedules',             'Unattended report generation by an explicit execution principal and credential.'),
    ('cob3_workspace.report_recipients',            'Explicit internal recipients (v1); replaces recipient JSON arrays.'),
    ('cob3_workspace.report_runs',                  'Idempotent run with resolved revision, private output and data-access manifest.'),
    ('cob3_workspace.report_deliveries',            'Per-recipient delivery status without regenerating the report.')
  ) AS c(t, txt) LOOP
    EXECUTE pg_catalog.format('COMMENT ON TABLE %s IS %L', _m_rec.t, _m_rec.txt);
END LOOP;

-- ---------------------------------------------------------------------------
-- Installation record (also marks the Catalog integration as installed, so the
-- separately invoked future_integrations template becomes a verified no-op).
-- ---------------------------------------------------------------------------
INSERT INTO cob3_tenant.foundation_installations (component, version, script_checksum, server_version_num, notes)
VALUES (_m_component, _m_version, _m_checksum, _m_server,
        'Migration 002: cob3_settings (11), cob3_catalog (10), cob3_workspace (16), Identity principal_emails + email_verification_challenges; '
        || 'user_profiles email projection/avatar_media_id; access_scopes.include_workspace_artifacts; real Catalog FKs and resolver; role cob3_worker.'),
       ('catalog_integration', _m_version, _m_checksum, _m_server,
        'Installed by migration 002 (settings_catalog_workspace): Catalog FKs validated, explicit/governed resolver with project inheritance.');

PERFORM cob3_identity.clear_request_context();
RESET ROLE;
PERFORM pg_catalog.set_config('search_path', _m_saved_path, true);

RAISE NOTICE 'Migration 002 (% %) applied in database %: cob3_settings, cob3_catalog, cob3_workspace installed; Catalog resolver enabled.',
    _m_component, _m_version, pg_catalog.current_database();
END
