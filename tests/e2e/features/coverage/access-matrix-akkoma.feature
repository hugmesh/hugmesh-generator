# ─────────────────────────────────────────────────────────────────────────────
# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Emitted by tests/e2e/tools/emit-coverage-matrix.ts from three catalogues:
#   personas   specs/rbac-roles.ts SYSTEMS_SEED_USERS
#              + tests/e2e-extra-personas.sh
#              + tests/qemu/seed-accounts.sh SYSTEMS_ROLE_USERS
#   services   tests/e2e/steps/dimensions.ts SERVICES
#   functions  tests/e2e/steps/coverage-catalogue.ts FUNCTIONS
#
# Regenerate with:  bash tests/e2e/gen-coverage-matrix.sh
# The drift guard tests/scripts/test-e2e-coverage-matrix.sh re-emits into a
# scratch dir and DIFFS against these files, so an edit here — or a catalogue
# change that was never re-emitted — turns the guard RED.
# ─────────────────────────────────────────────────────────────────────────────
#
# Mastodon-compatible server (akkoma) — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 31 personas x 9 functions = 279 cells.
# 9 of 9 function probe paths are DERIVED from a committed artefact;
# 0 are ASSERTED (no artefact pins them yet) — see the FUNCTIONS entry's
# `source` field, which the function-catalogue feature pins row by row.
#
# COLUMNS
#   role     the persona handle, from the union of the three seeding rosters
#   function the catalogued function id (steps/coverage-catalogue.ts FUNCTIONS)
#   outcome  what the COMMITTED gateway_route_access seed decides for that
#            persona's effective role-set — admitted | refused
#   pattern  the url_pattern that won the most-specific match, or
#            "(none — default deny)" when the seed governs no pattern at all
#   source   which seeding lanes create this persona. The three rosters DISAGREE;
#            the disagreement is shown here rather than resolved behind the scenes.
@layer:gateway @service:akkoma @coverage-matrix
Feature: Mastodon-compatible server (akkoma) — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:akkoma
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function                 | outcome  | pattern                  | source                         |
      | admin@hugmesh.net            | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.sign-in           | admitted | /oauth/**                | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.post              | admitted | /api/v1/**               | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.boost             | admitted | /api/v1/**               | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.follow            | admitted | /api/v1/**               | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.timeline          | admitted | /api/v1/**               | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.delete-post       | admitted | /api/v1/**               | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.moderate          | admitted | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | admin@hugmesh.net            | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | alice@gmail.com              | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | alice@gmail.com              | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | alice@gmail.com              | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | alice@gmail.com              | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | alice@gmail.com              | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | alice@gmail.com              | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | alice@gmail.com              | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | alice@gmail.com              | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | alice@gmail.com              | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | bob@gmail.com                | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | bob@gmail.com                | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | bob@gmail.com                | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | bob@gmail.com                | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | bob@gmail.com                | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | bob@gmail.com                | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | bob@gmail.com                | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | bob@gmail.com                | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | bob@gmail.com                | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | carol@gmail.com              | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | carol@gmail.com              | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | carol@gmail.com              | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | carol@gmail.com              | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | carol@gmail.com              | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | carol@gmail.com              | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | carol@gmail.com              | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | carol@gmail.com              | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | carol@gmail.com              | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | dave@gmail.com               | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | dave@gmail.com               | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | dave@gmail.com               | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | dave@gmail.com               | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | dave@gmail.com               | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | dave@gmail.com               | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | dave@gmail.com               | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | dave@gmail.com               | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | dave@gmail.com               | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | dragoneer                    | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | dragoneer                    | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | dragoneer                    | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | dragoneer                    | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | dragoneer                    | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | dragoneer                    | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | dragoneer                    | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | dragoneer                    | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | dragoneer                    | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | e2e-admin                    | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.sign-in           | admitted | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.post              | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.boost             | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.follow            | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.timeline          | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.delete-post       | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.moderate          | admitted | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.sign-in           | admitted | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.post              | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.boost             | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.follow            | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.timeline          | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.delete-post       | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.moderate          | admitted | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | e2e-banned                   | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | e2e-banned                   | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-banned                   | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-banned                   | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-banned                   | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-banned                   | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-banned                   | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | e2e-banned                   | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | e2e-denied                   | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | e2e-fleet                    | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | e2e-fleet                    | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-fleet                    | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-fleet                    | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-fleet                    | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-fleet                    | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | e2e-fleet                    | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | e2e-fleet                    | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | e2e-forum                    | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.sign-in           | admitted | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.post              | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.boost             | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.follow            | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.timeline          | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.delete-post       | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.moderate          | admitted | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.sign-in           | admitted | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.post              | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.boost             | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.follow            | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.timeline          | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.delete-post       | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.sign-in           | admitted | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.post              | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.boost             | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.follow            | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.timeline          | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.delete-post       | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.sign-in           | admitted | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.post              | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.boost             | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.follow            | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.timeline          | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.delete-post       | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.open-ui           | refused  | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.sign-in           | admitted | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.post              | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.boost             | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.follow            | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.timeline          | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.delete-post       | admitted | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.moderate          | admitted | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | akkoma.provision-account | refused  | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.open-ui           | refused  | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | akkoma.provision-account | refused  | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | akkoma.open-ui           | refused  | /social/mastodon/**      | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | akkoma.provision-account | refused  | /bff/provision/**        | extra-personas-sh+ts-catalogue |
      | e2e-user                     | akkoma.open-ui           | admitted | /social/mastodon/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.sign-in           | refused  | /oauth/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.post              | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.boost             | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.follow            | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.timeline          | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.delete-post       | refused  | /api/v1/**               | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | akkoma.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | eve@gmail.com                | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | eve@gmail.com                | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | eve@gmail.com                | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | eve@gmail.com                | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | eve@gmail.com                | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | eve@gmail.com                | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | eve@gmail.com                | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | eve@gmail.com                | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | frank@gmail.com              | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | frank@gmail.com              | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | frank@gmail.com              | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | frank@gmail.com              | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | frank@gmail.com              | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | frank@gmail.com              | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | frank@gmail.com              | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | frank@gmail.com              | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | frank@gmail.com              | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.open-ui           | admitted | /social/mastodon/**      | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.sign-in           | refused  | /oauth/**                | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.post              | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.boost             | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.follow            | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.timeline          | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.delete-post       | refused  | /api/v1/**               | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.moderate          | refused  | /api/v1/pleroma/admin/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | akkoma.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
