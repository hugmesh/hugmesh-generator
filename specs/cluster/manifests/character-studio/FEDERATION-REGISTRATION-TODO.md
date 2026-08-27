# federation_modules registration — character-studio (DONE)

The `character-studio` slug is registered as a federation module in the
**`hugmesh-federation-api`** repo (Liquibase changelog — not in this generator
repo): `040-register-character-studio-module.xml`, included in
`db.changelog-master.xml`. (It landed as changeset 040, not the 036 this file
originally predicted — 036 was taken by an unrelated changeset by the time this
wave ran.)

The canonical mountAt / requiresRole / exposed metadata still lives inline in
`specs/cluster/optional-services.yaml` (slug: character-studio → federationModule).
