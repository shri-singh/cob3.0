"""Migration 003: AI and agent state (8 schemas, 67 tables).

Exercises the design's key guarantees under real non-owner roles: explicit
asset sharing, sealed revisions, publication, self-owned execution contexts,
fencing, gapless sequences, bound tools, trusted assistant messages, lineage
validity and LLM accounting rules.
"""
from __future__ import annotations

import json
import uuid

import psycopg2
import pytest

from helpers import ACTOR, INSTALLER_ROLE, PKG, admin_org, dsn_for, expect_error, make_tenant, unique
from module_helpers import as_user, bind_asset_role, member, ready_file, sha_hex, worker

M003 = PKG / "migrations" / "003_ai_agent_state.sql"
OBJ = json.dumps({})


@pytest.fixture(scope="module")
def t(hm):
    return make_tenant(hm)


@pytest.fixture(scope="module")
def world(t):
    """Builder, reviewer, outsider; model provider; published prompt + agent; app/env/policy; service-account worker."""
    builder, bs = member(t, unique("bld"), roles=("organization_member", "ai_builder", "ai_administrator"))
    reviewer, rs = member(t, unique("rev"), roles=("organization_member",))
    outsider, os_ = member(t, unique("out"), roles=("organization_member", "ai_user"))
    w = {"builder": builder, "bs": bs, "reviewer": reviewer, "rs": rs, "outsider": outsider, "os": os_}
    with admin_org(t) as cur:
        cur.execute("select cob3_settings.ensure_scope('organization')")
        scope = cur.fetchone()[0]
        cur.execute("insert into cob3_settings.integration_configurations (tenant_id, organization_id, setting_scope_id, integration_code,"
                    " configuration_version, adapter_type, configuration, secret_reference, created_by, updated_by)"
                    " values (%s, %s, %s, %s, 1, 'model_provider', '{\"region\": \"eu\"}', 'vault://ai/provider', %s, %s)"
                    " returning integration_configuration_id", (t.id, t.org, scope, unique("llm"), ACTOR, ACTOR))
        w["config"] = cur.fetchone()[0]
        cur.execute("update cob3_settings.integration_configurations set status = 'active' where integration_configuration_id = %s", (w["config"],))
        cur.execute("select cob3_identity.create_service_account(%s, 'AI worker', %s, 'runtime worker')", (unique("svc"), builder))
        w["svc"] = cur.fetchone()[0]
    with as_user(t, builder, bs) as cur:
        cur.execute("insert into cob3_agent.model_deployments (tenant_id, organization_id, deployment_key, provider, provider_model_id,"
                    " integration_configuration_id, capabilities, enabled, created_by, updated_by)"
                    " values (%s, %s, %s, 'anthropic', 'claude-opus-5-5', %s, '{\"modalities\": [\"text\"]}', true, %s, %s)"
                    " returning model_deployment_id", (t.id, t.org, unique("dep"), w["config"], ACTOR, ACTOR))
        w["deployment"] = cur.fetchone()[0]
        cur.execute("select cob3_catalog.register_asset('prompt', %s, 'Support prompt')", (unique("prm"),))
        w["prompt_asset"] = cur.fetchone()[0]
        cur.execute("insert into cob3_agent.prompt_templates (tenant_id, organization_id, asset_id, template_key, purpose, created_by, updated_by)"
                    " values (%s, %s, %s, %s, 'Answer support questions', %s, %s) returning prompt_template_id",
                    (t.id, t.org, w["prompt_asset"], unique("tpl"), ACTOR, ACTOR))
        w["template"] = cur.fetchone()[0]
        cur.execute("insert into cob3_agent.prompt_versions (tenant_id, organization_id, prompt_template_id, version, body, variables_schema,"
                    " template_engine, sha256, created_by, updated_by) values (%s, %s, %s, 1, 'You are helpful.', '{}', 'plain', %s, %s, %s)"
                    " returning prompt_version_id", (t.id, t.org, w["template"], sha_hex("p1"), ACTOR, ACTOR))
        w["prompt_version"] = cur.fetchone()[0]
        cur.execute("select cob3_catalog.register_asset('agent', %s, 'Support agent')", (unique("agt"),))
        w["agent_asset"] = cur.fetchone()[0]
        cur.execute("insert into cob3_agent.agents (tenant_id, organization_id, asset_id, agent_key, enabled, created_by, updated_by)"
                    " values (%s, %s, %s, %s, true, %s, %s) returning agent_id", (t.id, t.org, w["agent_asset"], unique("agent"), ACTOR, ACTOR))
        w["agent"] = cur.fetchone()[0]
        cur.execute("select cob3_catalog.register_asset('tool', %s, 'Lookup tool')", (unique("tl"),))
        w["tool_asset"] = cur.fetchone()[0]
        cur.execute("insert into cob3_agent.tools (tenant_id, organization_id, asset_id, tool_key, enabled, created_by, updated_by)"
                    " values (%s, %s, %s, %s, true, %s, %s) returning tool_id", (t.id, t.org, w["tool_asset"], unique("tool"), ACTOR, ACTOR))
        w["tool"] = cur.fetchone()[0]
        for n in (1, 2):
            cur.execute("insert into cob3_agent.tool_revisions (tenant_id, organization_id, tool_id, revision, transport, operation, input_schema,"
                        " output_schema, risk_level, requires_approval, side_effect_class, timeout_seconds, sha256, created_by, updated_by)"
                        " values (%s, %s, %s, %s, 'internal', 'kb.search', '{}', '{}', 0, false, 'read_only', 30, %s, %s, %s)"
                        " returning tool_revision_id", (t.id, t.org, w["tool"], n, sha_hex(f"t{n}"), ACTOR, ACTOR))
            w[f"tool_rev{n}"] = cur.fetchone()[0]
        cur.execute("insert into cob3_agent.agent_revisions (tenant_id, organization_id, agent_id, revision, prompt_version_id, model_deployment_id,"
                    " model_config, execution_contract, memory_policy, autonomy_level, max_steps, max_duration_seconds, max_cost, currency,"
                    " content_sha256, change_note, created_by, updated_by) values (%s, %s, %s, 1, %s, %s, '{}', '{}', '{}', 1, 10, 600, 5, 'USD',"
                    " %s, 'initial', %s, %s) returning agent_revision_id",
                    (t.id, t.org, w["agent"], w["prompt_version"], w["deployment"], sha_hex("a1"), ACTOR, ACTOR))
        w["revision"] = cur.fetchone()[0]
        cur.execute("insert into cob3_agent.agent_tool_bindings (tenant_id, organization_id, agent_revision_id, tool_revision_id,"
                    " requires_approval, limits, created_by, updated_by) values (%s, %s, %s, %s, false, '{}', %s, %s)",
                    (t.id, t.org, w["revision"], w["tool_rev1"], ACTOR, ACTOR))
        cur.execute("select cob3_catalog.register_asset('ai_application', %s, 'Support app')", (unique("app"),))
        app_asset = cur.fetchone()[0]
        cur.execute("insert into cob3_llmobs.applications (tenant_id, organization_id, asset_id, application_key, criticality, classification,"
                    " created_by, updated_by) values (%s, %s, %s, %s, 1, 'internal', %s, %s) returning application_id",
                    (t.id, t.org, app_asset, unique("ap"), ACTOR, ACTOR))
        app = cur.fetchone()[0]
        cur.execute("insert into cob3_llmobs.application_environments (tenant_id, organization_id, application_id, environment_key,"
                    " semconv_version, created_by, updated_by) values (%s, %s, %s, 'production', 'genai-1.0', %s, %s)"
                    " returning application_environment_id", (t.id, t.org, app, ACTOR, ACTOR))
        w["env"] = cur.fetchone()[0]
        cur.execute("insert into cob3_llmobs.policy_versions (tenant_id, organization_id, application_environment_id, version,"
                    " content_retention_days, metadata_retention_days, sampling_rate, guardrail_config, redaction_config, evaluation_config,"
                    " policy_sha256, created_by, updated_by) values (%s, %s, %s, 1, 0, 30, 1, '{}', '{}', '{}', %s, %s, %s)"
                    " returning policy_version_id", (t.id, t.org, w["env"], sha_hex("pol"), ACTOR, ACTOR))
        w["policy"] = cur.fetchone()[0]
    # Separation of duties: the reviewer is shared on the exact assets only.
    with admin_org(t) as cur:
        bind_asset_role(cur, t, reviewer, "ai_reviewer", w["prompt_asset"])
        bind_asset_role(cur, t, reviewer, "ai_reviewer", w["agent_asset"])
    with as_user(t, reviewer, rs) as cur:
        cur.execute("insert into cob3_agent.releases (tenant_id, organization_id, prompt_version_id, action, approved_by_principal_id, reason,"
                    " created_by, updated_by) values (%s, %s, %s, 'publish', %s, 'reviewed', %s, %s)",
                    (t.id, t.org, w["prompt_version"], reviewer, ACTOR, ACTOR))
        cur.execute("insert into cob3_agent.releases (tenant_id, organization_id, agent_revision_id, action, approved_by_principal_id, reason,"
                    " created_by, updated_by) values (%s, %s, %s, 'publish', %s, 'evaluated', %s, %s)",
                    (t.id, t.org, w["revision"], reviewer, ACTOR, ACTOR))
    return w


def start_run(t, w, key=None, revision=None, trigger="api"):
    with as_user(t, w["builder"], w["bs"]) as cur:
        cur.execute("insert into cob3_ai_runtime.execution_contexts (tenant_id, organization_id, initiator_principal_id, execution_principal_id,"
                    " auth_session_id, audience, valid_until, authority_ceiling, ceiling_sha256, authorization_evidence, created_by, updated_by)"
                    " values (%s, %s, %s, %s, %s, 'copilot', now() + interval '1 hour', '{\"permissions\": [\"ai.agent.invoke\"]}', %s, '{}', %s, %s)"
                    " returning execution_context_id", (t.id, t.org, w["builder"], w["builder"], w["bs"], sha_hex("ceiling"), ACTOR, ACTOR))
        ctx = cur.fetchone()[0]
        cur.execute("insert into cob3_ai_runtime.runs (tenant_id, organization_id, execution_context_id, agent_revision_id,"
                    " application_environment_id, trigger_kind, idempotency_key, deadline_at, created_by, updated_by)"
                    " values (%s, %s, %s, %s, %s, %s, %s, now() + interval '1 hour', %s, %s) returning run_id",
                    (t.id, t.org, ctx, revision or w["revision"], w["env"], trigger, key or unique("k"), ACTOR, ACTOR))
        return cur.fetchone()[0]


# ---------------------------------------------------------------------------
def test_installed_and_rerun_is_noop(hm, module_notices):
    assert any("Migration 003" in n and "67 AI tables" in n for n in module_notices)
    conn = psycopg2.connect(dsn_for(hm.dbname, INSTALLER_ROLE))
    conn.autocommit = True
    conn.cursor().execute(M003.read_text(encoding="utf-8"))
    assert any("Verified no-op" in n for n in conn.notices)
    conn.close()


def test_publication_moves_pointer_and_definitions_are_explicit(t, world):
    w = world
    with as_user(t, w["builder"], w["bs"]) as cur:
        cur.execute("select current_revision_id from cob3_agent.agents where agent_id = %s", (w["agent"],))
        assert cur.fetchone()[0] == w["revision"]
    # An org-wide ai_user role does not open explicit AI resources.
    with as_user(t, w["outsider"], w["os"]) as cur:
        cur.execute("select count(*) from cob3_agent.agents where agent_id = %s", (w["agent"],))
        assert cur.fetchone()[0] == 0
        cur.execute("select count(*) from cob3_catalog.assets where asset_id = %s", (w["agent_asset"],))
        assert cur.fetchone()[0] == 0


def test_revision_bindings_are_sealed(t, world):
    w = world
    with as_user(t, w["builder"], w["bs"]) as cur:
        expect_error(cur, "insert into cob3_agent.agent_tool_bindings (tenant_id, organization_id, agent_revision_id, tool_revision_id,"
                          " requires_approval, limits, created_by, updated_by) values (%s, %s, %s, %s, false, '{}', %s, %s)",
                     (t.id, t.org, w["revision"], w["tool_rev2"], ACTOR, ACTOR), "SKIMM")
        expect_error(cur, "update cob3_agent.agent_revisions set change_note = 'x' where agent_revision_id = %s", (w["revision"],), "42501")


def test_double_publish_and_builder_self_release_rejected(t, world):
    w = world
    with as_user(t, w["reviewer"], w["rs"]) as cur:
        expect_error(cur, "insert into cob3_agent.releases (tenant_id, organization_id, agent_revision_id, action, approved_by_principal_id,"
                          " reason, created_by, updated_by) values (%s, %s, %s, 'publish', %s, 'again', %s, %s)",
                     (t.id, t.org, w["revision"], w["reviewer"], ACTOR, ACTOR), "SKSTA")
    with as_user(t, w["builder"], w["bs"]) as cur:
        expect_error(cur, "insert into cob3_agent.releases (tenant_id, organization_id, agent_revision_id, action, approved_by_principal_id,"
                          " reason, created_by, updated_by) values (%s, %s, %s, 'revoke', %s, 'self', %s, %s)",
                     (t.id, t.org, w["revision"], w["builder"], ACTOR, ACTOR), "42501")


def test_run_visibility_and_context_ownership(t, world):
    w = world
    run = start_run(t, w)
    with as_user(t, w["builder"], w["bs"]) as cur:
        cur.execute("select status from cob3_ai_runtime.runs where run_id = %s", (run,))
        assert cur.fetchone()[0] == "queued"
    with as_user(t, w["outsider"], w["os"]) as cur:
        cur.execute("select count(*) from cob3_ai_runtime.runs where run_id = %s", (run,))
        assert cur.fetchone()[0] == 0
        # Cannot create a context for someone else.
        expect_error(cur, "insert into cob3_ai_runtime.execution_contexts (tenant_id, organization_id, initiator_principal_id,"
                          " execution_principal_id, auth_session_id, audience, valid_until, authority_ceiling, ceiling_sha256,"
                          " authorization_evidence, created_by, updated_by) values (%s, %s, %s, %s, %s, 'x', now() + interval '1 hour',"
                          " '{}', %s, '{}', %s, %s)",
                     (t.id, t.org, w["builder"], w["builder"], w["bs"], sha_hex("c"), ACTOR, ACTOR), "42501")


def test_unpublished_revision_cannot_run(t, world):
    w = world
    with as_user(t, w["builder"], w["bs"]) as cur:
        cur.execute("insert into cob3_agent.agent_revisions (tenant_id, organization_id, agent_id, revision, prompt_version_id, model_deployment_id,"
                    " model_config, execution_contract, memory_policy, autonomy_level, max_steps, max_duration_seconds, max_cost, currency,"
                    " content_sha256, change_note, created_by, updated_by) values (%s, %s, %s, 2, %s, %s, '{}', '{}', '{}', 1, 10, 600, 5, 'USD',"
                    " %s, 'draft', %s, %s) returning agent_revision_id",
                    (t.id, t.org, w["agent"], w["prompt_version"], w["deployment"], sha_hex("a2"), ACTOR, ACTOR))
        draft = cur.fetchone()[0]
    with pytest.raises(psycopg2.Error) as exc:
        start_run(t, w, revision=draft)
    assert exc.value.pgcode == "SKSTA"


def test_fencing_and_event_sequence(t, world):
    w = world
    run = start_run(t, w)
    conn, cur = worker(t)
    cur.execute("insert into cob3_ai_runtime.run_attempts (tenant_id, organization_id, run_id, attempt_number, worker_principal_id, status,"
                " fencing_token, created_by, updated_by) values (%s, %s, %s, 1, %s, 'running', 1, 'system:w', 'system:w') returning run_attempt_id",
                (t.id, t.org, run, w["svc"]))
    cur.execute("update cob3_ai_runtime.run_attempts set status = 'lost' where run_id = %s", (run,))
    expect_error(cur, "insert into cob3_ai_runtime.run_attempts (tenant_id, organization_id, run_id, attempt_number, worker_principal_id, status,"
                      " fencing_token, created_by, updated_by) values (%s, %s, %s, 2, %s, 'running', 1, 'system:w', 'system:w')",
                 (t.id, t.org, run, w["svc"]), "SKINV")
    cur.execute("insert into cob3_ai_runtime.run_attempts (tenant_id, organization_id, run_id, attempt_number, worker_principal_id, status,"
                " fencing_token, created_by, updated_by) values (%s, %s, %s, 2, %s, 'running', 2, 'system:w', 'system:w')",
                (t.id, t.org, run, w["svc"]))
    cur.execute("insert into cob3_ai_runtime.run_events (tenant_id, organization_id, run_id, sequence, occurred_at, event_type, schema_version,"
                " payload, created_by, updated_by) values (%s, %s, %s, 1, now(), 'run.started', 1, '{}', 'system:w', 'system:w')", (t.id, t.org, run))
    expect_error(cur, "insert into cob3_ai_runtime.run_events (tenant_id, organization_id, run_id, sequence, occurred_at, event_type,"
                      " schema_version, payload, created_by, updated_by) values (%s, %s, %s, 3, now(), 'x', 1, '{}', 'system:w', 'system:w')",
                 (t.id, t.org, run), "SKINV")
    conn.commit()
    conn.close()
    # Terminal outcome is frozen.
    conn, cur = worker(t)
    cur.execute("update cob3_ai_runtime.runs set status = 'running', started_at = now() where run_id = %s", (run,))
    cur.execute("update cob3_ai_runtime.runs set status = 'succeeded', ended_at = now() where run_id = %s", (run,))
    expect_error(cur, "update cob3_ai_runtime.runs set error_code = 'late' where run_id = %s", (run,), "SKIMM")
    conn.commit()
    conn.close()


def test_tool_action_requires_bound_tool(t, world):
    w = world
    run = start_run(t, w)
    conn, cur = worker(t)
    fid, digest, size = ready_file(t, cur, w["svc"], "args-" + uuid.uuid4().hex)
    cur.execute("insert into cob3_ai_runtime.payloads (tenant_id, organization_id, file_object_id, content_type, schema_key, schema_version,"
                " sha256, size_bytes, classification, created_by, updated_by) values (%s, %s, %s, 'application/json', 'tool.args', 1,"
                " %s, %s, 'internal', 'system:w', 'system:w') returning payload_id", (t.id, t.org, fid, digest, size))
    payload = cur.fetchone()[0]
    cur.execute("insert into cob3_ai_runtime.run_steps (tenant_id, organization_id, run_id, step_key, kind, input_sha256, created_by, updated_by)"
                " values (%s, %s, %s, 'call-1', 'tool', %s, 'system:w', 'system:w') returning step_id", (t.id, t.org, run, sha_hex("in")))
    step = cur.fetchone()[0]
    expect_error(cur, "insert into cob3_ai_runtime.tool_actions (tenant_id, organization_id, step_id, tool_revision_id, arguments_payload_id,"
                      " arguments_sha256, target_manifest, idempotency_key, created_by, updated_by)"
                      " values (%s, %s, %s, %s, %s, %s, '{}', %s, 'system:w', 'system:w')",
                 (t.id, t.org, step, w["tool_rev2"], payload, digest, unique("idem")), "SKINV")
    cur.execute("insert into cob3_ai_runtime.tool_actions (tenant_id, organization_id, step_id, tool_revision_id, arguments_payload_id,"
                " arguments_sha256, target_manifest, idempotency_key, created_by, updated_by)"
                " values (%s, %s, %s, %s, %s, %s, '{}', %s, 'system:w', 'system:w')",
                (t.id, t.org, step, w["tool_rev1"], payload, digest, unique("idem")))
    conn.commit()
    conn.close()


def test_conversation_messages_roles(t, world):
    w = world
    with as_user(t, w["builder"], w["bs"]) as cur:
        cur.execute("select cob3_catalog.register_asset('conversation', %s, 'Chat')", (unique("cv"),))
        asset = cur.fetchone()[0]
        cur.execute("insert into cob3_copilot.threads (tenant_id, organization_id, asset_id, origin_surface, created_by, updated_by)"
                    " values (%s, %s, %s, 'web', %s, %s) returning thread_id", (t.id, t.org, asset, ACTOR, ACTOR))
        thread = cur.fetchone()[0]
        cur.execute("insert into cob3_copilot.branches (tenant_id, organization_id, thread_id, created_by, updated_by)"
                    " values (%s, %s, %s, %s, %s) returning branch_id", (t.id, t.org, thread, ACTOR, ACTOR))
        branch = cur.fetchone()[0]
    conn, wcur = worker(t)
    fid, digest, size = ready_file(t, wcur, w["builder"], "hello-" + uuid.uuid4().hex)
    conn.commit()
    conn.close()
    with as_user(t, w["builder"], w["bs"]) as cur:
        cur.execute("insert into cob3_ai_runtime.payloads (tenant_id, organization_id, file_object_id, content_type, schema_key, schema_version,"
                    " sha256, size_bytes, classification, created_by, updated_by) values (%s, %s, %s, 'application/json', 'chat.message', 1,"
                    " %s, %s, 'internal', %s, %s) returning payload_id", (t.id, t.org, fid, digest, size, ACTOR, ACTOR))
        payload = cur.fetchone()[0]
        cur.execute("insert into cob3_copilot.messages (tenant_id, organization_id, thread_id, branch_id, author_principal_id, role,"
                    " content_payload_id, sequence, created_by, updated_by) values (%s, %s, %s, %s, %s, 'user', %s, 1, %s, %s)",
                    (t.id, t.org, thread, branch, w["builder"], payload, ACTOR, ACTOR))
        expect_error(cur, "insert into cob3_copilot.messages (tenant_id, organization_id, thread_id, branch_id, role, content_payload_id,"
                          " sequence, created_by, updated_by) values (%s, %s, %s, %s, 'system', %s, 2, %s, %s)",
                     (t.id, t.org, thread, branch, payload, ACTOR, ACTOR), "SKAUZ")
    with as_user(t, w["outsider"], w["os"]) as cur:
        cur.execute("select count(*) from cob3_copilot.messages where thread_id = %s", (thread,))
        assert cur.fetchone()[0] == 0


def test_lineage_nodes_need_backing_rows_and_edges_no_cycles(t, world):
    w = world
    run = start_run(t, w)
    conn, cur = worker(t)
    expect_error(cur, "insert into cob3_ai_lineage.nodes (tenant_id, organization_id, node_kind, entity_id, created_by, updated_by)"
                      " values (%s, %s, 'run', gen_random_uuid(), 'system:w', 'system:w')", (t.id, t.org), "SKINV")
    expect_error(cur, "insert into cob3_ai_lineage.nodes (tenant_id, organization_id, node_kind, entity_id, created_by, updated_by)"
                      " values (%s, %s, 'free_text', %s, 'system:w', 'system:w')", (t.id, t.org, run), "SKINV")
    cur.execute("insert into cob3_ai_lineage.nodes (tenant_id, organization_id, node_kind, entity_id, created_by, updated_by)"
                " values (%s, %s, 'run', %s, 'system:w', 'system:w') returning lineage_node_id", (t.id, t.org, run))
    a = cur.fetchone()[0]
    cur.execute("insert into cob3_ai_lineage.nodes (tenant_id, organization_id, node_kind, entity_id, created_by, updated_by)"
                " values (%s, %s, 'agent_revision', %s, 'system:w', 'system:w') returning lineage_node_id", (t.id, t.org, w["revision"]))
    b = cur.fetchone()[0]
    cur.execute("insert into cob3_ai_lineage.edges (tenant_id, organization_id, source_node_id, derived_node_id, relation, transformation_key,"
                " dependency_kind, created_by, updated_by) values (%s, %s, %s, %s, 'derived_from', 'x.v1', 'access_dependency', 'system:w', 'system:w')",
                (t.id, t.org, b, a))
    expect_error(cur, "insert into cob3_ai_lineage.edges (tenant_id, organization_id, source_node_id, derived_node_id, relation, transformation_key,"
                      " dependency_kind, created_by, updated_by) values (%s, %s, %s, %s, 'derived_from', 'y.v1', 'access_dependency', 'system:w', 'system:w')",
                 (t.id, t.org, a, b), "SKINV")
    conn.commit()
    conn.close()


def test_llm_accounting_rules(t, world):
    w = world
    conn, cur = worker(t)
    cur.execute("insert into cob3_llmobs.invocations (tenant_id, organization_id, application_environment_id, source_system, source_call_id,"
                " status, started_at, policy_version_id, created_by, updated_by) values (%s, %s, %s, 'portkey', %s, 'succeeded', now(), %s,"
                " 'system:w', 'system:w') returning invocation_id", (t.id, t.org, w["env"], unique("call"), w["policy"]))
    inv = cur.fetchone()[0]
    # Unknown usage is NULL, never zero/fabricated.
    expect_error(cur, "insert into cob3_llmobs.invocation_attempts (tenant_id, organization_id, invocation_id, attempt_number, provider,"
                      " provider_model_id, outcome, started_at, usage_status, input_tokens, usage_dimensions, created_by, updated_by)"
                      " values (%s, %s, %s, 1, 'anthropic', 'm', 'succeeded', now(), 'unknown', 5, '{}', 'system:w', 'system:w')",
                 (t.id, t.org, inv), "23514")
    # Cache tokens are an input subset.
    expect_error(cur, "insert into cob3_llmobs.invocation_attempts (tenant_id, organization_id, invocation_id, attempt_number, provider,"
                      " provider_model_id, outcome, started_at, usage_status, input_tokens, output_tokens, cache_read_tokens, usage_dimensions,"
                      " created_by, updated_by) values (%s, %s, %s, 1, 'anthropic', 'm', 'succeeded', now(), 'known', 10, 5, 20, '{}',"
                      " 'system:w', 'system:w')", (t.id, t.org, inv), "23514")
    conn.commit()
    conn.close()
    with as_user(t, w["builder"], w["bs"]) as cur:
        cur.execute("insert into cob3_llmobs.model_prices (tenant_id, organization_id, provider, model_key, price_dimension, unit_quantity,"
                    " unit_price, currency, valid_from, valid_until, source_reference, created_by, updated_by) values (%s, %s, 'anthropic', 'm',"
                    " 'input', 1000000, 3, 'USD', '2026-01-01', '2027-01-01', 'contract 1', %s, %s)", (t.id, t.org, ACTOR, ACTOR))
        expect_error(cur, "insert into cob3_llmobs.model_prices (tenant_id, organization_id, provider, model_key, price_dimension, unit_quantity,"
                          " unit_price, currency, valid_from, valid_until, source_reference, created_by, updated_by) values (%s, %s, 'anthropic',"
                          " 'm', 'input', 1000000, 2, 'USD', '2026-06-01', '2026-09-01', 'overlap', %s, %s)", (t.id, t.org, ACTOR, ACTOR), "23P01")


def test_zero_retention_policy_cannot_capture(t, world):
    w = world
    with as_user(t, w["builder"], w["bs"]) as cur:
        expect_error(cur, "insert into cob3_llmobs.policy_versions (tenant_id, organization_id, application_environment_id, version,"
                          " capture_prompts, content_retention_days, metadata_retention_days, sampling_rate, guardrail_config, redaction_config,"
                          " evaluation_config, policy_sha256, created_by, updated_by) values (%s, %s, %s, 2, true, 0, 30, 1, '{}', '{}', '{}', %s, %s, %s)",
                     (t.id, t.org, w["env"], sha_hex("p2"), ACTOR, ACTOR), "23514")
