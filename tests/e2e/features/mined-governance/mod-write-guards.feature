# WHAT THIS ASSERTS. Three properties of the mod-bff write surface that the
# central suite never states, all derived from source and all checkable with
# nothing running.
#
# 1. PUNITIVE vs REMEDIAL GUARD ASYMMETRY. ModService.ban runs
#    guardNotSelf -> guardSameTenant -> guardNotPrivileged; ModService.lift runs
#    guardSameTenant ALONE. The split is deliberate and documented ("REMEDIAL —
#    mirrors lift: only the cross-tenant guard applies"), and it has real
#    consequences nobody has written down: a moderator MAY lift their own ban and
#    MAY lift a privileged target's. Comment-stripped, the central suite has zero
#    hits for 'guardNotSelf', 'self-ban' or 'cross-tenant'. Pinning BOTH halves
#    is what stops a well-meaning refactor from quietly closing the asymmetry —
#    or a careless one from opening it on the punitive side.
#
# 2. THE STEP-UP GATE SHIPS DARK. ModStepUpGate is armed by
#    app.mfa.enforce-sensitive-writes, default false, and returns true
#    unconditionally until it is flipped; armed, it is fail-closed. That flag is
#    SEPARATE from the gateway's app.mfa.enforce-privileged-floor, which
#    features/moderation-media/mfa-privileged-floor.feature already covers.
#    Nothing covers this one. MEASURED: exactly 5 of the 15 mapped ModController
#    endpoints carry it, and no GET does.
#
# 3. THE REFUSAL BODY IS A CONTRACT. Every mod-bff refusal renders {"error": …}
#    and every validation failure {"error":"validation failed","fields":{…}},
#    because mod-ui reads (await r.json()).error || 'HTTP <status>'. Widening the
#    envelope turns every moderator-visible refusal into a bare status code.
#
# NEEDS the hugmesh-mod-bff-api checkout beside this repo (source read only).
# Absent, every scenario SKIPS naming the path searched and the override var.
@service:gateway @layer:bff
Feature: The mod-bff write surface guards punitively, gates darkly, and refuses in a fixed shape

  Background:
    Given the mod-bff moderation surface is loaded

  # ── 1. the guard asymmetry ─────────────────────────────────────────────────
  Scenario Outline: the punitive write <method> runs the full three-guard chain @layer:bff
    Then the mod-bff service write "<method>" runs the guard chain "guardNotSelf, guardSameTenant, guardNotPrivileged"

    Examples:
      | method       |
      | ban          |
      | block        |
      | domainLock   |
      | domainUnlock |

  # The remedial half. This scenario is the one that documents the two
  # consequences: with no guardNotSelf a moderator may lift their OWN ban, and
  # with no guardNotPrivileged they may lift a privileged target's.
  Scenario: the remedial write lift runs the cross-tenant guard alone @layer:bff
    Then the mod-bff service write "lift" runs the guard chain "guardSameTenant"

  # The shared owncast path implements the SAME split inside one helper with a
  # punitive ternary: the punitive branch is the triple, the remedial branch the
  # lone tenant guard. Both branches appear, in that order.
  Scenario: the owncast helper carries both branches of the same split @layer:bff
    Then the mod-bff service write "owncastModerate" runs the guard chain "guardNotSelf, guardSameTenant, guardNotPrivileged, guardSameTenant"

  # ── 2. the step-up gate ────────────────────────────────────────────────────
  Scenario: the step-up gate covers exactly the five sensitive writes @layer:bff
    Then the mod-bff endpoints carrying the step-up gate are exactly "POST /ban, DELETE /ban, POST /block, POST /domain-lock/{role}/{user}, DELETE /domain-lock/{role}/{user}"

  # Arming the flag must not close the READ surface a moderator needs in order to
  # decide whether a write is warranted.
  Scenario: arming the gate leaves every read ungated @layer:bff
    Then every other mod-bff endpoint carries no step-up gate

  Scenario: every mod-bff endpoint starts at the moderator floor @layer:bff
    Then every mod-bff endpoint requires at least the moderator role

  Scenario: the gate is dark by default on its own flag and fail-closed when armed @layer:bff
    Then the mod step-up gate ships DARK on its own flag and is fail-closed when armed

  # ── 3. the refusal envelope ────────────────────────────────────────────────
  Scenario: a mod-bff refusal carries the {error} envelope the console renders @layer:bff
    Then the mod-bff refusal envelope is exactly the "error" key
    And a mod-bff validation failure adds a "fields" map beside it
