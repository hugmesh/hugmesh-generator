# The PER-PLATFORM ACCESS WALL: holding ROLE_USER no longer reaches Matrix or
# Mastodon. The broad ROLE_USER homeserver floor was REMOVED (commit 0100d3b) and
# replaced with the per-platform ROLE_MATRIX / ROLE_MASTODON rows, so a platform
# ban is now the ABSENCE of a role. Spec 17 asserts the deny; specs 05/06/10/11/31
# all had to change personas because of it. This feature states the rule once, in
# both the places it is enforced.
#
# TWO LAYERS, DELIBERATELY SEPARATE:
#   @layer:gateway  the route-access ORACLE (specs/rbac-route-access.ts, the
#                   mirror of manifests/route-access/20-schema.sql). Offline.
#   @layer:bff      the live user-bff hsproxy, driven as a signed-in browser
#                   session. Needs a running stack.
# A pass at one layer says nothing about the other, which is exactly why the two
# are not merged into one scenario.
#
# The oracle rows name only handles the TypeScript seed catalogue carries
# (specs/rbac-roles.ts SYSTEMS_SEED_USERS), because that is where the granted role
# set comes from. The live rows may additionally name shell-roster handles
# (alice@gmail.com and friends), which have no catalogue entry but are really
# seeded — the two rosters disagree today, and steps/dimensions.ts accepts the
# UNION rather than pretending they do not.
Feature: Only a per-platform ACCESS role reaches the Matrix or Mastodon backend

  Scenario Outline: the be-gateway answers <decision> for <role> at "<path>" @role:<role> @service:<service> @layer:gateway
    Then the route-access oracle decides "<decision>" for this persona at "<path>" on gateway "hugmesh-be-gateway"

    Examples: the Matrix client surface is gated on ROLE_MATRIX
      | role         | service | decision | path                    |
      | e2e-matrix   | tuwunel | ALLOW    | /_matrix/client/v3/sync |
      | e2e-mod      | tuwunel | ALLOW    | /_matrix/client/v3/sync |
      | e2e-admin    | tuwunel | ALLOW    | /_matrix/client/v3/sync |
      | e2e-user     | tuwunel | DENY     | /_matrix/client/v3/sync |
      | e2e-mastodon | tuwunel | DENY     | /_matrix/client/v3/sync |
      | e2e-forum    | tuwunel | DENY     | /_matrix/client/v3/sync |

    Examples: the Mastodon client surface is gated on ROLE_MASTODON
      | role         | service | decision | path                   |
      | e2e-mastodon | akkoma  | ALLOW    | /api/v1/timelines/home |
      | e2e-mod      | akkoma  | ALLOW    | /api/v1/timelines/home |
      | e2e-admin    | akkoma  | ALLOW    | /api/v1/timelines/home |
      | e2e-user     | akkoma  | DENY     | /api/v1/timelines/home |
      | e2e-matrix   | akkoma  | DENY     | /api/v1/timelines/home |
      | e2e-forum    | akkoma  | DENY     | /api/v1/timelines/home |

  # LIVE, through the same hsproxy the UI uses. The browser holds NO homeserver
  # token: auth is the httpOnly bff_session cookie, so this is the real custody
  # model and not a token smuggled in by the test.
  Scenario Outline: <role> reaches the Matrix homeserver through the hsproxy @role:<role> @service:tuwunel @layer:bff
    Given I am signed in as the persona for this scenario
    Then the Matrix hsproxy returns my Matrix user id

    Examples:
      | role                       |
      | e2e-matrix                 |
      | e2e-matrix-groupchat       |
      | e2e-matrix-external-client |

  Scenario Outline: <role> is refused the Matrix homeserver through the hsproxy @role:<role> @service:tuwunel @layer:bff
    Given I am signed in as the persona for this scenario
    Then the Matrix hsproxy refuses me the homeserver backend

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |
      | bob@gmail.com   |
      | dragoneer       |

  Scenario Outline: <role> reaches the Mastodon backend through the hsproxy @role:<role> @service:akkoma @layer:bff
    Given I am signed in as the persona for this scenario
    Then the Mastodon hsproxy returns my account id

    Examples:
      | role                         |
      | e2e-mastodon                 |
      | e2e-mastodon-external-client |

  Scenario Outline: <role> is refused the Mastodon backend through the hsproxy @role:<role> @service:akkoma @layer:bff
    Given I am signed in as the persona for this scenario
    Then the Mastodon hsproxy refuses me the homeserver backend

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |
      | dragoneer       |
