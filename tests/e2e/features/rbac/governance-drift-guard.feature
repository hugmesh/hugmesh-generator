# THE DRIFT GUARD — the actual deliverable of this unit.
#
# 34 identities x 33 governance functions is 1122 decisions, and the scenarios
# that make them are GENERATED from a catalogue rather than written out. That buys
# the coverage the operator asked for, and it buys one new failure mode with it:
# a catalogue entry that nothing executes reads exactly like coverage and is not.
# A .feature that never runs is worse than no .feature; a catalogue row that no
# scenario reaches is the same defect one level up.
#
# So every generative claim this domain makes is guarded here:
#   * every catalogued FUNCTION is named by some scenario;
#   * every catalogued IDENTITY is named by some scenario;
#   * every CONSOLE both admits somebody and refuses somebody, so neither half of
#     its gating is vacuous;
#   * the two SEEDERS agree about every identity they share;
#   * every one of the 126 swarm identities is really represented by the 3 that
#     stand in for it, so the shortcut costs no coverage;
#   * the TS route mirror grants nothing the shipped seed withholds, and the
#     governance patterns it is MISSING are a pinned number rather than a shrug.
#
# ADDING A PERSONA OR A FUNCTION EXPANDS COVERAGE AUTOMATICALLY — and if it does
# not, this file is what goes red.
#
# The feature-file scan STRIPS COMMENTS before matching. Counting a token that
# only ever appears in a comment has produced a false green in this repo five
# times; a `#` line is documentation, not an executed claim.
@service:gateway @layer:gateway
Feature: Governance coverage drift guard

  Scenario: no catalogued governance function is left unexercised @layer:gateway
    Then every catalogued governance function is named by a scenario

  Scenario: no seeded identity is left out of the governance matrix @layer:gateway
    Then every catalogued governance identity is named by a scenario

  Scenario: no governance console gates vacuously @layer:gateway
    Then every governance console has both an admitted and a refused identity

  Scenario: the TypeScript catalogue and the shell roster describe the same people @layer:casdoor
    Then both seeders agree about every identity they both create

  # The swarm is 120 users + 4 mods + 2 admins. Expanding all 126 would be 4158
  # fabricated decisions restating three facts, so exactly one representative per
  # tier joins the matrix. That is only honest while every excluded member really
  # does hold its representative's roles — and it is NOT a free assumption: all
  # three swarm tiers carry role-sets no other seeded persona has (the swarm user
  # holds ROLE_MATRIX and ROLE_MASTODON together, which no e2e-* persona does), so
  # dropping the swarm outright would have silently lost three whole role classes.
  Scenario: the three swarm representatives really stand for all 126 @layer:casdoor
    Then every swarm identity is represented in the governance matrix

  # The DANGEROUS direction of mirror drift: a mirror that grants MORE than the
  # shipped seed makes an ALLOW expectation pass on a door the mesh keeps shut, so
  # the suite would certify access nobody has. There is no ledger for this one.
  Scenario: the route-access mirror never grants what the shipped seed withholds @layer:gateway
    Then the route-access mirror grants nothing the shipped seed withholds

  # The OTHER direction, pinned as a number so both movements are visible:
  # widening the mirror (good — lower this) and adding an unmirrored governance
  # surface (needs a decision — mirror it, or raise this on purpose). Twelve
  # patterns on this tree: the whole moderator console, the fleet console, both
  # workload prefixes, three superadmin be-gateway prefixes, the internal wall and
  # forum/wiki/owncast admin. Each is a surface specs/rbac-route-access.ts cannot
  # decide at all, so in that tier they default-deny and every DENY about them
  # passes without testing anything.
  Scenario: the governance surfaces the route mirror cannot express are a known, pinned set @layer:gateway
    Then the governance surfaces missing from the route-access mirror number exactly 12
