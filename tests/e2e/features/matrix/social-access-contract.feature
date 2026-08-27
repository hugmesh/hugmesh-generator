# The ROLE x PLATFORM x SERVICE contract the social lane rests on — asserted with
# the STACK DOWN, before a single browser action.
#
# WHY IT COMES FIRST. Every journey below it (chat, calls, group rooms, the 3D
# room, the timeline) presumes three things that nothing else checks: that the
# service carries a surface somebody has actually pinned, that the personas the
# journeys drive are created by a seeder that really runs, and that the roster is
# BIG ENOUGH for a multi-party proof. When one of those is false the journey dies
# at login with a bare 401 or at navigation with a blank page — symptoms that read
# like a broken product and are really a missing fixture (the 2026-08-06 e2e-fleet
# shape). These scenarios turn each of those into a named, offline failure.
#
# PLATFORM AXIS. The social contract is identical on both image targets; the
# runner narrows to the one it actually brought up with SNAP_PLATFORM (the Before
# hook in steps/world.ts skips the other row with a named reason). Unset, both run.
@harness @layer:casdoor
Feature: The social services and their personas are real before any journey drives them

  Scenario Outline: <service> exposes a pinned surface on <platform> @service:<service> @platform:<platform> @layer:gateway
    Then the service named by the service dimension has a pinned surface

    Examples:
      | service | platform |
      | tuwunel | rpi5     |
      | tuwunel | x86      |
      | akkoma  | rpi5     |
      | akkoma  | x86      |

  # The roster the multi-party proofs draw from. Spec 31 SKIPS its three-party
  # test when the catalogue is short; asserting the catalogue here means a roster
  # that shrinks goes RED in a scenario named for it, instead of quietly turning a
  # group-chat proof into a skip nobody reads.
  Scenario Outline: the <service> platform roster seeds at least <count> non-domain-locked personas @service:<service> @layer:casdoor
    Then the platform roster for the service dimension seeds at least <count> non-domain-locked personas

    Examples:
      | service | count |
      | tuwunel | 3     |
      | akkoma  | 2     |

  Scenario Outline: <role> is seeded for the social lane @role:<role> @layer:casdoor
    Then the persona named by the role dimension is seeded

    Examples: platform-access holders — the only personas allowed to drive a homeserver
      | role                         |
      | e2e-matrix                   |
      | e2e-matrix-groupchat         |
      | e2e-matrix-external-client   |
      | e2e-mastodon                 |
      | e2e-mastodon-external-client |

    Examples: plain ROLE_USER handles — DENIED the homeserver backend by design
      | role            |
      | e2e-user        |
      | alice@gmail.com |
      | bob@gmail.com   |
      | dragoneer       |

  # The two halves of the non-federation proof must be seeded as OPPOSITES, or a
  # green negative means nothing: the subject must really be locked, and the clock
  # must really be free to federate.
  Scenario Outline: <role> is the domain-locked subject of the non-federation proof @role:<role> @layer:casdoor
    Then the persona named by the role dimension is seeded
    And the persona named by the role dimension holds a domain-locked platform role

    Examples:
      | role                      |
      | e2e-matrix-domainlocked   |
      | e2e-mastodon-domainlocked |

  Scenario Outline: <role> is the federating control for the non-federation proof @role:<role> @layer:casdoor
    Then the persona named by the role dimension is seeded
    And the persona named by the role dimension is a federation control user

    Examples:
      | role         |
      | e2e-matrix   |
      | e2e-mastodon |
