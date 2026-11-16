-- =============================================================================
-- 20  FOREIGN KEYS (second phase, design section 11)
-- -----------------------------------------------------------------------------
-- [table, constraint, columns, referenced table, referenced columns, deferrable]
-- '@' expands to "tenant_id, organization_id": every organization-owned
-- reference carries BOTH scope IDs, so cross-tenant/cross-organization links
-- are impossible even when code supplies wrong IDs. Where a row names a parent
-- and a child (agent + revision, thread + branch, run + step, ...) the
-- composite key proves the child belongs to that parent. Head pointers that
-- point back into their own version tables are DEFERRABLE INITIALLY DEFERRED
-- (publication transaction), never permanently inconsistent.
-- All FKs are ON UPDATE/DELETE RESTRICT; purge is an orchestrated workflow.
-- =============================================================================
FOREACH _m_def SLICE 1 IN ARRAY ARRAY[
-- cob3_agent
['cob3_agent.agents', 'agents_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_agent.agents', 'agents_current_revision_fk', '@, agent_id, current_revision_id', 'cob3_agent.agent_revisions', '@, agent_id, agent_revision_id', 'd'],
['cob3_agent.agent_revisions', 'agent_revisions_agent_fk', '@, agent_id', 'cob3_agent.agents', '@, agent_id', ''],
['cob3_agent.agent_revisions', 'agent_revisions_prompt_version_fk', '@, prompt_version_id', 'cob3_agent.prompt_versions', '@, prompt_version_id', ''],
['cob3_agent.agent_revisions', 'agent_revisions_model_deployment_fk', '@, model_deployment_id', 'cob3_agent.model_deployments', '@, model_deployment_id', ''],
['cob3_agent.prompt_templates', 'prompt_templates_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_agent.prompt_templates', 'prompt_templates_current_version_fk', '@, prompt_template_id, current_version_id', 'cob3_agent.prompt_versions', '@, prompt_template_id, prompt_version_id', 'd'],
['cob3_agent.prompt_versions', 'prompt_versions_template_fk', '@, prompt_template_id', 'cob3_agent.prompt_templates', '@, prompt_template_id', ''],
['cob3_agent.model_deployments', 'model_deployments_integration_fk', 'tenant_id, integration_configuration_id', 'cob3_settings.integration_configurations', 'tenant_id, integration_configuration_id', ''],
['cob3_agent.tools', 'tools_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_agent.tools', 'tools_current_revision_fk', '@, tool_id, current_revision_id', 'cob3_agent.tool_revisions', '@, tool_id, tool_revision_id', 'd'],
['cob3_agent.tool_revisions', 'tool_revisions_tool_fk', '@, tool_id', 'cob3_agent.tools', '@, tool_id', ''],
['cob3_agent.tool_revisions', 'tool_revisions_integration_fk', 'tenant_id, integration_configuration_id', 'cob3_settings.integration_configurations', 'tenant_id, integration_configuration_id', ''],
['cob3_agent.tool_permission_requirements', 'tool_permission_requirements_revision_fk', '@, tool_revision_id', 'cob3_agent.tool_revisions', '@, tool_revision_id', ''],
['cob3_agent.tool_permission_requirements', 'tool_permission_requirements_permission_fk', 'tenant_id, permission_id', 'cob3_identity.permissions', 'tenant_id, permission_id', ''],
['cob3_agent.skills', 'skills_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_agent.skills', 'skills_container_fk', '@, container_id', 'cob3_memory.containers', '@, container_id', ''],
['cob3_agent.skills', 'skills_current_version_fk', '@, skill_id, current_version_id', 'cob3_agent.skill_versions', '@, skill_id, skill_version_id', 'd'],
['cob3_agent.skill_versions', 'skill_versions_skill_fk', '@, skill_id', 'cob3_agent.skills', '@, skill_id', ''],
['cob3_agent.skill_files', 'skill_files_version_fk', '@, skill_version_id', 'cob3_agent.skill_versions', '@, skill_version_id', ''],
['cob3_agent.skill_files', 'skill_files_file_fk', '@, file_object_id', 'cob3_workspace.file_objects', '@, file_object_id', ''],
['cob3_agent.agent_tool_bindings', 'agent_tool_bindings_revision_fk', '@, agent_revision_id', 'cob3_agent.agent_revisions', '@, agent_revision_id', ''],
['cob3_agent.agent_tool_bindings', 'agent_tool_bindings_tool_revision_fk', '@, tool_revision_id', 'cob3_agent.tool_revisions', '@, tool_revision_id', ''],
['cob3_agent.agent_skill_bindings', 'agent_skill_bindings_revision_fk', '@, agent_revision_id', 'cob3_agent.agent_revisions', '@, agent_revision_id', ''],
['cob3_agent.agent_skill_bindings', 'agent_skill_bindings_skill_version_fk', '@, skill_version_id', 'cob3_agent.skill_versions', '@, skill_version_id', ''],
['cob3_agent.releases', 'releases_agent_revision_fk', '@, agent_revision_id', 'cob3_agent.agent_revisions', '@, agent_revision_id', ''],
['cob3_agent.releases', 'releases_skill_version_fk', '@, skill_version_id', 'cob3_agent.skill_versions', '@, skill_version_id', ''],
['cob3_agent.releases', 'releases_prompt_version_fk', '@, prompt_version_id', 'cob3_agent.prompt_versions', '@, prompt_version_id', ''],
['cob3_agent.releases', 'releases_approver_fk', '@, approved_by_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_agent.releases', 'releases_approval_fk', '@, approval_id', 'cob3_identity.action_approvals', '@, action_approval_id', ''],
['cob3_agent.releases', 'releases_evaluation_run_fk', '@, evaluation_run_id', 'cob3_learning.evaluation_runs', '@, evaluation_run_id', ''],
-- cob3_ai_runtime
['cob3_ai_runtime.execution_contexts', 'execution_contexts_initiator_fk', '@, initiator_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_ai_runtime.execution_contexts', 'execution_contexts_executor_fk', '@, execution_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_ai_runtime.execution_contexts', 'execution_contexts_grant_fk', '@, grant_id, execution_principal_id', 'cob3_identity.authorization_grants', '@, authorization_grant_id, grantee_principal_id', ''],
['cob3_ai_runtime.execution_contexts', 'execution_contexts_credential_fk', '@, credential_id', 'cob3_identity.principal_credentials', '@, credential_id', ''],
['cob3_ai_runtime.execution_contexts', 'execution_contexts_session_fk', 'tenant_id, auth_session_id', 'cob3_identity.auth_sessions', 'tenant_id, session_id', ''],
['cob3_ai_runtime.execution_contexts', 'execution_contexts_parent_fk', '@, parent_context_id', 'cob3_ai_runtime.execution_contexts', '@, execution_context_id', ''],
['cob3_ai_runtime.runs', 'runs_context_fk', '@, execution_context_id', 'cob3_ai_runtime.execution_contexts', '@, execution_context_id', ''],
['cob3_ai_runtime.runs', 'runs_agent_revision_fk', '@, agent_revision_id', 'cob3_agent.agent_revisions', '@, agent_revision_id', ''],
['cob3_ai_runtime.runs', 'runs_environment_fk', '@, application_environment_id', 'cob3_llmobs.application_environments', '@, application_environment_id', ''],
['cob3_ai_runtime.runs', 'runs_branch_fk', '@, thread_id, branch_id', 'cob3_copilot.branches', '@, thread_id, branch_id', ''],
['cob3_ai_runtime.runs', 'runs_parent_fk', '@, parent_run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_ai_runtime.runs', 'runs_input_payload_fk', '@, input_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.runs', 'runs_output_payload_fk', '@, output_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.run_attempts', 'run_attempts_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_ai_runtime.run_attempts', 'run_attempts_worker_fk', '@, worker_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_ai_runtime.run_steps', 'run_steps_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_ai_runtime.run_steps', 'run_steps_parent_fk', '@, run_id, parent_step_id', 'cob3_ai_runtime.run_steps', '@, run_id, step_id', ''],
['cob3_ai_runtime.run_steps', 'run_steps_result_payload_fk', '@, result_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.run_events', 'run_events_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_ai_runtime.run_events', 'run_events_attempt_fk', '@, run_id, run_attempt_id', 'cob3_ai_runtime.run_attempts', '@, run_id, run_attempt_id', ''],
['cob3_ai_runtime.run_events', 'run_events_step_fk', '@, run_id, step_id', 'cob3_ai_runtime.run_steps', '@, run_id, step_id', ''],
['cob3_ai_runtime.payloads', 'payloads_file_fk', '@, file_object_id', 'cob3_workspace.file_objects', '@, file_object_id', ''],
['cob3_ai_runtime.context_assemblies', 'context_assemblies_step_fk', '@, step_id', 'cob3_ai_runtime.run_steps', '@, step_id', ''],
['cob3_ai_runtime.context_assemblies', 'context_assemblies_prompt_version_fk', '@, prompt_version_id', 'cob3_agent.prompt_versions', '@, prompt_version_id', ''],
['cob3_ai_runtime.context_assemblies', 'context_assemblies_policy_version_fk', '@, policy_version_id', 'cob3_llmobs.policy_versions', '@, policy_version_id', ''],
['cob3_ai_runtime.context_assemblies', 'context_assemblies_page_payload_fk', '@, page_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.context_assemblies', 'context_assemblies_manifest_payload_fk', '@, manifest_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.context_sources', 'context_sources_assembly_fk', '@, context_assembly_id', 'cob3_ai_runtime.context_assemblies', '@, context_assembly_id', ''],
['cob3_ai_runtime.context_sources', 'context_sources_node_fk', '@, lineage_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_ai_runtime.checkpoints', 'checkpoints_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_ai_runtime.checkpoints', 'checkpoints_branch_fk', '@, branch_id', 'cob3_copilot.branches', '@, branch_id', ''],
['cob3_ai_runtime.checkpoints', 'checkpoints_parent_fk', '@, run_id, namespace, parent_checkpoint_id', 'cob3_ai_runtime.checkpoints', '@, run_id, namespace, checkpoint_id', ''],
['cob3_ai_runtime.checkpoints', 'checkpoints_state_payload_fk', '@, state_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.checkpoint_writes', 'checkpoint_writes_checkpoint_fk', '@, checkpoint_id', 'cob3_ai_runtime.checkpoints', '@, checkpoint_id', ''],
['cob3_ai_runtime.checkpoint_writes', 'checkpoint_writes_payload_fk', '@, value_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.tool_actions', 'tool_actions_step_fk', '@, step_id', 'cob3_ai_runtime.run_steps', '@, step_id', ''],
['cob3_ai_runtime.tool_actions', 'tool_actions_tool_revision_fk', '@, tool_revision_id', 'cob3_agent.tool_revisions', '@, tool_revision_id', ''],
['cob3_ai_runtime.tool_actions', 'tool_actions_arguments_payload_fk', '@, arguments_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.tool_actions', 'tool_actions_approval_fk', '@, approval_id', 'cob3_identity.action_approvals', '@, action_approval_id', ''],
['cob3_ai_runtime.tool_actions', 'tool_actions_result_payload_fk', '@, result_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.tool_attempts', 'tool_attempts_action_fk', '@, tool_action_id', 'cob3_ai_runtime.tool_actions', '@, tool_action_id', ''],
['cob3_ai_runtime.tool_attempts', 'tool_attempts_run_attempt_fk', '@, run_attempt_id', 'cob3_ai_runtime.run_attempts', '@, run_attempt_id', ''],
['cob3_ai_runtime.tool_attempts', 'tool_attempts_result_payload_fk', '@, result_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.interrupts', 'interrupts_step_fk', '@, run_id, step_id', 'cob3_ai_runtime.run_steps', '@, run_id, step_id', ''],
['cob3_ai_runtime.interrupts', 'interrupts_checkpoint_fk', '@, run_id, checkpoint_id', 'cob3_ai_runtime.checkpoints', '@, run_id, checkpoint_id', ''],
['cob3_ai_runtime.interrupts', 'interrupts_request_payload_fk', '@, request_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.interrupts', 'interrupts_approval_fk', '@, approval_id', 'cob3_identity.action_approvals', '@, action_approval_id', ''],
['cob3_ai_runtime.interrupts', 'interrupts_resolver_fk', '@, resolved_by_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_ai_runtime.interrupts', 'interrupts_resolution_payload_fk', '@, resolution_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_ai_runtime.outbox', 'outbox_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
-- cob3_copilot
['cob3_copilot.threads', 'threads_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_copilot.threads', 'threads_project_fk', '@, project_id', 'cob3_workspace.projects', '@, project_id', ''],
['cob3_copilot.threads', 'threads_folder_fk', '@, project_id, folder_id', 'cob3_workspace.folders', '@, project_id, folder_id', ''],
['cob3_copilot.threads', 'threads_default_agent_fk', '@, default_agent_id', 'cob3_agent.agents', '@, agent_id', ''],
['cob3_copilot.threads', 'threads_summary_payload_fk', '@, summary_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_copilot.threads', 'threads_summary_message_fk', '@, thread_id, summary_through_message_id', 'cob3_copilot.messages', '@, thread_id, message_id', 'd'],
['cob3_copilot.branches', 'branches_thread_fk', '@, thread_id', 'cob3_copilot.threads', '@, thread_id', ''],
['cob3_copilot.branches', 'branches_parent_fk', '@, thread_id, parent_branch_id', 'cob3_copilot.branches', '@, thread_id, branch_id', ''],
['cob3_copilot.branches', 'branches_fork_message_fk', '@, thread_id, fork_message_id', 'cob3_copilot.messages', '@, thread_id, message_id', 'd'],
['cob3_copilot.branches', 'branches_head_message_fk', '@, branch_id, head_message_id', 'cob3_copilot.messages', '@, branch_id, message_id', 'd'],
['cob3_copilot.branches', 'branches_last_run_fk', '@, last_run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_copilot.messages', 'messages_branch_fk', '@, thread_id, branch_id', 'cob3_copilot.branches', '@, thread_id, branch_id', ''],
['cob3_copilot.messages', 'messages_parent_fk', '@, thread_id, parent_message_id', 'cob3_copilot.messages', '@, thread_id, message_id', ''],
['cob3_copilot.messages', 'messages_replaces_fk', '@, thread_id, replaces_message_id', 'cob3_copilot.messages', '@, thread_id, message_id', ''],
['cob3_copilot.messages', 'messages_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_copilot.messages', 'messages_author_fk', '@, author_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_copilot.messages', 'messages_content_payload_fk', '@, content_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_copilot.messages', 'messages_tool_action_fk', '@, tool_action_id', 'cob3_ai_runtime.tool_actions', '@, tool_action_id', ''],
['cob3_copilot.message_attachments', 'message_attachments_message_fk', '@, message_id', 'cob3_copilot.messages', '@, message_id', ''],
['cob3_copilot.message_attachments', 'message_attachments_file_fk', '@, file_object_id', 'cob3_workspace.file_objects', '@, file_object_id', ''],
['cob3_copilot.thread_preferences', 'thread_preferences_thread_fk', '@, thread_id', 'cob3_copilot.threads', '@, thread_id', ''],
['cob3_copilot.thread_preferences', 'thread_preferences_principal_fk', '@, principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_copilot.thread_preferences', 'thread_preferences_last_read_fk', '@, thread_id, last_read_message_id', 'cob3_copilot.messages', '@, thread_id, message_id', ''],
['cob3_copilot.thread_preferences', 'thread_preferences_branch_fk', '@, thread_id, selected_branch_id', 'cob3_copilot.branches', '@, thread_id, branch_id', ''],
['cob3_copilot.search_documents', 'search_documents_message_fk', '@, message_id', 'cob3_copilot.messages', '@, message_id', ''],
['cob3_copilot.suggestions', 'suggestions_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_copilot.suggestions', 'suggestions_thread_fk', '@, thread_id', 'cob3_copilot.threads', '@, thread_id', ''],
['cob3_copilot.suggestions', 'suggestions_payload_fk', '@, message_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
-- cob3_memory
['cob3_memory.containers', 'containers_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_memory.containers', 'containers_owner_fk', '@, owner_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_memory.containers', 'containers_team_fk', '@, team_id', 'cob3_identity.teams', '@, team_id', ''],
['cob3_memory.containers', 'containers_project_fk', '@, project_id', 'cob3_workspace.projects', '@, project_id', ''],
['cob3_memory.items', 'items_container_fk', '@, container_id', 'cob3_memory.containers', '@, container_id', ''],
['cob3_memory.items', 'items_current_revision_fk', '@, memory_id, current_revision_id', 'cob3_memory.item_revisions', '@, memory_id, memory_revision_id', 'd'],
['cob3_memory.items', 'items_superseded_by_fk', '@, container_id, superseded_by_id', 'cob3_memory.items', '@, container_id, memory_id', ''],
['cob3_memory.item_revisions', 'item_revisions_memory_fk', '@, memory_id', 'cob3_memory.items', '@, memory_id', ''],
['cob3_memory.item_revisions', 'item_revisions_payload_fk', '@, content_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_memory.item_revisions', 'item_revisions_reviewer_fk', '@, reviewer_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_memory.item_revisions', 'item_revisions_approval_fk', '@, review_approval_id', 'cob3_identity.action_approvals', '@, action_approval_id', ''],
['cob3_memory.access_events', 'access_events_revision_fk', '@, memory_revision_id', 'cob3_memory.item_revisions', '@, memory_revision_id', ''],
['cob3_memory.access_events', 'access_events_step_fk', '@, run_id, step_id', 'cob3_ai_runtime.run_steps', '@, run_id, step_id', ''],
['cob3_memory.working_state', 'working_state_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_memory.working_state', 'working_state_payload_fk', '@, value_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_memory.consolidation_jobs', 'consolidation_jobs_container_fk', '@, container_id', 'cob3_memory.containers', '@, container_id', ''],
['cob3_memory.consolidation_jobs', 'consolidation_jobs_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_memory.consolidation_jobs', 'consolidation_jobs_input_fk', '@, input_manifest_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_memory.consolidation_jobs', 'consolidation_jobs_output_fk', '@, output_manifest_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
-- cob3_learning
['cob3_learning.feedback', 'feedback_author_fk', '@, author_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_learning.feedback', 'feedback_target_fk', '@, target_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_learning.feedback', 'feedback_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_learning.feedback', 'feedback_comment_fk', '@, comment_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.feedback', 'feedback_correction_fk', '@, correction_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.annotations', 'annotations_author_fk', '@, author_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_learning.annotations', 'annotations_target_fk', '@, target_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_learning.annotations', 'annotations_payload_fk', '@, payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.datasets', 'datasets_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_learning.datasets', 'datasets_current_version_fk', '@, dataset_id, current_version_id', 'cob3_learning.dataset_versions', '@, dataset_id, dataset_version_id', 'd'],
['cob3_learning.dataset_versions', 'dataset_versions_dataset_fk', '@, dataset_id', 'cob3_learning.datasets', '@, dataset_id', ''],
['cob3_learning.dataset_versions', 'dataset_versions_manifest_fk', '@, manifest_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.dataset_versions', 'dataset_versions_reviewer_fk', '@, reviewer_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_learning.dataset_versions', 'dataset_versions_approval_fk', '@, approval_id', 'cob3_identity.action_approvals', '@, action_approval_id', ''],
['cob3_learning.examples', 'examples_version_fk', '@, dataset_version_id', 'cob3_learning.dataset_versions', '@, dataset_version_id', ''],
['cob3_learning.examples', 'examples_input_fk', '@, input_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.examples', 'examples_expected_fk', '@, expected_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.examples', 'examples_chosen_fk', '@, chosen_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.examples', 'examples_rejected_fk', '@, rejected_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.examples', 'examples_source_node_fk', '@, source_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_learning.evaluation_runs', 'evaluation_runs_version_fk', '@, dataset_version_id', 'cob3_learning.dataset_versions', '@, dataset_version_id', ''],
['cob3_learning.evaluation_runs', 'evaluation_runs_agent_revision_fk', '@, agent_revision_id', 'cob3_agent.agent_revisions', '@, agent_revision_id', ''],
['cob3_learning.evaluation_runs', 'evaluation_runs_runtime_run_fk', '@, runtime_run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_learning.evaluation_results', 'evaluation_results_run_fk', '@, evaluation_run_id', 'cob3_learning.evaluation_runs', '@, evaluation_run_id', ''],
['cob3_learning.evaluation_results', 'evaluation_results_example_fk', '@, example_id', 'cob3_learning.examples', '@, example_id', ''],
['cob3_learning.evaluation_results', 'evaluation_results_evidence_fk', '@, evidence_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_learning.evaluation_results', 'evaluation_results_judge_call_fk', '@, judge_call_id', 'cob3_llmobs.invocations', '@, invocation_id', ''],
['cob3_learning.training_jobs', 'training_jobs_version_fk', '@, dataset_version_id', 'cob3_learning.dataset_versions', '@, dataset_version_id', ''],
['cob3_learning.training_jobs', 'training_jobs_runtime_run_fk', '@, runtime_run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_learning.training_jobs', 'training_jobs_base_model_fk', '@, base_model_deployment_id', 'cob3_agent.model_deployments', '@, model_deployment_id', ''],
['cob3_learning.training_jobs', 'training_jobs_result_model_fk', '@, result_model_deployment_id', 'cob3_agent.model_deployments', '@, model_deployment_id', ''],
['cob3_learning.training_jobs', 'training_jobs_integration_fk', 'tenant_id, integration_configuration_id', 'cob3_settings.integration_configurations', 'tenant_id, integration_configuration_id', ''],
-- cob3_llmobs
['cob3_llmobs.applications', 'applications_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_llmobs.application_environments', 'application_environments_application_fk', '@, application_id', 'cob3_llmobs.applications', '@, application_id', ''],
['cob3_llmobs.application_environments', 'application_environments_integration_fk', 'tenant_id, integration_configuration_id', 'cob3_settings.integration_configurations', 'tenant_id, integration_configuration_id', ''],
['cob3_llmobs.application_environments', 'application_environments_current_policy_fk', '@, application_environment_id, current_policy_version_id', 'cob3_llmobs.policy_versions', '@, application_environment_id, policy_version_id', 'd'],
['cob3_llmobs.policy_versions', 'policy_versions_environment_fk', '@, application_environment_id', 'cob3_llmobs.application_environments', '@, application_environment_id', ''],
['cob3_llmobs.invocations', 'invocations_environment_fk', '@, application_environment_id', 'cob3_llmobs.application_environments', '@, application_environment_id', ''],
['cob3_llmobs.invocations', 'invocations_policy_fk', '@, application_environment_id, policy_version_id', 'cob3_llmobs.policy_versions', '@, application_environment_id, policy_version_id', ''],
['cob3_llmobs.invocations', 'invocations_step_fk', '@, run_step_id', 'cob3_ai_runtime.run_steps', '@, step_id', ''],
['cob3_llmobs.invocations', 'invocations_context_fk', '@, execution_context_id', 'cob3_ai_runtime.execution_contexts', '@, execution_context_id', ''],
['cob3_llmobs.invocation_attempts', 'invocation_attempts_invocation_fk', '@, invocation_id', 'cob3_llmobs.invocations', '@, invocation_id', ''],
['cob3_llmobs.invocation_attempts', 'invocation_attempts_deployment_fk', '@, model_deployment_id', 'cob3_agent.model_deployments', '@, model_deployment_id', ''],
['cob3_llmobs.invocation_attempts', 'invocation_attempts_payload_fk', '@, content_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_llmobs.usage_charges', 'usage_charges_attempt_fk', '@, invocation_attempt_id', 'cob3_llmobs.invocation_attempts', '@, invocation_attempt_id', ''],
['cob3_llmobs.usage_charges', 'usage_charges_price_fk', '@, model_price_id', 'cob3_llmobs.model_prices', '@, model_price_id', ''],
['cob3_llmobs.usage_charges', 'usage_charges_adjusts_fk', '@, adjusts_charge_id', 'cob3_llmobs.usage_charges', '@, usage_charge_id', ''],
['cob3_llmobs.usage_charges', 'usage_charges_usage_event_fk', 'tenant_id, tenant_usage_event_id', 'cob3_tenant.usage_events', 'tenant_id, usage_event_id', ''],
['cob3_llmobs.guardrail_events', 'guardrail_events_policy_fk', '@, policy_version_id', 'cob3_llmobs.policy_versions', '@, policy_version_id', ''],
['cob3_llmobs.guardrail_events', 'guardrail_events_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_llmobs.guardrail_events', 'guardrail_events_invocation_fk', '@, invocation_id', 'cob3_llmobs.invocations', '@, invocation_id', ''],
['cob3_llmobs.guardrail_events', 'guardrail_events_evidence_fk', '@, evidence_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_llmobs.review_tasks', 'review_tasks_target_fk', '@, target_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_llmobs.review_tasks', 'review_tasks_assignee_fk', '@, assignee_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_llmobs.review_tasks', 'review_tasks_resolution_fk', '@, resolution_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_llmobs.retention_holds', 'retention_holds_target_fk', '@, target_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_llmobs.retention_holds', 'retention_holds_environment_fk', '@, application_environment_id', 'cob3_llmobs.application_environments', '@, application_environment_id', ''],
['cob3_llmobs.retention_holds', 'retention_holds_placed_by_fk', '@, placed_by_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_llmobs.retention_holds', 'retention_holds_released_by_fk', '@, released_by_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
-- cob3_ai_lineage
['cob3_ai_lineage.nodes', 'nodes_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_ai_lineage.edges', 'edges_source_fk', '@, source_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_ai_lineage.edges', 'edges_derived_fk', '@, derived_node_id', 'cob3_ai_lineage.nodes', '@, lineage_node_id', ''],
['cob3_ai_lineage.edges', 'edges_run_fk', '@, run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
-- cob3_connectors
['cob3_connectors.connections', 'connections_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_connectors.connections', 'connections_integration_fk', 'tenant_id, integration_configuration_id', 'cob3_settings.integration_configurations', 'tenant_id, integration_configuration_id', ''],
['cob3_connectors.connections', 'connections_executor_fk', '@, execution_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_connectors.connections', 'connections_grant_fk', '@, grant_id, execution_principal_id', 'cob3_identity.authorization_grants', '@, authorization_grant_id, grantee_principal_id', ''],
['cob3_connectors.connections', 'connections_credential_fk', '@, grant_id, credential_id', 'cob3_identity.principal_credentials', '@, authorization_grant_id, credential_id', ''],
['cob3_connectors.connections', 'connections_session_fk', 'tenant_id, auth_session_id', 'cob3_identity.auth_sessions', 'tenant_id, session_id', ''],
['cob3_connectors.sync_cursors', 'sync_cursors_connection_fk', '@, connection_id', 'cob3_connectors.connections', '@, connection_id', ''],
['cob3_connectors.sync_cursors', 'sync_cursors_payload_fk', '@, cursor_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_connectors.sync_cursors', 'sync_cursors_last_job_fk', '@, connection_id, last_successful_job_id', 'cob3_connectors.jobs', '@, connection_id, connector_job_id', 'd'],
['cob3_connectors.jobs', 'jobs_connection_fk', '@, connection_id', 'cob3_connectors.connections', '@, connection_id', ''],
['cob3_connectors.jobs', 'jobs_cursor_fk', '@, connection_id, sync_cursor_id', 'cob3_connectors.sync_cursors', '@, connection_id, sync_cursor_id', ''],
['cob3_connectors.jobs', 'jobs_runtime_run_fk', '@, runtime_run_id', 'cob3_ai_runtime.runs', '@, run_id', ''],
['cob3_connectors.job_attempts', 'job_attempts_job_fk', '@, connector_job_id', 'cob3_connectors.jobs', '@, connector_job_id', ''],
['cob3_connectors.job_attempts', 'job_attempts_worker_fk', '@, worker_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', ''],
['cob3_connectors.records', 'records_connection_fk', '@, connection_id', 'cob3_connectors.connections', '@, connection_id', ''],
['cob3_connectors.records', 'records_payload_fk', '@, content_payload_id', 'cob3_ai_runtime.payloads', '@, payload_id', ''],
['cob3_connectors.records', 'records_asset_fk', '@, asset_id', 'cob3_catalog.assets', '@, asset_id', ''],
['cob3_connectors.records', 'records_last_job_fk', '@, connection_id, last_job_id', 'cob3_connectors.jobs', '@, connection_id, connector_job_id', ''],
['cob3_connectors.source_scope_bindings', 'source_scope_bindings_connection_fk', '@, source_connection_id', 'cob3_connectors.connections', '@, connection_id', ''],
['cob3_connectors.source_scope_bindings', 'source_scope_bindings_approver_fk', '@, approved_by_principal_id', 'cob3_identity.organization_memberships', '@, principal_id', '']
]::text[] LOOP
    EXECUTE pg_catalog.format(
        'ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES %s (%s) ON UPDATE RESTRICT ON DELETE RESTRICT%s',
        _m_def[1], _m_def[2],
        pg_catalog.replace(_m_def[3], '@', 'tenant_id, organization_id'),
        _m_def[4],
        pg_catalog.replace(_m_def[5], '@', 'tenant_id, organization_id'),
        CASE WHEN _m_def[6] = 'd' THEN ' DEFERRABLE INITIALLY DEFERRED' ELSE '' END);
END LOOP;

-- Index every foreign key that no existing index covers with the same leading
-- columns (deterministic names: <constraint>_ix).
FOR _m_rec IN
    SELECT c.conrelid::regclass AS tbl, c.conname,
           (SELECT pg_catalog.string_agg(pg_catalog.quote_ident(a.attname), ', ' ORDER BY k.ord)
              FROM pg_catalog.unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum) AS cols
      FROM pg_catalog.pg_constraint c
     WHERE c.contype = 'f'
       AND c.connamespace::regnamespace::text = ANY (_m_schemas)
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                        WHERE i.indrelid = c.conrelid
                          AND (i.indkey::int2[])[0:pg_catalog.array_length(c.conkey, 1) - 1] @> c.conkey
                          AND (i.indkey::int2[])[0:pg_catalog.array_length(c.conkey, 1) - 1] <@ c.conkey)
     ORDER BY 1, 2
LOOP
    EXECUTE pg_catalog.format('CREATE INDEX %I ON %s (%s)', pg_catalog.left(_m_rec.conname, 60) || '_ix', _m_rec.tbl, _m_rec.cols);
END LOOP;

-- Access-path indexes (design section 10).
CREATE INDEX runs_status_deadline_ix ON cob3_ai_runtime.runs (tenant_id, organization_id, status, deadline_at);
CREATE INDEX runs_active_ix ON cob3_ai_runtime.runs (status, deadline_at) WHERE status IN ('queued', 'running', 'waiting_input', 'waiting_approval', 'cancellation_requested');
CREATE UNIQUE INDEX run_attempts_one_live_uix ON cob3_ai_runtime.run_attempts (tenant_id, organization_id, run_id) WHERE status IN ('queued', 'running');
CREATE INDEX run_attempts_lease_ix ON cob3_ai_runtime.run_attempts (status, lease_until) WHERE status IN ('queued', 'running');
CREATE INDEX outbox_dispatch_ix ON cob3_ai_runtime.outbox (status, available_at) WHERE status IN ('pending', 'leased', 'failed');
CREATE INDEX interrupts_pending_ix ON cob3_ai_runtime.interrupts (tenant_id, organization_id, expires_at) WHERE status = 'pending';
CREATE INDEX messages_branch_sequence_ix ON cob3_copilot.messages (tenant_id, organization_id, branch_id, sequence);
CREATE INDEX search_documents_vector_ix ON cob3_copilot.search_documents USING gin (search_vector);
CREATE INDEX items_container_status_ix ON cob3_memory.items (tenant_id, organization_id, container_id, status, valid_from);
CREATE INDEX edges_derived_ix ON cob3_ai_lineage.edges (tenant_id, organization_id, derived_node_id);
CREATE INDEX invocation_attempts_time_ix ON cob3_llmobs.invocation_attempts (tenant_id, organization_id, started_at);
CREATE INDEX invocations_time_ix ON cob3_llmobs.invocations (tenant_id, organization_id, application_environment_id, started_at);
CREATE UNIQUE INDEX training_jobs_provider_uix ON cob3_learning.training_jobs (tenant_id, integration_configuration_id, provider_job_id)
    WHERE provider_job_id IS NOT NULL;
CREATE UNIQUE INDEX job_attempts_one_live_uix ON cob3_connectors.job_attempts (tenant_id, organization_id, connector_job_id) WHERE status = 'running';
CREATE INDEX jobs_runnable_ix ON cob3_connectors.jobs (status, available_at) WHERE status = 'queued';
CREATE INDEX connections_due_ix ON cob3_connectors.connections (next_run_at) WHERE enabled;
