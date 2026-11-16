-- =============================================================================
-- 10  SECURITY CONTEXT ACCESSORS AND GENERIC TRIGGER FUNCTIONS
-- -----------------------------------------------------------------------------
-- Trust boundary (documented honestly): cob3.* settings are ordinary
-- user-settable GUCs. They are trustworthy only because the trusted backend
-- sets them transaction-locally after authentication and end users never get
-- SQL access to the runtime connection. A compromised runtime connection can
-- set any context; RLS then still confines it to the tenant it claims and to
-- the authority that tenant's identity rows grant, but it is not a defence
-- against a malicious backend.
-- =============================================================================

CREATE FUNCTION cob3_identity.ctx_uuid(p_setting text)
    RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT CASE
             WHEN s.v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
             THEN s.v::uuid
           END
      FROM (SELECT pg_catalog.current_setting(p_setting, true) AS v) AS s
$fn$;

CREATE FUNCTION cob3_identity.ctx_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT cob3_identity.ctx_uuid('cob3.tenant_id') $fn$;

CREATE FUNCTION cob3_identity.ctx_organization_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT cob3_identity.ctx_uuid('cob3.organization_id') $fn$;

CREATE FUNCTION cob3_identity.ctx_principal_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT cob3_identity.ctx_uuid('cob3.principal_id') $fn$;

CREATE FUNCTION cob3_identity.ctx_session_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT cob3_identity.ctx_uuid('cob3.session_id') $fn$;

CREATE FUNCTION cob3_identity.ctx_credential_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT cob3_identity.ctx_uuid('cob3.credential_id') $fn$;

-- Stable actor string: principal:<uuid> when a principal context exists,
-- otherwise a validated system:<name> actor, otherwise NULL.
CREATE FUNCTION cob3_identity.ctx_actor() RETURNS text
    LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE(
             'principal:' || cob3_identity.ctx_principal_id()::text,
             CASE WHEN pg_catalog.current_setting('cob3.actor', true) ~ '^system:[a-z0-9][a-z0-9_.:-]{0,200}$'
                  THEN pg_catalog.current_setting('cob3.actor', true) END)
$fn$;

-- Establish request context for the current transaction only. Must be called
-- inside an explicit transaction by trusted backend code after authentication.
CREATE FUNCTION cob3_identity.set_request_context(
        p_tenant_id       uuid,
        p_organization_id uuid,
        p_principal_id    uuid,
        p_session_id      uuid DEFAULT NULL,
        p_credential_id   uuid DEFAULT NULL)
    RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    PERFORM pg_catalog.set_config('cob3.tenant_id',       COALESCE(p_tenant_id::text, ''),       true);
    PERFORM pg_catalog.set_config('cob3.organization_id', COALESCE(p_organization_id::text, ''), true);
    PERFORM pg_catalog.set_config('cob3.principal_id',    COALESCE(p_principal_id::text, ''),    true);
    PERFORM pg_catalog.set_config('cob3.session_id',      COALESCE(p_session_id::text, ''),      true);
    PERFORM pg_catalog.set_config('cob3.credential_id',   COALESCE(p_credential_id::text, ''),   true);
    PERFORM pg_catalog.set_config('cob3.actor',           '',                                    true);
END
$fn$;

-- Platform workers (provisioning, commercial) identify themselves with a
-- stable system actor and carry no principal/tenant context.
CREATE FUNCTION cob3_identity.set_system_context(p_actor text)
    RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF p_actor IS NULL OR p_actor !~ '^system:[a-z0-9][a-z0-9_.:-]{0,200}$' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'System actor must match system:<lowercase-name>.';
    END IF;
    PERFORM cob3_identity.set_request_context(NULL, NULL, NULL, NULL, NULL);
    PERFORM pg_catalog.set_config('cob3.actor', p_actor, true);
END
$fn$;

CREATE FUNCTION cob3_identity.clear_request_context()
    RETURNS void
    LANGUAGE sql VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT cob3_identity.set_request_context(NULL, NULL, NULL, NULL, NULL) $fn$;

-- Advisory lock helper: one 64-bit key per logical serialization domain.
CREATE FUNCTION cob3_identity.xact_lock(p_domain text, p_key text)
    RETURNS void
    LANGUAGE sql VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $fn$ SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cob3:' || p_domain || ':' || p_key, 0)) $fn$;

-- Race-sensitive checks rely on "lock, then read with a fresh snapshot".
-- READ COMMITTED satisfies that; SERIALIZABLE aborts conflicting writers.
-- REPEATABLE READ would read a stale snapshot after waiting, so it is refused.
CREATE FUNCTION cob3_identity.assert_isolation_safe()
    RETURNS void
    LANGUAGE plpgsql STABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF pg_catalog.current_setting('transaction_isolation') = 'repeatable read' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKISO',
            MESSAGE = 'This operation enforces a concurrency-sensitive invariant and must run under READ COMMITTED or SERIALIZABLE isolation.';
    END IF;
END
$fn$;

-- -----------------------------------------------------------------------------
-- Generic row stamping: immutable creation fields, trusted modification fields,
-- monotonically increasing row_version, immutable tenant/organization scope.
-- -----------------------------------------------------------------------------
CREATE FUNCTION cob3_identity.tg_stamp_row()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_actor text := cob3_identity.ctx_actor();
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at  := pg_catalog.now();
        NEW.created_by  := COALESCE(v_actor, NEW.created_by);
        NEW.updated_at  := NEW.created_at;
        NEW.updated_by  := NEW.created_by;
        NEW.row_version := 1;
    ELSE
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
           OR NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKIMM',
                MESSAGE = pg_catalog.format('%I.%I: tenant_id and organization_id are immutable scope identifiers.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
        END IF;
        NEW.created_at  := OLD.created_at;
        NEW.created_by  := OLD.created_by;
        NEW.updated_at  := pg_catalog.now();
        NEW.updated_by  := COALESCE(v_actor, NEW.updated_by);
        NEW.row_version := OLD.row_version + 1;
    END IF;
    RETURN NEW;
END
$fn$;

-- Immutable columns: TG_ARGV lists column names that may never change.
CREATE FUNCTION cob3_identity.tg_immutable_columns()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_old jsonb := pg_catalog.to_jsonb(OLD);
    v_new jsonb := pg_catalog.to_jsonb(NEW);
    v_col text;
BEGIN
    FOREACH v_col IN ARRAY TG_ARGV LOOP
        IF (v_old -> v_col) IS DISTINCT FROM (v_new -> v_col) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKIMM',
                MESSAGE = pg_catalog.format('%I.%I.%I is immutable.', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_col);
        END IF;
    END LOOP;
    RETURN NEW;
END
$fn$;

-- State machine: TG_ARGV[0] is the state column; remaining arguments are
-- allowed transitions 'from>to', and allowed initial states '>to'.
CREATE FUNCTION cob3_identity.tg_state_transition()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_col text := TG_ARGV[0];
    v_new text := pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0];
    v_old text;
    v_key text;
    i     integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_key := '>' || v_new;
    ELSE
        v_old := pg_catalog.to_jsonb(OLD) ->> v_col;
        IF v_old IS NOT DISTINCT FROM v_new THEN
            RETURN NEW;
        END IF;
        v_key := v_old || '>' || v_new;
    END IF;
    FOR i IN 1 .. TG_NARGS - 1 LOOP
        IF TG_ARGV[i] = v_key THEN
            RETURN NEW;
        END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'SKSTA',
        MESSAGE = pg_catalog.format('%I.%I: %s %s is not a permitted state change.', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_col,
                    CASE WHEN TG_OP = 'INSERT' THEN 'initial value ' || pg_catalog.quote_literal(v_new)
                         ELSE pg_catalog.quote_literal(v_old) || ' -> ' || pg_catalog.quote_literal(v_new) END);
END
$fn$;

-- Maintains revoked_at for tables with status/revoked_at pairs. The CHECK
-- ((status = 'revoked') = (revoked_at IS NOT NULL)) remains authoritative.
CREATE FUNCTION cob3_identity.tg_maintain_revoked_at()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'revoked' THEN
        NEW.revoked_at := COALESCE(NEW.revoked_at, pg_catalog.now());
    ELSE
        NEW.revoked_at := NULL;
    END IF;
    RETURN NEW;
END
$fn$;

CREATE FUNCTION cob3_identity.tg_append_only()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    RAISE EXCEPTION USING ERRCODE = 'SKAPP',
        MESSAGE = pg_catalog.format('%I.%I is append-only: %s is not permitted.', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP);
END
$fn$;

CREATE FUNCTION cob3_identity.tg_block_truncate()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    RAISE EXCEPTION USING ERRCODE = 'SKAPP',
        MESSAGE = pg_catalog.format('TRUNCATE of %I.%I is not permitted; retention is a separate controlled process.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
END
$fn$;

-- Freeze a row once it leaves its editable state(s).
--   TG_ARGV[0]  state column ('' = no editable state: always frozen)
--   TG_ARGV[1]  comma-separated editable states ('' = none)
--   TG_ARGV[2..] columns that remain mutable after freezing
-- Stamping columns and metadata are always mutable (stamping is trusted).
CREATE FUNCTION cob3_identity.tg_freeze_columns()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_state_col text   := TG_ARGV[0];
    v_editable  text[] := pg_catalog.string_to_array(TG_ARGV[1], ',');
    v_allowed   text[] := ARRAY['updated_at', 'updated_by', 'row_version', 'metadata'];
    v_old       jsonb  := pg_catalog.to_jsonb(OLD);
    v_new       jsonb  := pg_catalog.to_jsonb(NEW);
    v_changed   text;
    i           integer;
BEGIN
    IF v_state_col <> '' AND (v_old ->> v_state_col) = ANY (v_editable) THEN
        RETURN NEW;
    END IF;
    FOR i IN 2 .. TG_NARGS - 1 LOOP
        v_allowed := v_allowed || TG_ARGV[i];
    END LOOP;
    IF (v_old - v_allowed) IS DISTINCT FROM (v_new - v_allowed) THEN
        SELECT pg_catalog.string_agg(n.key, ', ' ORDER BY n.key)
          INTO v_changed
          FROM pg_catalog.jsonb_each(v_new - v_allowed) AS n
         WHERE n.value IS DISTINCT FROM (v_old -> n.key);
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = pg_catalog.format('%I.%I: row is frozen%s; attempted to change: %s.', TG_TABLE_SCHEMA, TG_TABLE_NAME,
                        CASE WHEN v_state_col <> '' THEN ' in state ' || pg_catalog.quote_literal(v_old ->> v_state_col) ELSE '' END,
                        COALESCE(v_changed, '?'));
    END IF;
    RETURN NEW;
END
$fn$;

-- Columns that may never decrease (TG_ARGV: column names).
CREATE FUNCTION cob3_identity.tg_nondecreasing()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_col text;
BEGIN
    FOREACH v_col IN ARRAY TG_ARGV LOOP
        IF ((pg_catalog.to_jsonb(NEW) ->> v_col)::numeric) < ((pg_catalog.to_jsonb(OLD) ->> v_col)::numeric) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKIMM',
                MESSAGE = pg_catalog.format('%I.%I.%I may not decrease.', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_col);
        END IF;
    END LOOP;
    RETURN NEW;
END
$fn$;

-- Rows that may only be deleted while in a given state (TG_ARGV: column, values...).
CREATE FUNCTION cob3_identity.tg_delete_only_in_state()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_val text := pg_catalog.to_jsonb(OLD) ->> TG_ARGV[0];
    i     integer;
BEGIN
    FOR i IN 1 .. TG_NARGS - 1 LOOP
        IF TG_ARGV[i] = v_val THEN
            RETURN OLD;
        END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'SKIMM',
        MESSAGE = pg_catalog.format('%I.%I rows with %s=%L cannot be deleted.', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_ARGV[0], v_val);
END
$fn$;
