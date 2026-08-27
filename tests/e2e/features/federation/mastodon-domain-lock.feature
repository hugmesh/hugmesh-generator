# NON-FEDERATION PROOF (Mastodon/akkoma) AND ITS POSITIVE CONTROL, in ONE outline.
#
# Executable form of tests/e2e/specs/19-nofed-mastodon-local-only.spec.ts and
# 22-nofed-positive-control.spec.ts. Those two specs drive the IDENTICAL journey —
# the peer follows a local actor, the actor posts a RAW-API visibility=public toot,
# and the peer is watched — and differ ONLY in who posts and what must happen. So
# the federated/non-federated split belongs in an EXAMPLES COLUMN, not in two
# duplicated scenarios that can drift apart.
#
# WHY THE CONTROL ROW IS NOT OPTIONAL. Without it, "the peer never saw the toot"
# could equally mean federation is broken, the peer is down, or the follow never
# took. Control GREEN + locked GREEN means federation works AND the lock enforces.
# Control RED means the harness is broken and the locked row is INCONCLUSIVE — which
# is why the control's failure message says exactly that instead of just failing.
#
# THE OBSERVATION IS AT THE REMOTE. The akkoma-peer is a real, genuinely-federating
# ActivityPub instance on its own origin, reset per run; "no federation" is observed
# in ITS timeline and ITS copy of the actor's statuses, never merely asserted at the
# source. The negative watches the FULL window and fails the moment the marker
# appears; both rows use the same bound, or the negative would prove nothing.
#
# PLATFORM. Pinned to x86: the peer only exists in a heavy/x86 test cluster, and the
# egress backstop that backs the Matrix half of this proof is x86-only too. Claiming
# an rpi5 row would be a matrix cell nothing can run.
#
# HONEST GATING. The MRF + egress enforcement ships DARK. The locked row needs
# SNAP_FEDERATION_PEER *and* SNAP_DOMAINLOCK_ENABLED=1; the control row needs only
# the peer (it federates regardless, and a peer-only lane should still be able to
# expose a broken harness). Both skip with the precise reason and the env var name.
@platform:x86 @service:akkoma @layer:egress
Feature: A domain-locked toot stays local while a non-locked one federates

  Scenario Outline: the remote peer <outcome> a public toot from <role> @role:<role> @platform:x86 @service:akkoma @layer:egress
    Given the federation observer peer is deployed, and the domain-lock gate too when this persona is domain-locked
    And the remote peer follows the persona for this scenario
    When the persona for this scenario posts a public toot carrying a unique marker
    Then the toot is visible on the local instance timeline
    And the remote peer "<outcome>" that toot within 45 seconds

    Examples:
      | role                      | outcome    |
      | e2e-mastodon-domainlocked | never sees |
      | e2e-mastodon              | sees       |
