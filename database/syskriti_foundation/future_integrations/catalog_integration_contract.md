# Catalog integration contract (future, not installed)

**Status:** PENDING. The foundation installer creates only `cob3_tenant` and
`cob3_identity`. Every Catalog-dependent path currently **fails closed**:

| Operation | Behavior now | Mechanism |
|---|---|---|
| `access_scopes` with `scope_type` `domain` / `asset` | rejected, SQLSTATE `SKCAT` | `trg_05_catalog_guard` → `cob3_identity.assert_catalog_domain/asset` |
| `team_domains` insert/update | rejected, `SKCAT` | `trg_05_catalog_guard` → `assert_catalog_domain` |
| Team role binding on domain/asset scope | rejected, `SKCAT` | `tg_role_bindings_validate` |
| Authorization of any target other than the organization itself (domains, applications, dashboards, incidents, logs, …) | denied (`rbac_denied` / `no_matching_grant_entry`) | `cob3_identity.catalog_scope_covers(...)` returns `false` |
| Organization-scoped identity/admin operations | **work** | `scope_covers_target` organization branch |

`access_scopes.domain_id`, `access_scopes.asset_id` and `team_domains.domain_id`
are **not foreign keys yet**. Nothing in the database currently proves that
such an ID exists; that is exactly why writes are rejected.

## What the Catalog module must provide

Schema `cob3_catalog` in the same database, with at least:

```sql
cob3_catalog.domains (
    tenant_id       uuid NOT NULL,
    organization_id uuid NOT NULL,
    domain_id       uuid NOT NULL,
    status          varchar NOT NULL,           -- 'active' = usable
    UNIQUE (tenant_id, organization_id, domain_id),
    FOREIGN KEY (tenant_id, organization_id) REFERENCES cob3_identity.organizations (tenant_id, organization_id)
);
cob3_catalog.assets (
    tenant_id         uuid NOT NULL,
    organization_id   uuid NOT NULL,
    asset_id          uuid NOT NULL,
    resource_type     varchar NOT NULL,         -- equals the permission resource_type, e.g. 'application'
    primary_domain_id uuid NULL,                -- ONE authorization domain per asset (v1)
    status            varchar NOT NULL,         -- 'active' = usable
    UNIQUE (tenant_id, organization_id, asset_id),
    FOREIGN KEY (tenant_id, organization_id, primary_domain_id)
        REFERENCES cob3_catalog.domains (tenant_id, organization_id, domain_id)
);
```

and `GRANT SELECT, REFERENCES ON cob3_catalog.domains, cob3_catalog.assets TO cob3_owner`
(automatic if `cob3_owner` owns the Catalog schema). Multi-domain tagging is not
authorization membership; only `primary_domain_id` is used for scope decisions.

## What `catalog_integration.sql.template` does (one atomic statement)

1. **Verifies first, changes nothing on failure:** foundation 1.0.0 installed;
   Catalog component not already installed; `cob3_catalog.domains`/`assets`
   exist with the columns and types above; the composite UNIQUE keys exist;
   `cob3_owner` has SELECT + REFERENCES; no existing identity rows would violate
   the new FKs.
2. Adds the real FKs `NOT VALID`, then `VALIDATE CONSTRAINT`s them:
   `access_scopes_domain_fk`, `access_scopes_asset_fk`, `team_domains_domain_fk`.
3. Replaces (same signatures, privileges and owner preserved) the guards with a
   trusted resolver:
   * `assert_catalog_domain/asset` → accept only existing **active** rows of the
     same tenant and organization;
   * `catalog_scope_covers` → organization scope + `include_contained_assets`
     covers active assets of the organization; domain scope covers the domain
     and (with containment) assets whose primary domain is that domain; asset
     scope covers that asset; team bindings on domain/asset scopes additionally
     require an active `team_domains` responsibility for the (primary) domain;
     permission `resource_type` must equal the target type;
   * `catalog_integration_installed()` → `true`.
4. Records component `catalog_integration` in `cob3_tenant.foundation_installations`.

Only after all of this succeeds in the same transaction do domain/asset
operations become available. There is no always-true validator at any point.

## After installation

* Catalog moves between domains/organizations, ownership changes, team-domain
  changes and role edits are authorization-changing events: invalidate caches
  and re-check affected grants (evaluation is live; no cache is shipped).
* Cross-organization asset moves require explicit migration/rebinding, never an
  in-place `organization_id` rewrite (scope IDs are immutable here anyway).
* Asset grants with fixed lists use asset scopes; domain scopes with
  `include_contained_assets = true` intentionally include future assets.
