# THE MATRIX FUNCTION SURFACE — every thing a user can DO on tuwunel, and who
# the deployed gateway lets do it.
#
# WHAT THIS ADDS THAT THE EXISTING MATRIX FEATURES DO NOT. two-party-chat,
# matrix-call, chat-then-call, group-chat and chat3d each drive ONE journey
# end to end. Between them they touch perhaps six of the twenty-one functions
# below, and every one of those five features needs a live stack — so on a
# laptop with no mesh, the Matrix coverage of this suite is the access-wall
# contract and nothing else. This feature is the other half: the whole function
# surface, asserted offline, for the WHOLE seeded roster.
#
# THE CLAIM EACH ROW MAKES. steps/social-functions.ts declares, by hand, which
# role a function requires and which roles are supersets of it. The DEPLOYED
# route-access seed (specs/cluster/manifests/route-access/initdb/20-schema.sql)
# decides the same question for the same probe path. The row passes only when
# the two AGREE for every one of the 31 seeded personas — so it is a cross-check
# between two independently maintained artefacts, not a test of a table against
# itself.
#
# GENERATIVE ON THE PERSONA AXIS. The roster is iterated INSIDE the step. Seed a
# new persona into specs/rbac-roles.ts or tests/e2e-extra-personas.sh and every
# row below widens to cover it with no edit here. The mirror-image row (one
# persona, every function) lives in ../platform/social-function-matrix.feature,
# and the drift guard that fails when a catalogued function has NO row at all
# lives there too.
#
# THE `arity` COLUMN is the INTERACTION axis: how many DISTINCT signed-in
# identities the function needs before it means anything. A 'pair' function
# silently downgraded to 'solo' is how "my peer sees it" quietly becomes one page
# asserting against itself.
#
# RUNS WITH THE STACK DOWN. No browser, no homeserver, no cluster.
@service:tuwunel @layer:gateway @harness
Feature: Every Matrix function is gated for every seeded persona as the catalogue declares

  Scenario Outline: <function> is gated for the whole roster exactly as the catalogue declares @service:tuwunel @layer:gateway
    Then the route-access seed gates the "<function>" function of the service dimension for every seeded persona
    And the "<function>" function of the service dimension is a "<arity>" interaction

    Examples:
      | function                 | arity |
      | whoami                   | solo  |
      | sync                     | solo  |
      | create-room              | solo  |
      | invite                   | pair  |
      | join                     | pair  |
      | leave                    | pair  |
      | send-message             | pair  |
      | redact                   | pair  |
      | read-receipt             | pair  |
      | room-state               | solo  |
      | call-invite              | pair  |
      | call-answer              | pair  |
      | send-sticker             | pair  |
      | upload-media             | solo  |
      | set-displayname          | pair  |
      | public-rooms             | solo  |
      | wellknown-delegation     | solo  |
      | external-client-login    | solo  |
      | external-client-register | solo  |
      | shell-route              | solo  |
      | provision-account        | solo  |
      | federate-remote-join     | pair  |

  # The same sweep in ONE scenario, so a run that lost the rows above still
  # cannot report green with a broken matrix. The rows exist for the REPORT
  # (the reporter pivots perService off the title); this exists for the PROOF.
  Scenario: every tuwunel function agrees with the deployed route-access seed for every persona @service:tuwunel @layer:gateway
    Then every function of the service dimension agrees with the route-access seed for every seeded persona
    And every catalogued probe path resolves to a real route-access pattern
