# federation_modules registration — character-forge (TODO: separate repo)

> **STATUS 2026-08-26 — THIS WAVE HAS LANDED. The number below is WRONG.**
> The registration shipped in `hugmesh-federation-api` as
> `src/main/resources/db/changelog/038-register-character-forge-module.xml`, not the `037-…`
> this file predicted: 036 and 037 were taken first by the unrelated
> `036-system-findings.xml` / `037-system-findings-subject-ref.xml` pair, so every
> "next free number" claim below went stale. `specs/cluster/optional-services.yaml`
> now names the real changeset, and `scripts/validate-federation-module-slugs.sh`
> re-derives both sides each run so this cannot drift again unnoticed. The changeset
> body below is kept only as the historical record of what was requested — the
> shipped one is authoritative and, being merged Liquibase history, immutable.


The `character-forge` slug must be registered as a federation module so the Angular
host loads its remote at runtime and the public `/api/federation/capabilities`
projection can grey it out when not installed. That registry row is a **Liquibase
changeset**, and the `federation_modules` table + its changelog live in the
**`hugmesh-federation-api`** repo — **NOT** in this generator repo. This file is
the placeholder/TODO the optional-service contract requires until that repo's wave
lands; the canonical metadata also lives inline in
`specs/cluster/optional-services.yaml` (slug: character-forge → federationModule).

## Where to add it

Repo: `hugmesh/hugmesh-federation-api`

1. New file: `src/main/resources/db/changelog/037-register-character-forge-module.xml`
   (036 is already reserved for character-studio — see
   `manifests/character-studio/FEDERATION-REGISTRATION-TODO.md` — so character-forge
   takes the NEXT free number, 037).
2. Append an `<include>` to `src/main/resources/db/changelog/db.changelog-master.xml`
   immediately after the `036-register-character-studio-module.xml` include:

   ```xml
   <include file="db/changelog/037-register-character-forge-module.xml"/>
   ```

Mirrors `025-register-games-module.xml` / `036-register-character-studio-module.xml`
field-for-field, with the character-forge-specific slug / mountAt / role.

## Exact changeset to add (`037-register-character-forge-module.xml`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-4.29.xsd">

    <!--
        REGISTER character-forge (the Character Forge 3D character maker: SVG-VN →
        3D mapping studio + the XR chat room's avatar source) as a federation
        module — the registry row the Angular host loads at runtime + the row the
        PUBLIC /api/federation/capabilities projection reports so a logged-out /
        non-admin host can grey-out the service when it is NOT installed.

        character-forge is an OPTIONAL service (DEFAULT-OFF, admin gate;
        add/remove-by-command on a generated USB). It is an Angular native-federation
        REMOTE (kind = 'remote-shell', like the forum/games/tube/character-studio
        rows), served at the apex PATH /character-forge with a ROLE_USER floor.

        Idempotent: the preCondition (MARK_RAN, slug-absent) seeds only when the
        'character-forge' slug is absent, so re-running over an existing DB is a
        no-op. remote_entry_url is the platform service-DNS placeholder the
        deployment's Service wires at runtime
        (http://hugmesh-character-forge-ui:8080/remoteEntry.json).
    -->

    <changeSet id="037-1-register-character-forge-module" author="federation">
        <preConditions onFail="MARK_RAN">
            <sqlCheck expectedResult="0">
                SELECT COUNT(*) FROM federation_modules WHERE slug = 'character-forge'
            </sqlCheck>
        </preConditions>
        <insert tableName="federation_modules">
            <column name="slug" value="character-forge"/>
            <column name="display_name" value="Character Forge (3D)"/>
            <column name="kind" value="remote-shell"/>
            <column name="remote_entry_url" value="http://hugmesh-character-forge-ui:8080/remoteEntry.json"/>
            <column name="exposed_module" value="./routes"/>
            <column name="version" value="0.1.0"/>
            <column name="visibility" value="internal"/>
            <column name="enabled" valueBoolean="false"/>
            <column name="circuit_state" value="closed"/>
            <column name="metadata" value="{&quot;requiresRole&quot;:&quot;ROLE_USER&quot;,&quot;mountAt&quot;:&quot;/character-forge&quot;}"/>
        </insert>
    </changeSet>

</databaseChangeLog>
```

## ReservedNames sync

The `character-forge` label is reserved in `specs/cluster/reserved-prefixes.yaml`
(revision 9) together with the games-side `games-character-forge` +
`games-shadows-of-the-net` labels. The four app-repo ReservedNames copies
(federation-api, user-bff-api, hugmesh-actions, admin-bff-api) must add the same
labels in the same wave — `scripts/validate-reserved-prefixes.sh`'s code-copy
assertion flags the drift when the sibling repos are present in CI.

## Why a placeholder here instead of the changeset in this repo

`gate_optional_services()` prunes this whole `manifests/character-forge/` dir (plus
`manifests/character-forge-bff-api/` + `manifests/character-forge-bff-db/`) when the
slug is deselected, so this TODO travels with the slug. The actual changeset cannot
live here because the generator does not own the federation DB schema — that is the
federation-api repo's Liquibase changelog. The generator records the
mountAt / requiresRole / exposed metadata in `optional-services.yaml` so it can
derive / verify the registration when the federation-api wave runs.
