# federation_modules registration — character-forge (DONE)

The `character-forge` slug is registered as a federation module in the
**`hugmesh-federation-api`** repo (Liquibase changelog — not in this generator
repo): `038-register-character-forge-module.xml`, plus a follow-up
`039-rebrand-character-forge-remote-entry.xml` that repoints `remote_entry_url`
after the rebrand. Both are included in `db.changelog-master.xml`.

The canonical mountAt / requiresRole / exposed metadata still lives inline in
`specs/cluster/optional-services.yaml` (slug: character-forge → federationModule).
