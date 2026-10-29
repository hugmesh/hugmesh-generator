# ISSUE hugmesh-generator#297 — "Manual test: the standalone device owner — build,
# neutrality, boot, install". The one persona who never authenticates: no
# account, no mesh, no SSO. They test a BUILD ARTIFACT, and their entry points are
# `make x86-standalone-unaffiliated` (CLI) and the Studio wizard.
#
# WHAT IS COVERED HERE, and from which of the plan's numbered steps:
#   step 2   the make target threads the role into the builder container (dry run)
#   step 3   the unprivileged resolver states the whole neutral posture
#   step 4   the LOOK half of the identity-vs-look split is ACCEPTED
#   N1-N12   every identity/platform re-attachment is REFUSED, by name
#   step 18  the Studio's Qt-free config mirror agrees with the builder
#   N15      the anonymous-visitor probe at a live mesh (the plan's ONLY
#            network step, optional there; availability-gated here)
#
# WHAT IS NOT, and why: steps 5-17 are a ~300-minute build, a QEMU boot, a
# VNC-driven LUKS install, a greeter and a Plasma session — hours-long, driven
# through a serial console and a framebuffer no runner can reach. The plan says
# so itself ("captured by hand; the harness cannot make it"). They stay a
# person's run on this issue; nothing here pretends otherwise.
#
# Every command below is the resolver-only mode that exits BEFORE the root gate
# and before any filesystem write (build-x86-host-stage4.sh: --print-plan is
# handled before `id -u`), or a `make -n`, or a read-only GET. Nothing builds.
@interface:cli @issue:generator-297
Feature: the unaffiliated x86 standalone build strips every platform identity before a byte is built

  # step 2 — under -n the recipe is PRINTED, not run: `ensure-image` carries
  # $(MAKE), so make executes only its read-only `docker image inspect`.
  Scenario: the make target threads the role into the builder container without executing a build
    When I run the shell command "make -n x86-standalone-unaffiliated"
    Then the command succeeded
    And the command output contains "hugmesh-builder make x86-standalone-unaffiliated NATIVE=1"
    And the command output contains "-e STANDALONE_FLAGS"

  # step 3 — the contract, before any build. PLAN_ROLE_TAG is BARE (no -user,
  # no domain suffix): that is the artifact-level proof a person-role tie did
  # not land. PLAN_PERSON_ROLE reads `user` by a known cosmetic quirk (the
  # client-role default is assigned AFTER the conflict check) — RECORD, DO NOT
  # BLOCK on the issue — so it is deliberately not asserted either way.
  Scenario: the unprivileged resolver states the whole neutral posture
    When I run the shell command "./build-x86-host-stage4.sh --role standalone-unaffiliated --local-user alice --print-plan"
    Then the command succeeded
    And the command output contains "PLAN_ROLE=standalone-unaffiliated"
    And the command output contains "PLAN_ROLE_TAG=standalone-unaffiliated"
    And the command output does not contain "PLAN_ROLE_TAG=standalone-unaffiliated-"
    And the command output contains "PLAN_ROLE_CLASS=standalone"
    And the command output contains "PLAN_UNAFFILIATED=true"
    And the command output contains "PLAN_STANDALONE=true"
    And the command output contains "PLAN_K8S=none"
    And the command output contains "PLAN_MESH=skip"
    And the command output contains "PLAN_SSO=off"
    And the command output contains "PLAN_BRAND=gentoo"
    And the command output contains "PLAN_HOSTNAME=gentoo-desktop"
    And the command output contains "PLAN_ENCRYPT_ROOT=true"
    And the command output contains "PLAN_ARTIFACTS=stage4.tar.xz,img,live.iso,installer.iso,fs.tar.xz"
    And the command output contains "PLAN_ARTIFACT_PREFIX=gentoo-x86-amd64-standalone-unaffiliated-"
    And the command output does not contain "PLAN_ARTIFACT_PREFIX=hugmesh-"
    And the command output does not contain "Run as root"

  # step 4 — the ALLOWED half of the identity-vs-look split. Themes and
  # wallpaper stay legal on an unaffiliated build; the wallpaper file need not
  # exist at plan time.
  Scenario Outline: the look flags <look> are accepted on the unaffiliated role
    When I run the shell command "./build-x86-host-stage4.sh --role standalone-unaffiliated <look> --print-plan"
    Then the command succeeded
    And the command output contains "PLAN_UNAFFILIATED=true"
    And the command output contains "PLAN_BRAND=gentoo"

    Examples:
      | look                                             |
      | --theme dark                                     |
      | --wallpaper /tmp/w.png --accent-color '#ff0000'  |

  # N1-N12 — every one must be refused with rc=1 and the named reason. An rc=0
  # is the finding. Even `--brand gentoo` is refused: the builder forces the
  # neutral identity itself, so no caller may spell it.
  Scenario Outline: negative check <check>: the builder refuses <flags> naming the conflict
    When I run the shell command "./build-x86-host-stage4.sh <flags> --print-plan"
    Then the command exit code was 1
    And the command output contains "<refusal>"

    Examples:
      | check | flags                                                  | refusal                                                              |
      | N1    | --role pki --unaffiliated                              | --unaffiliated composes onto desktop/client roles only               |
      | N2a   | --role standalone-unaffiliated --brand acme            | drop --brand/--brand-title/--org                                     |
      | N2b   | --role standalone-unaffiliated --brand gentoo          | drop --brand/--brand-title/--org                                     |
      | N2c   | --role standalone-unaffiliated --brand-title Acme      | drop --brand/--brand-title/--org                                     |
      | N2d   | --role standalone-unaffiliated --org acme              | drop --brand/--brand-title/--org                                     |
      | N3    | --role standalone-unaffiliated --brand-logo /tmp/l.png | drop --brand-logo/--brand-locked                                     |
      | N4    | --role standalone-unaffiliated --brand-locked          | drop --brand-logo/--brand-locked                                     |
      | N5    | --role standalone-unaffiliated --person-role user      | --unaffiliated conflicts with --person-role/--domains                |
      | N6    | --role standalone-unaffiliated --domains acme.example  | --unaffiliated conflicts with --person-role/--domains                |
      | N7    | --role standalone-unaffiliated --with-tailscale        | --unaffiliated conflicts with --with-tailscale                       |
      | N8    | --role standalone-unaffiliated --with-sso              | --unaffiliated conflicts with --with-sso                             |
      | N9    | --role standalone-unaffiliated --bundle-source         | --unaffiliated conflicts with --bundle-source                        |
      | N10   | --role standalone-unaffiliated --home-seed-code x      | --unaffiliated conflicts with --home-seed-code                       |
      | N11   | --role standalone-unaffiliated --desktop thin          | --desktop thin contradicts --role standalone-unaffiliated            |
      | N12a  | --role standalone-unaffiliated --theme ../..           | invalid --theme '../..'                                              |
      | N12b  | --role standalone-unaffiliated --theme nosuch          | unknown --theme 'nosuch'                                             |

  # N3's refusal must ALSO list the eight legal LOOK flags, or the next reader
  # concludes the whole branding page is forbidden — the pre-2026-08-26 bug.
  Scenario: the brand-mark refusal names the eight look flags that remain legal
    When I run the shell command "./build-x86-host-stage4.sh --role standalone-unaffiliated --brand-logo /tmp/l.png --print-plan"
    Then the command exit code was 1
    And the command output contains "--theme/--branding-dir/--wallpaper/--grub-background/--grub-theme/--login-background/--accent-color/--color-scheme"

  # step 18 — the Studio's config mirror, headless and Qt-free. A mirror that
  # printed a valid-looking command for a build the builder is guaranteed to
  # refuse is the drift this step exists to catch.
  Scenario: the Studio mirror previews the look config as the same neutral builder argv
    When I run the shell script:
      """
      set -euo pipefail
      printf '{"platform":"x86","role":"standalone-unaffiliated","mode":"standalone","env":"test","theme":"dark"}' > "$HUGMESH_BDD_SCRATCH/look.json"
      PYTHONPATH=studio "$HUGMESH_STUDIO_PYTHON" -m hugmesh_studio --print-command --config "$HUGMESH_BDD_SCRATCH/look.json"
      """
    Then the command succeeded
    And the command output contains "build-x86-host-stage4.sh"
    And the command output contains "--role standalone-unaffiliated"
    And the command output contains "--theme dark"
    And the command output does not contain "--brand"
    And the command output does not contain "Traceback"

  Scenario: the Studio mirror refuses a brand identity on the unaffiliated role with the builder's own reason
    When I run the shell script:
      """
      set -uo pipefail
      printf '{"platform":"x86","role":"standalone-unaffiliated","mode":"standalone","env":"test","brand":"acme"}' > "$HUGMESH_BDD_SCRATCH/identity.json"
      PYTHONPATH=studio "$HUGMESH_STUDIO_PYTHON" -m hugmesh_studio --print-command --config "$HUGMESH_BDD_SCRATCH/identity.json"
      """
    Then the command exit code was 2
    And the command output contains "ZERO HugMesh affiliation"
    And the command output contains "brand identity"
    And the command output does not contain "build-x86-host-stage4.sh -w"

  Scenario: the Studio mirror refuses a brand logo on the unaffiliated role
    When I run the shell script:
      """
      set -uo pipefail
      printf '{"platform":"x86","role":"standalone-unaffiliated","mode":"standalone","env":"test","brand_logo":"/tmp/l.png"}' > "$HUGMESH_BDD_SCRATCH/logo.json"
      PYTHONPATH=studio "$HUGMESH_STUDIO_PYTHON" -m hugmesh_studio --print-command --config "$HUGMESH_BDD_SCRATCH/logo.json"
      """
    Then the command exit code was 2
    And the command output contains "brand_logo"
    And the command output does not contain "build-x86-host-stage4.sh -w"

  # N15 — the anonymous-visitor boundary, the plan's only network step and the
  # only reason an unaffiliated device ever meets a mesh. CALIBRATION FIRST:
  # /login/ and / must answer 200 text/html from the same door in the same run,
  # or the 401s below are a dead door, not a deny. Read-only GETs, no cookie
  # jar; the gateway 401s, it does not redirect anonymous callers to /login.
  @env:docker @service:gateway @layer:gateway
  Scenario: an anonymous visitor at a live mesh gets the sign-in form and nothing else
    When I run the shell script:
      """
      set -uo pipefail
      for p in /login/ /; do
        printf 'open %s -> %s\n' "$p" "$(curl -sk -o /dev/null -m 15 -w '%{http_code} %{content_type}' "$HUGMESH_BDD_BASE_URL$p")"
      done
      """
    Then the command succeeded
    And the command output contains "open /login/ -> 200 text/html"
    And the command output contains "open / -> 200 text/html"
    When I run the shell script:
      """
      set -uo pipefail
      for p in /admin/ /mod/ /user/ /apidocs /social/ /home /admin/remoteEntry.json /mod/remoteEntry.json /bff/session; do
        printf 'gated %s -> %s loc=%s\n' "$p" "$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "$HUGMESH_BDD_BASE_URL$p")" "$(curl -sk -o /dev/null -m 15 -w '%{redirect_url}' "$HUGMESH_BDD_BASE_URL$p")"
      done
      """
    Then the command succeeded
    And every non-empty line of the command's stdout matches "^gated /[^ ]* -> 401 loc=$"
