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
# THE FUNCTION CATALOGUE ITSELF, pinned row by row.
#
# The access matrices assert WHO reaches WHAT. This feature asserts the catalogue
# those matrices are computed from has not moved underneath them: every function
# still belongs to a legal SERVICES id, still probes the gateway and path the
# catalogue records, and still carries the derived/asserted label a reader uses
# to tell a measurement from a judgement call.
#
# WHY THE 'unreachable' LIST IS AN ASSERTION AND NOT A COMMENT. 15 of the
# 64 catalogued functions can be reached by NO seeded persona at all. Most of
# those are a real gap rather than a bug in this file: no seeding lane grants
# ROLE_WIKI, ROLE_OWNCAST, ROLE_TUBE, ROLE_FORUM_MOD or the ROLE_GAMES_SERVICES_*
# pair, so three whole services and two consoles are gated behind roles that
# nothing creates. Pinning the list means CLOSING one of those gaps (seeding the
# role) turns this scenario red and forces the list to shrink deliberately —
# and means a new service arriving unreachable cannot slip in unnoticed.
@layer:gateway @coverage-matrix
Feature: The function catalogue the coverage matrix is computed from

  Scenario Outline: the <function> function is catalogued against <gateway> <path> @service:<service>
    Then the "<function>" function belongs to the "<service>" service
    And the "<function>" function probes "<gateway>" at "<path>"
    And the "<function>" function probe path is "<evidence>"

    Examples:
      | function                        | service          | gateway                    | path                                                            | evidence |
      | tuwunel.open-ui                 | tuwunel          | hugmesh-fe-gateway         | /social/matrix/                                                 | derived  |
      | tuwunel.sign-in                 | tuwunel          | hugmesh-fe-gateway         | /_matrix/client/v3/login                                        | derived  |
      | tuwunel.join-room               | tuwunel          | hugmesh-fe-gateway         | /_matrix/client/v3/join/!e2e:hugmesh.net                        | derived  |
      | tuwunel.send-message            | tuwunel          | hugmesh-fe-gateway         | /_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.room.message/1 | derived  |
      | tuwunel.receive-message         | tuwunel          | hugmesh-fe-gateway         | /_matrix/client/v3/sync                                         | derived  |
      | tuwunel.start-call              | tuwunel          | hugmesh-fe-gateway         | /_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.call.invite/1  | derived  |
      | tuwunel.leave-room              | tuwunel          | hugmesh-fe-gateway         | /_matrix/client/v3/rooms/!e2e:hugmesh.net/leave                 | derived  |
      | tuwunel.well-known              | tuwunel          | hugmesh-fe-gateway         | /.well-known/matrix/client                                      | derived  |
      | akkoma.open-ui                  | akkoma           | hugmesh-fe-gateway         | /social/mastodon/                                               | derived  |
      | akkoma.sign-in                  | akkoma           | hugmesh-fe-gateway         | /oauth/token                                                    | derived  |
      | akkoma.post                     | akkoma           | hugmesh-fe-gateway         | /api/v1/statuses                                                | derived  |
      | akkoma.boost                    | akkoma           | hugmesh-fe-gateway         | /api/v1/statuses/1/reblog                                       | derived  |
      | akkoma.follow                   | akkoma           | hugmesh-fe-gateway         | /api/v1/accounts/1/follow                                       | derived  |
      | akkoma.timeline                 | akkoma           | hugmesh-fe-gateway         | /api/v1/timelines/home                                          | derived  |
      | akkoma.delete-post              | akkoma           | hugmesh-fe-gateway         | /api/v1/statuses/1                                              | derived  |
      | akkoma.moderate                 | akkoma           | hugmesh-be-gateway         | /api/v1/pleroma/admin/users                                     | derived  |
      | phpbb.open-ui                   | phpbb            | hugmesh-fe-gateway         | /social/forum/                                                  | derived  |
      | phpbb.read-topic                | phpbb            | hugmesh-fe-gateway         | /bff/forum/topics/1                                             | derived  |
      | phpbb.post-topic                | phpbb            | hugmesh-fe-gateway         | /bff/forum/topics                                               | derived  |
      | phpbb.reply                     | phpbb            | hugmesh-fe-gateway         | /bff/forum/topics/1/posts                                       | derived  |
      | phpbb.moderate                  | phpbb            | hugmesh-fe-gateway         | /bff/forum/moderation/reports                                   | derived  |
      | phpbb.administer                | phpbb            | hugmesh-fe-gateway         | /bff/forum/admin/forums                                         | derived  |
      | games.list                      | games            | hugmesh-fe-gateway         | /games/                                                         | derived  |
      | games.launch                    | games            | hugmesh-fe-gateway         | /games/play/chat3d                                              | asserted |
      | games.instance-lifecycle        | games            | hugmesh-be-gateway         | /games/api/instances                                            | derived  |
      | games.server-fleet              | games            | hugmesh-be-gateway         | /games/servers/lobby                                            | derived  |
      | games.admin-console             | games            | hugmesh-fe-gateway         | /games/admin/queue                                              | derived  |
      | games.services-runner           | games            | hugmesh-fe-gateway         | /admin/games-services/runners                                   | derived  |
      | owncast.watch                   | owncast          | hugmesh-fe-gateway         | /owncast/                                                       | derived  |
      | owncast.publish                 | owncast          | hugmesh-fe-gateway         | /bff/owncast/stream                                             | asserted |
      | owncast.chat                    | owncast          | hugmesh-fe-gateway         | /bff/owncast/chat                                               | asserted |
      | owncast.administer              | owncast          | hugmesh-fe-gateway         | /bff/owncast/admin/config                                       | derived  |
      | tube.watch                      | tube             | hugmesh-fe-gateway         | /tube/                                                          | derived  |
      | tube.list                       | tube             | hugmesh-fe-gateway         | /bff/tube/channels                                              | asserted |
      | tube.publish                    | tube             | hugmesh-fe-gateway         | /bff/tube/videos                                                | asserted |
      | tube.delete                     | tube             | hugmesh-fe-gateway         | /bff/tube/videos/1                                              | asserted |
      | wiki.read                       | wiki             | hugmesh-fe-gateway         | /wiki/                                                          | derived  |
      | wiki.edit                       | wiki             | hugmesh-fe-gateway         | /bff/wiki/pages/home                                            | asserted |
      | wiki.history                    | wiki             | hugmesh-fe-gateway         | /bff/wiki/pages/home/history                                    | asserted |
      | wiki.administer                 | wiki             | hugmesh-fe-gateway         | /bff/wiki/admin/pages                                           | derived  |
      | character-studio.open           | character-studio | hugmesh-fe-gateway         | /character-studio/                                              | derived  |
      | character-studio.create         | character-studio | hugmesh-fe-gateway         | /bff/user/character-studio/characters                           | derived  |
      | character-studio.save           | character-studio | hugmesh-fe-gateway         | /bff/user/character-studio/characters/1                         | derived  |
      | character-studio.export         | character-studio | hugmesh-fe-gateway         | /bff/user/character-studio/characters/1/export                  | asserted |
      | character-forge.open            | character-forge  | hugmesh-fe-gateway         | /character-forge/                                               | derived  |
      | character-forge.create          | character-forge  | hugmesh-fe-gateway         | /bff/character-forge/characters                                 | derived  |
      | character-forge.save            | character-forge  | hugmesh-fe-gateway         | /bff/character-forge/characters/1                               | derived  |
      | character-forge.export          | character-forge  | hugmesh-fe-gateway         | /bff/character-forge/characters/1/export                        | asserted |
      | gateway.front-door              | gateway          | hugmesh-fe-gateway         | /                                                               | derived  |
      | gateway.host-shell-importmap    | gateway          | hugmesh-fe-gateway         | /importmap.json                                                 | derived  |
      | gateway.session                 | gateway          | hugmesh-fe-gateway         | /bff/me/session                                                 | derived  |
      | gateway.federation-manifest     | gateway          | hugmesh-fe-gateway         | /api/federation/manifest                                        | derived  |
      | gateway.federation-capabilities | gateway          | hugmesh-fe-gateway         | /api/federation/capabilities                                    | derived  |
      | gateway.internal-refused        | gateway          | hugmesh-fe-gateway         | /bff/internal/health                                            | derived  |
      | login.form                      | login            | hugmesh-fe-gateway         | /login/                                                         | derived  |
      | login.native-sign-in            | login            | hugmesh-fe-gateway         | /bff/login                                                      | derived  |
      | login.register                  | login            | hugmesh-fe-gateway         | /bff/register/complete                                          | derived  |
      | login.provision                 | login            | hugmesh-fe-gateway         | /bff/provision/keys                                             | derived  |
      | admin.console                   | admin            | hugmesh-fe-gateway         | /admin/                                                         | derived  |
      | admin.allowlist                 | admin            | hugmesh-fe-gateway         | /bff/admin/allowlist                                            | derived  |
      | admin.phone-fleet               | admin            | hugmesh-fe-gateway         | /bff/admin/phone-fleet/devices                                  | derived  |
      | admin.api-docs                  | admin            | hugmesh-fe-gateway         | /api-docs/index.html                                            | derived  |
      | admin.moderation-console        | admin            | hugmesh-fe-gateway         | /mod/                                                           | derived  |
      | admin.superadmin-catalog        | admin            | hugmesh-superadmin-gateway | /superadmin/service-catalog/index                               | derived  |

  # Every SERVICES id must carry at least one function, and every catalogued
  # function must name a legal service. Both directions, because a one-way check
  # lets a typo'd service id sit in the catalogue forever.
  Scenario: every catalogued service has functions and every function has a catalogued service
    Then every service in the catalogue has at least one function
    And every catalogued function names a legal service

  Scenario Outline: no seeded persona can reach <function> @service:<service>
    Then no seeded persona is admitted at the "<function>" function

    Examples:
      | function                 | service |
      | phpbb.moderate           | phpbb   |
      | games.list               | games   |
      | games.launch             | games   |
      | games.services-runner    | games   |
      | owncast.watch            | owncast |
      | owncast.publish          | owncast |
      | owncast.chat             | owncast |
      | tube.watch               | tube    |
      | tube.list                | tube    |
      | tube.publish             | tube    |
      | tube.delete              | tube    |
      | wiki.read                | wiki    |
      | wiki.edit                | wiki    |
      | wiki.history             | wiki    |
      | gateway.internal-refused | gateway |
