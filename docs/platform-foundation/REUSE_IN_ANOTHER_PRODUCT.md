# Reusing the foundation in another Syskriti product

## Model: isolated per-product tenancy (v1)

Each product gets **its own database** with the same installer, migration history, entity model,
security rules and provisioning workflow. There is no shared cross-product identity database, no
cross-product SSO, no product subscriptions and no `product_id` column. A customer of two products is two
independent tenants. A future shared-account strategy (central identity, product entitlements,
federation between deployments) is a separate architecture decision and a separate migration line.

## Install

1. Create the product database (outside the installer) and a migration login with CREATE on it and
   CREATEROLE — or have the DBA pre-create the four `cob3_*` roles and `GRANT cob3_owner` to it.
2. Run `INSTALL_FOUNDATION.sql`, then `VERIFY_FOUNDATION.sql`.
3. Create product logins and grant exactly one foundation role each
   (`cob3_runtime`, `cob3_provisioner`, `cob3_commercial_admin`).

Role names are cluster-wide. Prefer one PostgreSQL cluster per product. If products share a cluster,
revoke `CONNECT` on every product database from `PUBLIC` and grant `CONNECT` only to that product's
logins, so a login of product A cannot connect to product B even though both use `cob3_runtime`.

## Product seeds (do not copy Observei's)

Write `seeds/<product>_catalog_and_iam.sql` modeled on `seeds/optional_observei_examples.sql`:

* **Platform catalog (as `cob3_commercial_admin`):** product features (`value_type`, `unit_code`,
  `measurement_kind` chosen deliberately — they become immutable once used), plans, versions,
  entitlements and prices. Publish only after commercial review. Include the 7 core identity features in
  every plan; missing entitlement means disabled.
* **Per-tenant IAM (as `cob3_provisioner`):** call `register_tenant_permission`, `register_tenant_role`
  and `add_role_permission` for each tenant (they are idempotent and refuse conflicting redefinitions).
  Product permission codes need real endpoints; a row alone creates no behavior.
* Resource-dependent product permissions stay denied until the Catalog adapter resolves those resource
  types.

## Bind the Catalog adapter

When the product's Catalog module exists, satisfy
`future_integrations/catalog_integration_contract.md` (composite keys, `resource_type`,
`primary_domain_id`, SELECT/REFERENCES for `cob3_owner`) and run the reviewed integration migration
derived from `catalog_integration.sql.template`. It verifies first and changes nothing on failure.

## Upgrade the shared foundation without forking

* Changes go into `src/` of the foundation package; `build_installer.py` regenerates the fresh
  installer, and an **ordered migration** (`migrations/002_…sql`) alters existing installations and
  records a new `foundation_installations` row. Products adopt releases by applying migrations in order.
* Product-specific behavior lives only in product seeds, product Catalog resolvers and backend code —
  never in edits to core objects. If a product needs a core change, contribute it to the foundation.
* CI for every product should run `python build_installer.py --check`, the foundation test suite against
  a disposable server, and `VERIFY_FOUNDATION.sql` after migrations.
