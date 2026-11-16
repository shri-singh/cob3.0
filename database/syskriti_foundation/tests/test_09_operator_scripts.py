"""Operator scripts: VERIFY report, core template sync and optional product seed."""
from __future__ import annotations

from helpers import COMMERCIAL_LOGIN, INSTALLER_ROLE, PKG, PROVISIONER_LOGIN


def test_verify_report_has_no_failures_and_flags_catalog_as_pending(h):
    conn = h.connect(INSTALLER_ROLE)
    cur = conn.cursor()
    cur.execute("SET TRANSACTION READ ONLY")
    cur.execute((PKG / "VERIFY_FOUNDATION.sql").read_text(encoding="utf-8"))
    rows = cur.fetchall()
    conn.rollback()
    conn.close()
    bad = [r for r in rows if r[2] in ("FAIL", "WARN")]
    assert not bad, bad
    statuses = {r[1]: r[2] for r in rows}
    assert statuses["catalog integration"] == "PENDING"
    assert statuses["expected tables present"] == "PASS"
    assert len(rows) >= 25


def test_core_template_sync_is_idempotent_under_provisioner(h):
    conn = h.connect(PROVISIONER_LOGIN, autocommit=True)
    sql = (PKG / "seeds" / "core_permission_templates.sql").read_text(encoding="utf-8")
    conn.cursor().execute(sql)
    conn.cursor().execute(sql)
    assert sum("synchronized" in n for n in conn.notices) == 2
    conn.close()
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    cur.execute("""select count(*) from (select tenant_id, count(*) c from cob3_identity.permissions group by tenant_id) x where c < 20""")
    assert cur.fetchone()[0] == 0
    cur.execute("select count(*) from cob3_identity.roles where tenant_id is null")
    assert cur.fetchone()[0] == 0
    owner.close()


def test_optional_observei_seed_is_separate_and_idempotent(h):
    prov = h.connect(PROVISIONER_LOGIN, autocommit=True)
    prov.cursor().execute((PKG / "BOOTSTRAP_EXAMPLE.sql").read_text(encoding="utf-8"))  # idempotent
    text = (PKG / "seeds" / "optional_observei_examples.sql").read_text(encoding="utf-8")
    part_a, part_b = text.split("-- Part B: per-tenant Observei IAM permissions and roles (provisioning)")
    comm = h.connect(COMMERCIAL_LOGIN, autocommit=True)
    for _ in range(2):
        comm.cursor().execute(part_a)
        prov.cursor().execute(part_b)
    comm.close()
    prov.close()
    owner = h.connect(INSTALLER_ROLE)
    cur = owner.cursor()
    cur.execute("select count(*) from cob3_tenant.features where feature_code in ('storage.bytes', 'logs.ingested_bytes', 'ai.tokens', 'api.requests', 'lineage.enabled')")
    assert cur.fetchone()[0] == 5
    cur.execute("select v.status from cob3_tenant.plan_versions v join cob3_tenant.plans p using (plan_id) where p.plan_code = 'observei-standard-example'")
    assert cur.fetchone()[0] == "draft"  # never published by the example
    cur.execute("""select count(*) from cob3_identity.role_permissions rp
                     join cob3_identity.roles r on r.tenant_id = rp.tenant_id and r.role_id = rp.role_id
                     join cob3_tenant.tenants t on t.tenant_id = r.tenant_id
                    where t.tenant_code = 'example-tenant' and r.role_code in ('viewer', 'incident_operator', 'dashboard_editor', 'ingestion_writer')""")
    assert cur.fetchone()[0] == 15
    # Product permissions are not present in the installer itself.
    installer = (PKG / "INSTALL_FOUNDATION.sql").read_text(encoding="utf-8").lower()
    for word in ("observei", "opsi", "dynatrace", "elasticsearch", "copilotkit", "incident.read", "log.ingest"):
        assert word not in installer, word
    owner.close()
