# The ROLE axis of this domain, stated as a tripwire instead of a lament.
#
# Each service here is gated on its own per-service ACCESS role. Three of those
# roles — ROLE_WIKI, ROLE_OWNCAST, ROLE_TUBE — are held by NO persona in either
# e2e roster (specs/rbac-roles.ts SYSTEMS_SEED_USERS and
# tests/e2e-extra-personas.sh). That is why this domain's console features drive
# wiki/owncast/tube as an ADMIN and not as the member the service was built for:
# the member does not exist. Signing in as one would 401 at setup and read like a
# broken login, which is the exact 2026-08-06 e2e-fleet symptom
# tests/scripts/test-e2e-persona-catalogue.sh was written about.
#
# Asserting the gap does two things a comment cannot. It keeps the gap visible in
# the run output next to the coverage it limits, and it makes the day the gap
# CLOSES loud: seed a `e2e-wiki:ROLE_WIKI,ROLE_USER:E2E_WIKI_PASSWORD` persona
# and the first scenario below fails, which is the prompt to go and widen the
# console features that are currently admin-only.
#
# Runs with the stack DOWN — it reads the two rosters, not a live Casdoor.
@harness @layer:casdoor
Feature: Which uncovered services the e2e roster can actually sign in and drive

  Scenario Outline: nothing seeds <access_role>, so no member persona can drive <service> @service:<service> @layer:casdoor
    Then no persona in the e2e roster holds the access role "<access_role>"

    Examples:
      | service | access_role  |
      | wiki    | ROLE_WIKI    |
      | owncast | ROLE_OWNCAST |
      | tube    | ROLE_TUBE    |

  Scenario Outline: <service> has a seeded persona that can drive it as its real audience @service:<service> @layer:casdoor
    Then some persona in the e2e roster holds the access role "<access_role>"

    Examples:
      | service          | access_role |
      | phpbb            | ROLE_FORUM  |
      | games            | ROLE_GAMES  |
      | character-studio | ROLE_USER   |
      | character-forge  | ROLE_USER   |
