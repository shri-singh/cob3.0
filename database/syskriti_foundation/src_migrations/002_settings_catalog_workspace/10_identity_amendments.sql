-- =============================================================================
-- 10  IDENTITY AMENDMENTS (design section 6)
-- -----------------------------------------------------------------------------
-- * principal_emails / email_verification_challenges (new Identity tables)
-- * user_profiles.avatar_media_id (FK to Settings media added in 50_*)
-- * user_profiles.email / email_verified_at become a read projection of the
--   primary active verified principal email (one writable master)
-- * access_scopes.include_workspace_artifacts (explicit project inheritance)
-- * worker context for trusted background workers (cob3_worker)
-- =============================================================================

-- Canonical comparison key: trim, lower-case the domain only. The local part is
-- preserved (no dot/plus/case folding). IDNA conversion of the domain is the
-- backend's responsibility; the key must already be in that canonical form.
CREATE FUNCTION cob3_identity.email_key(p_address text)
    RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT CASE WHEN pg_catalog.btrim(p_address) ~ '^[^@\s]+@[^@\s]+$' THEN
               pg_catalog.left(pg_catalog.btrim(p_address),
                               pg_catalog.length(pg_catalog.btrim(p_address)) - pg_catalog.strpos(pg_catalog.reverse(pg_catalog.btrim(p_address)), '@'))
               || '@' || pg_catalog.lower(pg_catalog.split_part(pg_catalog.btrim(p_address), '@', -1))
           END
$fn$;

CREATE TABLE cob3_identity.principal_emails (
    tenant_id            uuid          NOT NULL,
    principal_email_id   uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id      uuid          NULL,
    principal_id         uuid          NOT NULL,
    email_address        varchar(320)  NOT NULL,
    email_key            varchar(320)  NOT NULL,
    label                varchar(32)   NOT NULL,
    is_primary           boolean       NOT NULL DEFAULT false,
    verified_at          timestamptz   NULL,
    verification_source  varchar(24)   NULL,
    status               varchar(20)   NOT NULL DEFAULT 'active',
    created_at           timestamptz   NOT NULL DEFAULT now(),
    created_by           varchar(255)  NOT NULL,
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    updated_by           varchar(255)  NOT NULL,
    metadata             jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version          bigint        NOT NULL DEFAULT 1,
    CONSTRAINT principal_emails_pk PRIMARY KEY (tenant_id, principal_email_id),
    CONSTRAINT principal_emails_owner_entity_uq UNIQUE (tenant_id, principal_id, principal_email_id),
    CONSTRAINT principal_emails_principal_key_uq UNIQUE (tenant_id, principal_id, email_key),
    CONSTRAINT principal_emails_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT principal_emails_principal_fk FOREIGN KEY (tenant_id, principal_id)
        REFERENCES cob3_identity.principals (tenant_id, principal_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT principal_emails_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT principal_emails_address_format_ck CHECK (email_address ~ '^[^@\s]+@[^@\s]+$' AND email_address = btrim(email_address)),
    CONSTRAINT principal_emails_key_format_ck CHECK (email_key ~ '^[^@\s]+@[^@\s]+$'
        AND split_part(email_key, '@', -1) = lower(split_part(email_key, '@', -1))),
    CONSTRAINT principal_emails_label_ck CHECK (label IN ('work', 'personal', 'alternate')),
    CONSTRAINT principal_emails_status_ck CHECK (status IN ('active', 'revoked')),
    CONSTRAINT principal_emails_verification_source_ck CHECK (verification_source IN ('email_challenge', 'trusted_idp', 'migration_review')),
    CONSTRAINT principal_emails_verification_pair_ck CHECK ((verified_at IS NULL) = (verification_source IS NULL)),
    CONSTRAINT principal_emails_primary_ck CHECK (NOT is_primary OR (verified_at IS NOT NULL AND status = 'active'))
);
CREATE UNIQUE INDEX principal_emails_primary_uix ON cob3_identity.principal_emails (tenant_id, principal_id)
    WHERE is_primary AND status = 'active';
CREATE INDEX principal_emails_key_ix ON cob3_identity.principal_emails (tenant_id, email_key);

CREATE TABLE cob3_identity.email_verification_challenges (
    tenant_id                        uuid          NOT NULL,
    email_verification_challenge_id  uuid          NOT NULL DEFAULT gen_random_uuid(),
    organization_id                  uuid          NULL,
    principal_email_id               uuid          NOT NULL,
    token_digest                     bytea         NOT NULL,
    expires_at                       timestamptz   NOT NULL,
    consumed_at                      timestamptz   NULL,
    revoked_at                       timestamptz   NULL,
    attempt_count                    integer       NOT NULL DEFAULT 0,
    created_at                       timestamptz   NOT NULL DEFAULT now(),
    created_by                       varchar(255)  NOT NULL,
    updated_at                       timestamptz   NOT NULL DEFAULT now(),
    updated_by                       varchar(255)  NOT NULL,
    metadata                         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    row_version                      bigint        NOT NULL DEFAULT 1,
    CONSTRAINT email_verification_challenges_pk PRIMARY KEY (tenant_id, email_verification_challenge_id),
    CONSTRAINT email_verification_challenges_digest_uq UNIQUE (tenant_id, token_digest),
    CONSTRAINT email_verification_challenges_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES cob3_tenant.tenants (tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT email_verification_challenges_email_fk FOREIGN KEY (tenant_id, principal_email_id)
        REFERENCES cob3_identity.principal_emails (tenant_id, principal_email_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT email_verification_challenges_scope_ck CHECK (organization_id IS NULL),
    CONSTRAINT email_verification_challenges_digest_len_ck CHECK (octet_length(token_digest) BETWEEN 32 AND 64),
    CONSTRAINT email_verification_challenges_expiry_ck CHECK (expires_at > created_at),
    CONSTRAINT email_verification_challenges_attempts_ck CHECK (attempt_count >= 0),
    CONSTRAINT email_verification_challenges_terminal_ck CHECK (NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL))
);
CREATE INDEX email_verification_challenges_email_ix ON cob3_identity.email_verification_challenges (tenant_id, principal_email_id);

-- ---------------------------------------------------------------------------
-- user_profiles: avatar reference (FK in 50_*), retired avatar_uri, and the
-- email projection guard.
-- ---------------------------------------------------------------------------
ALTER TABLE cob3_identity.user_profiles
    ADD COLUMN avatar_media_id uuid NULL,
    ADD CONSTRAINT user_profiles_avatar_uri_retired_ck CHECK (avatar_uri IS NULL);

-- Projection of the primary active verified address (NULL when none).
CREATE FUNCTION cob3_identity.primary_email_of(p_tenant_id uuid, p_principal_id uuid,
        OUT email text, OUT email_verified_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT e.email_address::text, e.verified_at
      FROM cob3_identity.principal_emails e
     WHERE e.tenant_id = p_tenant_id AND e.principal_id = p_principal_id
       AND e.is_primary AND e.status = 'active'
$fn$;

CREATE FUNCTION cob3_identity.sync_profile_email(p_tenant_id uuid, p_principal_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM cob3_identity.primary_email_of(p_tenant_id, p_principal_id);
    PERFORM pg_catalog.set_config('cob3.profile_email_sync', 'on', true);
    UPDATE cob3_identity.user_profiles p
       SET email = v.email, email_verified_at = v.email_verified_at
     WHERE p.tenant_id = p_tenant_id AND p.principal_id = p_principal_id
       AND (p.email, p.email_verified_at) IS DISTINCT FROM (v.email, v.email_verified_at);
    PERFORM pg_catalog.set_config('cob3.profile_email_sync', '', true);
END
$fn$;

-- Legacy writes of user_profiles.email (e.g. foundation bootstrap) are recorded
-- as a principal_emails row: unverified unless the writer also supplied
-- email_verified_at (trusted owner path => 'migration_review'). The profile
-- columns then hold only the projection.
CREATE FUNCTION cob3_identity.tg_user_profiles_email_projection()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_key   text;
    v_proj  record;
BEGIN
    IF pg_catalog.current_setting('cob3.profile_email_sync', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.email, NEW.email_verified_at) IS DISTINCT FROM (OLD.email, OLD.email_verified_at) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKIMM',
                MESSAGE = 'user_profiles.email/email_verified_at are a read projection; manage addresses through cob3_identity.principal_emails.';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.email IS NOT NULL THEN
        v_key := cob3_identity.email_key(NEW.email);
        IF v_key IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Invalid email address on profile.';
        END IF;
        INSERT INTO cob3_identity.principal_emails
               (tenant_id, principal_id, email_address, email_key, label, is_primary, verified_at, verification_source,
                created_by, updated_by)
        VALUES (NEW.tenant_id, NEW.principal_id, pg_catalog.btrim(NEW.email), v_key, 'work',
                NEW.email_verified_at IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM cob3_identity.principal_emails x
                                     WHERE x.tenant_id = NEW.tenant_id AND x.principal_id = NEW.principal_id
                                       AND x.is_primary AND x.status = 'active'),
                NEW.email_verified_at,
                CASE WHEN NEW.email_verified_at IS NOT NULL THEN 'migration_review' END,
                NEW.created_by, NEW.updated_by)
        ON CONFLICT ON CONSTRAINT principal_emails_principal_key_uq DO NOTHING;
    END IF;
    SELECT * INTO v_proj FROM cob3_identity.primary_email_of(NEW.tenant_id, NEW.principal_id);
    NEW.email := v_proj.email;
    NEW.email_verified_at := v_proj.email_verified_at;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_06_email_projection BEFORE INSERT OR UPDATE ON cob3_identity.user_profiles
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_user_profiles_email_projection();

-- ---------------------------------------------------------------------------
-- access_scopes: explicit project-to-artifact inheritance (section 6.4)
-- ---------------------------------------------------------------------------
ALTER TABLE cob3_identity.access_scopes
    ADD COLUMN include_workspace_artifacts boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT access_scopes_workspace_inheritance_ck CHECK (NOT include_workspace_artifacts OR scope_type = 'asset');
DROP INDEX cob3_identity.access_scopes_asset_uix;
CREATE UNIQUE INDEX access_scopes_asset_uix
    ON cob3_identity.access_scopes (tenant_id, organization_id, asset_id, include_workspace_artifacts)
    WHERE scope_type = 'asset';
DROP TRIGGER trg_20_immutable ON cob3_identity.access_scopes;
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_identity.access_scopes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns(
        'scope_type', 'domain_id', 'asset_id', 'include_contained_assets', 'include_workspace_artifacts');

-- ---------------------------------------------------------------------------
-- Worker context: a trusted background worker (member of cob3_worker) enters
-- exactly one tenant/organization scope per transaction with a system actor.
-- It carries no principal, session or credential and therefore never passes
-- end-user authorization checks; business authority stays in typed columns
-- (execution principal, grant, credential) that workers re-validate.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.set_worker_context(p_tenant_id uuid, p_organization_id uuid, p_actor text)
    RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'Worker context requires a tenant.';
    END IF;
    IF p_actor IS NULL OR p_actor !~ '^system:[a-z0-9][a-z0-9_.:-]{0,140}$' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'Worker actor must match system:<lowercase-name>.';
    END IF;
    PERFORM pg_catalog.set_config('cob3.tenant_id',       p_tenant_id::text,                     true);
    PERFORM pg_catalog.set_config('cob3.organization_id', COALESCE(p_organization_id::text, ''), true);
    PERFORM pg_catalog.set_config('cob3.principal_id',    '',                                    true);
    PERFORM pg_catalog.set_config('cob3.session_id',      '',                                    true);
    PERFORM pg_catalog.set_config('cob3.credential_id',   '',                                    true);
    PERFORM pg_catalog.set_config('cob3.actor',           p_actor,                               true);
    PERFORM pg_catalog.set_config('cob3.worker', 'on', true);
END
$fn$;

-- True only inside a worker scope established for this transaction.
CREATE FUNCTION cob3_identity.ctx_is_worker()
    RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE(pg_catalog.current_setting('cob3.worker', true) = 'on', false)
       AND cob3_identity.ctx_tenant_id() IS NOT NULL
       AND cob3_identity.ctx_principal_id() IS NULL
$fn$;
