-- =============================================================================
-- 60  TENANT COMMERCIAL LOGIC AND INVARIANT TRIGGERS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Entitlement resolution
--   1. one eligible subscription (trialing/active/past_due); none => disabled
--   2. the contract segment effective at p_at (optionally the latest earlier
--      segment, assuming renewal, for future allocation validation)
--   3. plan entitlement (missing => disabled, never unlimited)
--   4. at most one approved override, which REPLACES the plan entitlement
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.effective_entitlement(
        p_tenant_id       uuid,
        p_feature_id      uuid,
        p_at              timestamptz,
        p_assume_renewal  boolean DEFAULT false,
        OUT is_enabled             boolean,
        OUT is_unlimited           boolean,
        OUT limit_value            numeric,
        OUT reset_period           text,
        OUT source                 text,
        OUT subscription_id        uuid,
        OUT subscription_period_id uuid,
        OUT billing_period_key     text,
        OUT plan_version_id        uuid)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_sub    uuid;
    v_period cob3_tenant.subscription_periods%ROWTYPE;
    v_ent    cob3_tenant.plan_entitlements%ROWTYPE;
    v_ov     cob3_tenant.tenant_entitlement_overrides%ROWTYPE;
BEGIN
    is_enabled := false; is_unlimited := false; limit_value := NULL; reset_period := 'none'; source := 'no_subscription';
    SELECT s.subscription_id INTO v_sub
      FROM cob3_tenant.subscriptions s
     WHERE s.tenant_id = p_tenant_id AND s.status IN ('trialing', 'active', 'past_due');
    IF v_sub IS NULL THEN
        RETURN;
    END IF;
    subscription_id := v_sub;
    source := 'none';
    SELECT sp.* INTO v_period
      FROM cob3_tenant.subscription_periods sp
     WHERE sp.tenant_id = p_tenant_id AND sp.subscription_id = v_sub
       AND sp.period_start <= p_at AND sp.period_end > p_at;
    IF v_period.subscription_period_id IS NULL AND p_assume_renewal THEN
        SELECT sp.* INTO v_period
          FROM cob3_tenant.subscription_periods sp
         WHERE sp.tenant_id = p_tenant_id AND sp.subscription_id = v_sub AND sp.period_start <= p_at
         ORDER BY sp.period_start DESC
         LIMIT 1;
    END IF;
    IF v_period.subscription_period_id IS NOT NULL THEN
        subscription_period_id := v_period.subscription_period_id;
        billing_period_key := v_period.billing_period_key;
        plan_version_id := v_period.plan_version_id;
        SELECT pe.* INTO v_ent
          FROM cob3_tenant.plan_entitlements pe
         WHERE pe.plan_version_id = v_period.plan_version_id AND pe.feature_id = p_feature_id;
        IF v_ent.plan_entitlement_id IS NOT NULL THEN
            is_enabled := v_ent.is_enabled; is_unlimited := v_ent.is_unlimited;
            limit_value := v_ent.limit_value; reset_period := v_ent.reset_period; source := 'plan';
        END IF;
    END IF;
    SELECT o.* INTO v_ov
      FROM cob3_tenant.tenant_entitlement_overrides o
     WHERE o.tenant_id = p_tenant_id AND o.feature_id = p_feature_id AND o.status = 'approved'
       AND o.valid_from <= p_at AND o.valid_until > p_at;
    IF v_ov.tenant_entitlement_override_id IS NOT NULL THEN
        is_enabled := v_ov.is_enabled; is_unlimited := v_ov.is_unlimited;
        limit_value := v_ov.limit_value; reset_period := v_ov.reset_period; source := 'override';
    END IF;
    RETURN;
END
$fn$;

-- Runtime wrapper: tenant comes from the authenticated request context.
CREATE FUNCTION cob3_tenant.resolve_entitlement(p_feature_code text, p_at timestamptz DEFAULT now())
    RETURNS TABLE (feature_code text, value_type text, measurement_kind text, unit_code text,
                   is_enabled boolean, is_unlimited boolean, limit_value numeric, reset_period text, source text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    RETURN QUERY SELECT * FROM cob3_tenant.resolve_tenant_entitlement(cob3_identity.ctx_tenant_id(), p_feature_code, p_at);
END
$fn$;

-- Platform wrapper (commercial/provisioning roles only).
CREATE FUNCTION cob3_tenant.resolve_tenant_entitlement(p_tenant_id uuid, p_feature_code text, p_at timestamptz DEFAULT now())
    RETURNS TABLE (feature_code text, value_type text, measurement_kind text, unit_code text,
                   is_enabled boolean, is_unlimited boolean, limit_value numeric, reset_period text, source text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT f.feature_code::text, f.value_type::text, f.measurement_kind::text, f.unit_code::text,
           e.is_enabled, e.is_unlimited, e.limit_value, e.reset_period, e.source
      FROM cob3_tenant.features f
     CROSS JOIN LATERAL cob3_tenant.effective_entitlement(p_tenant_id, f.feature_id, p_at, false) AS e
     WHERE f.feature_code = p_feature_code
$fn$;

-- Capability check. Onboarding (tenant still 'provisioning') is exempt; a
-- retired feature is no longer commercially governed.
CREATE FUNCTION cob3_tenant.assert_feature_enabled(p_tenant_id uuid, p_feature_code text)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_status  text;
    v_feature cob3_tenant.features%ROWTYPE;
    v_e       record;
BEGIN
    SELECT t.status INTO v_status FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id;
    IF v_status = 'provisioning' THEN
        RETURN;
    END IF;
    SELECT f.* INTO v_feature FROM cob3_tenant.features f WHERE f.feature_code = p_feature_code;
    IF v_feature.feature_id IS NULL OR v_feature.status <> 'active' THEN
        RETURN;
    END IF;
    SELECT * INTO v_e FROM cob3_tenant.effective_entitlement(p_tenant_id, v_feature.feature_id, pg_catalog.now(), false);
    IF NOT v_e.is_enabled THEN
        RAISE EXCEPTION USING ERRCODE = 'SKENT',
            MESSAGE = pg_catalog.format('Tenant is not entitled to feature %s (%s).', p_feature_code, v_e.source);
    END IF;
END
$fn$;

-- Gauge quota check. Callers take cob3_identity.xact_lock('quota', ...) and
-- count AFTER the lock (fresh snapshot), then call this before commit.
CREATE FUNCTION cob3_tenant.assert_gauge_capacity(
        p_tenant_id uuid, p_organization_id uuid, p_feature_code text, p_tenant_usage numeric, p_org_usage numeric)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_status  text;
    v_feature cob3_tenant.features%ROWTYPE;
    v_e       record;
    v_alloc   numeric;
BEGIN
    SELECT t.status INTO v_status FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id;
    IF v_status = 'provisioning' THEN
        RETURN;
    END IF;
    SELECT f.* INTO v_feature FROM cob3_tenant.features f WHERE f.feature_code = p_feature_code;
    IF v_feature.feature_id IS NULL OR v_feature.status <> 'active' THEN
        RETURN;
    END IF;
    SELECT * INTO v_e FROM cob3_tenant.effective_entitlement(p_tenant_id, v_feature.feature_id, pg_catalog.now(), false);
    IF NOT v_e.is_enabled THEN
        RAISE EXCEPTION USING ERRCODE = 'SKQTA',
            MESSAGE = pg_catalog.format('Quota %s is not entitled for this tenant (%s).', p_feature_code, v_e.source);
    END IF;
    IF NOT v_e.is_unlimited AND p_tenant_usage > v_e.limit_value THEN
        RAISE EXCEPTION USING ERRCODE = 'SKQTA',
            MESSAGE = pg_catalog.format('Quota %s exceeded: %s in use, tenant limit %s.', p_feature_code, p_tenant_usage, v_e.limit_value);
    END IF;
    IF p_organization_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM cob3_tenant.organization_quota_allocations a
            WHERE a.tenant_id = p_tenant_id AND a.feature_id = v_feature.feature_id AND a.status = 'active'
              AND a.valid_from <= pg_catalog.now() AND a.valid_until > pg_catalog.now()) THEN
        SELECT a.allocated_limit INTO v_alloc
          FROM cob3_tenant.organization_quota_allocations a
         WHERE a.tenant_id = p_tenant_id AND a.organization_id = p_organization_id
           AND a.feature_id = v_feature.feature_id AND a.status = 'active'
           AND a.valid_from <= pg_catalog.now() AND a.valid_until > pg_catalog.now();
        IF v_alloc IS NULL OR p_org_usage > v_alloc THEN
            RAISE EXCEPTION USING ERRCODE = 'SKQTA',
                MESSAGE = pg_catalog.format('Quota %s exceeded for organization %s: %s in use, allocation %s.',
                            p_feature_code, p_organization_id, p_org_usage, COALESCE(v_alloc::text, 'none (partitioned capacity)'));
        END IF;
    END IF;
END
$fn$;

-- Sum of simultaneous active allocations must not exceed the effective
-- tenant entitlement at any change boundary within the window. Serialized per
-- tenant/feature with an advisory lock; reads happen after the lock.
CREATE FUNCTION cob3_tenant.validate_allocations(p_tenant_id uuid, p_feature_id uuid, p_from timestamptz, p_until timestamptz)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_feature uuid;
    v_t       timestamptz;
    v_total   numeric;
    v_e       record;
BEGIN
    PERFORM cob3_identity.assert_isolation_safe();
    FOR v_feature IN
        SELECT DISTINCT a.feature_id
          FROM cob3_tenant.organization_quota_allocations a
         WHERE a.tenant_id = p_tenant_id
           AND (p_feature_id IS NULL OR a.feature_id = p_feature_id)
           AND a.status = 'active' AND a.valid_from < p_until AND a.valid_until > p_from
         ORDER BY a.feature_id
    LOOP
        PERFORM cob3_identity.xact_lock('allocation', p_tenant_id::text || ':' || v_feature::text);
        FOR v_t IN
            SELECT DISTINCT b.t FROM (
                SELECT p_from AS t
                UNION ALL
                SELECT a.valid_from FROM cob3_tenant.organization_quota_allocations a
                 WHERE a.tenant_id = p_tenant_id AND a.feature_id = v_feature AND a.status = 'active'
                   AND a.valid_from > p_from AND a.valid_from < p_until
                UNION ALL
                SELECT sp.period_start FROM cob3_tenant.subscription_periods sp
                 WHERE sp.tenant_id = p_tenant_id AND sp.period_start > p_from AND sp.period_start < p_until
                UNION ALL
                SELECT o.valid_from FROM cob3_tenant.tenant_entitlement_overrides o
                 WHERE o.tenant_id = p_tenant_id AND o.feature_id = v_feature AND o.valid_from > p_from AND o.valid_from < p_until
                UNION ALL
                SELECT o.valid_until FROM cob3_tenant.tenant_entitlement_overrides o
                 WHERE o.tenant_id = p_tenant_id AND o.feature_id = v_feature AND o.valid_until > p_from AND o.valid_until < p_until
            ) AS b
            ORDER BY 1
        LOOP
            SELECT COALESCE(sum(a.allocated_limit), 0) INTO v_total
              FROM cob3_tenant.organization_quota_allocations a
             WHERE a.tenant_id = p_tenant_id AND a.feature_id = v_feature AND a.status = 'active'
               AND a.valid_from <= v_t AND a.valid_until > v_t;
            IF v_total = 0 THEN
                CONTINUE;
            END IF;
            SELECT * INTO v_e FROM cob3_tenant.effective_entitlement(p_tenant_id, v_feature, v_t, true);
            IF v_e.is_enabled AND v_e.is_unlimited THEN
                CONTINUE;
            END IF;
            IF NOT v_e.is_enabled OR v_e.limit_value IS NULL OR v_total > v_e.limit_value THEN
                RAISE EXCEPTION USING ERRCODE = 'SKQTA',
                    MESSAGE = pg_catalog.format('Organization allocations for feature %s total %s at %s, exceeding the tenant entitlement (%s).',
                                v_feature, v_total, v_t,
                                CASE WHEN v_e.is_enabled THEN v_e.limit_value::text ELSE 'not entitled: ' || v_e.source END),
                    HINT = 'Reallocate before changing contract terms or adding allocations.';
            END IF;
        END LOOP;
    END LOOP;
END
$fn$;

-- Counter window key for usage counters.
CREATE FUNCTION cob3_tenant.counter_window_key(p_reset_period text, p_occurred_at timestamptz, p_billing_period_key text)
    RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT CASE
             WHEN p_reset_period = 'subscription_period' AND p_billing_period_key IS NOT NULL THEN 'sp:' || p_billing_period_key
             ELSE 'cm:' || pg_catalog.to_char(p_occurred_at AT TIME ZONE 'UTC', 'YYYY-MM')
           END
$fn$;

-- ---------------------------------------------------------------------------
-- Usage recording with idempotency, correction limits and hard counters.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.record_usage_internal(
        p_tenant_id              uuid,
        p_organization_id        uuid,
        p_feature_code           text,
        p_source_code            text,
        p_source_event_id        text,
        p_occurred_at            timestamptz,
        p_quantity               numeric,
        p_request_id             uuid,
        p_correction_of_event_id uuid,
        p_enforce_limit          boolean,
        OUT usage_event_id uuid,
        OUT duplicate      boolean)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_feature  cob3_tenant.features%ROWTYPE;
    v_original cob3_tenant.usage_events%ROWTYPE;
    v_existing cob3_tenant.usage_events%ROWTYPE;
    v_e        record;
    v_at       timestamptz := p_occurred_at;
    v_org      uuid := p_organization_id;
    v_window   text;
    v_tenant_used numeric;
    v_org_used    numeric;
    v_alloc       numeric;
    v_has_allocs  boolean;
    v_new_id      uuid;
BEGIN
    duplicate := false;
    PERFORM cob3_identity.assert_isolation_safe();
    SELECT f.* INTO v_feature FROM cob3_tenant.features f WHERE f.feature_code = p_feature_code;
    IF v_feature.feature_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKENT', MESSAGE = pg_catalog.format('Unknown feature %s.', p_feature_code);
    END IF;
    IF v_feature.measurement_kind <> 'counter' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Feature %s is a %s; usage events measure counter features only.', p_feature_code, v_feature.measurement_kind);
    END IF;
    IF p_correction_of_event_id IS NOT NULL THEN
        -- Corrections are attributed to the original event's window and organization.
        SELECT e.* INTO v_original FROM cob3_tenant.usage_events e
         WHERE e.tenant_id = p_tenant_id AND e.usage_event_id = p_correction_of_event_id;
        IF v_original.usage_event_id IS NOT NULL THEN
            v_at := v_original.occurred_at;
        END IF;
    END IF;

    SELECT * INTO v_e FROM cob3_tenant.effective_entitlement(p_tenant_id, v_feature.feature_id, v_at, false);
    v_window := cob3_tenant.counter_window_key(v_e.reset_period, v_at, v_e.billing_period_key);

    -- Lock the tenant-total and organization counter rows (serializes consumers).
    INSERT INTO cob3_tenant.quota_counters AS q (tenant_id, organization_id, scope_kind, feature_id, window_key, consumed_quantity)
    VALUES (p_tenant_id, NULL, 'tenant_total', v_feature.feature_id, v_window, 0)
    ON CONFLICT ON CONSTRAINT quota_counters_bucket_uq DO NOTHING;
    SELECT q.consumed_quantity INTO v_tenant_used FROM cob3_tenant.quota_counters q
     WHERE q.tenant_id = p_tenant_id AND q.feature_id = v_feature.feature_id AND q.window_key = v_window
       AND q.scope_kind = 'tenant_total' AND q.organization_id IS NULL
       FOR UPDATE;
    IF v_org IS NOT NULL THEN
        INSERT INTO cob3_tenant.quota_counters AS q (tenant_id, organization_id, scope_kind, feature_id, window_key, consumed_quantity)
        VALUES (p_tenant_id, v_org, 'organization', v_feature.feature_id, v_window, 0)
        ON CONFLICT ON CONSTRAINT quota_counters_bucket_uq DO NOTHING;
        SELECT q.consumed_quantity INTO v_org_used FROM cob3_tenant.quota_counters q
         WHERE q.tenant_id = p_tenant_id AND q.feature_id = v_feature.feature_id AND q.window_key = v_window
           AND q.scope_kind = 'organization' AND q.organization_id = v_org
           FOR UPDATE;
    END IF;

    -- Idempotent insert; validation trigger enforces correction rules.
    INSERT INTO cob3_tenant.usage_events AS u
           (tenant_id, organization_id, feature_id, source_code, source_event_id, occurred_at,
            quantity, correction_of_event_id, request_id, created_by, updated_by)
    VALUES (p_tenant_id, v_org, v_feature.feature_id, p_source_code, p_source_event_id, p_occurred_at,
            p_quantity, p_correction_of_event_id, p_request_id,
            COALESCE(cob3_identity.ctx_actor(), 'system:usage'), COALESCE(cob3_identity.ctx_actor(), 'system:usage'))
    ON CONFLICT ON CONSTRAINT usage_events_idempotency_uq DO NOTHING
    RETURNING u.usage_event_id INTO v_new_id;

    IF v_new_id IS NULL THEN
        SELECT e.* INTO v_existing FROM cob3_tenant.usage_events e
         WHERE e.tenant_id = p_tenant_id AND e.source_code = p_source_code AND e.source_event_id = p_source_event_id;
        IF v_existing.feature_id = v_feature.feature_id
           AND v_existing.organization_id IS NOT DISTINCT FROM v_org
           AND v_existing.occurred_at = p_occurred_at
           AND v_existing.quantity = p_quantity
           AND v_existing.correction_of_event_id IS NOT DISTINCT FROM p_correction_of_event_id THEN
            usage_event_id := v_existing.usage_event_id;
            duplicate := true;
            RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'SKIDM',
            MESSAGE = pg_catalog.format('Usage idempotency key (%s, %s) was already used with a different payload.', p_source_code, p_source_event_id);
    END IF;

    IF p_enforce_limit AND p_quantity > 0 THEN
        IF NOT v_e.is_enabled THEN
            RAISE EXCEPTION USING ERRCODE = 'SKQTA',
                MESSAGE = pg_catalog.format('Feature %s is not entitled for this tenant (%s).', p_feature_code, v_e.source);
        END IF;
        IF NOT v_e.is_unlimited AND v_tenant_used + p_quantity > v_e.limit_value THEN
            RAISE EXCEPTION USING ERRCODE = 'SKQTA',
                MESSAGE = pg_catalog.format('Quota %s exceeded for window %s: %s used + %s requested > limit %s.',
                            p_feature_code, v_window, v_tenant_used, p_quantity, v_e.limit_value);
        END IF;
        SELECT EXISTS (SELECT 1 FROM cob3_tenant.organization_quota_allocations a
                        WHERE a.tenant_id = p_tenant_id AND a.feature_id = v_feature.feature_id AND a.status = 'active'
                          AND a.valid_from <= v_at AND a.valid_until > v_at)
          INTO v_has_allocs;
        IF v_has_allocs AND v_org IS NOT NULL THEN
            SELECT a.allocated_limit INTO v_alloc FROM cob3_tenant.organization_quota_allocations a
             WHERE a.tenant_id = p_tenant_id AND a.organization_id = v_org AND a.feature_id = v_feature.feature_id
               AND a.status = 'active' AND a.valid_from <= v_at AND a.valid_until > v_at;
            IF v_alloc IS NULL OR COALESCE(v_org_used, 0) + p_quantity > v_alloc THEN
                RAISE EXCEPTION USING ERRCODE = 'SKQTA',
                    MESSAGE = pg_catalog.format('Organization quota %s exceeded for window %s (allocation %s).',
                                p_feature_code, v_window, COALESCE(v_alloc::text, 'none'));
            END IF;
        END IF;
    END IF;

    UPDATE cob3_tenant.quota_counters q
       SET consumed_quantity = q.consumed_quantity + p_quantity, updated_at = pg_catalog.now()
     WHERE q.tenant_id = p_tenant_id AND q.feature_id = v_feature.feature_id AND q.window_key = v_window
       AND ((q.scope_kind = 'tenant_total' AND q.organization_id IS NULL)
            OR (v_org IS NOT NULL AND q.scope_kind = 'organization' AND q.organization_id = v_org));
    usage_event_id := v_new_id;
    RETURN;
END
$fn$;

-- Runtime entry point: tenant from authenticated context; organization
-- attribution must be the context organization (or none).
CREATE FUNCTION cob3_tenant.record_usage_event(
        p_feature_code text, p_source_code text, p_source_event_id text, p_occurred_at timestamptz,
        p_quantity numeric, p_organization_id uuid DEFAULT NULL, p_request_id uuid DEFAULT NULL,
        p_correction_of_event_id uuid DEFAULT NULL, p_enforce_limit boolean DEFAULT true,
        OUT usage_event_id uuid, OUT duplicate boolean)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NOT cob3_identity.ctx_auth_valid() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'No valid authenticated request context.';
    END IF;
    IF p_organization_id IS NOT NULL AND p_organization_id IS DISTINCT FROM cob3_identity.ctx_organization_id() THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ', MESSAGE = 'Usage may only be attributed to the request organization.';
    END IF;
    SELECT r.usage_event_id, r.duplicate INTO usage_event_id, duplicate
      FROM cob3_tenant.record_usage_internal(cob3_identity.ctx_tenant_id(), p_organization_id, p_feature_code, p_source_code,
                                             p_source_event_id, p_occurred_at, p_quantity, p_request_id,
                                             p_correction_of_event_id, p_enforce_limit) AS r;
END
$fn$;

-- Platform metering pipeline entry point (commercial role).
CREATE FUNCTION cob3_tenant.record_platform_usage_event(
        p_tenant_id uuid, p_feature_code text, p_source_code text, p_source_event_id text, p_occurred_at timestamptz,
        p_quantity numeric, p_organization_id uuid DEFAULT NULL, p_request_id uuid DEFAULT NULL,
        p_correction_of_event_id uuid DEFAULT NULL, p_enforce_limit boolean DEFAULT false,
        OUT usage_event_id uuid, OUT duplicate boolean)
    LANGUAGE sql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT r.usage_event_id, r.duplicate
      FROM cob3_tenant.record_usage_internal(p_tenant_id, p_organization_id, p_feature_code, p_source_code,
                                             p_source_event_id, p_occurred_at, p_quantity, p_request_id,
                                             p_correction_of_event_id, p_enforce_limit) AS r
$fn$;

-- ---------------------------------------------------------------------------
-- Tenant lifecycle routines (provisioning role)
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.use_system_actor(p_actor text)
    RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF p_actor IS NULL OR p_actor !~ '^system:[a-z0-9][a-z0-9_.:-]{0,200}$' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKCTX', MESSAGE = 'Actor must match system:<lowercase-name>.';
    END IF;
    PERFORM pg_catalog.set_config('cob3.principal_id', '', true);
    PERFORM pg_catalog.set_config('cob3.actor', p_actor, true);
END
$fn$;

CREATE FUNCTION cob3_tenant.create_tenant(
        p_tenant_code text, p_name text, p_legal_name text, p_home_region text,
        p_request_id uuid, p_reason text, p_actor text DEFAULT 'system:provisioning')
    RETURNS uuid
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    INSERT INTO cob3_tenant.tenants (tenant_code, name, legal_name, status, home_region, created_by, updated_by)
    VALUES (p_tenant_code, p_name, p_legal_name, 'provisioning', p_home_region, p_actor, p_actor)
    RETURNING tenant_id INTO v_tenant;
    INSERT INTO cob3_tenant.tenant_lifecycle_events
           (tenant_id, from_status, to_status, occurred_at, reason, request_id, created_by, updated_by)
    VALUES (v_tenant, NULL, 'provisioning', pg_catalog.now(), p_reason, p_request_id, p_actor, p_actor);
    RETURN v_tenant;
END
$fn$;

CREATE FUNCTION cob3_tenant.transition_tenant_status(
        p_tenant_id uuid, p_to_status text, p_reason text, p_request_id uuid,
        p_actor text DEFAULT 'system:provisioning', p_suspension_reason text DEFAULT NULL,
        p_actor_principal_id uuid DEFAULT NULL)
    RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_from     text;
    v_existing cob3_tenant.tenant_lifecycle_events%ROWTYPE;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    SELECT e.* INTO v_existing FROM cob3_tenant.tenant_lifecycle_events e
     WHERE e.tenant_id = p_tenant_id AND e.request_id = p_request_id;
    IF v_existing.tenant_lifecycle_event_id IS NOT NULL THEN
        IF v_existing.to_status = p_to_status THEN
            RETURN 'duplicate_request';
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'SKIDM', MESSAGE = 'Lifecycle request_id was already used for a different transition.';
    END IF;
    SELECT t.status INTO v_from FROM cob3_tenant.tenants t WHERE t.tenant_id = p_tenant_id FOR UPDATE;
    IF v_from IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Unknown tenant.';
    END IF;
    UPDATE cob3_tenant.tenants t
       SET status = p_to_status,
           suspension_reason = CASE WHEN p_to_status = 'suspended' THEN p_suspension_reason ELSE NULL END,
           updated_by = p_actor
     WHERE t.tenant_id = p_tenant_id;
    INSERT INTO cob3_tenant.tenant_lifecycle_events
           (tenant_id, from_status, to_status, occurred_at, reason, request_id, actor_principal_id, created_by, updated_by)
    VALUES (p_tenant_id, v_from, p_to_status, pg_catalog.now(), p_reason, p_request_id, p_actor_principal_id, p_actor, p_actor);
    RETURN 'transitioned';
END
$fn$;

-- Provisioning job queue (competing workers; SKIP LOCKED + lease).
CREATE FUNCTION cob3_tenant.claim_provisioning_job(p_job_types text[], p_lease interval DEFAULT interval '5 minutes',
                                                   p_actor text DEFAULT 'system:provisioning-worker')
    RETURNS SETOF cob3_tenant.provisioning_jobs
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    RETURN QUERY
    UPDATE cob3_tenant.provisioning_jobs j
       SET status = 'running', started_at = pg_catalog.now(), lease_expires_at = pg_catalog.now() + p_lease,
           attempt_count = j.attempt_count + 1, completed_at = NULL, updated_by = p_actor
     WHERE j.provisioning_job_id = (
           SELECT c.provisioning_job_id
             FROM cob3_tenant.provisioning_jobs c
            WHERE c.job_type = ANY (p_job_types)
              AND c.status = 'pending'
              AND (c.next_attempt_at IS NULL OR c.next_attempt_at <= pg_catalog.now())
            ORDER BY c.next_attempt_at NULLS FIRST, c.created_at
            LIMIT 1
              FOR UPDATE SKIP LOCKED)
    RETURNING j.*;
END
$fn$;

-- Idempotent provider event intake; duplicates are no-ops only when the
-- payload digest matches. Tenant must already have been resolved from a
-- trusted provider-customer mapping by the caller (never from webhook data).
CREATE FUNCTION cob3_tenant.record_provider_event(
        p_tenant_id uuid, p_provider_code text, p_provider_account_reference text, p_external_event_id text,
        p_event_type text, p_occurred_at timestamptz, p_payload_digest bytea,
        p_actor text DEFAULT 'system:billing-ingress',
        OUT provider_event_id uuid, OUT duplicate boolean)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_existing cob3_tenant.provider_events%ROWTYPE;
    v_id       uuid;
BEGIN
    PERFORM cob3_tenant.use_system_actor(p_actor);
    duplicate := false;
    IF NOT EXISTS (SELECT 1 FROM cob3_tenant.billing_accounts b
                    WHERE b.tenant_id = p_tenant_id AND b.provider_code = p_provider_code
                      AND b.provider_account_reference = p_provider_account_reference) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKAUZ',
            MESSAGE = 'Provider account is not mapped to this tenant through a billing account; route to the restricted platform ingress queue.';
    END IF;
    INSERT INTO cob3_tenant.provider_events AS e
           (tenant_id, provider_code, provider_account_reference, external_event_id, event_type, occurred_at,
            payload_digest, created_by, updated_by)
    VALUES (p_tenant_id, p_provider_code, p_provider_account_reference, p_external_event_id, p_event_type, p_occurred_at,
            p_payload_digest, p_actor, p_actor)
    ON CONFLICT ON CONSTRAINT provider_events_external_uq DO NOTHING
    RETURNING e.provider_event_id INTO v_id;
    IF v_id IS NOT NULL THEN
        provider_event_id := v_id;
        RETURN;
    END IF;
    SELECT e.* INTO v_existing FROM cob3_tenant.provider_events e
     WHERE e.provider_code = p_provider_code AND e.provider_account_reference = p_provider_account_reference
       AND e.external_event_id = p_external_event_id;
    IF v_existing.tenant_id = p_tenant_id AND v_existing.payload_digest = p_payload_digest
       AND v_existing.event_type = p_event_type THEN
        provider_event_id := v_existing.provider_event_id;
        duplicate := true;
        RETURN;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'SKIDM',
        MESSAGE = 'Provider event id was already recorded with different content; route to reconciliation.';
END
$fn$;

-- ===========================================================================
-- Tenant-table triggers
-- ===========================================================================

-- tenants -------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_tenants_lifecycle()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            IF NEW.status = 'active' THEN
                NEW.activated_at := COALESCE(OLD.activated_at, pg_catalog.now());
            END IF;
            IF NEW.status = 'suspended' THEN
                NEW.suspended_at := pg_catalog.now();
            ELSE
                NEW.suspended_at := NULL;
                NEW.suspension_reason := NULL;
            END IF;
            IF NEW.status = 'closed' THEN
                NEW.closed_at := pg_catalog.now();
            END IF;
        END IF;
        IF OLD.activated_at IS NOT NULL AND NEW.activated_at IS DISTINCT FROM OLD.activated_at THEN
            RAISE EXCEPTION USING ERRCODE = 'SKIMM', MESSAGE = 'tenants.activated_at records first activation and is immutable.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.tenants
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>provisioning', 'provisioning>active', 'provisioning>closed', 'active>suspended', 'active>closing',
        'suspended>active', 'suspended>closing', 'closing>closed', 'closing>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.tenants
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('tenant_code', 'home_region');
CREATE TRIGGER trg_30_lifecycle BEFORE INSERT OR UPDATE ON cob3_tenant.tenants
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_tenants_lifecycle();

CREATE FUNCTION cob3_tenant.tg_tenants_lifecycle_recorded()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cob3_tenant.tenant_lifecycle_events e
                    WHERE e.tenant_id = NEW.tenant_id AND e.to_status = NEW.status
                      AND e.created_at = pg_catalog.now()) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = pg_catalog.format('Tenant status change to %s must be recorded in tenant_lifecycle_events in the same transaction.', NEW.status);
    END IF;
    RETURN NULL;
END
$fn$;
CREATE CONSTRAINT TRIGGER trg_80_lifecycle_recorded AFTER INSERT OR UPDATE OF status ON cob3_tenant.tenants
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_tenants_lifecycle_recorded();

-- tenant_lifecycle_events -----------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_lifecycle_events_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.from_status IS NULL AND EXISTS (SELECT 1 FROM cob3_tenant.tenant_lifecycle_events e WHERE e.tenant_id = NEW.tenant_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'from_status may be NULL only for the tenant creation event.';
    END IF;
    IF NEW.from_status IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cob3_tenant.tenant_lifecycle_events e WHERE e.tenant_id = NEW.tenant_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'The first lifecycle event must be the creation event (from_status NULL).';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_validate BEFORE INSERT ON cob3_tenant.tenant_lifecycle_events
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_lifecycle_events_validate();

-- provisioning_jobs ------------------------------------------------------------
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.provisioning_jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>pending', 'pending>running', 'pending>failed', 'running>succeeded', 'running>failed', 'running>pending', 'failed>pending');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.provisioning_jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('job_type', 'idempotency_key');
CREATE TRIGGER trg_21_nondecreasing BEFORE UPDATE ON cob3_tenant.provisioning_jobs
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('attempt_count');

-- plans -------------------------------------------------------------------------
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.plans
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>draft', 'draft>active', 'draft>retired', 'active>retired');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.plans
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('plan_code');

-- plan_versions -----------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_plan_versions_publish()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'published' AND OLD.status = 'draft' THEN
        NEW.published_at := COALESCE(NEW.published_at, pg_catalog.now());
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.plan_versions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>draft', 'draft>published', 'published>retired');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.plan_versions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('plan_id', 'version_number');
CREATE TRIGGER trg_30_publish BEFORE UPDATE ON cob3_tenant.plan_versions
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_plan_versions_publish();
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.plan_versions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status', 'published_at');

-- features ----------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_features_definition_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF (NEW.value_type, NEW.unit_code, NEW.measurement_kind) IS DISTINCT FROM (OLD.value_type, OLD.unit_code, OLD.measurement_kind)
       AND (EXISTS (SELECT 1 FROM cob3_tenant.plan_entitlements x WHERE x.feature_id = OLD.feature_id)
            OR EXISTS (SELECT 1 FROM cob3_tenant.tenant_entitlement_overrides x WHERE x.feature_id = OLD.feature_id)
            OR EXISTS (SELECT 1 FROM cob3_tenant.organization_quota_allocations x WHERE x.feature_id = OLD.feature_id)
            OR EXISTS (SELECT 1 FROM cob3_tenant.usage_events x WHERE x.feature_id = OLD.feature_id)
            OR EXISTS (SELECT 1 FROM cob3_tenant.usage_rollups x WHERE x.feature_id = OLD.feature_id)
            OR EXISTS (SELECT 1 FROM cob3_tenant.invoice_lines x WHERE x.feature_id = OLD.feature_id)) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = 'Feature value_type, unit_code and measurement_kind are immutable once the feature is used.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.features
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>retired', 'retired>active');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.features
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('feature_code');
CREATE TRIGGER trg_30_definition_guard BEFORE UPDATE ON cob3_tenant.features
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_features_definition_guard();

-- Shared shape rule for plan entitlements and overrides (vs the feature type).
CREATE FUNCTION cob3_tenant.assert_entitlement_shape(
        p_feature_id uuid, p_is_enabled boolean, p_limit numeric, p_unlimited boolean, p_reset text)
    RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_f cob3_tenant.features%ROWTYPE;
BEGIN
    SELECT f.* INTO v_f FROM cob3_tenant.features f WHERE f.feature_id = p_feature_id;
    IF v_f.value_type = 'boolean' THEN
        IF p_limit IS NOT NULL OR p_unlimited OR p_reset <> 'none' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Boolean feature %s takes no limit, no unlimited flag and reset_period none.', v_f.feature_code);
        END IF;
    ELSE
        IF p_is_enabled AND NOT p_unlimited AND p_limit IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Enabled finite quota %s requires a nonnegative limit_value.', v_f.feature_code);
        END IF;
        IF v_f.measurement_kind = 'gauge' AND p_reset <> 'none' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Gauge quota %s must use reset_period none.', v_f.feature_code);
        END IF;
        IF v_f.measurement_kind = 'counter' AND p_is_enabled AND p_reset = 'none' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Counter quota %s requires reset_period calendar_month or subscription_period.', v_f.feature_code);
        END IF;
    END IF;
END
$fn$;

-- plan_entitlements -------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_plan_entitlements_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_version uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.plan_version_id ELSE NEW.plan_version_id END;
    v_status  text;
BEGIN
    SELECT v.status INTO v_status FROM cob3_tenant.plan_versions v WHERE v.plan_version_id = v_version FOR SHARE;
    IF v_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = 'Plan entitlements may change only while the plan version is draft (publication freezes them).';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    PERFORM cob3_tenant.assert_entitlement_shape(NEW.feature_id, NEW.is_enabled, NEW.limit_value, NEW.is_unlimited, NEW.reset_period);
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_guard BEFORE INSERT OR UPDATE OR DELETE ON cob3_tenant.plan_entitlements
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_plan_entitlements_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.plan_entitlements
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('plan_version_id', 'feature_id');

-- plan_prices -------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_plan_prices_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_status text;
BEGIN
    SELECT v.status INTO v_status FROM cob3_tenant.plan_versions v WHERE v.plan_version_id = NEW.plan_version_id FOR SHARE;
    IF TG_OP = 'INSERT' AND v_status = 'retired' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Prices cannot be added to a retired plan version.';
    END IF;
    IF NEW.status = 'published' AND (TG_OP = 'INSERT' OR OLD.status <> 'published') AND v_status <> 'published' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'A price can be published only on a published plan version.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.plan_prices
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>draft', 'draft>published', 'draft>retired', 'published>retired');
CREATE TRIGGER trg_15_guard BEFORE INSERT OR UPDATE ON cob3_tenant.plan_prices
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_plan_prices_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.plan_prices
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('plan_version_id', 'price_code');
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.plan_prices
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status', 'provider_price_reference');
CREATE TRIGGER trg_50_delete_draft_only BEFORE DELETE ON cob3_tenant.plan_prices
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_delete_only_in_state('status', 'draft');

-- billing_accounts / subscription provider references ------------------------------
CREATE FUNCTION cob3_tenant.assert_provider_subscription_reference_unique(
        p_billing_account_id uuid, p_reference text, p_subscription_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_b cob3_tenant.billing_accounts%ROWTYPE;
BEGIN
    IF p_reference IS NULL THEN
        RETURN;
    END IF;
    SELECT b.* INTO v_b FROM cob3_tenant.billing_accounts b WHERE b.billing_account_id = p_billing_account_id;
    IF v_b.provider_code IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV',
            MESSAGE = 'A provider subscription reference requires a billing account with provider account context.';
    END IF;
    PERFORM cob3_identity.xact_lock('provider_subscription', v_b.provider_code || ':' || v_b.provider_account_reference || ':' || p_reference);
    IF EXISTS (SELECT 1
                 FROM cob3_tenant.subscriptions s
                 JOIN cob3_tenant.billing_accounts b ON b.billing_account_id = s.billing_account_id
                WHERE s.provider_subscription_reference = p_reference
                  AND b.provider_code = v_b.provider_code
                  AND b.provider_account_reference = v_b.provider_account_reference
                  AND s.subscription_id <> p_subscription_id) THEN
        RAISE EXCEPTION USING ERRCODE = '23505',
            MESSAGE = 'provider_subscription_reference must be unique within its provider account.';
    END IF;
END
$fn$;

CREATE FUNCTION cob3_tenant.tg_billing_accounts_provider_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_s record;
BEGIN
    IF OLD.provider_code IS NOT NULL
       AND (NEW.provider_code, NEW.provider_account_reference, NEW.provider_customer_reference)
           IS DISTINCT FROM (OLD.provider_code, OLD.provider_account_reference, OLD.provider_customer_reference) THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM',
            MESSAGE = 'Billing account provider mapping is immutable once set; create a new billing account instead.';
    END IF;
    IF OLD.provider_code IS NULL AND NEW.provider_code IS NOT NULL THEN
        FOR v_s IN SELECT s.subscription_id, s.provider_subscription_reference FROM cob3_tenant.subscriptions s
                    WHERE s.billing_account_id = NEW.billing_account_id AND s.provider_subscription_reference IS NOT NULL LOOP
            PERFORM cob3_tenant.assert_provider_subscription_reference_unique(NEW.billing_account_id, v_s.provider_subscription_reference, v_s.subscription_id);
        END LOOP;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_provider_guard BEFORE UPDATE ON cob3_tenant.billing_accounts
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_billing_accounts_provider_guard();

-- subscriptions ------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_subscriptions_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status IN ('trialing', 'active') THEN
        NEW.started_at := COALESCE(NEW.started_at, pg_catalog.now());
    END IF;
    IF NEW.status IN ('canceled', 'expired') THEN
        NEW.ended_at := COALESCE(NEW.ended_at, pg_catalog.now());
    END IF;
    IF TG_OP = 'INSERT'
       OR NEW.provider_subscription_reference IS DISTINCT FROM OLD.provider_subscription_reference
       OR NEW.billing_account_id IS DISTINCT FROM OLD.billing_account_id THEN
        PERFORM cob3_tenant.assert_provider_subscription_reference_unique(NEW.billing_account_id, NEW.provider_subscription_reference, NEW.subscription_id);
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.subscriptions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>pending', '>trialing', '>active',
        'pending>trialing', 'pending>active', 'pending>canceled',
        'trialing>active', 'trialing>past_due', 'trialing>canceled', 'trialing>expired',
        'active>past_due', 'active>paused', 'active>canceled', 'active>expired',
        'past_due>active', 'past_due>paused', 'past_due>canceled', 'past_due>expired',
        'paused>active', 'paused>canceled', 'paused>expired');
CREATE TRIGGER trg_15_guard BEFORE INSERT OR UPDATE ON cob3_tenant.subscriptions
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_subscriptions_guard();
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.subscriptions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'pending,trialing,active,past_due,paused');

-- subscription_periods -------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_subscription_periods_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_sub_status     text;
    v_price          cob3_tenant.plan_prices%ROWTYPE;
    v_version_status text;
BEGIN
    SELECT s.status INTO v_sub_status FROM cob3_tenant.subscriptions s
     WHERE s.tenant_id = NEW.tenant_id AND s.subscription_id = NEW.subscription_id FOR UPDATE;
    IF v_sub_status IN ('canceled', 'expired') THEN
        RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Contract segments cannot be added to an ended subscription.';
    END IF;
    IF TG_OP = 'INSERT' OR NEW.plan_price_id IS DISTINCT FROM OLD.plan_price_id OR NEW.currency_code IS DISTINCT FROM OLD.currency_code THEN
        SELECT p.* INTO v_price FROM cob3_tenant.plan_prices p WHERE p.plan_price_id = NEW.plan_price_id;
        SELECT v.status INTO v_version_status FROM cob3_tenant.plan_versions v WHERE v.plan_version_id = NEW.plan_version_id;
        IF v_price.status = 'draft' OR v_version_status = 'draft' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Contract segments must reference published catalog terms.';
        END IF;
        IF (v_price.status = 'retired' OR v_version_status = 'retired')
           AND NOT EXISTS (SELECT 1 FROM cob3_tenant.subscription_periods x
                            WHERE x.tenant_id = NEW.tenant_id AND x.subscription_id = NEW.subscription_id
                              AND x.plan_price_id = NEW.plan_price_id
                              AND x.subscription_period_id <> NEW.subscription_period_id) THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA',
                MESSAGE = 'Retired catalog terms cannot be newly selected; they may only continue an existing contract.';
        END IF;
        IF NEW.currency_code <> v_price.currency_code THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Contract segment currency must match the price currency.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.subscription_periods
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>scheduled', '>active', 'scheduled>active', 'active>closed');
CREATE TRIGGER trg_15_guard BEFORE INSERT OR UPDATE ON cob3_tenant.subscription_periods
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_subscription_periods_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.subscription_periods
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('subscription_id', 'billing_period_key', 'segment_number');
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.subscription_periods
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'scheduled', 'status');
CREATE TRIGGER trg_50_delete_scheduled_only BEFORE DELETE ON cob3_tenant.subscription_periods
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_delete_only_in_state('status', 'scheduled');

CREATE FUNCTION cob3_tenant.tg_subscription_periods_revalidate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM cob3_tenant.validate_allocations(OLD.tenant_id, NULL, OLD.period_start, 'infinity'::timestamptz);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM cob3_tenant.validate_allocations(NEW.tenant_id, NULL, NEW.period_start, 'infinity'::timestamptz);
    END IF;
    RETURN NULL;
END
$fn$;
CREATE TRIGGER trg_60_revalidate_allocations AFTER INSERT OR UPDATE OR DELETE ON cob3_tenant.subscription_periods
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_subscription_periods_revalidate();

-- subscription_changes ----------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_subscription_changes_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_price_status text;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.target_plan_price_id IS NOT NULL THEN
        SELECT p.status INTO v_price_status FROM cob3_tenant.plan_prices p WHERE p.plan_price_id = NEW.target_plan_price_id;
        IF v_price_status <> 'published' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Plan changes must target a published price.';
        END IF;
    END IF;
    IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') THEN
        NEW.approved_at := COALESCE(NEW.approved_at, pg_catalog.now());
    END IF;
    IF NEW.status = 'applied' AND (TG_OP = 'INSERT' OR OLD.status <> 'applied') THEN
        PERFORM 1 FROM cob3_tenant.subscriptions s
          WHERE s.tenant_id = NEW.tenant_id AND s.subscription_id = NEW.subscription_id FOR UPDATE;
        NEW.applied_at := COALESCE(NEW.applied_at, pg_catalog.now());
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.subscription_changes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>requested', 'requested>approved', 'requested>rejected', 'requested>canceled', 'approved>applied', 'approved>canceled');
CREATE TRIGGER trg_15_guard BEFORE INSERT OR UPDATE ON cob3_tenant.subscription_changes
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_subscription_changes_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.subscription_changes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('subscription_id', 'change_type', 'target_plan_price_id',
        'idempotency_key', 'requested_by_principal_id', 'reason');
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.subscription_changes
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'requested',
        'status', 'approved_by_principal_id', 'approved_at', 'applied_at');

-- tenant_entitlement_overrides --------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_overrides_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    PERFORM cob3_tenant.assert_entitlement_shape(NEW.feature_id, NEW.is_enabled, NEW.limit_value, NEW.is_unlimited, NEW.reset_period);
    IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') THEN
        NEW.approved_at := COALESCE(NEW.approved_at, pg_catalog.now());
        NEW.approved_by := COALESCE(NEW.approved_by, cob3_identity.ctx_actor());
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.tenant_entitlement_overrides
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>draft', '>approved', 'draft>approved', 'draft>revoked', 'approved>revoked');
CREATE TRIGGER trg_15_guard BEFORE INSERT OR UPDATE ON cob3_tenant.tenant_entitlement_overrides
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_overrides_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.tenant_entitlement_overrides
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('feature_id');
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.tenant_entitlement_overrides
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status');

CREATE FUNCTION cob3_tenant.tg_overrides_revalidate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'approved' OR (TG_OP = 'UPDATE' AND OLD.status = 'approved') THEN
        PERFORM cob3_tenant.validate_allocations(NEW.tenant_id, NEW.feature_id, NEW.valid_from, NEW.valid_until);
    END IF;
    RETURN NULL;
END
$fn$;
CREATE TRIGGER trg_60_revalidate_allocations AFTER INSERT OR UPDATE ON cob3_tenant.tenant_entitlement_overrides
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_overrides_revalidate();

-- organization_quota_allocations ------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_allocations_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_type text;
BEGIN
    SELECT f.value_type INTO v_type FROM cob3_tenant.features f WHERE f.feature_id = NEW.feature_id;
    IF v_type <> 'quota' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Only finite numeric quota features are allocatable to organizations.';
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.organization_quota_allocations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status', '>active', 'active>revoked');
CREATE TRIGGER trg_15_guard BEFORE INSERT ON cob3_tenant.organization_quota_allocations
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_allocations_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.organization_quota_allocations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('feature_id');
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.organization_quota_allocations
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'active', 'status');

CREATE FUNCTION cob3_tenant.tg_allocations_revalidate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF NEW.status = 'active' THEN
        PERFORM cob3_tenant.validate_allocations(NEW.tenant_id, NEW.feature_id, NEW.valid_from, NEW.valid_until);
    END IF;
    RETURN NULL;
END
$fn$;
CREATE TRIGGER trg_60_revalidate AFTER INSERT OR UPDATE ON cob3_tenant.organization_quota_allocations
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_allocations_revalidate();

-- usage_events --------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_usage_events_validate()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_kind     text;
    v_original cob3_tenant.usage_events%ROWTYPE;
    v_reversed numeric;
BEGIN
    SELECT f.measurement_kind INTO v_kind FROM cob3_tenant.features f WHERE f.feature_id = NEW.feature_id;
    IF v_kind <> 'counter' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'usage_events measure counter features only; gauges are read from authoritative stores.';
    END IF;
    IF NEW.correction_of_event_id IS NOT NULL THEN
        SELECT e.* INTO v_original FROM cob3_tenant.usage_events e
         WHERE e.tenant_id = NEW.tenant_id AND e.usage_event_id = NEW.correction_of_event_id
           FOR UPDATE;
        IF v_original.correction_of_event_id IS NOT NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A correction must reference an original consumption event, not another correction.';
        END IF;
        IF v_original.feature_id <> NEW.feature_id OR v_original.organization_id IS DISTINCT FROM NEW.organization_id THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'A correction must keep the original feature and organization attribution.';
        END IF;
        SELECT COALESCE(sum(c.quantity), 0) INTO v_reversed FROM cob3_tenant.usage_events c
         WHERE c.tenant_id = NEW.tenant_id AND c.correction_of_event_id = NEW.correction_of_event_id;
        IF v_original.quantity + v_reversed + NEW.quantity < 0 THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Cumulative corrections (%s) would exceed the original consumption (%s).',
                            v_reversed + NEW.quantity, v_original.quantity);
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_validate BEFORE INSERT ON cob3_tenant.usage_events
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_usage_events_validate();

-- invoices ------------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_invoices_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_lines_total bigint;
    v_paid        bigint;
BEGIN
    IF OLD.status = 'draft' AND NEW.status <> 'draft' THEN
        -- Issuance: validate draft lines and totals atomically.
        NEW.issued_at := COALESCE(NEW.issued_at, pg_catalog.now());
        SELECT COALESCE(sum(l.line_subtotal_minor), 0) INTO v_lines_total
          FROM cob3_tenant.invoice_lines l WHERE l.tenant_id = NEW.tenant_id AND l.invoice_id = NEW.invoice_id;
        IF v_lines_total <> NEW.subtotal_minor THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Invoice subtotal %s does not equal the sum of line subtotals %s.', NEW.subtotal_minor, v_lines_total);
        END IF;
        IF NEW.billing_snapshot = '{}'::jsonb THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'An issued invoice requires a billing snapshot (party, address, terms).';
        END IF;
    END IF;
    IF NEW.status = 'paid' AND OLD.status <> 'paid' THEN
        SELECT COALESCE(sum(CASE WHEN p.transaction_type = 'payment' THEN p.amount_minor ELSE -p.amount_minor END), 0)
          INTO v_paid
          FROM cob3_tenant.payment_transactions p
         WHERE p.tenant_id = NEW.tenant_id AND p.invoice_id = NEW.invoice_id AND p.status = 'succeeded';
        IF v_paid < NEW.total_minor THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Invoice cannot be marked paid: reconciled net payments %s < total %s.', v_paid, NEW.total_minor);
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.invoices
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>draft', 'draft>open', 'draft>void', 'open>paid', 'open>void', 'open>uncollectible', 'uncollectible>paid', 'uncollectible>void');
CREATE TRIGGER trg_15_guard BEFORE UPDATE ON cob3_tenant.invoices
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_invoices_guard();
CREATE TRIGGER trg_40_freeze BEFORE UPDATE ON cob3_tenant.invoices
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_freeze_columns('status', 'draft', 'status', 'provider_invoice_reference');
CREATE TRIGGER trg_50_delete_draft_only BEFORE DELETE ON cob3_tenant.invoices
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_delete_only_in_state('status', 'draft');

-- invoice_lines ---------------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_invoice_lines_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tenant  uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.tenant_id ELSE NEW.tenant_id END;
    v_invoice uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END;
    v_status  text;
BEGIN
    SELECT i.status INTO v_status FROM cob3_tenant.invoices i
     WHERE i.tenant_id = v_tenant AND i.invoice_id = v_invoice FOR UPDATE;
    IF v_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION USING ERRCODE = 'SKIMM', MESSAGE = 'Invoice lines can change only while the invoice is draft.';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_guard BEFORE INSERT OR UPDATE OR DELETE ON cob3_tenant.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_invoice_lines_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('invoice_id');

-- payment_transactions --------------------------------------------------------------
CREATE FUNCTION cob3_tenant.tg_payment_transactions_guard()
    RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_invoice  cob3_tenant.invoices%ROWTYPE;
    v_parent   cob3_tenant.payment_transactions%ROWTYPE;
    v_reversed bigint;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT i.* INTO v_invoice FROM cob3_tenant.invoices i
         WHERE i.tenant_id = NEW.tenant_id AND i.invoice_id = NEW.invoice_id;
        IF v_invoice.status = 'draft' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKSTA', MESSAGE = 'Payments cannot be recorded against a draft invoice.';
        END IF;
        IF NEW.currency_code <> v_invoice.currency_code THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Transaction currency must match the invoice currency.';
        END IF;
    END IF;
    IF NEW.parent_transaction_id IS NOT NULL
       AND NEW.status IN ('pending', 'succeeded')
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
        SELECT p.* INTO v_parent FROM cob3_tenant.payment_transactions p
         WHERE p.tenant_id = NEW.tenant_id AND p.payment_transaction_id = NEW.parent_transaction_id
           FOR UPDATE;
        IF v_parent.transaction_type <> 'payment' OR v_parent.status <> 'succeeded' THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Refunds and chargebacks require a succeeded parent payment.';
        END IF;
        IF v_parent.currency_code <> NEW.currency_code THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = 'Reversal currency must match the parent payment.';
        END IF;
        SELECT COALESCE(sum(r.amount_minor), 0) INTO v_reversed FROM cob3_tenant.payment_transactions r
         WHERE r.tenant_id = NEW.tenant_id AND r.parent_transaction_id = NEW.parent_transaction_id
           AND r.status IN ('pending', 'succeeded') AND r.payment_transaction_id <> NEW.payment_transaction_id;
        IF v_reversed + NEW.amount_minor > v_parent.amount_minor THEN
            RAISE EXCEPTION USING ERRCODE = 'SKINV',
                MESSAGE = pg_catalog.format('Reversals (%s + %s) would exceed the parent payment amount %s.', v_reversed, NEW.amount_minor, v_parent.amount_minor);
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.payment_transactions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>pending', '>succeeded', '>failed', 'pending>succeeded', 'pending>failed');
CREATE TRIGGER trg_15_guard BEFORE INSERT OR UPDATE ON cob3_tenant.payment_transactions
    FOR EACH ROW EXECUTE FUNCTION cob3_tenant.tg_payment_transactions_guard();
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.payment_transactions
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('invoice_id', 'parent_transaction_id', 'transaction_type',
        'amount_minor', 'currency_code', 'provider_code', 'provider_account_reference', 'provider_transaction_reference', 'occurred_at');

-- provider_events -------------------------------------------------------------------
CREATE TRIGGER trg_10_state BEFORE INSERT OR UPDATE OF status ON cob3_tenant.provider_events
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_state_transition('status',
        '>received', 'received>processing', 'received>failed', 'processing>processed', 'processing>failed',
        'processing>received', 'failed>processing', 'failed>received');
CREATE TRIGGER trg_20_immutable BEFORE UPDATE ON cob3_tenant.provider_events
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_immutable_columns('provider_code', 'provider_account_reference',
        'external_event_id', 'event_type', 'occurred_at', 'payload_digest', 'received_at');
CREATE TRIGGER trg_21_nondecreasing BEFORE UPDATE ON cob3_tenant.provider_events
    FOR EACH ROW EXECUTE FUNCTION cob3_identity.tg_nondecreasing('attempt_count');
