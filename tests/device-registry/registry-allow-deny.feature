# Device-license registry — the full ALLOW+DENY SSH-boundary role matrix (PR6).
#
# This is the Gherkin-READABLE companion to
# tests/device-registry/test-registry-allow-deny.sh. The executable harness
# evaluates the ONE auth predicate from the VERIFIED DESIGN
# (snapdragon-device-license-registry memory) against BOTH fail-closed layers
# compiled from ONE signed, unscoped per-mesh export:
#
#   SUPERADMIN -> ALLOW iff P's node is in D.mesh_id AND offered key K is enrolled.
#   ADMIN      -> DENY if D.owner_type == SUPERADMIN; DENY if D.domain != DOMAIN_P;
#                 else ALLOW iff an active license l has l.operator == P AND
#                       K in l.key_fingerprints AND
#                       (DEVICE: l.device_id == D.id OR DOMAIN: l.target_domain == D.domain).
#   MOD / USER -> DENY.
#
# HOW THE HARNESS BACKS EACH SCENARIO (honest about modeled-vs-needs-live-mesh):
#   * Layer-B scenarios RUN THE REAL specs/usr/sbin/snapdragon-authorized-keys-lookup
#     against a per-test fake-root (its absolute paths rewritten so an unprivileged
#     run can stage node.env + the baked public key + a REAL signed export cache).
#     The signature is a REAL detached Ed25519 over the REAL canonical bytes, baking
#     only the throwaway keypair's PUBLIC half. The lookup's verify, monotonic
#     rollback guard, mesh guard, per-node fp match, per-key %f pin, and fail-closed
#     empty-on-error deny are all exercised. [REAL-LAYER-B]
#   * Layer-A scenarios SOURCE the real renderer (render_policy / dev_tag_for_fp /
#     sanitise_tag) from specs/usr/sbin/gen-headscale-policy.sh and evaluate the
#     rendered ssh[] under headscale default-deny SSH semantics. [REAL-LAYER-A]
#   * NEEDS-LIVE-MESH (called out per scenario, never hidden): the live kill of an
#     ALREADY-ESTABLISHED session, that a booted sshd with AuthorizedKeysFile none
#     ignores any stale baked key, that a LIVE headscale REJECTS a forged
#     --advertise-tags (forced tag wins), genuine :22 unreachability, and that
#     MOD/USER keys are refused at a real :22. These are MODELED here against
#     constructed device/license/export/node state. [MODEL]

Feature: The device-license registry compiles to a default-deny ALLOW+DENY SSH boundary

  Background:
    Given a signed, unscoped per-mesh export for mesh "east-01" with strict-monotonic generations
    And the export carries ONLY explicit ADMIN licenses (via in DEVICE-LICENSE, DOMAIN-LICENSE)
    And SUPERADMIN-owned / core nodes and other-domain nodes are ABSENT by BFF compile
    And the export is a detached Ed25519 signature over the canonical bytes, verified against the BAKED key-USB public half
    And both enforcement layers are fail-closed (empty/error => DENY; keep last-good cache)

  # ── LAYER B: per-node sshd (AuthorizedKeysFile none + AuthorizedKeysCommand) ──

  Scenario: A licensed admin reaches their own licensed own-domain device (ALLOW) [REAL-LAYER-B]
    Given node "node-a" (machine_key_fp "fpA") carries a DEVICE-LICENSE for operator "alice" pinning key "SHA256:ka"
    And node "node-a" bakes MACHINE_KEY_FP "fpA" and MESH_ID "east-01"
    When operator "alice" offers the pinned key "SHA256:ka" and the lookup runs
    Then the lookup emits exactly that offered key as the authorized_keys line (ALLOW)

  Scenario: A DOMAIN-LICENSE authorises the operator onto an in-domain node (ALLOW) [REAL-LAYER-B]
    Given node "node-b" (machine_key_fp "fpB") is covered by a DOMAIN-LICENSE for "alice" pinning "SHA256:ka"
    When "alice" offers "SHA256:ka" on node-b
    Then the lookup ALLOWs (the DOMAIN scope satisfies the predicate)

  Scenario: An admin cannot reach a SUPERADMIN-owned / core node (DENY) [REAL-LAYER-B]
    Given node "core-1" (machine_key_fp "fpCORE") is SUPERADMIN-owned and therefore ABSENT from the export
    And a core node never has the registry lookup installed and never bakes an admin key
    When an admin offers any key against fpCORE's lookup
    Then no export entry matches fpCORE so the lookup output is empty (DENY)

  Scenario: An admin cannot reach an other-domain node (DENY) [REAL-LAYER-B]
    Given node "node-z" (machine_key_fp "fpZ") resides in a DIFFERENT domain and is ABSENT from the export
    When an admin offers any key against fpZ's lookup
    Then no export entry matches fpZ so the lookup denies (cross-domain isolation at compile)

  Scenario: An admin cannot reach an UNLICENSED own-domain node (DENY) [REAL-LAYER-B]
    Given node "node-u" (machine_key_fp "fpU") is own-domain and registry-enforced but "alice" holds NO license for it
    When "alice" offers her key against fpU's lookup
    Then no entry pins any key onto fpU so the lookup denies (default-deny steady state)

  Scenario: The pinned key %f must match — a licensed node still denies an unpinned key (DENY) [REAL-LAYER-B]
    Given "alice" is licensed on node-a pinning ONLY "SHA256:ka"
    When "alice" offers a DIFFERENT key "SHA256:NOTPINNED"
    Then the offered fingerprint is not in entry.keyFingerprints so the lookup denies (FIX-PINKEY)

  Scenario: Revocation at the next-higher generation drops the pin (DENY) [REAL-LAYER-B]
    Given the export advances to generation 12 with "alice"'s license on node-a REVOKED (fpA no longer pinned for her)
    And the sync agent only ever writes forward (strict generation greater-than last-good)
    When "alice" offers her previously-valid key on node-a after the refresh
    Then the next authentication re-runs the lookup against the new cache and denies (FIX-REVOKE convergence)
    # the LIVE kill of an already-established session is best-effort in the sync agent's
    # revoked_session_sweep; the AUTHORITATIVE cut is this per-auth re-check [MODEL: live-kill needs a booted node]

  Scenario: An UNSIGNED export is rejected (DENY) [REAL-LAYER-B]
    Given the cached export has signed=false and a null signature
    When the lookup verifies it
    Then verification fails and the lookup denies (fail-closed; the BFF serves unsigned only with no signing key)

  Scenario: A TAMPERED export body is rejected (DENY) [REAL-LAYER-B]
    Given an attacker appends a forged operator entry to a validly-signed body without re-signing
    When the lookup recomputes the canonical bytes and verifies the detached signature
    Then the signature no longer covers the bytes so verification fails and the lookup denies (no forged grant)

  Scenario: A ROLLED-BACK cache below last-good is rejected (DENY) [REAL-LAYER-B]
    Given a correctly-signed but OLD export at generation 11 is replayed when last-good is already 20
    When the lookup checks the cached generation against the recorded last-good
    Then generation 11 < last-good 20 is rejected and the node fails closed to the last-good license set
    And the SYNC agent's strict acceptance guard also rejects a fetched generation <= last-good (no replay)

  Scenario: An export signed by a ROTATED key whose public half was not re-baked is rejected (DENY) [REAL-LAYER-B]
    Given the BFF signs with a NEW private key but this node still bakes the OLD public half
    When the lookup verifies the new signature against the stale baked public key
    Then verification fails and the node denies (a stale baked key fails CLOSED = fleet lockout to break-glass; see the rotation runbook)

  Scenario: An export for a DIFFERENT mesh does not authorise (DENY) [REAL-LAYER-B]
    Given a validly-signed export for mesh "west-02" is presented to a node that baked MESH_ID "east-01"
    When the lookup compares the export meshId to the baked MESH_ID
    Then the mesh mismatch denies (a foreign-mesh cache must never authorise)

  Scenario: AuthorizedKeysFile none makes the lookup the SOLE key source (no baked-key OR) [MODEL]
    Given the enforcement drop-in device-registry.conf
    Then it sets AuthorizedKeysFile none, AuthorizedKeysCommand to the lookup, and AuthorizedKeysCommandUser nobody
    # FIX-AUTHKEYSFILE-NONE: there is no file to OR against, so a registry DENY is a hard deny;
    # that a booted sshd then ignores any stale baked authorized_keys is sshd semantics [MODEL: needs a live node]

  # ── LAYER A: headscale SSH ACL rendered from the same signed export ──

  Scenario: A licensed admin reaches their own licensed node on :22 (ALLOW) [REAL-LAYER-A]
    Given node-a (fpA) appears in the export with a DEVICE-LICENSE for "alice"
    When the policy is rendered
    Then there is an ssh accept whose dst is the server-forced tag:dev_<hash(fpA)>

  Scenario: The same admin cannot reach a superadmin/core node on :22 (DENY) [REAL-LAYER-A]
    Given core-1 is SUPERADMIN-owned and ABSENT from the export
    When the policy is rendered
    Then no ssh accept names a dst tag:dev_ for core-1, so the admin is default-denied

  Scenario: The same admin cannot reach an other-domain node on :22 (DENY) [REAL-LAYER-A]
    Given node-z resides in a different domain and is ABSENT from the export
    When the policy is rendered
    Then no ssh accept names a dst tag:dev_<hash(fpZ)>, so the admin is default-denied

  Scenario: SUPERADMIN reaches ALL nodes in its mesh on :22 (ALLOW) [REAL-LAYER-A]
    Given the always-emitted rule src tag:superadmin -> dst tag:mesh_east-01
    And tag:mesh_east-01 is server-force-assigned to EVERY approved node in the mesh, including core nodes the export omits
    When the policy is rendered
    Then superadmin reaches core-1, node-a, and node-z on :22 via tag:mesh_east-01

  Scenario: SUPERADMIN NOT in the mesh is denied (mesh-membership is the precondition) (DENY) [REAL-LAYER-A]
    Given a node that is NOT force-tagged tag:mesh_east-01 (un-enrolled or only tag:mesh_west-02)
    Then the mesh-scoped superadmin rule does not match it, so superadmin is denied
    # cross-mesh reach requires being force-tagged tag:superadmin on THAT mesh's control node

  Scenario: Server-forced destination tags are not self-applyable (forged-tag DENY) [REAL-LAYER-A]
    Then tag:dev_* and tag:superadmin are listed in tagOwners as owned by the control "snapdragon" user only
    And no preauth key lets a node self-advertise them
    # the live REJECTION of a forged --advertise-tags (forced tag WINS) is [MODEL: needs a live headscale]

  # ── MOD / USER ──

  Scenario: A MOD operator cannot SSH any node (DENY) [MODEL]
    Given MOD operators never enrol an SSH license, so no license row and no export entry exists for them
    When a mod offers any key on any node
    Then there is no entry to authorise it and the node default-denies (same cut as the unlicensed/wrong-key cases)

  Scenario: A USER operator cannot SSH any node (DENY) [MODEL]
    Given USER operators never enrol an SSH license, so no license row and no export entry exists for them
    When a user offers any key on any node
    Then there is no entry to authorise it and the node default-denies
    # the unscoped export cannot see roles, so the BFF compile only ever emits ADMIN licenses;
    # MOD/USER (and SUPERADMIN) are excluded by absence, the predicate's MOD/USER->DENY total leg
