-- =============================================================================
-- 40  AI ASSET TYPES, PERMISSIONS, RESOLVER HELPERS, RLS, GRANTS, RECORD
-- -----------------------------------------------------------------------------
-- Resource sharing uses Catalog assets with authorization_mode = 'explicit'
-- (design section 4): agent, prompt, tool, skill, conversation, memory
-- container, AI dataset, AI application and connector connection. Every
-- runtime read/write of an AI row is checked against a LIVE Identity decision
-- on the governing asset (or the caller's own run), never a cached grant.
-- =============================================================================
PERFORM cob3_identity.set_system_context('system:migration-003');

INSERT INTO cob3_catalog.asset_types
       (type_code, name, owning_module, attributes_schema, subtype_table, read_permission_code, write_permission_code,
        create_permission_code, owner_role_code, created_by, updated_by)
SELECT v.*, 'system:migration-003', 'system:migration-003'
  FROM (VALUES
    ('agent',                'AI agent',             'ai', '{}'::jsonb, 'cob3_agent.agents',            'ai.agent.read',        'ai.agent.edit',          'ai.agent.edit',          'ai_resource_owner'),
    ('prompt',               'Prompt template',      'ai', '{}'::jsonb, 'cob3_agent.prompt_templates',  'ai.prompt.read',       'ai.prompt.edit',         'ai.prompt.edit',         'ai_resource_owner'),
    ('tool',                 'AI tool',              'ai', '{}'::jsonb, 'cob3_agent.tools',             'ai.tool.read',         'ai.tool.edit',           'ai.tool.edit',           'ai_resource_owner'),
    ('skill',                'AI skill',             'ai', '{}'::jsonb, 'cob3_agent.skills',            'ai.skill.read',        'ai.skill.edit',          'ai.skill.edit',          'ai_resource_owner'),
    ('conversation',         'Conversation',         'ai', '{}'::jsonb, 'cob3_copilot.threads',         'ai.conversation.read', 'ai.conversation.write',  'ai.conversation.write',  'ai_resource_owner'),
    ('memory_container',     'Memory container',     'ai', '{}'::jsonb, 'cob3_memory.containers',       'ai.memory.read',       'ai.memory.manage',       'ai.memory.manage',       'ai_resource_owner'),
    ('ai_dataset',           'AI dataset',           'ai', '{}'::jsonb, 'cob3_learning.datasets',       'ai.dataset.read',      'ai.dataset.curate',      'ai.dataset.curate',      'ai_resource_owner'),
    ('ai_application',       'AI application',       'ai', '{}'::jsonb, 'cob3_llmobs.applications',     'ai.telemetry.read',    'ai.application.manage',  'ai.application.manage',  'ai_resource_owner'),
    ('connector_connection', 'Connector connection', 'ai', '{}'::jsonb, 'cob3_connectors.connections',  'ai.connector.manage',  'ai.connector.manage',    'ai.connector.manage',    'ai_resource_owner')
  ) AS v(type_code, name, owning_module, attributes_schema, subtype_table, read_permission_code, write_permission_code,
         create_permission_code, owner_role_code);

-- ---------------------------------------------------------------------------
-- Permission and role templates (design section 4). resource_type = asset type
-- code the permission is checked against; organization-level operations
-- (creation, model/retention/review administration) target the organization.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cob3_agent.module_permission_templates()
    RETURNS TABLE (permission_code text, resource_type text, action text, permission_class text,
                   is_delegable boolean, automation_allowed boolean, is_identity_management boolean, description text)
    LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp
AS $fn$
    VALUES
        ('ai.agent.read',             'agent',                'read',            'organization', true,  true,  false, 'Read an agent definition and its revisions'),
        ('ai.agent.edit',             'agent',                'edit',            'organization', true,  false, false, 'Create agents and author revisions'),
        ('ai.agent.publish',          'agent',                'publish',         'organization', false, false, false, 'Request publication of an agent revision'),
        ('ai.agent.invoke',           'agent',                'invoke',          'organization', true,  true,  false, 'Start runs of an agent'),
        ('ai.prompt.read',            'prompt',               'read',            'organization', true,  true,  false, 'Read prompt templates'),
        ('ai.prompt.edit',            'prompt',               'edit',            'organization', true,  false, false, 'Author prompt versions'),
        ('ai.tool.read',              'tool',                 'read',            'organization', true,  true,  false, 'Read tool definitions'),
        ('ai.tool.edit',              'tool',                 'edit',            'organization', true,  false, false, 'Author tool revisions'),
        ('ai.tool.invoke',            'tool',                 'invoke',          'organization', true,  true,  false, 'Invoke a tool (each target action is checked separately)'),
        ('ai.skill.read',             'skill',                'read',            'organization', true,  true,  false, 'Read skills'),
        ('ai.skill.edit',             'skill',                'edit',            'organization', true,  false, false, 'Author skill versions'),
        ('ai.run.read',               'agent',                'run_read',        'organization', true,  true,  false, 'Read runs of an agent'),
        ('ai.run.cancel',             'agent',                'run_cancel',      'organization', true,  true,  false, 'Request cancellation of runs of an agent'),
        ('ai.run.resume',             'agent',                'run_resume',      'organization', true,  true,  false, 'Resolve interrupts and resume runs of an agent'),
        ('ai.conversation.read',      'conversation',         'read',            'organization', true,  true,  false, 'Read a conversation'),
        ('ai.conversation.write',     'conversation',         'write',           'organization', true,  true,  false, 'Create conversations and post messages'),
        ('ai.conversation.share',     'conversation',         'share',           'organization', false, false, true,  'Share a conversation (IAM-related)'),
        ('ai.memory.read',            'memory_container',     'read',            'organization', true,  true,  false, 'Read memories of a container'),
        ('ai.memory.propose',         'memory_container',     'propose',         'organization', true,  true,  false, 'Propose candidate memories'),
        ('ai.memory.approve',         'memory_container',     'approve',         'organization', false, false, false, 'Review and approve memories'),
        ('ai.memory.delete',          'memory_container',     'delete',          'organization', false, false, false, 'Retract or purge memories'),
        ('ai.memory.manage',          'memory_container',     'manage',          'organization', true,  false, false, 'Create and configure memory containers'),
        ('ai.feedback.create',        'ai_feedback',          'create',          'organization', true,  true,  false, 'Submit feedback and annotations'),
        ('ai.dataset.read',           'ai_dataset',           'read',            'organization', true,  true,  false, 'Read AI datasets'),
        ('ai.dataset.curate',         'ai_dataset',           'curate',          'organization', true,  false, false, 'Curate dataset versions and examples'),
        ('ai.dataset.export',         'ai_dataset',           'export',          'organization', false, false, false, 'Export or declassify derived data (reviewed)'),
        ('ai.evaluation.run',         'ai_dataset',           'evaluate',        'organization', true,  true,  false, 'Run evaluations against a dataset'),
        ('ai.training.submit',        'ai_dataset',           'train',           'organization', false, false, false, 'Submit fine-tuning exports'),
        ('ai.release.approve',        'asset',                'approve_release', 'organization', false, false, false, 'Publish or revoke agent/skill/prompt versions'),
        ('ai.telemetry.read',         'ai_application',       'read',            'organization', true,  true,  false, 'Read AI application telemetry metadata'),
        ('ai.telemetry.read_content', 'ai_application',       'read_content',    'organization', false, false, false, 'Read captured AI content and guardrail evidence'),
        ('ai.application.manage',     'ai_application',       'manage',          'organization', true,  false, false, 'Configure AI applications, environments and capture policies'),
        ('ai.model.manage',           'ai_model',             'manage',          'organization', true,  false, false, 'Manage model deployments and contract prices'),
        ('ai.connector.manage',       'connector_connection', 'manage',          'organization', true,  false, false, 'Manage connector connections and scope bindings'),
        ('ai.connector.run',          'connector_connection', 'run',             'organization', true,  true,  false, 'Trigger connector jobs'),
        ('ai.review.manage',          'ai_review',            'manage',          'organization', true,  false, false, 'Create and assign AI review tasks'),
        ('ai.retention.manage',       'ai_retention',         'manage',          'organization', false, false, false, 'Place and release retention holds'),
        ('ai.lineage.read',           'ai_lineage',           'read',            'organization', true,  true,  false, 'Read the AI lineage registry')
$fn$;

CREATE FUNCTION cob3_agent.module_role_templates()
    RETURNS TABLE (role_code text, role_name text, role_class text, permission_code text)
    LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT r.role_code, r.role_name, r.role_class, p.permission_code
      FROM (VALUES
              ('ai_user', 'AI user', 'organization',
               ARRAY['ai.agent.read', 'ai.agent.invoke', 'ai.prompt.read', 'ai.tool.read', 'ai.tool.invoke', 'ai.skill.read',
                     'ai.run.read', 'ai.run.cancel', 'ai.run.resume', 'ai.conversation.read', 'ai.conversation.write',
                     'ai.memory.read', 'ai.memory.propose', 'ai.feedback.create', 'ai.dataset.read', 'ai.telemetry.read']),
              ('ai_builder', 'AI builder', 'organization',
               ARRAY['ai.agent.read', 'ai.agent.edit', 'ai.agent.invoke', 'ai.prompt.read', 'ai.prompt.edit', 'ai.tool.read',
                     'ai.tool.edit', 'ai.tool.invoke', 'ai.skill.read', 'ai.skill.edit', 'ai.run.read', 'ai.run.cancel',
                     'ai.run.resume', 'ai.conversation.read', 'ai.conversation.write', 'ai.memory.read', 'ai.memory.propose',
                     'ai.memory.manage', 'ai.feedback.create', 'ai.dataset.read', 'ai.dataset.curate', 'ai.evaluation.run',
                     'ai.telemetry.read', 'ai.application.manage', 'ai.connector.manage', 'ai.connector.run']),
              ('ai_resource_owner', 'AI resource owner', 'organization',
               ARRAY['ai.agent.read', 'ai.agent.edit', 'ai.agent.invoke', 'ai.run.read', 'ai.run.cancel', 'ai.run.resume',
                     'ai.prompt.read', 'ai.prompt.edit', 'ai.tool.read', 'ai.tool.edit', 'ai.tool.invoke', 'ai.skill.read',
                     'ai.skill.edit', 'ai.conversation.read', 'ai.conversation.write', 'ai.conversation.share', 'ai.memory.read',
                     'ai.memory.propose', 'ai.memory.manage', 'ai.dataset.read', 'ai.dataset.curate', 'ai.evaluation.run',
                     'ai.telemetry.read', 'ai.application.manage', 'ai.connector.manage', 'ai.connector.run', 'asset.share']),
              ('ai_reviewer', 'AI reviewer', 'organization',
               ARRAY['ai.release.approve', 'ai.memory.approve', 'ai.telemetry.read_content', 'ai.review.manage', 'ai.lineage.read']),
              ('ai_administrator', 'AI administrator', 'organization',
               ARRAY['ai.model.manage', 'ai.retention.manage', 'ai.review.manage', 'ai.lineage.read', 'ai.dataset.export',
                     'ai.training.submit', 'ai.memory.delete'])
           ) AS r(role_code, role_name, role_class, perms)
     CROSS JOIN LATERAL pg_catalog.unnest(r.perms) AS p(permission_code)
$fn$;

CREATE OR REPLACE FUNCTION cob3_identity.core_permission_templates()
    RETURNS TABLE (permission_code text, resource_type text, action text, permission_class text,
                   is_delegable boolean, automation_allowed boolean, is_identity_management boolean, description text)
    LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT * FROM cob3_identity.foundation_permission_templates()
    UNION ALL SELECT * FROM cob3_catalog.module_permission_templates()
    UNION ALL SELECT * FROM cob3_agent.module_permission_templates()
$fn$;

CREATE OR REPLACE FUNCTION cob3_identity.core_role_templates()
    RETURNS TABLE (role_code text, role_name text, role_class text, permission_code text)
    LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT * FROM cob3_identity.foundation_role_templates()
    UNION ALL SELECT * FROM cob3_catalog.module_role_templates()
    UNION ALL SELECT * FROM cob3_agent.module_role_templates()
$fn$;

FOR _m_rec IN SELECT t.tenant_id FROM cob3_tenant.tenants t ORDER BY t.tenant_id LOOP
    PERFORM cob3_identity.provision_tenant_iam_seed(_m_rec.tenant_id, 'system:migration-003');
END LOOP;
PERFORM cob3_identity.set_system_context('system:migration-003');

-- ---------------------------------------------------------------------------
-- Resolver helpers (evaluated with the request context; SECURITY DEFINER so
-- they can traverse parents independently of the caller's own row visibility).
-- ---------------------------------------------------------------------------
-- Governing Catalog asset of an AI row of the given kind.
CREATE FUNCTION cob3_ai_lineage.asset_of(p_kind text, p_organization_id uuid, p_id uuid)
    RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    t uuid := cob3_identity.ctx_tenant_id();
    o uuid := p_organization_id;
    v uuid;
BEGIN
    CASE p_kind
        WHEN 'agent' THEN
            SELECT a.asset_id INTO v FROM cob3_agent.agents a WHERE a.tenant_id = t AND a.organization_id = o AND a.agent_id = p_id;
        WHEN 'agent_revision' THEN
            SELECT a.asset_id INTO v FROM cob3_agent.agent_revisions r
              JOIN cob3_agent.agents a ON a.tenant_id = r.tenant_id AND a.organization_id = r.organization_id AND a.agent_id = r.agent_id
             WHERE r.tenant_id = t AND r.organization_id = o AND r.agent_revision_id = p_id;
        WHEN 'prompt_template' THEN
            SELECT p.asset_id INTO v FROM cob3_agent.prompt_templates p WHERE p.tenant_id = t AND p.organization_id = o AND p.prompt_template_id = p_id;
        WHEN 'prompt_version' THEN
            SELECT p.asset_id INTO v FROM cob3_agent.prompt_versions x
              JOIN cob3_agent.prompt_templates p ON p.tenant_id = x.tenant_id AND p.organization_id = x.organization_id AND p.prompt_template_id = x.prompt_template_id
             WHERE x.tenant_id = t AND x.organization_id = o AND x.prompt_version_id = p_id;
        WHEN 'tool' THEN
            SELECT x.asset_id INTO v FROM cob3_agent.tools x WHERE x.tenant_id = t AND x.organization_id = o AND x.tool_id = p_id;
        WHEN 'tool_revision' THEN
            SELECT x.asset_id INTO v FROM cob3_agent.tool_revisions r
              JOIN cob3_agent.tools x ON x.tenant_id = r.tenant_id AND x.organization_id = r.organization_id AND x.tool_id = r.tool_id
             WHERE r.tenant_id = t AND r.organization_id = o AND r.tool_revision_id = p_id;
        WHEN 'skill' THEN
            SELECT x.asset_id INTO v FROM cob3_agent.skills x WHERE x.tenant_id = t AND x.organization_id = o AND x.skill_id = p_id;
        WHEN 'skill_version' THEN
            SELECT x.asset_id INTO v FROM cob3_agent.skill_versions r
              JOIN cob3_agent.skills x ON x.tenant_id = r.tenant_id AND x.organization_id = r.organization_id AND x.skill_id = r.skill_id
             WHERE r.tenant_id = t AND r.organization_id = o AND r.skill_version_id = p_id;
        WHEN 'thread' THEN
            SELECT x.asset_id INTO v FROM cob3_copilot.threads x WHERE x.tenant_id = t AND x.organization_id = o AND x.thread_id = p_id;
        WHEN 'message' THEN
            SELECT x.asset_id INTO v FROM cob3_copilot.messages m
              JOIN cob3_copilot.threads x ON x.tenant_id = m.tenant_id AND x.organization_id = m.organization_id AND x.thread_id = m.thread_id
             WHERE m.tenant_id = t AND m.organization_id = o AND m.message_id = p_id;
        WHEN 'container' THEN
            SELECT x.asset_id INTO v FROM cob3_memory.containers x WHERE x.tenant_id = t AND x.organization_id = o AND x.container_id = p_id;
        WHEN 'memory_item' THEN
            SELECT x.asset_id INTO v FROM cob3_memory.items i
              JOIN cob3_memory.containers x ON x.tenant_id = i.tenant_id AND x.organization_id = i.organization_id AND x.container_id = i.container_id
             WHERE i.tenant_id = t AND i.organization_id = o AND i.memory_id = p_id;
        WHEN 'memory_revision' THEN
            SELECT x.asset_id INTO v FROM cob3_memory.item_revisions r
              JOIN cob3_memory.items i ON i.tenant_id = r.tenant_id AND i.organization_id = r.organization_id AND i.memory_id = r.memory_id
              JOIN cob3_memory.containers x ON x.tenant_id = i.tenant_id AND x.organization_id = i.organization_id AND x.container_id = i.container_id
             WHERE r.tenant_id = t AND r.organization_id = o AND r.memory_revision_id = p_id;
        WHEN 'dataset' THEN
            SELECT x.asset_id INTO v FROM cob3_learning.datasets x WHERE x.tenant_id = t AND x.organization_id = o AND x.dataset_id = p_id;
        WHEN 'dataset_version' THEN
            SELECT x.asset_id INTO v FROM cob3_learning.dataset_versions r
              JOIN cob3_learning.datasets x ON x.tenant_id = r.tenant_id AND x.organization_id = r.organization_id AND x.dataset_id = r.dataset_id
             WHERE r.tenant_id = t AND r.organization_id = o AND r.dataset_version_id = p_id;
        WHEN 'evaluation_run' THEN
            SELECT x.asset_id INTO v FROM cob3_learning.evaluation_runs e
              JOIN cob3_learning.dataset_versions r ON r.tenant_id = e.tenant_id AND r.organization_id = e.organization_id AND r.dataset_version_id = e.dataset_version_id
              JOIN cob3_learning.datasets x ON x.tenant_id = r.tenant_id AND x.organization_id = r.organization_id AND x.dataset_id = r.dataset_id
             WHERE e.tenant_id = t AND e.organization_id = o AND e.evaluation_run_id = p_id;
        WHEN 'application' THEN
            SELECT x.asset_id INTO v FROM cob3_llmobs.applications x WHERE x.tenant_id = t AND x.organization_id = o AND x.application_id = p_id;
        WHEN 'environment' THEN
            SELECT x.asset_id INTO v FROM cob3_llmobs.application_environments e
              JOIN cob3_llmobs.applications x ON x.tenant_id = e.tenant_id AND x.organization_id = e.organization_id AND x.application_id = e.application_id
             WHERE e.tenant_id = t AND e.organization_id = o AND e.application_environment_id = p_id;
        WHEN 'policy_version' THEN
            SELECT x.asset_id INTO v FROM cob3_llmobs.policy_versions pv
              JOIN cob3_llmobs.application_environments e ON e.tenant_id = pv.tenant_id AND e.organization_id = pv.organization_id AND e.application_environment_id = pv.application_environment_id
              JOIN cob3_llmobs.applications x ON x.tenant_id = e.tenant_id AND x.organization_id = e.organization_id AND x.application_id = e.application_id
             WHERE pv.tenant_id = t AND pv.organization_id = o AND pv.policy_version_id = p_id;
        WHEN 'invocation' THEN
            SELECT x.asset_id INTO v FROM cob3_llmobs.invocations i
              JOIN cob3_llmobs.application_environments e ON e.tenant_id = i.tenant_id AND e.organization_id = i.organization_id AND e.application_environment_id = i.application_environment_id
              JOIN cob3_llmobs.applications x ON x.tenant_id = e.tenant_id AND x.organization_id = e.organization_id AND x.application_id = e.application_id
             WHERE i.tenant_id = t AND i.organization_id = o AND i.invocation_id = p_id;
        WHEN 'invocation_attempt' THEN
            SELECT x.asset_id INTO v FROM cob3_llmobs.invocation_attempts ia
              JOIN cob3_llmobs.invocations i ON i.tenant_id = ia.tenant_id AND i.organization_id = ia.organization_id AND i.invocation_id = ia.invocation_id
              JOIN cob3_llmobs.application_environments e ON e.tenant_id = i.tenant_id AND e.organization_id = i.organization_id AND e.application_environment_id = i.application_environment_id
              JOIN cob3_llmobs.applications x ON x.tenant_id = e.tenant_id AND x.organization_id = e.organization_id AND x.application_id = e.application_id
             WHERE ia.tenant_id = t AND ia.organization_id = o AND ia.invocation_attempt_id = p_id;
        WHEN 'connection' THEN
            SELECT x.asset_id INTO v FROM cob3_connectors.connections x WHERE x.tenant_id = t AND x.organization_id = o AND x.connection_id = p_id;
        WHEN 'job' THEN
            SELECT x.asset_id INTO v FROM cob3_connectors.jobs j
              JOIN cob3_connectors.connections x ON x.tenant_id = j.tenant_id AND x.organization_id = j.organization_id AND x.connection_id = j.connection_id
             WHERE j.tenant_id = t AND j.organization_id = o AND j.connector_job_id = p_id;
        ELSE
            RAISE EXCEPTION USING ERRCODE = 'SKINV', MESSAGE = pg_catalog.format('Unknown AI resource kind %L.', p_kind);
    END CASE;
    RETURN v;
END
$fn$;

CREATE FUNCTION cob3_ai_lineage.ctx_permitted(p_kind text, p_organization_id uuid, p_id uuid, p_permission_code text)
    RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE(cob3_catalog.ctx_asset_permitted(p_organization_id, cob3_ai_lineage.asset_of(p_kind, p_organization_id, p_id),
                                                     p_permission_code), false)
$fn$;

-- A run is visible to its initiator and execution principal, to holders of
-- ai.run.read on its agent, and to readers of its conversation. The column
-- form is used by the runs SELECT policy itself (a row being inserted with
-- RETURNING is not yet visible to a lookup by id).
CREATE FUNCTION cob3_ai_runtime.ctx_can_read_run_row(p_organization_id uuid, p_execution_context_id uuid,
                                                     p_agent_revision_id uuid, p_thread_id uuid)
    RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT (EXISTS (SELECT 1 FROM cob3_ai_runtime.execution_contexts c
                     WHERE c.tenant_id = cob3_identity.ctx_tenant_id() AND c.organization_id = p_organization_id
                       AND c.execution_context_id = p_execution_context_id
                       AND cob3_identity.ctx_principal_id() IN (c.initiator_principal_id, c.execution_principal_id))
            OR cob3_ai_lineage.ctx_permitted('agent_revision', p_organization_id, p_agent_revision_id, 'ai.run.read')
            OR (p_thread_id IS NOT NULL AND cob3_ai_lineage.ctx_permitted('thread', p_organization_id, p_thread_id, 'ai.conversation.read')))
       AND cob3_identity.ctx_auth_valid()
$fn$;

CREATE FUNCTION cob3_ai_runtime.ctx_can_read_run(p_organization_id uuid, p_run_id uuid)
    RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((
        SELECT cob3_ai_runtime.ctx_can_read_run_row(r.organization_id, r.execution_context_id, r.agent_revision_id, r.thread_id)
          FROM cob3_ai_runtime.runs r
         WHERE r.tenant_id = cob3_identity.ctx_tenant_id() AND r.organization_id = p_organization_id AND r.run_id = p_run_id), false)
$fn$;

-- Run of a runtime child row.
CREATE FUNCTION cob3_ai_runtime.run_of(p_kind text, p_organization_id uuid, p_id uuid)
    RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT CASE p_kind
        WHEN 'step' THEN (SELECT s.run_id FROM cob3_ai_runtime.run_steps s
                           WHERE s.tenant_id = cob3_identity.ctx_tenant_id() AND s.organization_id = p_organization_id AND s.step_id = p_id)
        WHEN 'checkpoint' THEN (SELECT c.run_id FROM cob3_ai_runtime.checkpoints c
                                 WHERE c.tenant_id = cob3_identity.ctx_tenant_id() AND c.organization_id = p_organization_id AND c.checkpoint_id = p_id)
        WHEN 'tool_action' THEN (SELECT s.run_id FROM cob3_ai_runtime.tool_actions a
                                   JOIN cob3_ai_runtime.run_steps s ON s.tenant_id = a.tenant_id AND s.organization_id = a.organization_id AND s.step_id = a.step_id
                                  WHERE a.tenant_id = cob3_identity.ctx_tenant_id() AND a.organization_id = p_organization_id AND a.tool_action_id = p_id)
        WHEN 'context_assembly' THEN (SELECT s.run_id FROM cob3_ai_runtime.context_assemblies a
                                        JOIN cob3_ai_runtime.run_steps s ON s.tenant_id = a.tenant_id AND s.organization_id = a.organization_id AND s.step_id = a.step_id
                                       WHERE a.tenant_id = cob3_identity.ctx_tenant_id() AND a.organization_id = p_organization_id AND a.context_assembly_id = p_id)
    END
$fn$;

-- Permission on the agent of a run (cancel/resume).
CREATE FUNCTION cob3_ai_runtime.ctx_run_permitted(p_organization_id uuid, p_run_id uuid, p_permission_code text)
    RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE((SELECT cob3_ai_lineage.ctx_permitted('agent_revision', r.organization_id, r.agent_revision_id, p_permission_code)
                       FROM cob3_ai_runtime.runs r
                      WHERE r.tenant_id = cob3_identity.ctx_tenant_id() AND r.organization_id = p_organization_id AND r.run_id = p_run_id), false)
$fn$;

-- The caller created this execution context for itself.
CREATE FUNCTION cob3_ai_runtime.ctx_owns_context(p_organization_id uuid, p_execution_context_id uuid)
    RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (SELECT 1 FROM cob3_ai_runtime.execution_contexts c
                    WHERE c.tenant_id = cob3_identity.ctx_tenant_id() AND c.organization_id = p_organization_id
                      AND c.execution_context_id = p_execution_context_id
                      AND c.initiator_principal_id = cob3_identity.ctx_principal_id()
                      AND c.valid_until > pg_catalog.now())
       AND cob3_identity.ctx_auth_valid()
$fn$;

-- Payload content is reachable only through a resource the caller may read.
CREATE FUNCTION cob3_ai_runtime.ctx_can_read_payload(p_organization_id uuid, p_payload_id uuid, p_file_object_id uuid)
    RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (SELECT 1 FROM cob3_workspace.file_objects f
                    WHERE f.tenant_id = cob3_identity.ctx_tenant_id() AND f.organization_id = p_organization_id
                      AND f.file_object_id = p_file_object_id AND f.uploaded_by_principal_id = cob3_identity.ctx_principal_id())
        OR EXISTS (SELECT 1 FROM cob3_copilot.messages m
                    WHERE m.tenant_id = cob3_identity.ctx_tenant_id() AND m.organization_id = p_organization_id
                      AND m.content_payload_id = p_payload_id
                      AND cob3_ai_lineage.ctx_permitted('thread', m.organization_id, m.thread_id, 'ai.conversation.read'))
        OR EXISTS (SELECT 1 FROM cob3_ai_runtime.runs r
                    WHERE r.tenant_id = cob3_identity.ctx_tenant_id() AND r.organization_id = p_organization_id
                      AND p_payload_id IN (r.input_payload_id, r.output_payload_id)
                      AND cob3_ai_runtime.ctx_can_read_run(r.organization_id, r.run_id))
        OR EXISTS (SELECT 1 FROM cob3_memory.item_revisions ir
                    WHERE ir.tenant_id = cob3_identity.ctx_tenant_id() AND ir.organization_id = p_organization_id
                      AND ir.content_payload_id = p_payload_id
                      AND cob3_ai_lineage.ctx_permitted('memory_item', ir.organization_id, ir.memory_id, 'ai.memory.read'))
$fn$;

CREATE FUNCTION cob3_agent.release_asset(p_organization_id uuid, p_agent_revision_id uuid, p_skill_version_id uuid, p_prompt_version_id uuid)
    RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT COALESCE(cob3_ai_lineage.asset_of('agent_revision', p_organization_id, p_agent_revision_id),
                    cob3_ai_lineage.asset_of('skill_version', p_organization_id, p_skill_version_id),
                    cob3_ai_lineage.asset_of('prompt_version', p_organization_id, p_prompt_version_id))
$fn$;

-- ---------------------------------------------------------------------------
-- RLS: enable + force everywhere, owner policy, worker scope.
-- ---------------------------------------------------------------------------
FOREACH _m_table IN ARRAY _m_tables LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', _m_schema, _m_name);
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', _m_schema, _m_name);
    EXECUTE pg_catalog.format('CREATE POLICY %I ON %I.%I AS PERMISSIVE FOR ALL TO cob3_owner USING (true) WITH CHECK (true)',
                              _m_name || '_owner_all', _m_schema, _m_name);
    EXECUTE pg_catalog.format(
        'CREATE POLICY %I ON %I.%I FOR SELECT TO cob3_worker USING ((SELECT cob3_identity.ctx_is_worker())'
        ' AND tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id()))',
        _m_name || '_worker_select', _m_schema, _m_name);
END LOOP;

-- Trusted runtime workers write execution state (never definitions/config).
FOREACH _m_table IN ARRAY ARRAY[
    'cob3_ai_runtime.execution_contexts', 'cob3_ai_runtime.runs', 'cob3_ai_runtime.run_attempts', 'cob3_ai_runtime.run_steps',
    'cob3_ai_runtime.run_events', 'cob3_ai_runtime.payloads', 'cob3_ai_runtime.context_assemblies', 'cob3_ai_runtime.context_sources',
    'cob3_ai_runtime.checkpoints', 'cob3_ai_runtime.checkpoint_writes', 'cob3_ai_runtime.tool_actions', 'cob3_ai_runtime.tool_attempts',
    'cob3_ai_runtime.interrupts', 'cob3_ai_runtime.outbox',
    'cob3_copilot.threads', 'cob3_copilot.branches', 'cob3_copilot.messages', 'cob3_copilot.message_attachments',
    'cob3_copilot.search_documents', 'cob3_copilot.suggestions',
    'cob3_memory.items', 'cob3_memory.item_revisions', 'cob3_memory.access_events', 'cob3_memory.working_state',
    'cob3_memory.consolidation_jobs',
    'cob3_learning.feedback', 'cob3_learning.annotations', 'cob3_learning.evaluation_runs', 'cob3_learning.evaluation_results',
    'cob3_learning.training_jobs',
    'cob3_llmobs.invocations', 'cob3_llmobs.invocation_attempts', 'cob3_llmobs.usage_charges', 'cob3_llmobs.guardrail_events',
    'cob3_llmobs.review_tasks',
    'cob3_ai_lineage.nodes', 'cob3_ai_lineage.edges',
    'cob3_connectors.connections', 'cob3_connectors.sync_cursors', 'cob3_connectors.jobs', 'cob3_connectors.job_attempts',
    'cob3_connectors.records'
] LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format(
        'CREATE POLICY %I ON %I.%I FOR INSERT TO cob3_worker WITH CHECK ((SELECT cob3_identity.ctx_is_worker())'
        ' AND tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id()))',
        _m_name || '_worker_insert', _m_schema, _m_name);
    EXECUTE pg_catalog.format(
        'CREATE POLICY %I ON %I.%I FOR UPDATE TO cob3_worker USING ((SELECT cob3_identity.ctx_is_worker())'
        ' AND tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id()))'
        ' WITH CHECK ((SELECT cob3_identity.ctx_is_worker())'
        ' AND tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id()))',
        _m_name || '_worker_update', _m_schema, _m_name);
    EXECUTE pg_catalog.format('GRANT INSERT ON %I.%I TO cob3_worker', _m_schema, _m_name);
    IF NOT (_m_table = ANY (_m_append_only)) THEN
        EXECUTE pg_catalog.format('GRANT UPDATE ON %I.%I TO cob3_worker', _m_schema, _m_name);
    END IF;
END LOOP;
-- TTL / rebuild deletes.
FOREACH _m_table IN ARRAY ARRAY['cob3_memory.working_state', 'cob3_copilot.search_documents', 'cob3_copilot.suggestions'] LOOP
    _m_schema := pg_catalog.split_part(_m_table, '.', 1);
    _m_name   := pg_catalog.split_part(_m_table, '.', 2);
    EXECUTE pg_catalog.format(
        'CREATE POLICY %I ON %I.%I FOR DELETE TO cob3_worker USING ((SELECT cob3_identity.ctx_is_worker())'
        ' AND tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND organization_id = (SELECT cob3_identity.ctx_organization_id()))',
        _m_name || '_worker_delete', _m_schema, _m_name);
    EXECUTE pg_catalog.format('GRANT DELETE ON %I.%I TO cob3_worker', _m_schema, _m_name);
END LOOP;

-- ---------------------------------------------------------------------------
-- Runtime (end-user API) policies:
-- [table, SELECT predicate, INSERT check, UPDATE predicate (USING = CHECK)]
-- Every predicate is ANDed with: same tenant, same context organization and an
-- effective membership. '' = no runtime access for that command.
-- ---------------------------------------------------------------------------
FOREACH _m_def SLICE 1 IN ARRAY ARRAY[
-- cob3_agent
['cob3_agent.agents',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.agent.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.agent.edit')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.agent.edit')$p$],
['cob3_agent.agent_revisions',
 $p$cob3_ai_lineage.ctx_permitted('agent', organization_id, agent_id, 'ai.agent.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('agent', organization_id, agent_id, 'ai.agent.edit')$p$, ''],
['cob3_agent.prompt_templates',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.prompt.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.prompt.edit')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.prompt.edit')$p$],
['cob3_agent.prompt_versions',
 $p$cob3_ai_lineage.ctx_permitted('prompt_template', organization_id, prompt_template_id, 'ai.prompt.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('prompt_template', organization_id, prompt_template_id, 'ai.prompt.edit')$p$, ''],
['cob3_agent.model_deployments', $p$true$p$,
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.model.manage'))$p$,
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.model.manage'))$p$],
['cob3_agent.tools',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.tool.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.tool.edit')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.tool.edit')$p$],
['cob3_agent.tool_revisions',
 $p$cob3_ai_lineage.ctx_permitted('tool', organization_id, tool_id, 'ai.tool.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('tool', organization_id, tool_id, 'ai.tool.edit')$p$, ''],
['cob3_agent.tool_permission_requirements',
 $p$cob3_ai_lineage.ctx_permitted('tool_revision', organization_id, tool_revision_id, 'ai.tool.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('tool_revision', organization_id, tool_revision_id, 'ai.tool.edit')$p$, ''],
['cob3_agent.skills',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.skill.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.skill.edit')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.skill.edit')$p$],
['cob3_agent.skill_versions',
 $p$cob3_ai_lineage.ctx_permitted('skill', organization_id, skill_id, 'ai.skill.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('skill', organization_id, skill_id, 'ai.skill.edit')$p$, ''],
['cob3_agent.skill_files',
 $p$cob3_ai_lineage.ctx_permitted('skill_version', organization_id, skill_version_id, 'ai.skill.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('skill_version', organization_id, skill_version_id, 'ai.skill.edit')$p$, ''],
['cob3_agent.agent_tool_bindings',
 $p$cob3_ai_lineage.ctx_permitted('agent_revision', organization_id, agent_revision_id, 'ai.agent.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('agent_revision', organization_id, agent_revision_id, 'ai.agent.edit')
    AND cob3_ai_lineage.ctx_permitted('tool_revision', organization_id, tool_revision_id, 'ai.tool.read')$p$, ''],
['cob3_agent.agent_skill_bindings',
 $p$cob3_ai_lineage.ctx_permitted('agent_revision', organization_id, agent_revision_id, 'ai.agent.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('agent_revision', organization_id, agent_revision_id, 'ai.agent.edit')
    AND cob3_ai_lineage.ctx_permitted('skill_version', organization_id, skill_version_id, 'ai.skill.read')$p$, ''],
['cob3_agent.releases',
 $p$cob3_catalog.ctx_asset_readable(organization_id, cob3_agent.release_asset(organization_id, agent_revision_id, skill_version_id, prompt_version_id))$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, cob3_agent.release_asset(organization_id, agent_revision_id, skill_version_id, prompt_version_id), 'ai.release.approve')$p$, ''],
-- cob3_ai_runtime
['cob3_ai_runtime.execution_contexts',
 $p$((SELECT cob3_identity.ctx_principal_id()) IN (initiator_principal_id, execution_principal_id)
     OR (SELECT cob3_identity.ctx_has_org_permission('audit.read')))$p$,
 $p$initiator_principal_id = (SELECT cob3_identity.ctx_principal_id())
    AND execution_principal_id = (SELECT cob3_identity.ctx_principal_id())
    AND auth_session_id IS NOT DISTINCT FROM (SELECT cob3_identity.ctx_session_id())
    AND credential_id IS NOT DISTINCT FROM (SELECT cob3_identity.ctx_credential_id())$p$, ''],
['cob3_ai_runtime.runs',
 $p$cob3_ai_runtime.ctx_can_read_run_row(organization_id, execution_context_id, agent_revision_id, thread_id)$p$,
 $p$status = 'queued' AND cob3_ai_runtime.ctx_owns_context(organization_id, execution_context_id)
    AND cob3_ai_lineage.ctx_permitted('agent_revision', organization_id, agent_revision_id, 'ai.agent.invoke')
    AND (thread_id IS NULL OR cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.write'))$p$,
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)
    AND cob3_ai_runtime.ctx_run_permitted(organization_id, run_id, 'ai.run.cancel')$p$],
['cob3_ai_runtime.run_attempts', $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)$p$, '', ''],
['cob3_ai_runtime.run_steps', $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)$p$, '', ''],
['cob3_ai_runtime.run_events', $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)$p$, '', ''],
['cob3_ai_runtime.payloads',
 $p$cob3_ai_runtime.ctx_can_read_payload(organization_id, payload_id, file_object_id)$p$,
 $p$EXISTS (SELECT 1 FROM cob3_workspace.file_objects f WHERE f.tenant_id = payloads.tenant_id AND f.organization_id = payloads.organization_id
            AND f.file_object_id = payloads.file_object_id AND f.uploaded_by_principal_id = (SELECT cob3_identity.ctx_principal_id()))$p$, ''],
['cob3_ai_runtime.context_assemblies',
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, cob3_ai_runtime.run_of('step', organization_id, step_id))$p$, '', ''],
['cob3_ai_runtime.context_sources',
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, cob3_ai_runtime.run_of('context_assembly', organization_id, context_assembly_id))$p$, '', ''],
['cob3_ai_runtime.checkpoints', $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)$p$, '', ''],
['cob3_ai_runtime.checkpoint_writes',
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, cob3_ai_runtime.run_of('checkpoint', organization_id, checkpoint_id))$p$, '', ''],
['cob3_ai_runtime.tool_actions',
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, cob3_ai_runtime.run_of('step', organization_id, step_id))$p$, '', ''],
['cob3_ai_runtime.tool_attempts',
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, cob3_ai_runtime.run_of('tool_action', organization_id, tool_action_id))$p$, '', ''],
['cob3_ai_runtime.interrupts',
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)$p$, '',
 $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)
    AND cob3_ai_runtime.ctx_run_permitted(organization_id, run_id, 'ai.run.resume')
    AND (resolved_by_principal_id IS NULL OR resolved_by_principal_id = (SELECT cob3_identity.ctx_principal_id()))$p$],
['cob3_ai_runtime.outbox', '',
 $p$run_id IS NOT NULL AND EXISTS (SELECT 1 FROM cob3_ai_runtime.runs r WHERE r.tenant_id = outbox.tenant_id
     AND r.organization_id = outbox.organization_id AND r.run_id = outbox.run_id
     AND cob3_ai_runtime.ctx_owns_context(r.organization_id, r.execution_context_id))$p$, ''],
-- cob3_copilot
['cob3_copilot.threads',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.conversation.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.conversation.write')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.conversation.write')$p$],
['cob3_copilot.branches',
 $p$cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.write')$p$,
 $p$cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.write')$p$],
['cob3_copilot.messages',
 $p$cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.read')$p$,
 $p$role = 'user' AND author_principal_id = (SELECT cob3_identity.ctx_principal_id())
    AND cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.write')$p$, ''],
['cob3_copilot.message_attachments',
 $p$cob3_ai_lineage.ctx_permitted('message', organization_id, message_id, 'ai.conversation.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('message', organization_id, message_id, 'ai.conversation.write')$p$, ''],
['cob3_copilot.thread_preferences',
 $p$principal_id = (SELECT cob3_identity.ctx_principal_id())$p$,
 $p$principal_id = (SELECT cob3_identity.ctx_principal_id())
    AND cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.read')$p$,
 $p$principal_id = (SELECT cob3_identity.ctx_principal_id())
    AND cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.read')$p$],
['cob3_copilot.search_documents',
 $p$cob3_ai_lineage.ctx_permitted('message', organization_id, message_id, 'ai.conversation.read')$p$, '', ''],
['cob3_copilot.suggestions',
 $p$cob3_ai_lineage.ctx_permitted('thread', organization_id, thread_id, 'ai.conversation.read')$p$, '', ''],
-- cob3_memory
['cob3_memory.containers',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.memory.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.memory.manage')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.memory.manage')$p$],
['cob3_memory.items',
 $p$cob3_ai_lineage.ctx_permitted('container', organization_id, container_id, 'ai.memory.read')$p$,
 $p$status = 'candidate' AND cob3_ai_lineage.ctx_permitted('container', organization_id, container_id, 'ai.memory.propose')$p$,
 $p$cob3_ai_lineage.ctx_permitted('container', organization_id, container_id, 'ai.memory.approve')$p$],
['cob3_memory.item_revisions',
 $p$cob3_ai_lineage.ctx_permitted('memory_item', organization_id, memory_id, 'ai.memory.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('memory_item', organization_id, memory_id, 'ai.memory.propose')
    AND (reviewer_principal_id IS NULL OR (reviewer_principal_id = (SELECT cob3_identity.ctx_principal_id())
         AND cob3_ai_lineage.ctx_permitted('memory_item', organization_id, memory_id, 'ai.memory.approve')))$p$, ''],
['cob3_memory.access_events',
 $p$cob3_ai_lineage.ctx_permitted('memory_revision', organization_id, memory_revision_id, 'ai.memory.read')$p$, '', ''],
['cob3_memory.working_state', $p$cob3_ai_runtime.ctx_can_read_run(organization_id, run_id)$p$, '', ''],
['cob3_memory.consolidation_jobs',
 $p$cob3_ai_lineage.ctx_permitted('container', organization_id, container_id, 'ai.memory.read')$p$, '', ''],
-- cob3_learning
['cob3_learning.feedback',
 $p$(author_principal_id = (SELECT cob3_identity.ctx_principal_id())
     OR (SELECT cob3_identity.ctx_has_org_permission('ai.review.manage')))$p$,
 $p$author_principal_id = (SELECT cob3_identity.ctx_principal_id()) AND source_kind = 'human'
    AND (SELECT cob3_identity.ctx_has_org_permission('ai.feedback.create'))$p$, ''],
['cob3_learning.annotations',
 $p$(author_principal_id = (SELECT cob3_identity.ctx_principal_id())
     OR (SELECT cob3_identity.ctx_has_org_permission('ai.review.manage')))$p$,
 $p$author_principal_id = (SELECT cob3_identity.ctx_principal_id())
    AND (SELECT cob3_identity.ctx_has_org_permission('ai.feedback.create'))$p$, ''],
['cob3_learning.datasets',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.dataset.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.dataset.curate')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.dataset.curate')$p$],
['cob3_learning.dataset_versions',
 $p$cob3_ai_lineage.ctx_permitted('dataset', organization_id, dataset_id, 'ai.dataset.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('dataset', organization_id, dataset_id, 'ai.dataset.curate')
    AND reviewer_principal_id = (SELECT cob3_identity.ctx_principal_id())$p$, ''],
['cob3_learning.examples',
 $p$cob3_ai_lineage.ctx_permitted('dataset_version', organization_id, dataset_version_id, 'ai.dataset.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('dataset_version', organization_id, dataset_version_id, 'ai.dataset.curate')$p$, ''],
['cob3_learning.evaluation_runs',
 $p$cob3_ai_lineage.ctx_permitted('dataset_version', organization_id, dataset_version_id, 'ai.dataset.read')$p$,
 $p$status = 'queued' AND cob3_ai_lineage.ctx_permitted('dataset_version', organization_id, dataset_version_id, 'ai.evaluation.run')$p$, ''],
['cob3_learning.evaluation_results',
 $p$cob3_ai_lineage.ctx_permitted('evaluation_run', organization_id, evaluation_run_id, 'ai.dataset.read')$p$, '', ''],
['cob3_learning.training_jobs',
 $p$cob3_ai_lineage.ctx_permitted('dataset_version', organization_id, dataset_version_id, 'ai.dataset.read')$p$,
 $p$status = 'queued' AND cob3_ai_lineage.ctx_permitted('dataset_version', organization_id, dataset_version_id, 'ai.training.submit')$p$, ''],
-- cob3_llmobs
['cob3_llmobs.applications',
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.telemetry.read')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.application.manage')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.application.manage')$p$],
['cob3_llmobs.application_environments',
 $p$cob3_ai_lineage.ctx_permitted('application', organization_id, application_id, 'ai.telemetry.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('application', organization_id, application_id, 'ai.application.manage')$p$,
 $p$cob3_ai_lineage.ctx_permitted('application', organization_id, application_id, 'ai.application.manage')$p$],
['cob3_llmobs.policy_versions',
 $p$cob3_ai_lineage.ctx_permitted('environment', organization_id, application_environment_id, 'ai.telemetry.read')$p$,
 $p$cob3_ai_lineage.ctx_permitted('environment', organization_id, application_environment_id, 'ai.application.manage')$p$, ''],
['cob3_llmobs.invocations',
 $p$cob3_ai_lineage.ctx_permitted('environment', organization_id, application_environment_id, 'ai.telemetry.read')$p$, '', ''],
['cob3_llmobs.invocation_attempts',
 $p$cob3_ai_lineage.ctx_permitted('invocation', organization_id, invocation_id, 'ai.telemetry.read')$p$, '', ''],
['cob3_llmobs.model_prices',
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.model.manage'))$p$,
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.model.manage'))$p$, ''],
['cob3_llmobs.usage_charges',
 $p$cob3_ai_lineage.ctx_permitted('invocation_attempt', organization_id, invocation_attempt_id, 'ai.telemetry.read')$p$, '', ''],
['cob3_llmobs.guardrail_events',
 $p$cob3_ai_lineage.ctx_permitted('policy_version', organization_id, policy_version_id, 'ai.telemetry.read_content')$p$, '', ''],
['cob3_llmobs.review_tasks',
 $p$(assignee_principal_id = (SELECT cob3_identity.ctx_principal_id())
     OR (SELECT cob3_identity.ctx_has_org_permission('ai.review.manage')))$p$,
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.review.manage'))$p$,
 $p$(assignee_principal_id = (SELECT cob3_identity.ctx_principal_id())
     OR (SELECT cob3_identity.ctx_has_org_permission('ai.review.manage')))$p$],
['cob3_llmobs.retention_holds',
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.retention.manage'))$p$,
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.retention.manage'))$p$,
 $p$(SELECT cob3_identity.ctx_has_org_permission('ai.retention.manage'))$p$],
-- cob3_ai_lineage
['cob3_ai_lineage.nodes',
 $p$((SELECT cob3_identity.ctx_has_org_permission('ai.lineage.read'))
     OR (asset_id IS NOT NULL AND cob3_catalog.ctx_asset_readable(organization_id, asset_id)))$p$, '', ''],
['cob3_ai_lineage.edges',
 $p$EXISTS (SELECT 1 FROM cob3_ai_lineage.nodes n WHERE n.tenant_id = edges.tenant_id AND n.organization_id = edges.organization_id
            AND n.lineage_node_id = edges.source_node_id)
    AND EXISTS (SELECT 1 FROM cob3_ai_lineage.nodes n WHERE n.tenant_id = edges.tenant_id AND n.organization_id = edges.organization_id
            AND n.lineage_node_id = edges.derived_node_id)$p$, '', ''],
-- cob3_connectors
['cob3_connectors.connections',
 $p$(cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.connector.manage')
     OR cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.connector.run'))$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.connector.manage')$p$,
 $p$cob3_catalog.ctx_asset_permitted(organization_id, asset_id, 'ai.connector.manage')$p$],
['cob3_connectors.sync_cursors',
 $p$cob3_ai_lineage.ctx_permitted('connection', organization_id, connection_id, 'ai.connector.manage')$p$, '', ''],
['cob3_connectors.jobs',
 $p$(cob3_ai_lineage.ctx_permitted('connection', organization_id, connection_id, 'ai.connector.manage')
     OR cob3_ai_lineage.ctx_permitted('connection', organization_id, connection_id, 'ai.connector.run'))$p$,
 $p$status = 'queued' AND cob3_ai_lineage.ctx_permitted('connection', organization_id, connection_id, 'ai.connector.run')$p$, ''],
['cob3_connectors.job_attempts',
 $p$cob3_ai_lineage.ctx_permitted('job', organization_id, connector_job_id, 'ai.connector.manage')$p$, '', ''],
['cob3_connectors.records',
 $p$cob3_ai_lineage.ctx_permitted('connection', organization_id, connection_id, 'ai.connector.manage')$p$, '', ''],
['cob3_connectors.source_scope_bindings',
 $p$cob3_ai_lineage.ctx_permitted('connection', organization_id, source_connection_id, 'ai.connector.manage')$p$,
 $p$cob3_ai_lineage.ctx_permitted('connection', organization_id, source_connection_id, 'ai.connector.manage')$p$,
 $p$cob3_ai_lineage.ctx_permitted('connection', organization_id, source_connection_id, 'ai.connector.manage')$p$]
]::text[] LOOP
    _m_schema := pg_catalog.split_part(_m_def[1], '.', 1);
    _m_name   := pg_catalog.split_part(_m_def[1], '.', 2);
    IF _m_def[2] <> '' THEN
        EXECUTE pg_catalog.format(
            'CREATE POLICY %I ON %I.%I FOR SELECT TO cob3_runtime USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())'
            ' AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()) AND (%s))',
            _m_name || '_runtime_select', _m_schema, _m_name, _m_def[2]);
        EXECUTE pg_catalog.format('GRANT SELECT ON %I.%I TO cob3_runtime', _m_schema, _m_name);
    END IF;
    IF _m_def[3] <> '' THEN
        EXECUTE pg_catalog.format(
            'CREATE POLICY %I ON %I.%I FOR INSERT TO cob3_runtime WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())'
            ' AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()) AND (%s))',
            _m_name || '_runtime_insert', _m_schema, _m_name, _m_def[3]);
        EXECUTE pg_catalog.format('GRANT INSERT ON %I.%I TO cob3_runtime', _m_schema, _m_name);
    END IF;
    IF _m_def[4] <> '' THEN
        EXECUTE pg_catalog.format(
            'CREATE POLICY %2$I ON %3$I.%4$I FOR UPDATE TO cob3_runtime USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id())'
            ' AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()) AND (%1$s))'
            ' WITH CHECK (tenant_id = (SELECT cob3_identity.ctx_tenant_id())'
            ' AND organization_id = (SELECT cob3_identity.ctx_organization_id()) AND (SELECT cob3_identity.ctx_in_org()) AND (%1$s))',
            _m_def[4], _m_name || '_runtime_update', _m_schema, _m_name);
        EXECUTE pg_catalog.format('GRANT UPDATE ON %I.%I TO cob3_runtime', _m_schema, _m_name);
    END IF;
END LOOP;

-- Narrow runtime UPDATE to the columns the API may change.
REVOKE UPDATE ON cob3_ai_runtime.runs, cob3_ai_runtime.interrupts, cob3_memory.items FROM cob3_runtime;
GRANT UPDATE (status, metadata, updated_by) ON cob3_ai_runtime.runs TO cob3_runtime;          -- cancellation requests
GRANT UPDATE (status, resolved_by_principal_id, resolved_at, resolution_payload_id, metadata, updated_by)
   ON cob3_ai_runtime.interrupts TO cob3_runtime;                                               -- interrupt resolution
GRANT UPDATE (status, current_revision_id, valid_until, superseded_by_id, metadata, updated_by)
   ON cob3_memory.items TO cob3_runtime;                                                         -- review decisions
CREATE POLICY runs_runtime_cancel_only ON cob3_ai_runtime.runs AS RESTRICTIVE FOR UPDATE TO cob3_runtime
    USING (true) WITH CHECK (status = 'cancellation_requested');
CREATE POLICY thread_preferences_runtime_delete ON cob3_copilot.thread_preferences FOR DELETE TO cob3_runtime
    USING (tenant_id = (SELECT cob3_identity.ctx_tenant_id()) AND principal_id = (SELECT cob3_identity.ctx_principal_id()));
GRANT DELETE ON cob3_copilot.thread_preferences TO cob3_runtime;

-- Schema usage and helper execution.
FOREACH _m_schema IN ARRAY _m_schemas LOOP
    EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA %I TO cob3_runtime, cob3_worker, cob3_provisioner', _m_schema);
    EXECUTE pg_catalog.format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO cob3_worker', _m_schema);
END LOOP;
GRANT EXECUTE ON FUNCTION
    cob3_ai_lineage.asset_of(text, uuid, uuid), cob3_ai_lineage.ctx_permitted(text, uuid, uuid, text),
    cob3_ai_runtime.ctx_can_read_run(uuid, uuid), cob3_ai_runtime.ctx_can_read_run_row(uuid, uuid, uuid, uuid),
    cob3_ai_runtime.run_of(text, uuid, uuid),
    cob3_ai_runtime.ctx_run_permitted(uuid, uuid, text), cob3_ai_runtime.ctx_owns_context(uuid, uuid),
    cob3_ai_runtime.ctx_can_read_payload(uuid, uuid, uuid), cob3_agent.release_asset(uuid, uuid, uuid, uuid)
    TO cob3_runtime;
GRANT EXECUTE ON FUNCTION cob3_agent.module_permission_templates(), cob3_agent.module_role_templates() TO cob3_provisioner;
GRANT EXECUTE ON FUNCTION cob3_agent.release_state(uuid, uuid, text, uuid) TO cob3_runtime, cob3_worker;
GRANT EXECUTE ON FUNCTION cob3_learning.dataset_purpose(uuid, uuid, uuid) TO cob3_runtime, cob3_worker;
GRANT EXECUTE ON FUNCTION cob3_ai_lineage.node_kind_backing(text) TO cob3_runtime, cob3_worker;

-- ---------------------------------------------------------------------------
-- Comments and installation record
-- ---------------------------------------------------------------------------
COMMENT ON SCHEMA cob3_agent IS 'Agent, prompt, tool, skill and model definitions with immutable executable revisions and releases (migration 003).';
COMMENT ON SCHEMA cob3_ai_runtime IS 'Execution authority, runs, attempts, events, checkpoints, tool actions, context and durable dispatch (migration 003).';
COMMENT ON SCHEMA cob3_copilot IS 'Conversations, message branches, attachments and user-facing projections (migration 003).';
COMMENT ON SCHEMA cob3_memory IS 'Durable knowledge, recall evidence and bounded working memory (migration 003).';
COMMENT ON SCHEMA cob3_learning IS 'Feedback, evaluation, curated datasets and controlled promotion (migration 003).';
COMMENT ON SCHEMA cob3_llmobs IS 'AI application configuration, capture policies and LLM invocation accounting (migration 003). Imported gateway observations stay in obs3_aiops.llm_gateway_call.';
COMMENT ON SCHEMA cob3_ai_lineage IS 'Typed provenance registry and dependency edges; lineage never grants access (migration 003).';
COMMENT ON SCHEMA cob3_connectors IS 'Connections, sync cursors, jobs, attempts, imported records and telemetry scope bindings (migration 003).';
COMMENT ON TABLE cob3_connectors.source_scope_bindings IS
    'Telemetry design 3.2 control table: how a legacy/source namespace (e.g. numeric obs3 tenant_id + stream + selector) resolves to canonical tenant/organization. Immutable once active; retire and version for corrections.';
COMMENT ON TABLE cob3_llmobs.invocation_attempts IS
    'Native runtime provider attempts. Imported Portkey/gateway history stays in obs3_aiops.llm_gateway_call and is linked by verified correlation, never duplicated here.';

INSERT INTO cob3_tenant.foundation_installations (component, version, script_checksum, server_version_num, notes)
VALUES (_m_component, _m_version, _m_checksum, _m_server,
        'Migration 003: 8 AI schemas, 66 design tables + cob3_connectors.source_scope_bindings; AI asset types, permissions and roles.');

PERFORM cob3_identity.clear_request_context();
RESET ROLE;
PERFORM pg_catalog.set_config('search_path', _m_saved_path, true);

RAISE NOTICE 'Migration 003 (% %) applied in database %: % AI tables installed.',
    _m_component, _m_version, pg_catalog.current_database(), pg_catalog.cardinality(_m_tables);
END
