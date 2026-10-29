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
# Matrix homeserver (tuwunel) — the ACCESS MATRIX: every seeded persona against every catalogued
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
@layer:gateway @service:tuwunel @coverage-matrix
Feature: Matrix homeserver (tuwunel) — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:tuwunel
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function                  | outcome  | pattern                  | source                         |
      | admin@hugmesh.net            | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.join-room         | admitted | /_matrix/**              | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.send-message      | admitted | /_matrix/**              | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.receive-message   | admitted | /_matrix/**              | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.start-call        | admitted | /_matrix/**              | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.leave-room        | admitted | /_matrix/**              | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.well-known        | admitted | /.well-known/matrix/**   | extra-personas-sh              |
      | admin@hugmesh.net            | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | alice@gmail.com              | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | bob@gmail.com                | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | carol@gmail.com              | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | dave@gmail.com               | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | dragoneer                    | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | dragoneer                    | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | dragoneer                    | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | dragoneer                    | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | dragoneer                    | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | dragoneer                    | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | dragoneer                    | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | dragoneer                    | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | dragoneer                    | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | e2e-admin                    | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | e2e-banned                   | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | e2e-banned                   | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-banned                   | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-banned                   | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-banned                   | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-banned                   | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-banned                   | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | e2e-banned                   | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | e2e-denied                   | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | e2e-fleet                    | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | e2e-forum                    | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.sign-in           | admitted | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.open-ui           | refused  | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.join-room         | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.send-message      | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.receive-message   | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.start-call        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.leave-room        | admitted | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.well-known        | admitted | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tuwunel.provision-account | refused  | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.open-ui           | refused  | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tuwunel.provision-account | refused  | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | tuwunel.open-ui           | refused  | /social/matrix/**        | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tuwunel.provision-account | refused  | /bff/provision/**        | extra-personas-sh+ts-catalogue |
      | e2e-user                     | tuwunel.open-ui           | admitted | /social/matrix/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.join-room         | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.send-message      | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.receive-message   | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.start-call        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.leave-room        | refused  | /_matrix/**              | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.well-known        | refused  | /.well-known/matrix/**   | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tuwunel.provision-account | admitted | /bff/provision/**        | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | eve@gmail.com                | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | frank@gmail.com              | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | rbac-approved@gmail.com      | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | rbac-pending@gmail.com       | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.open-ui           | admitted | /social/matrix/**        | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.sign-in           | refused  | /_matrix/client/v3/login | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.join-room         | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.send-message      | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.receive-message   | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.start-call        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.leave-room        | refused  | /_matrix/**              | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.well-known        | refused  | /.well-known/matrix/**   | extra-personas-sh              |
      | rbac-plain@gmail.com         | tuwunel.provision-account | admitted | /bff/provision/**        | extra-personas-sh              |
