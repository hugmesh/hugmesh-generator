# Executable form of tests/e2e/specs/20-nofed-matrix-local-only.spec.ts.
#
# WHERE THE MATRIX PROOF ACTUALLY LIVES. There is NO per-user federation control in
# tuwunel/Conduit — only a server-wide allow/deny list and per-room m.federate at
# create time. So the AUTHORITATIVE non-federation control for Matrix is the EGRESS
# BACKSTOP: the homeserver gets no direct internet egress and the squid proxy
# allowlist excludes the target (manifests/networkpolicy/homeserver-egress.yaml, see
# docs/DOMAIN-LOCK.md). The proof is therefore taken at the egress boundary, not in
# a user setting, which is why this scenario probes the CS-API directly rather than
# driving the UI.
#
# THE SHAPE OF THE CLAIM. Two refusals bracketing one success: a remote join must
# fail, a LOCAL room must still be created (domain lock removes federation, not local
# access — without this middle step a totally broken token would pass the scenario),
# and an invite aimed at the remote server must fail too.
#
# Positive control: the non-locked row of mastodon-domain-lock.feature.
@platform:x86 @service:tuwunel @layer:egress
Feature: A domain-locked Matrix user cannot federate a room or an invite off-cluster

  @role:e2e-matrix-domainlocked
  Scenario: the egress backstop blocks a remote join and a remote invite, but not local use
    Given the federation observer peer and the domain-lock gate are both live
    And the domain-locked Matrix persona holds a provisioned homeserver token
    When the persona tries to join a room hosted on the remote server
    Then the remote room join is refused
    When the persona creates a local Matrix room
    Then the local room is created
    When the persona invites a user on the remote server
    Then the remote invite is refused
