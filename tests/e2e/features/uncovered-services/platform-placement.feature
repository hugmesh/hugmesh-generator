# The PLATFORM axis, with real teeth.
#
# A mesh is a MIX of Pi 5 (arm64) and x86 (amd64) nodes, and three of the
# services in this domain cannot run on the Pi half at all: owncast, tube and the
# games worker each pin `kubernetes.io/arch: amd64` plus `hugmesh.net/compute:
# gpu` in their cluster Deployment, because they transcode. On an all-rpi5 mesh
# their Pods sit Pending forever and the UI shows nothing at all about why.
#
# So the platform axis here is not ceremony — it is the difference between "this
# service is off" and "this service can never come on for this operator". The
# always-on micro-frontends (wiki-ui, character-studio, character-forge,
# forum-ui) are plain nginx and pin NOTHING, which is what makes both rows of
# their Examples table honest rows rather than a doubled test.
#
# Both halves are asserted, and the NEGATIVE half is the one that matters: if
# somebody adds an arch pin to a UI remote, the rpi5 row of the platform-neutral
# scenario starts failing and says so, instead of the Pi image quietly shipping a
# menu entry that can never resolve.
@harness @layer:gateway
Feature: Which platform each uncovered service can actually schedule on

  # SNAP_PLATFORM=rpi5 skips these with a named reason (steps/world.ts); unset,
  # they run and assert the pin is present.
  Scenario Outline: <service> can only schedule on an x86 GPU worker @service:<service> @platform:x86 @layer:gateway
    Then the "<manifest_dir>" deployment pins the node architecture "amd64"

    Examples:
      | service | manifest_dir |
      | owncast | owncast      |
      | tube    | tube         |
      | games   | games        |

  # The platform-NEUTRAL surfaces. Every row here runs on both image targets
  # because the underlying Deployment pins no architecture — asserted, not
  # assumed, so the Examples table cannot outlive the fact it rests on.
  Scenario Outline: the <service> remote schedules unchanged on <platform> @service:<service> @platform:<platform> @layer:gateway
    Then the "<manifest_dir>" deployment pins no node architecture

    Examples:
      | service          | manifest_dir     | platform |
      | wiki             | wiki-ui          | rpi5     |
      | wiki             | wiki-ui          | x86      |
      | character-studio | character-studio | rpi5     |
      | character-studio | character-studio | x86      |
      | character-forge  | character-forge  | rpi5     |
      | character-forge  | character-forge  | x86      |
      | phpbb            | forum-ui         | rpi5     |
      | phpbb            | forum-ui         | x86      |
