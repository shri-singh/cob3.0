-- =============================================================================
-- NONPRODUCTION EXAMPLE  --  DO NOT RUN IN PRODUCTION
-- Syskriti foundation: bootstrap one synthetic tenant
-- -----------------------------------------------------------------------------
-- Purpose : demonstrate the supported, controlled bootstrap path on a DISPOSABLE
--           database: tenant -> per-tenant IAM seed -> organization -> human
--           principal/profile -> membership -> tenant administrator and
--           organization administrator bindings -> (synthetic) identity
--           provider link -> activation.
-- Values  : synthetic only (.invalid domains, example-* codes). No passwords,
--           tokens, secrets or real customer data. No default credentials:
--           the example admin can only sign in through a real IdP that you
--           configure, never with a password.
-- Security: uses the cob3_provisioner routines; RLS and constraints stay on.
--           The bootstrap routine refuses tenants that are already active or
--           already have an administrator, so it is not a permanent open door.
-- Rerun   : safe; if the example tenant already exists it does nothing.
--
-- Prerequisites (disposable database only):
--   1. INSTALL_FOUNDATION.sql has been executed.
--   2. Your login can SET ROLE cob3_provisioner, e.g. as a DBA:
--        GRANT cob3_provisioner TO <your_login>;
--
-- Real onboarding: call cob3_identity.bootstrap_tenant(...) from the trusted
-- provisioning service with values from the signed customer order:
--   * tenant_code/name/legal name/home_region from the contract,
--   * admin principal_code/display name/email from the verified customer contact,
--   * p_request_id = the onboarding request's idempotency UUID,
--   * identity provider issuer = the customer's real IdP issuer URL, and
--     configuration_reference = the Settings/secret-manager reference that holds
--     its client configuration (never the secret itself),
--   * external identity subject = the exact, stable `sub` (OIDC) / NameID (SAML)
--     asserted by that IdP for the administrator (no case folding, never email).
-- Then create the subscription through the commercial service before relying
-- on quota-governed operations (missing entitlement means disabled).
-- =============================================================================
BEGIN;

SET LOCAL ROLE cob3_provisioner;

DO $example$
DECLARE
    v_tenant  uuid;
    v_org     uuid;
    v_admin   uuid;
    v_idp     uuid;
    v_ext     uuid;
BEGIN
    IF EXISTS (SELECT 1 FROM cob3_tenant.tenants WHERE tenant_code = 'example-tenant') THEN
        RAISE NOTICE 'NONPRODUCTION EXAMPLE: tenant example-tenant already exists; nothing to do.';
        RETURN;
    END IF;

    -- 1. Tenant + IAM seed + first organization + administrator (kept in
    --    'provisioning' so the synthetic IdP can be attached before activation).
    SELECT b.tenant_id, b.organization_id, b.admin_principal_id
      INTO v_tenant, v_org, v_admin
      FROM cob3_identity.bootstrap_tenant(
               p_tenant_code          => 'example-tenant',
               p_tenant_name          => 'Example Tenant (synthetic)',
               p_legal_name           => NULL,
               p_home_region          => 'example-region',
               p_organization_code    => 'example-org',
               p_organization_name    => 'Example Organization (synthetic)',
               p_admin_principal_code => 'example-admin',
               p_admin_display_name   => 'Example Administrator',
               p_admin_email          => 'admin@example.invalid',
               p_request_id           => '6f1c2a5e-0000-4000-8000-00000000e001'::uuid,
               p_activate             => false,
               p_actor                => 'system:bootstrap-example') AS b;

    -- 2. Synthetic identity provider and subject mapping. Replace with the real
    --    issuer, configuration reference and IdP subject in a real onboarding.
    v_idp := cob3_identity.bootstrap_identity_provider(
                 v_tenant, 'example-oidc', 'Example OIDC provider (synthetic)', 'oidc',
                 'https://idp.example.invalid/', 'settings://identity-providers/example-oidc',
                 'system:bootstrap-example');
    v_ext := cob3_identity.bootstrap_link_external_identity(
                 v_tenant, v_admin, v_idp, 'synthetic-subject-0001', 'system:bootstrap-example');

    -- 3. Activate (recorded atomically in tenant_lifecycle_events).
    PERFORM cob3_tenant.transition_tenant_status(
                v_tenant, 'active', 'NONPRODUCTION EXAMPLE bootstrap complete',
                '6f1c2a5e-0000-4000-8000-00000000e002'::uuid, 'system:bootstrap-example');

    RAISE NOTICE 'NONPRODUCTION EXAMPLE: tenant %, organization %, administrator %, identity provider %',
        v_tenant, v_org, v_admin, v_idp;
END
$example$;

COMMIT;

-- Optional read-back (run as the database owner / migration role, which is a
-- member of cob3_owner; the provisioner role intentionally cannot read
-- identity tables):
-- SELECT t.tenant_code, t.status, o.organization_code, p.principal_code, r.role_code
--   FROM cob3_tenant.tenants t
--   JOIN cob3_identity.organizations o ON o.tenant_id = t.tenant_id
--   JOIN cob3_identity.tenant_role_bindings b ON b.tenant_id = t.tenant_id
--   JOIN cob3_identity.principals p ON p.tenant_id = b.tenant_id AND p.principal_id = b.principal_id
--   JOIN cob3_identity.roles r ON r.tenant_id = b.tenant_id AND r.role_id = b.role_id
--  WHERE t.tenant_code = 'example-tenant';
