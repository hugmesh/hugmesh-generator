# Layer-A device-license-registry headscale SSH ACL — ALLOW+DENY role matrix.
#
# This is the Gherkin-READABLE companion to
# tests/device-registry/test-layer-a-headscale-acl.sh (PR6 in the device-license
# registry plan). The executable test RENDERS the real policy from the real
# template + a synthetic signed-export body using the REAL renderer functions
# (sourced from specs/usr/sbin/gen-headscale-policy.sh), then evaluates each
# scenario against headscale's documented SSH semantics: SSH is DEFAULT-DENY and
# ONLY the listed `ssh[]` accepts apply. The src side is ADVISORY until OIDC users
# land (see the Background note) — these scenarios assert the DESTINATION cut +
# the default-deny that ship NOW, which is the real Layer-A hardening.
#
# NOT covered here (needs a LIVE headscale + a running admin-bff /export — see the
# NEEDS-HEADSCALE matrix in the PR body): that a real control node REJECTS a node
# self-advertising tag:dev_<otherfp>/tag:dom_<other> (forced-tag override), and
# that :22 is genuinely unreachable on a booted node for a denied edge.

Feature: Layer-A headscale SSH ACL is generated from the signed device-license export

  Background:
    Given a verified, signed per-mesh export for mesh "east-01"
    And the export contains ONLY explicit ADMIN licenses (superadmin/core nodes are absent by design)
    And the headscale policy is rendered from policy.hujson.tmpl by gen-headscale-policy.sh
    And headscale SSH is default-deny — only the rendered ssh[] accepts apply
    # SOURCE-SIDE CAVEAT (FIX-OIDC-USERS deferred): every generated edge uses the
    # advisory src tag:hugmesh until per-tenant Casdoor->headscale OIDC users
    # land; the load-bearing per-operator SOURCE authenticity + per-key %f pinning
    # stay in Layer-B. These scenarios assert the DESTINATION cut + default-deny.

  Scenario: A licensed admin operator reaches a licensed own-domain node on :22 (ALLOW)
    Given node "node-a" (machine_key_fp "fpA") appears in the export with a DEVICE-LICENSE for operator "alice"
    When the policy is rendered
    Then there is exactly one ssh accept whose dst is the server-forced tag:dev_<hash(fpA)>
    And its users list is the node-local privileged ssh account (not the operator name)

  Scenario: The same admin cannot reach a superadmin/core node on :22 (DENY)
    Given node "core-1" is SUPERADMIN-owned and therefore ABSENT from the export
    When the policy is rendered
    Then no ssh accept names a dst tag:dev_ for core-1
    And core-1 is reachable only via the always-emitted SUPERADMIN mesh rule (tag:superadmin -> tag:mesh_east-01), never via an export edge

  Scenario: The same admin cannot reach an other-domain node on :22 (DENY)
    Given node "node-z" resides in a DIFFERENT domain and has no license for operator "alice"
    And node-z therefore does NOT appear in the export
    When the policy is rendered
    Then no ssh accept names a dst tag:dev_<hash(fpZ)>

  Scenario: SUPERADMIN reaches ALL nodes in its mesh on :22 (ALLOW)
    Given the always-emitted rule {src:[tag:superadmin], dst:[tag:mesh_east-01], users:[<ssh user>]}
    And tag:mesh_east-01 is server-force-assigned to EVERY approved node in mesh east-01 (incl. core nodes)
    When the policy is rendered
    Then exactly one ssh accept has src tag:superadmin and dst tag:mesh_east-01
    And this rule is emitted independent of the export body (even an empty export keeps it)

  Scenario: SUPERADMIN reach is scoped to its own mesh (cross-mesh DENY)
    Given the SUPERADMIN edge dst is tag:mesh_east-01 (THIS control node's MESH_ID)
    Then a superadmin operator does NOT reach nodes whose control node did not force-tag them tag:mesh_east-01
    # cross-mesh reach requires being force-tagged tag:superadmin on THAT mesh's control node

  Scenario: Non-:22 fleet traffic still rides the CIDR data-plane only (k8s, not SSH)
    When the policy is rendered
    Then the acls[] keeps exactly the {src:[tag:hugmesh], dst:[10.244.0.0/16:*,10.96.0.0/12:*]} rule
    And the acls[] contains NO any-to-any tag:hugmesh -> tag:hugmesh:* rule

  Scenario: The bootstrap policy already drops the any-to-any :22 hole (pre-export)
    Given the baked policy.bootstrap.hujson applied during provisioning
    Then it has NO any-to-any tag:hugmesh -> tag:hugmesh:* rule
    And it keeps the 10.244/10.96 data-plane rule
    And it has a single conservative @@TS_SSH_USER@@ ssh accept for the bootstrap window

  Scenario: Server-forced destination tags are not self-applyable (FIX-SERVERTAG)
    Then tag:dev_*, tag:superadmin (and tag:mesh_*/tag:dom_* when present) are listed in tagOwners as owned by the control "hugmesh" user only
    And no preauth key is minted that would let a node self-advertise them
    # the live-rejection of a forged advertise-tags is a NEEDS-HEADSCALE assertion

  # ── COMPILE-SIDE RECONCILIATION (added 2026-07-30) ─────────────────────────
  # Layer-A has TWO would-be writers of one headscale policy: the node-side
  # renderer above (LIVE on every control node) and hugmesh-admin-bff-api's
  # HeadscaleAclCompiler + reconcile loop (SHIPS DARK behind
  # app.registry.headscale-acl.enabled=false). These scenarios pin them to each
  # other so that enabling the push is not a leap into an unverified mesh.

  Scenario: The dark BFF compiler addresses nodes by the tag nodes actually carry
    Given nodes are server-force-assigned tag:dev_<sha256(machine_key_fp)[0:12]>
    When the BFF compiles the same signed export into a headscale policy
    Then its node dst tags use the tag:dev_ prefix, never tag:node-<raw fp>
    And its pinned fp->tag vector equals the one dev_tag_for_fp computes in this repo
    # tag:node-* is carried by NO node: pushing it would kill every SSH edge

  Scenario: The compiled policy preserves the k8s data-plane rule
    When the BFF compiles any export, including an EMPTY one
    Then acls[] is NOT empty: it carries {src:[tag:hugmesh], dst:[10.244.0.0/16:*,10.96.0.0/12:*]}
    And autoApprovers still auto-approves those two advertised subnet routes
    # an empty acls[] pushed in DB mode blanks cross-node pod/ClusterIP reachability

  Scenario: The compiled policy keeps superadmin's reach to the core nodes
    When the BFF compiles an export that (by design) omits the core nodes
    Then ssh[] still carries src:[tag:superadmin] dst:[tag:mesh_<id>]
    And every dst tag it names is declared control-owned in tagOwners
    And no src names a group:op-<operator> principal headscale does not know

  Scenario: A file-mode vs DB-mode push mismatch fails loudly, not silently
    Given headscale runs policy mode:file (specs/etc/headscale/config.yaml)
    And PUT /api/v1/policy is a DB-policy-mode-only call
    When an operator sets app.registry.headscale-acl.enabled=true
    And leaves app.registry.headscale-acl.policy-mode at its default 'file'
    Then the push client REFUSES to be wired and the BFF context fails to start
    And the message names both sides of the mismatch and the single-writer decision
    # otherwise the loop 4xxs every 60s forever at one WARN line: a silent no-op

  Scenario: The push stays DARK
    Then app.registry.headscale-acl.enabled still defaults to false
    And the Noop policy client is the wired client, issuing no HTTP at all
    # enabling is cluster-gated: live CANONICAL-FP confirmation + an API key +
    # the file-vs-DB single-writer decision

  Scenario: A revocation survives a headscale that will not load the new policy
    Given the running policy grants operators alice and bob an ssh edge
    And the next export generation revokes bob
    When headscale refuses to load (or is too late loading) the rendered policy
    Then headscale keeps running the previous policy MINUS bob's edge, never bob's edge back
    And the refused policy is retried on later ticks without a new export generation
    And an alarm stays raised until the exported policy is loaded
    And loading the fallback on a later tick neither clears the alarm nor drops the refused policy
    # the cursor has already advanced, so a plain rollback would never be corrected

  Scenario: The fallback cannot be computed
    Given the running policy grants operators alice and bob an ssh edge
    And the next export generation revokes bob and headscale refuses it
    When the previous policy cannot be narrowed
    Then the previous policy is NOT restored, the refused one stays and headscale stays down
    And the narrowing itself needs no temp file, so an unusable TMPDIR cannot turn it off

  Scenario: The policy cannot be written into /etc/headscale
    Given the next export generation revokes bob
    When its policy cannot be staged or installed (disk full, read-only)
    Then an alarm is raised and the policy is kept pending
    And the export cursor is not advanced, so the same generation is installed again next tick
