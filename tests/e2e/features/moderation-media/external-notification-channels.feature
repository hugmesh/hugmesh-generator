# admin-bff's EXTERNAL notification channels — hugmesh/hugmesh-admin-bff-api#88
# (Matrix @system DM), #89 (Akkoma per-user notice), #90 (phpBB PM seam), #91
# (email recipient resolution), #92 (preference consult on the external path)
# and #93 (consuming mod-bff's notify_channels directive).
#
# WHAT IS OBSERVABLE FROM AN INTERFACE THIS SUITE DRIVES, measured on origin/main
# 2026-09-23 against hugmesh-admin-bff-api 6dc72d1 and this repo's manifests:
#   * NO deploy profile wires any channel flag. `notify.matrix.enabled`,
#     `notify.akkoma.enabled`, `notify.forum.seam-wired` and `notify.email.enabled`
#     have no NOTIFY_* environment entry in specs/cluster/manifests/admin-bff-api/
#     deployment.yaml or tests/stack/compose.local.yaml, and application.yml
#     carries no `notify:` block — every adapter is unreachable on every mesh the
#     generator produces, not merely dark by default.
#   * the ExternalChannelReconciler's outcomes (sent / stubbed / skipped / FAILED
#     / skipped-by-preference) reach no read surface: no controller under
#     notification/ lists outbox rows, and the micrometer counters it increments
#     (notification.external.*) are pod-internal.
#   * a suspended subject loses the very surfaces a DM or notice would land on
#     (the hsproxy gate, the Akkoma account), so "the DM reached the persona's
#     room" cannot be read back as that persona either.
# So #88, #89, #90, #91 and #92's delivery/preference behaviours are recorded as
# NOT WRITABLE HONESTLY in this round, and this file carries the one measurement
# that gates all of them plus the one wire fact #93 asks to be verified first.
#
# WHY THE MEASUREMENT IS A SCENARIO AND NOT A COMMENT: the day an operator wires
# a NOTIFY_* entry into a profile, the grep below goes red — that is the prompt
# to come back and write the driven delivery scenarios against a stack that can
# actually deliver, with the read surface #88's "observed once" bullet implies.
@service:admin @layer:bff
Feature: External notification channels ship unwired, and the mod-bff directive already travels

  # ── the gating measurement (#88 #89 #90 #91 #92) ──────────────────────────
  @issue:admin-bff-api-88 @issue:admin-bff-api-89 @issue:admin-bff-api-90 @issue:admin-bff-api-91 @issue:admin-bff-api-92 @harness @interface:cli
  Scenario Outline: no <profile> profile arms an external notification channel
    When I run the shell command "grep -c -E 'NOTIFY_(MATRIX|AKKOMA|FORUM|EMAIL)_(ENABLED|SEAM_WIRED)|notify\.(matrix|akkoma|forum|email)\.' <file>"
    Then the command failed
    And the command exit code was 1

    Examples:
      | profile | file                                                   |
      | cluster | specs/cluster/manifests/admin-bff-api/deployment.yaml |
      | compose | tests/stack/compose.local.yaml                         |

  # The positive control for the same search: the pattern DOES find the sibling
  # adapter flag this repo already wires (the forum congruence leg), so an empty
  # result above is the absence of NOTIFY_* rather than a typo in the regex.
  @issue:admin-bff-api-90 @harness @interface:cli
  Scenario: the same search shape really does find the adapter flag the compose profile wires
    When I run the shell command "grep -c -E 'EXTERNAL_FORUM_ENABLED' tests/stack/compose.local.yaml"
    Then the command succeeded

  # ── #93, the wire half the issue says to verify before writing anything ────
  # mod-bff's BanRequest carries notifyChannels, and AdminSuspensionClient puts it
  # in the body it POSTs to admin-bff. A TTL'd matrix ban on the standing banned
  # persona is the least-destructive real write through that path: the effect
  # expires on its own and no other scenario expects that persona un-banned. The
  # admin-bff CONSUMPTION half (SuspensionRequest gaining the field, the outbox
  # row carrying it) has no read surface and stays unasserted here, by name.
  @issue:admin-bff-api-93 @env:docker @role:e2e-mod @service:admin @layer:bff
  Scenario: a moderator's ban carrying a notify_channels directive is accepted by the mod surface
    Given I hold an API session as the persona for this scenario
    When I ban "e2e-banned" on platform "matrix" for 5 seconds with the notify channels "matrix"
    Then the ban was accepted as pending-reconcile with HTTP 202
