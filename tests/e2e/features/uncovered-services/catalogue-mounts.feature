# The MOUNT half of "running-but-unreachable".
#
# tests/stack/seed-e2e.sh names this failure in its own comments: a freshly
# seeded mesh ships owncast, tube and character-forge with the federation
# registry row disabled, "so those services run as containers and are INVISIBLE
# in the host shell's menu — running-but-unreachable, which is precisely the
# failure the Studio catalogue was written to prevent, with the one control that
# could fix it doing nothing."
#
# The catalogue (specs/cluster/optional-services.yaml) is where a slug declares
# the mount path the host shell will use. If that path and the fe-gateway route
# path ever disagree, the shell mounts a remote at a URL the gateway does not
# serve — and the operator sees a menu entry that leads to a blank page. These
# scenarios pin the two together for every service in this domain, offline.
@harness @layer:gateway
Feature: Every optional service declares the mount path its gateway route serves

  Scenario Outline: <service> is mounted by the catalogue at the path its route serves @service:<service> @layer:gateway
    Then the optional-services catalogue mounts this service at "<mount_at>"
    And the fe gateway routes "<pattern>" to the "<upstream>" upstream

    Examples:
      | service          | mount_at          | pattern              | upstream                    |
      | tube             | /tube             | /tube/**             | hugmesh-tube-ui             |
      | owncast          | /owncast          | /owncast/**          | hugmesh-owncast-ui          |
      | character-studio | /character-studio | /character-studio/** | hugmesh-character-studio-ui |
      | character-forge  | /character-forge  | /character-forge/**  | hugmesh-character-forge-ui  |
      | phpbb            | /social/forum     | /social/forum/**     | hugmesh-forum-ui            |

  # DEFAULT-OFF is the other half of the same story: none of these ships on a
  # mesh the operator did not explicitly opt into. Every pending reason in this
  # domain's driven-UI features is written against that fact, so if a default
  # flips, this scenario is what says the reasons are now stale.
  Scenario Outline: <service> ships default-off, so an un-opted-in mesh has none of it @service:<service> @layer:gateway
    Then this service is default-off in the optional-services catalogue

    Examples:
      | service          |
      | tube             |
      | owncast          |
      | character-studio |
      | character-forge  |
      | games            |

  # phpbb is the ONE slug in this domain that is default-ON, and that single fact
  # is why the forum micro-frontend is the only surface here an ordinary member
  # can reach on an un-opted-in mesh. Measured, not assumed: this scenario was
  # written asserting default-OFF alongside its siblings and FAILED, which is how
  # the difference was found rather than guessed.
  #
  # (The phpBB POD is a separate story: it rides the `phpbb` COMPOSE profile,
  # which is off by default — see the pending scenarios in forum-console.feature.
  # Cluster catalogue default and compose profile are different switches.)
  @service:phpbb @layer:gateway
  Scenario: the forum slug ships default-on, which is why it is the one drivable forum surface @layer:gateway @service:phpbb
    Then this service is default-on in the optional-services catalogue
