# Executable form of tests/e2e/specs/21-nofed-admin-announcement-local.spec.ts.
#
# THE RISK THIS CLOSES. Domain lock is enforced per-ACTOR (the force-local set), but
# an admin "announcement"/broadcast could plausibly take a DIFFERENT delivery path
# than an ordinary user toot. If the whole instance is domain-locked — every local
# actor force-local — then the admin's own outbound announcement must ALSO be
# filtered to local inboxes only. A privileged path that leaks is still a leak.
#
# Its positive control is the non-locked row in mastodon-domain-lock.feature: a
# green here is enforcement only because that row proves the pipe is alive.
#
# EXTRA GATE, ON PURPOSE. This variant needs the INSTANCE-WIDE lock
# (SNAP_DOMAINLOCK_INSTANCE_WIDE=1), which is a different deployment from a
# single-user lock — flagged separately so a per-user-only deployment SKIPS honestly
# instead of failing for a reason that is not a defect.
@platform:x86 @service:akkoma @layer:egress
Feature: An admin announcement on a domain-locked instance stays local

  @role:e2e-admin
  Scenario: the instance-wide lock withholds even the admin's own broadcast
    Given the federation observer peer and the domain-lock gate are both live
    And the instance-wide domain lock is in force
    And the remote peer follows the persona for this scenario
    When the persona for this scenario posts a public toot carrying a unique marker
    Then the toot is visible on the local instance timeline
    And the remote peer "never sees" that toot within 30 seconds
