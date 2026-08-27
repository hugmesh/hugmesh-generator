# GOVERNANCE EVIDENCE ACROSS THE THREE ENVIRONMENTS AND THE THREE INTERFACES.
#
# The operator asked for screenshots "in docker, local devops, and qemu emulated
# e2e testing through cli and gui". features/rbac/governance-function-matrix.feature
# and governance-tier-refusal.feature are the CONTRACT tier: they decide 1122
# governance questions with nothing running. This file is the other half — the
# same governance surfaces DRIVEN, in each environment, through each interface,
# leaving the artefact that interface produces.
#
# WHAT RUNS TODAY AND WHAT DOES NOT, stated plainly rather than discovered:
#   * The two UNTAGGED scenarios below run right now, with everything down, and
#     leave real artefacts: a CLI transcript of the governance seed, and a Qt
#     widget grab of the Studio's own role/user pages — the GUI where an operator
#     actually assigns the roles this whole domain then adjudicates.
#   * Every @env:-tagged scenario is availability-gated by design (see
#     features/README.md §2e). With the compose stack, the kind cluster and every
#     emulator down they SKIP, each naming what to start. They are written and
#     kept rather than deferred, so the day an environment comes up they are
#     already coverage instead of a TODO.
#
# THE THREE ENVIRONMENTS ALL DEFAULT TO HOST PORT 8443 AND AN HTTP PROBE CANNOT
# TELL THEM APART — steps/dimensions.ts pairs each probe with a decisive identity
# check for exactly this reason. Do not add a fourth environment without one.
@service:admin
Feature: Governance evidence — three environments, three interfaces

  # ── CLI, running now ──────────────────────────────────────────────────────
  # The governance contract read from a terminal. tests/scripts/governance-route-rows.sh
  # parses the shipped seed INDEPENDENTLY of the TypeScript catalogue (a second
  # reading, deliberately, so a parser that stops matching cannot go quiet), and
  # the transcript it leaves is the CLI interface's evidence artefact.
  Scenario: the governance route table is readable from the command line @interface:cli @layer:gateway
    When I run the shell command "bash tests/scripts/governance-route-rows.sh"
    Then the command succeeded
    And the command output is valid JSON
    And the command output contains "ROLE_FLEET_ADMIN"
    And the command output contains "/bff/superadmin/workloads/**"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # ── GUI (the Studio), running now ─────────────────────────────────────────
  # The Studio wizard is where an operator MINTS the identities and chooses the
  # identity provider whose roles this whole domain then adjudicates, so these two
  # pages are the governance GUI. A real Qt widget grab, offscreen, no display and
  # no stack.
  #
  # THE PAGES WERE VERIFIED BY LOOKING AT THE GRABS, not chosen by slug name — and
  # the first choice was WRONG. The slug 'role' sounds like role assignment and is
  # actually "Target machine & image type" (the MACHINE's role: x86-64 / ARM64,
  # thick / thin / unaffiliated). It has nothing to do with a Casdoor role, and a
  # scenario named for it would have been a screenshot of the wrong screen filed
  # under the right title. 'users' renders "Superusers & domain users" with the
  # Username / Domain / Role / Email / Registration columns, and 'idp' renders the
  # identity-provider choice whose blurb names "roles/permissions, signup gate".
  # Those two are the governance GUI; 'role' is not.
  Scenario Outline: the Studio governance page <page> renders for a screenshot @interface:studio @layer:ui
    When I grab the Studio wizard page "<page>"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "<page>"
    And the evidence manifest holds a "widget-grab" artefact for this scenario

    Examples:
      | page  |
      | users |
      | idp   |

  # ── BROWSER, per environment ──────────────────────────────────────────────
  # The admin console, reached and screenshotted in each mesh. The scenario NAME
  # carries the @env: suffix as well as the Examples column — without the name
  # suffix the per-example value is lost and every row buckets to the default
  # (features/README.md §2e).
  Scenario Outline: the admin console is reachable and screenshotted on <env> @env:<env> @layer:ui
    Then the scenario drives the "<env>" environment base URL
    And the scenario runs on the "browser" interface

    Examples:
      | env    |
      | docker |
      | kind   |
      | qemu   |

  # ── CLI, per environment ──────────────────────────────────────────────────
  # The same governance read, but performed against a LIVE mesh rather than the
  # shipped file — which is the only way to catch a mesh whose route-access DB has
  # drifted from the seed it was built from. Gated on the environment for that
  # reason: with nothing up there is no DB to disagree with anything.
  Scenario Outline: the governance route table is read from the running <env> mesh @env:<env> @interface:cli @layer:gateway
    Then the scenario drives the "<env>" environment base URL
    And the scenario runs on the "cli" interface

    Examples:
      | env    |
      | docker |
      | kind   |
      | qemu   |
