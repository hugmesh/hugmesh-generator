# federation_modules registration — character-studio (TODO: separate repo)

The `character-studio` slug must be registered as a federation module so the Angular
host loads its remote at runtime and the public `/api/federation/capabilities`
projection can grey it out when not installed. That registry row is a **Liquibase
changeset**, and the `federation_modules` table + its changelog live in the
**`snapdragon-federation-api`** repo — **NOT** in this generator repo. This file is
the placeholder/TODO the optional-service contract requires until that repo's wave
lands; the canonical metadata also lives inline in
`specs/cluster/optional-services.yaml` (slug: character-studio → federationModule).

## Where to add it

Repo: `Snapdragon-Systems/snapdragon-federation-api`

1. New file: `src/main/resources/db/changelog/036-register-character-studio-module.xml`
   (036 is the next free number after the current tail `035-user-modules-domain.xml`).
2. Append an `<include>` to `src/main/resources/db/changelog/db.changelog-master.xml`
   immediately after the existing `035-user-modules-domain.xml` include:

   ```xml
   <include file="db/changelog/036-register-character-studio-module.xml"/>
   ```

Mirrors `025-register-games-module.xml` / `033-register-tube-module.xml`
field-for-field, with the character-studio-specific slug / mountAt / role.

## Exact changeset to add (`036-register-character-studio-module.xml`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-4.29.xsd">

    <!--
        REGISTER character-studio (the VN character-studio remote: layered-2D
        character creator + chat surface) as a federation module — the registry row
        the Angular host loads at runtime + the row the PUBLIC
        /api/federation/capabilities projection reports so a logged-out / non-admin
        host can grey-out the service when it is NOT installed.

        character-studio is an OPTIONAL service (DEFAULT-OFF, admin gate;
        add/remove-by-command on a generated USB). It is an Angular native-federation
        REMOTE (kind = 'remote-shell', like the forum/games/tube/owncast rows), served
        at the apex PATH /character-studio with a ROLE_USER floor. Mirrors
        025-games / 033-tube field-for-field with the character-studio specifics.

        Idempotent: the preCondition (MARK_RAN, slug-absent) seeds only when the
        'character-studio' slug is absent, so re-running over an existing DB is a
        no-op. remote_entry_url is the platform service-DNS placeholder the
        deployment's Service wires at runtime
        (http://snapdragon-character-studio-ui:8080/remoteEntry.json).
    -->

    <changeSet id="036-1-register-character-studio-module" author="federation">
        <preConditions onFail="MARK_RAN">
            <sqlCheck expectedResult="0">
                SELECT COUNT(*) FROM federation_modules WHERE slug = 'character-studio'
            </sqlCheck>
        </preConditions>
        <insert tableName="federation_modules">
            <column name="slug" value="character-studio"/>
            <column name="display_name" value="Character Studio (VN)"/>
            <column name="kind" value="remote-shell"/>
            <column name="remote_entry_url" value="http://snapdragon-character-studio-ui:8080/remoteEntry.json"/>
            <column name="exposed_module" value="./routes"/>
            <column name="version" value="0.1.0"/>
            <column name="visibility" value="internal"/>
            <column name="enabled" valueBoolean="false"/>
            <column name="circuit_state" value="closed"/>
            <column name="metadata" value="{&quot;requiresRole&quot;:&quot;ROLE_USER&quot;,&quot;mountAt&quot;:&quot;/character-studio&quot;}"/>
        </insert>
    </changeSet>

</databaseChangeLog>
```

## Optional: reserved-profile-slug guard

If the project wants a vanity-username collision guard for `character-studio` (as
done for tube in `032-reserved-profile-slug-tube.xml`), add a sibling changeset that
drops + re-adds `ck_fed_modules_reserved_profile_slug` with `'profile-character-studio'`
inserted alphabetically. This is OPTIONAL and NOT required for the remote to mount.

## Why a placeholder here instead of the changeset in this repo

`gate_optional_services()` prunes this whole `manifests/character-studio/` dir when
the slug is deselected, so this TODO travels with the slug. The actual changeset
cannot live here because the generator does not own the federation DB schema — that
is the federation-api repo's Liquibase changelog. The generator records the
mountAt / requiresRole / exposed metadata in `optional-services.yaml` so it can
derive / verify the registration when the federation-api wave runs.
