-- =============================================================================
-- 50  CROSS-MODULE FOREIGN KEYS (dependency-safe second phase)
-- -----------------------------------------------------------------------------
-- * Workspace head pointer and Settings project scope (deferrable: inserted in
--   one transaction with their targets).
-- * Identity -> Settings avatar media.
-- * Identity -> Catalog: the FKs that were PENDING in foundation 1.0.0
--   (design 6.2). They are validated immediately; preflight proved no rows.
-- =============================================================================

ALTER TABLE cob3_workspace.artifacts
    ADD CONSTRAINT artifacts_current_revision_fk FOREIGN KEY (tenant_id, organization_id, artifact_id, current_revision_id)
        REFERENCES cob3_workspace.artifact_revisions (tenant_id, organization_id, artifact_id, artifact_revision_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE cob3_settings.setting_scopes
    ADD CONSTRAINT setting_scopes_project_fk FOREIGN KEY (tenant_id, organization_id, project_id)
        REFERENCES cob3_workspace.projects (tenant_id, organization_id, project_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX setting_scopes_project_ix ON cob3_settings.setting_scopes (tenant_id, organization_id, project_id) WHERE project_id IS NOT NULL;
CREATE INDEX setting_scopes_team_ix ON cob3_settings.setting_scopes (tenant_id, organization_id, team_id) WHERE team_id IS NOT NULL;
CREATE INDEX setting_scopes_principal_ix ON cob3_settings.setting_scopes (tenant_id, principal_id) WHERE principal_id IS NOT NULL;
CREATE INDEX setting_scopes_principal_org_ix ON cob3_settings.setting_scopes (tenant_id, organization_id, principal_id) WHERE principal_id IS NOT NULL;

ALTER TABLE cob3_identity.user_profiles
    ADD CONSTRAINT user_profiles_avatar_media_fk FOREIGN KEY (tenant_id, avatar_media_id)
        REFERENCES cob3_settings.media_objects (tenant_id, media_object_id) ON UPDATE RESTRICT ON DELETE RESTRICT;
CREATE INDEX user_profiles_avatar_media_ix ON cob3_identity.user_profiles (tenant_id, avatar_media_id) WHERE avatar_media_id IS NOT NULL;

ALTER TABLE cob3_identity.access_scopes
    ADD CONSTRAINT access_scopes_domain_fk FOREIGN KEY (tenant_id, organization_id, domain_id)
        REFERENCES cob3_catalog.domains (tenant_id, organization_id, domain_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    ADD CONSTRAINT access_scopes_asset_fk FOREIGN KEY (tenant_id, organization_id, asset_id)
        REFERENCES cob3_catalog.assets (tenant_id, organization_id, asset_id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE cob3_identity.team_domains
    ADD CONSTRAINT team_domains_domain_fk FOREIGN KEY (tenant_id, organization_id, domain_id)
        REFERENCES cob3_catalog.domains (tenant_id, organization_id, domain_id) ON UPDATE RESTRICT ON DELETE RESTRICT;
CREATE INDEX team_domains_domain_ix ON cob3_identity.team_domains (tenant_id, organization_id, domain_id);

COMMENT ON COLUMN cob3_identity.access_scopes.domain_id IS 'FK access_scopes_domain_fk -> cob3_catalog.domains(tenant_id, organization_id, domain_id) (migration 002).';
COMMENT ON COLUMN cob3_identity.access_scopes.asset_id IS 'FK access_scopes_asset_fk -> cob3_catalog.assets(tenant_id, organization_id, asset_id) (migration 002).';
COMMENT ON COLUMN cob3_identity.access_scopes.include_workspace_artifacts IS
    'Asset scope on a Workspace project only: also covers artifacts of that project with inherit_project_access = true (design 6.4). Immutable.';
COMMENT ON COLUMN cob3_identity.team_domains.domain_id IS 'FK team_domains_domain_fk -> cob3_catalog.domains(tenant_id, organization_id, domain_id) (migration 002).';
COMMENT ON COLUMN cob3_identity.user_profiles.email IS 'Read projection of the primary active verified cob3_identity.principal_emails row (migration 002). Not writable.';
COMMENT ON COLUMN cob3_identity.user_profiles.avatar_uri IS 'Retired (migration 002): must be NULL. The API generates avatar URLs for avatar_media_id.';
COMMENT ON COLUMN cob3_identity.user_profiles.avatar_media_id IS 'Ready principal-scope cob3_settings.media_objects row owned by this profile principal.';
