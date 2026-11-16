"""Commercial invariants (master prompt tests 16, 17) including real concurrency."""
from __future__ import annotations

import threading
import uuid
from datetime import datetime, timedelta, timezone

import psycopg2

from helpers import (ACTOR, COMMERCIAL_LOGIN, RUNTIME_LOGIN, admin_org, admin_tenant, create_published_plan, expect_error,
                     make_tenant, request)


def _commercial(h):
    conn = h.connect(COMMERCIAL_LOGIN)
    conn.cursor().execute("select cob3_identity.set_system_context(%s)", (ACTOR,))
    return conn


def test_published_catalog_terms_are_immutable(h):
    pv, price = create_published_plan(h, {"humans.max": 10})
    conn = _commercial(h)
    cur = conn.cursor()
    expect_error(cur, "update cob3_tenant.plan_entitlements set limit_value = 999 where plan_version_id = %s", (pv,), code="SKIMM")
    expect_error(cur, "insert into cob3_tenant.plan_entitlements (plan_version_id, feature_id, is_enabled, reset_period, created_by, updated_by)"
                      " select %s, feature_id, true, 'none', %s, %s from cob3_tenant.features where feature_code = 'sso.enabled'",
                 (pv, ACTOR, ACTOR), code="SKIMM")
    expect_error(cur, "delete from cob3_tenant.plan_entitlements where plan_version_id = %s", (pv,), code="SKIMM")
    expect_error(cur, "update cob3_tenant.plan_prices set base_amount_minor = 1 where plan_price_id = %s", (price,), code="SKIMM")
    expect_error(cur, "update cob3_tenant.plan_versions set effective_from = now() where plan_version_id = %s", (pv,), code="SKIMM")
    expect_error(cur, "update cob3_tenant.plan_versions set status = 'draft' where plan_version_id = %s", (pv,), code="SKSTA")
    cur.execute("update cob3_tenant.plan_versions set status = 'retired' where plan_version_id = %s", (pv,))  # allowed lifecycle step
    # Feature definition is immutable once used.
    expect_error(cur, "update cob3_tenant.features set unit_code = 'byte' where feature_code = 'humans.max'", code="SKIMM")
    conn.rollback()
    conn.close()


def test_issued_invoice_snapshot_is_immutable_and_paid_requires_reconciled_payment(h):
    t = make_tenant(h)
    conn = _commercial(h)
    cur = conn.cursor()
    cur.execute("select billing_account_id from cob3_tenant.subscriptions where subscription_id = %s", (t.subscription,))
    ba = cur.fetchone()[0]
    inv = uuid.uuid4()
    cur.execute("insert into cob3_tenant.invoices (invoice_id, tenant_id, billing_account_id, subscription_id, currency_code, subtotal_minor, total_minor, billing_snapshot, created_by, updated_by)"
                " values (%s, %s, %s, %s, 'USD', 1500, 1500, '{\"party\": \"Example Ltd\"}', %s, %s)", (inv, t.id, ba, t.subscription, ACTOR, ACTOR))
    cur.execute("insert into cob3_tenant.invoice_lines (tenant_id, invoice_id, line_number, description, quantity, unit_price, line_subtotal_minor, created_by, updated_by)"
                " values (%s, %s, 1, 'Base plan', 1, 10.00, 1000, %s, %s)", (t.id, inv, ACTOR, ACTOR))
    expect_error(cur, "update cob3_tenant.invoices set status = 'open', invoice_number = 'INV-1' where invoice_id = %s", (inv,), code="SKINV")  # 1500 <> 1000
    cur.execute("insert into cob3_tenant.invoice_lines (tenant_id, invoice_id, line_number, description, quantity, unit_price, line_subtotal_minor, created_by, updated_by)"
                " values (%s, %s, 2, 'Usage', 5, 1.00, 500, %s, %s)", (t.id, inv, ACTOR, ACTOR))
    cur.execute("update cob3_tenant.invoices set status = 'open', invoice_number = 'INV-1' where invoice_id = %s", (inv,))
    expect_error(cur, "update cob3_tenant.invoice_lines set line_subtotal_minor = 1 where invoice_id = %s and line_number = 1", (inv,), code="SKIMM")
    expect_error(cur, "insert into cob3_tenant.invoice_lines (tenant_id, invoice_id, line_number, description, quantity, unit_price, line_subtotal_minor, created_by, updated_by)"
                      " values (%s, %s, 3, 'Late', 1, 1, 1, %s, %s)", (t.id, inv, ACTOR, ACTOR), code="SKIMM")
    expect_error(cur, "update cob3_tenant.invoices set billing_snapshot = '{\"party\": \"Other\"}' where invoice_id = %s", (inv,), code="SKIMM")
    expect_error(cur, "update cob3_tenant.invoices set total_minor = 0, subtotal_minor = 0 where invoice_id = %s", (inv,), code="SKIMM")
    expect_error(cur, "delete from cob3_tenant.invoices where invoice_id = %s", (inv,), code="SKIMM")
    expect_error(cur, "update cob3_tenant.invoices set status = 'paid' where invoice_id = %s", (inv,), code="SKINV")  # no payments yet
    pay = uuid.uuid4()
    cur.execute("insert into cob3_tenant.payment_transactions (payment_transaction_id, tenant_id, invoice_id, transaction_type, status, amount_minor, currency_code,"
                " provider_code, provider_account_reference, provider_transaction_reference, occurred_at, created_by, updated_by)"
                " values (%s, %s, %s, 'payment', 'succeeded', 1500, 'USD', 'test-psp', 'acct-1', %s, now(), %s, %s)",
                (pay, t.id, inv, "tx-" + uuid.uuid4().hex, ACTOR, ACTOR))
    expect_error(cur, "insert into cob3_tenant.payment_transactions (tenant_id, invoice_id, parent_transaction_id, transaction_type, status, amount_minor, currency_code,"
                      " provider_code, provider_account_reference, provider_transaction_reference, occurred_at, created_by, updated_by)"
                      " values (%s, %s, %s, 'refund', 'pending', 1600, 'USD', 'test-psp', 'acct-1', %s, now(), %s, %s)",
                 (t.id, inv, pay, "rf-" + uuid.uuid4().hex, ACTOR, ACTOR), code="SKINV")  # exceeds payment
    expect_error(cur, "insert into cob3_tenant.payment_transactions (tenant_id, invoice_id, transaction_type, status, amount_minor, currency_code,"
                      " provider_code, provider_account_reference, provider_transaction_reference, occurred_at, created_by, updated_by)"
                      " values (%s, %s, 'payment', 'pending', 10, 'EUR', 'test-psp', 'acct-1', %s, now(), %s, %s)",
                 (t.id, inv, "tx-" + uuid.uuid4().hex, ACTOR, ACTOR), code="SKINV")  # currency mismatch
    cur.execute("update cob3_tenant.invoices set status = 'paid' where invoice_id = %s", (inv,))
    expect_error(cur, "update cob3_tenant.payment_transactions set amount_minor = 1 where payment_transaction_id = %s", (pay,), code="SKIMM")
    conn.commit()
    conn.close()
    # Tenant administrators cannot mark invoices paid (no write privilege at all).
    with admin_tenant(t) as rcur:
        expect_error(rcur, "update cob3_tenant.invoices set status = 'void'", code="42501")


def test_subscription_and_override_overlaps_prevented(h):
    t = make_tenant(h)
    conn = _commercial(h)
    cur = conn.cursor()
    expect_error(cur, "insert into cob3_tenant.subscription_periods (tenant_id, subscription_id, billing_period_key, segment_number, plan_version_id,"
                      " plan_price_id, period_start, period_end, currency_code, contract_amount_minor, created_by, updated_by)"
                      " values (%s, %s, 'cycle-1', 2, %s, %s, now() + interval '10 days', now() + interval '40 days', 'USD', 1000, %s, %s)",
                 (t.id, t.subscription, t.plan_version, t.plan_price, ACTOR, ACTOR), code="23P01")
    expect_error(cur, "insert into cob3_tenant.subscription_periods (tenant_id, subscription_id, billing_period_key, segment_number, plan_version_id,"
                      " plan_price_id, period_start, period_end, currency_code, contract_amount_minor, created_by, updated_by)"
                      " values (%s, %s, 'cycle-2', 1, %s, %s, now() + interval '30 days', now() + interval '60 days', 'EUR', 1000, %s, %s)",
                 (t.id, t.subscription, t.plan_version, t.plan_price, ACTOR, ACTOR), code="SKINV")  # currency must match price
    cur.execute("select billing_account_id from cob3_tenant.subscriptions where subscription_id = %s", (t.subscription,))
    ba = cur.fetchone()[0]
    expect_error(cur, "insert into cob3_tenant.subscriptions (tenant_id, billing_account_id, status, created_by, updated_by) values (%s, %s, 'pending', %s, %s)",
                 (t.id, ba, ACTOR, ACTOR), code="23505")  # one live base subscription
    ins = ("insert into cob3_tenant.tenant_entitlement_overrides (tenant_id, feature_id, is_enabled, limit_value, reset_period, valid_from, valid_until, status, reason, created_by, updated_by)"
           " select %s, feature_id, true, %s, 'none', now() + make_interval(days => %s), now() + make_interval(days => %s), 'approved', 'contract', %s, %s"
           " from cob3_tenant.features where feature_code = 'humans.max'")
    cur.execute(ins, (t.id, 50, 0, 30, ACTOR, ACTOR))
    expect_error(cur, ins, (t.id, 60, 10, 40, ACTOR, ACTOR), code="23P01")
    cur.execute("select approved_by from cob3_tenant.tenant_entitlement_overrides where tenant_id = %s", (t.id,))
    assert cur.fetchone()[0] == ACTOR
    expect_error(cur, "update cob3_tenant.tenant_entitlement_overrides set limit_value = 500 where tenant_id = %s", (t.id,), code="SKIMM")
    conn.commit()
    cur.execute("select limit_value, source from cob3_tenant.resolve_tenant_entitlement(%s, 'humans.max')", (t.id,))
    assert cur.fetchone() == (50, "override")  # replacement, not addition
    conn.rollback()
    conn.close()


def test_usage_idempotency_and_correction_limits(h):
    t = make_tenant(h)
    rt = h.conn(RUNTIME_LOGIN)
    call = "select usage_event_id, duplicate from cob3_tenant.record_usage_event('test.requests', 'gateway', %s, %s::timestamptz, %s, %s, NULL, %s, true)"
    # Inside the subscription period created by make_tenant (now() - 1 day .. + 30 days); fixed for idempotent retries.
    occurred = (datetime.now(timezone.utc) - timedelta(hours=1)).replace(microsecond=0).isoformat()
    with admin_org(t, rt) as cur:
        cur.execute(call, ("evt-1", occurred, 10, t.org, None))
        original, dup = cur.fetchone()
        assert dup is False
        cur.execute(call, ("evt-1", occurred, 10, t.org, None))
        assert cur.fetchone() == (original, True)  # retry is a no-op
        expect_error(cur, call, ("evt-1", occurred, 11, t.org, None), code="SKIDM")  # same key, different payload
        expect_error(cur, call, ("evt-1b", occurred, 1, uuid.uuid4(), None), code="SKAUZ")  # foreign org attribution
        cur.execute(call, ("corr-1", occurred, -4, t.org, original))
        cur.execute(call, ("corr-2", occurred, -6, t.org, original))
        expect_error(cur, call, ("corr-3", occurred, -1, t.org, original), code="SKINV")  # beyond original consumption
        expect_error(cur, call, ("corr-4", occurred, -1, None, original), code="SKINV")   # attribution must match
    owner = h.connect("t_installer")
    oc = owner.cursor()
    oc.execute("select consumed_quantity from cob3_tenant.quota_counters where tenant_id = %s and scope_kind = 'tenant_total'", (t.id,))
    assert oc.fetchone()[0] == 0
    expect_error(oc, "update cob3_tenant.usage_events set quantity = 1 where tenant_id = %s", (t.id,), code="SKAPP")
    owner.rollback()
    owner.close()


def _parallel(h, n, fn):
    results = []
    lock = threading.Lock()
    barrier = threading.Barrier(n)

    def run(i):
        conn = h.connect(RUNTIME_LOGIN)
        try:
            barrier.wait()
            res = fn(conn, i)
        except psycopg2.Error as exc:
            conn.rollback()
            res = exc.pgcode
        finally:
            conn.close()
        with lock:
            results.append(res)

    threads = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    return results


def test_concurrent_counter_consumption_never_exceeds_limit(h):
    t = make_tenant(h, limits={"test.requests": 10})

    def consume(conn, i):
        cur = conn.cursor()
        cur.execute("select cob3_identity.set_request_context(%s, %s, %s, %s, NULL)", (t.id, t.org, t.admin, t.admin_org_session))
        cur.execute("select usage_event_id from cob3_tenant.record_usage_event('test.requests', 'gateway', %s, now(), 1, %s)", (f"r-{i}", t.org))
        conn.commit()
        return "ok"

    results = _parallel(h, 20, consume)
    assert results.count("ok") == 10 and results.count("SKQTA") == 10, results
    owner = h.connect("t_installer")
    oc = owner.cursor()
    oc.execute("select count(*) from cob3_tenant.usage_events where tenant_id = %s", (t.id,))
    assert oc.fetchone()[0] == 10
    oc.execute("select consumed_quantity from cob3_tenant.quota_counters where tenant_id = %s and scope_kind = 'tenant_total'", (t.id,))
    assert oc.fetchone()[0] == 10
    owner.close()


def test_concurrent_allocations_cannot_oversubscribe_and_downgrade_requires_reallocation(h):
    t = make_tenant(h, limits={"service_accounts.max": 10})
    with admin_tenant(t) as cur:
        org_b = uuid.uuid4()
        cur.execute("insert into cob3_identity.organizations (tenant_id, organization_id, organization_code, name, created_by, updated_by)"
                    " values (%s, %s, 'org-b', 'Org B', %s, %s)", (t.id, org_b, ACTOR, ACTOR))
    orgs = [t.org, org_b]

    def allocate(conn, i):
        cur = conn.cursor()
        cur.execute("select cob3_identity.set_request_context(%s, NULL, %s, %s, NULL)", (t.id, t.admin, t.admin_tenant_session))
        cur.execute("insert into cob3_tenant.organization_quota_allocations (tenant_id, organization_id, feature_id, allocated_limit, valid_from, valid_until, reason, created_by, updated_by)"
                    " select %s, %s, feature_id, 6, now() - interval '1 hour', now() + interval '20 days', 'split', %s, %s"
                    " from cob3_tenant.features where feature_code = 'service_accounts.max'", (t.id, orgs[i], ACTOR, ACTOR))
        conn.commit()
        return "ok"

    results = _parallel(h, 2, allocate)
    assert sorted(results) == ["SKQTA", "ok"], results
    # A downgrade that would invalidate existing allocations is refused.
    conn = _commercial(h)
    cur = conn.cursor()
    expect_error(cur, "insert into cob3_tenant.tenant_entitlement_overrides (tenant_id, feature_id, is_enabled, limit_value, reset_period, valid_from, valid_until, status, reason, created_by, updated_by)"
                      " select %s, feature_id, true, 4, 'none', now(), now() + interval '30 days', 'approved', 'downgrade', %s, %s"
                      " from cob3_tenant.features where feature_code = 'service_accounts.max'", (t.id, ACTOR, ACTOR), code="SKQTA")
    conn.rollback()
    conn.close()


def test_gauge_quota_enforced_under_concurrency(h):
    t = make_tenant(h, limits={"organizations.max": 2})  # bootstrap organization already counts as 1

    def create_org(conn, i):
        cur = conn.cursor()
        cur.execute("select cob3_identity.set_request_context(%s, NULL, %s, %s, NULL)", (t.id, t.admin, t.admin_tenant_session))
        cur.execute("insert into cob3_identity.organizations (tenant_id, organization_id, organization_code, name, created_by, updated_by)"
                    " values (%s, gen_random_uuid(), %s, 'Concurrent', %s, %s)", (t.id, f"org-c{i}", ACTOR, ACTOR))
        conn.commit()
        return "ok"

    results = _parallel(h, 4, create_org)
    assert results.count("ok") == 1 and results.count("SKQTA") == 3, results


def test_missing_entitlement_means_disabled_not_unlimited(h):
    t = make_tenant(h, limits={"automation.enabled": False})
    with admin_org(t) as cur:
        expect_error(cur, "select cob3_identity.create_automation('bot-x', 'x', %s, 'x', 'agent', 'portal', NULL)", (t.admin,), code="SKENT")
    t2 = make_tenant(h, subscribe_plan=False)
    with admin_org(t2) as cur:
        expect_error(cur, "insert into cob3_identity.principals (tenant_id, principal_id, principal_type, principal_code, display_name, created_by, updated_by)"
                          " values (%s, gen_random_uuid(), 'human', 'nobody', 'Nobody', 'system:x', 'system:x')", (t2.id,), code="SKQTA")
