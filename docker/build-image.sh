#!/bin/sh
# build-image.sh — the admin-bff-api image-gen builder worker entrypoint.
#
# Baked into the image at /builder/build-image.sh (see docker/Dockerfile.image-gen)
# and run by admin-bff-api's k8s Job as: /bin/sh /builder/build-image.sh
# (jobs/image-gen-job.yaml in hugmesh-admin-bff-api — read-only source of
# truth for the contract this script implements). Written in POSIX sh (no
# bash-only syntax) because the Job invokes it via `/bin/sh <path>`, which
# ignores this file's own shebang and runs it under whatever /bin/sh resolves
# to in the image.
#
# ── Contract (from admin-bff-api; do not change without re-checking there) ──
#
# Env vars the Job sets:
#   BUILD_ID          image_build.id (UUID string).
#   TARGET_USER       matches ^[A-Za-z0-9._@/-]{1,400}$; optionally "<org>/<name>".
#   DOMAIN            server-derived brand/cluster domain (not attacker input).
#   IMAGE_TYPE        one of: primary | mesh-extension | client.
#   HARDWARE_CLASS    matches ^[A-Za-z0-9._-]{0,64}$; MAY BE EMPTY. admin-bff-api
#                     does not define any mapping from this to a generator build
#                     target — that mapping is entirely this script's own
#                     convention (documented below).
#   SSH_KEYS_ALLOWED  literal "true" or "false".
#   TOR_ONION         OPTIONAL, literal "true" or "false" (default "false" when
#                     absent). Legacy channel only: "true" folds the Tor v3 onion
#                     NODE service onto an x86 node build via the x86 builder's
#                     additive, idempotent --with-tor flag (exposes fe-gateway as a
#                     v3 .onion). Rejected LOUDLY for imageType=client (the onion is
#                     a cluster-node service, not a client-image feature) or a non-
#                     x86 resolved platform (rpi5/edge Tor nodes have no dedicated
#                     --with-tor flag — use the IMAGE_SPEC_JSON channel, where the
#                     Studio emits the correct per-platform mechanism). INERT in spec
#                     mode: the spec is authoritative for image content, tor included.
#   INGEST_URL        the fully-substituted terminal-report POST URL.
#   INTERNAL_TOKEN    OPTIONAL (secretKeyRef optional:true) — may be absent.
#   ARTIFACT_DIR      /artifacts/build-${BUILD_ID} — where products are written.
#   IMAGE_SPEC_JSON   OPTIONAL, additive. Path to ONE materialized flat
#                     ImageConfig JSON (the Studio worklist's per-image entry),
#                     mounted from the per-build ConfigMap image-spec-${BUILD_ID}
#                     at /etc/hugmesh/image-spec.json. When set (and the file
#                     exists) this worker derives the ENTIRE builder invocation
#                     from that spec via the Studio's own `--print-command`
#                     translator, instead of from the 6 IMAGE_TYPE/HARDWARE_CLASS
#                     env scalars. Absent/empty -> the legacy env path runs
#                     byte-identically. See the image-spec.json channel section
#                     below.
#
# Volumes:
#   /artifacts             the hugmesh-image-artifacts PVC, read-write.
#   /secrets/dial           OPTIONAL, read-only. The per-device DIAL PRIVATE key
#                           (already minted and pushed to Vault by an earlier,
#                           out-of-band step — this Job does not mint it). Must
#                           be read from here only; NEVER copied into
#                           ARTIFACT_DIR, logged, or put in the ingest body.
#
# Ingest: exactly ONE terminal POST to INGEST_URL, header
#   X-Internal-Token: <INTERNAL_TOKEN>   (sent only when INTERNAL_TOKEN is set —
#   its absence is NOT a failure; mTLS is the primary transport boundary and is
#   entirely out of this script's hands), body = JSON matching
#   ImageBuildIngestRequest exactly: status (COMPLETED|FAILED|ERROR, required),
#   imageRef, keysRef, deviceId, machineKeyFp, hostname, dialUser, hostKeyPub,
#   hostKeyFp, dialPubFp, vaultRef, k8sSecretName, message, error (all optional,
#   null when not applicable). imageRef/keysRef MUST be paths relative to the
#   artifacts root, of the exact shape "build-${BUILD_ID}/<name>" — never
#   absolute, never containing "..".
#
# ── image-spec.json channel (OPTIONAL, additive, legacy byte-identical) ──────
# The 6 IMAGE_TYPE/HARDWARE_CLASS env scalars can only express a tiny slice of a
# real image (a platform + a role + a board/flavor). They cannot carry a domain
# list, per-image branding, package add/drop deltas, users, home posture, etc.
# The Studio (studio/hugmesh_studio) already owns the ONE authoritative
# ImageConfig->builder-flags translation, and this worker image bakes the whole
# generator tree — studio/ and python3 included (docker/Dockerfile.image-gen
# `COPY . .`; python3 is already a hard requirement below). So when a richer,
# fully-materialized spec is available, we reuse that single translator rather
# than re-deriving flags a second, drifting way here.
#
#   * The admin-bff-api ImageBuildOrchestrator writes ONE materialized flat
#     ImageConfig JSON to a per-build ConfigMap (image-spec-${BUILD_ID}), mounts
#     it read-only at /etc/hugmesh/image-spec.json, and sets the Job env
#     IMAGE_SPEC_JSON to that path. Rich values ride the FILE, never yamlSafe env
#     scalars (the [A-Za-z0-9._-] env charset cannot carry a theme name or a
#     domain list).
#   * When IMAGE_SPEC_JSON names an existing file, this worker derives the exact
#     builder invocation with the Studio's own headless translator:
#         python3 -m hugmesh_studio --print-command \
#             --config "$IMAGE_SPEC_JSON" --backend native \
#             --generator-dir "$GENERATOR_DIR"
#     (--print-command is Qt-free by a pinned Studio test; it fails LOUDLY on a
#     worklist ENVELOPE — the BFF must hand us ONE already-materialized image,
#     never the whole worklist, mirroring I5 "one image = one Job".)
#   * This worker then OVERLAYS its own operational/tenancy flags AFTER the
#     spec-derived ones. The six ARM/x86 builders parse repeated scalar flags
#     LAST-WINS (verified: build-x86-host-stage4.sh:659-673 `case ... "$2"`), so
#     appended overlays authoritatively override whatever the spec carried:
#       --cluster-domain "$DOMAIN"  — server-derived tenancy domain; NEVER the
#                                     spec's (keeps I6: DOMAIN stays issuer-
#                                     derived, never client image content).
#       -H "$HOSTNAME_OUT"          — the BUILD_ID-derived worker hostname.
#       -w "$SCRATCH_DIR/work" -j "$JOBS" --env "$IMG_BUILD_ENV" — worker infra +
#                                     the fail-secure hardening tier (see below).
#       --no-live-iso/--no-iso --no-tar (x86/rpi5) — the single-artifact ingest
#                                     policy (one imageRef per build, I5), exactly
#                                     as the legacy run_*_build() functions force.
#     Everything else (role, board, flavor, --standalone, --local-user, brand/
#     theme, domains, users, package deltas) is SPEC CONTENT and rides through
#     untouched — the spec is authoritative for it. HEADSCALE_URL/PENTEST that
#     the Studio emits as an `env K=V` passthrough prefix are preserved verbatim.
#   * Absent/empty IMAGE_SPEC_JSON -> the legacy IMAGE_TYPE/HARDWARE_CLASS path
#     below runs byte-identically (resolve_build_target + run_*_build untouched).
#     The spec path adds a build target; it never alters the legacy one.
#   * Parity gate: tests/build-image-spec-parity.sh proves the spec-derived
#     builder command equals the GUI-channel --print-command for the same config,
#     modulo the worker overlay above. It drives this script's
#     BUILD_IMAGE_SH_PRINT_ONLY dev/CI escape hatch (spec channel only): assemble
#     and PRINT the builder argv (one token per line) then exit, running no build.
#     Like BUILD_IMAGE_SH_DEV_ENV_OVERRIDE, that var is NOT part of the
#     admin-bff-api Job contract and must never be wired into image-gen-job.yaml.
#
# ── HARDWARE_CLASS → generator build-target convention (this script's own) ──
# admin-bff-api passes IMAGE_TYPE/HARDWARE_CLASS through as opaque strings with
# no defined mapping to the generator's build vocabulary. This script defines
# one, dot-delimited so it fits the allowed HARDWARE_CLASS charset
# (^[A-Za-z0-9._-]{1,64}$ — no "+", no ":"):
#
#   "<platform>.<role>[.<extra>]"   platform ∈ {x86, rpi5, frite, jetson,
#                        orangepi5, orangepizero2, orangepizero2w,
#                        orangepizero3, orangepi3-lts, orangepi4-lts}
#
#   x86 node roles      (primary | mesh-extension): pki | backend | frontend |
#                        backend-gpu | omnibus | edge-ai
#                        Old spellings still accepted, normalized at parse time:
#                        be, fe, be-gpu, host, gpu-host, edge_ai, full. NOTE the
#                        charset bans "+", which is the only reason `be-gpu` ever
#                        existed; `backend-gpu` needs no such workaround.
#   x86 client roles     (client):                   laptop | chromebook |
#                        desktop | standalone-thin | standalone-thick |
#                        standalone-unaffiliated (UNAFFILIATED plain Gentoo
#                        desktop — no brand/theme/seed/mesh/SSO flags may
#                        accompany it; the role presets the neutral identity)
#   rpi5 node roles      (primary | mesh-extension): "<role>[.<board>]"; role =
#                        pki | backend | frontend | desktop | standalone-desktop
#                        (default: backend); board = rpi5 (default) | rpi4 |
#                        rpi3. board=rpi3 is DESKTOP-ONLY (1 GB RAM has no
#                        headroom for the k8s cluster-node stack) — role !=
#                        desktop/standalone-desktop with board=rpi3 is a clean
#                        FAILED ingest, mirroring build-rpi5-stage4.sh's own
#                        hard-error. standalone-desktop resolves the SAME
#                        --role desktop the plain "desktop" token does, but
#                        also has run_rpi5_build() append --standalone (and
#                        --local-user TARGET_NAME when TARGET_USER carries a
#                        name) — the hardened LUKS2 local-login posture, no
#                        mesh/SSO (see docs/STANDALONE-DESKTOP.md).
#   frite (client only): "<board>.<flavor>"; board = la-frite (default) |
#                        le-potato | sweet-potato; flavor = live | installer
#                        (default) | standalone. Bare "frite" = la-frite.installer.
#                        NOTE: build-frite-stage4.sh's own "both" flavor
#                        (building live AND installer in one invocation) is
#                        intentionally NOT exposed through HARDWARE_CLASS here
#                        — the ingest contract's imageRef is a single path, so
#                        a two-artifact build has no honest way to report both
#                        halves. Requesting flavor=both is a clean, immediate
#                        FAILED ingest (see resolve_build_target below) rather
#                        than silently keeping one artifact and discarding the
#                        other. flavor=standalone requests the hardened
#                        no-mesh/LUKS2/local-login posture: resolve_build_target
#                        normalizes it to the real flavor=installer (--standalone
#                        forces the installer path internally anyway) and
#                        run_frite_build() appends --standalone (and
#                        --local-user TARGET_NAME when set).
#   jetson (EXPERIMENTAL; primary | mesh-extension): "<role>.<board>"; role =
#                        edge-ai (default) | backend-gpu | omnibus | desktop; board =
#                        orin-nano (default) | orin-nano-4gb | orin-nx-8gb |
#                        orin-nx-16gb. NO standalone token here, deliberately
#                        — see the JETSON STANDALONE EXCEPTION note below.
#   orangepi5 (EXPERIMENTAL; client only, no --role axis — a light-desktop
#                        client device like frite): "<board>.<flavor>"; board =
#                        orange-pi-5-plus (default) | orange-pi-5; flavor =
#                        live | installer (default) | standalone. Bare
#                        "orangepi5" = orange-pi-5-plus.installer. "both" is
#                        rejected for the same single-imageRef reason as frite
#                        above; flavor=standalone behaves exactly as frite's
#                        does (normalized to installer + --standalone/
#                        --local-user appended by run_orangepi5_build()).
#   orangepizero2 (EXPERIMENTAL; client only — "client" here means "a single
#                        physical appliance provisioned via the host KEYS
#                        profile," not "has a desktop GUI": this platform is
#                        HEADLESS, no --role/--board axis at all): "<flavor>";
#                        flavor = live | installer (default) | standalone. Bare
#                        "orangepizero2" = installer. "both" is rejected for
#                        the same single-imageRef reason as frite above;
#                        flavor=standalone behaves exactly as frite's does
#                        (normalized to installer + --standalone/--local-user
#                        appended by run_orangepizero2_build()).
#   orangepizero2w (EXPERIMENTAL; client only): "<flavor>" — identical grammar
#                        to orangepizero2 above (the Zero 2's H618 sibling;
#                        headless appliance, no --role/--board axis); handled
#                        by run_orangepizero2w_build().
#   orangepizero3 (EXPERIMENTAL; client only): "<flavor>" — identical grammar
#                        to orangepizero2 above (the Zero 2's H618 sibling;
#                        headless appliance, no --role/--board axis); handled
#                        by run_orangepizero3_build().
#   orangepi4-lts (EXPERIMENTAL; client only): "<flavor>" — identical grammar
#                        to orangepi3-lts below. A LIGHT DESKTOP (RK3399,
#                        Mali-T860) rather than an appliance, but the CLI
#                        grammar is the same because it is also single-board.
#                        Handled by run_orangepi4lts_build().
#   orangepi3-lts (EXPERIMENTAL; client only): "<flavor>" — identical grammar
#                        to orangepizero2 above (Allwinner H6 — a SoC
#                        generation BEFORE the Zero 2's H616, not its sibling;
#                        headless appliance, no --role/--board axis);
#                        handled by run_orangepi3lts_build().
#
#   A bare token with no platform prefix (e.g. HARDWARE_CLASS="pki") is
#   accepted as a legacy/convenience alias for the matching x86 role.
#   Empty HARDWARE_CLASS defaults to: primary/mesh-extension -> x86.backend-gpu
#   (the Makefile's own default role, formerly spelled be+gpu / host); client ->
#   x86.desktop.
#
#   An unrecognized combination is a clean FAILED ingest report, never a
#   silent default and never a crash.
#
# ── Scope / known gaps (deliberately NOT solved by this script) ──────────────
#  * ARM STANDALONE GAP — CLOSED for rpi5/frite/orangepi5/orangepizero2: the
#    standalone-ARM track added --standalone/--local-user/--local-pass/
#    --encrypt-root support to build-rpi5-stage4.sh, build-frite-stage4.sh,
#    build-jetson-stage4.sh, build-orangepi5-stage4.sh and
#    build-orangepi-zero2-stage4.sh (docs/STANDALONE-DESKTOP.md's "ARM
#    platforms" section); this Job worker now has a HARDWARE_CLASS token that
#    requests it on four of those five platforms, mirroring x86's
#    standalone-thin/standalone-thick/standalone-unaffiliated shape:
#      - rpi5:          the role token "standalone-desktop" (e.g.
#                        "rpi5.standalone-desktop.rpi4") — resolves --role
#                        desktop (the only role --standalone composes onto)
#                        plus RPI5_STANDALONE, which run_rpi5_build() turns
#                        into --standalone (+ --local-user when TARGET_USER
#                        carries a name).
#      - frite/orangepi5/orangepizero2: the flavor value "standalone" (e.g.
#                        "frite.la-frite.standalone") on platforms with no
#                        --role axis at all — normalized to the real
#                        flavor=installer (--standalone forces the installer
#                        path internally regardless) plus a per-platform
#                        *_STANDALONE flag that the matching run_*_build()
#                        turns into --standalone (+ --local-user).
#    Jetson remains the one deliberate exception — see the JETSON STANDALONE
#    EXCEPTION note right below — and is NOT given a HARDWARE_CLASS token for
#    this; any jetson request shaped like one falls through to the same
#    generic "unsupported combination" FAILED ingest as any other bad token.
#  * JETSON STANDALONE EXCEPTION: build-jetson-stage4.sh itself hard-errors on
#    --standalone/--encrypt-root ("not supported on this platform yet") because
#    the Orin's single boot+root partition means encrypting root would leave
#    UEFI firmware unable to find a kernel — see docs/STANDALONE-DESKTOP.md's
#    Jetson section. Since the underlying builder cannot honor the posture at
#    all, this script deliberately does NOT add a jetson HARDWARE_CLASS token
#    for it either; that would just be a friendlier way to reach the same
#    hard-error, not a real capability.
#  * CONTRACT GAP — prod vs. test hardening: TriggerImageBuildRequest and
#    image-gen-job.yaml have NO field at all for selecting production-tier
#    hardening (locked-down firewalld, Cloudflare/ACME) vs. the weaker
#    test-tier posture the generator's build scripts also support. There is
#    therefore no real, contract-sanctioned signal this script can read to
#    tell a real admin-console-triggered build from a test one. Given that
#    gap, this script fails SECURE: it defaults to the STRONGER "prod"
#    hardening for every build unless the manual-testing escape hatch below is
#    used. Over-hardening a build is at worst a functional inconvenience;
#    under-hardening a real device is a real security regression, so "prod" is
#    the only safe default in the absence of a real signal. A future
#    admin-bff-api change should add a real field for this (e.g. an
#    `imageEnv`/`hardeningTier` on TriggerImageBuildRequest, threaded through
#    to a Job env var) instead of leaning on this worker's default — see the
#    IMG_BUILD_ENV assignment below for the escape hatch used to select "test"
#    for manual/CI testing of this script itself (NOT wired into the real Job
#    manifest, NOT part of the admin-bff-api contract).
#  * The Job's securityContext (runAsNonRoot: true, runAsUser: 65532) is
#    INCOMPATIBLE with the generator's build scripts, which hard-require root
#    for the chroot/loop/mount work a real build does. This script fails
#    closed with a clear ERROR report rather than silently limping along; an
#    operator must fix the Job's securityContext (and likely grant the loop/
#    mount capabilities the image tooling needs) separately. Out of scope here
#    per the task that produced this file (RBAC/PVC/Job-security decisions are
#    a separate operator concern).
#  * Per-device SSH HOST identity (a stable keypair provision_ssh_host_keys()
#    would install at /etc/ssh/ so the BFF can pin a fingerprint before first
#    boot) is NOT generated by this script. The only per-device secret channel
#    actually wired into the current Job manifest is the DIAL key (read-only,
#    pre-seeded into Vault by an earlier step); there is no analogous mount or
#    writable secret channel for a freshly-minted HOST key, and inventing one
#    (e.g. writing a private key onto the shared, non-secret artifacts PVC)
#    would violate the contract's own no-secrets-in-artifacts rule. Wiring a
#    real host-identity channel (an image-gen-host-${BUILD_ID} secret mount,
#    analogous to dial-key) is a follow-up, not this PR.
#  * The DIAL key is handled fully per contract: this script reads the PRIVATE
#    key from /secrets/dial (when present) ONLY to derive its PUBLIC half and
#    a fingerprint, which it reports via ingest so the BFF can seed the
#    non-secret device_registry row (ImageBuildService.seedNonSecretRegistry).
#    Installing that derived public key into the eventual device's own
#    authorized_keys is understood to be driven by the device's own existing
#    registry-sync agent once it enrolls against that registry row — this
#    script does not attempt to bake it into the image directly (the
#    generator's build scripts have no supported hook for that, and baking it
#    via an ad hoc loopback mount would need privileges this Job does not
#    have either — see the securityContext gap above).
#
set -eu

# ── fixed locations ──────────────────────────────────────────────────────────
GENERATOR_DIR="${GENERATOR_DIR:-/opt/hugmesh-generator}"
# THE role vocabulary (scripts/_roles-lib.sh), baked into the image alongside the
# builders. It is written to be POSIX sh precisely so this /bin/sh worker can read
# it: the two KEYS_ROLE tables below used to be the SAME table written twice, each
# ending in a `*) -> host` catch-all that silently gave omnibus, edge-ai, generic and
# every client role the plain worker keys profile.
# shellcheck source=scripts/_roles-lib.sh
. "${GENERATOR_DIR}/scripts/_roles-lib.sh"

# Role folding and the KEYS profile both come from the lib's own functions
# (hugmesh_role_for / hugmesh_role_keyprofile). NO private wrappers here: the two
# harnesses that extract resolve_build_target() verbatim source _roles-lib.sh, and a
# helper defined only in THIS file would be missing from the extract — which makes
# every probed row reject and reads exactly like a real regression.
DIAL_SECRET_DIR="${DIAL_SECRET_DIR:-/secrets/dial}"
SCRATCH_PARENT="${SCRATCH_PARENT:-/artifacts/.scratch}"
DIAL_USER_DEFAULT="${DIAL_USER:-bff-dial}"
# BUILD_IMAGE_SH_DEV_ENV_OVERRIDE is NOT part of the admin-bff-api Job
# contract — image-gen-job.yaml never sets it, and it must never be wired
# into that manifest. It exists solely so a human (or CI) invoking this
# script directly, outside the real Job, can request the weaker "test"
# hardening tier when deliberately testing build-image.sh itself. Every real
# admin-console-triggered build gets the fail-secure "prod" default below —
# see the CONTRACT GAP note in the header comment for why.
IMG_BUILD_ENV="${BUILD_IMAGE_SH_DEV_ENV_OVERRIDE:-prod}"
# BUILD_IMAGE_SH_PRINT_ONLY is likewise NOT part of the admin-bff-api Job
# contract and must never be set by image-gen-job.yaml. It is the dev/CI escape
# hatch used ONLY by the image-spec parity fixture: with the IMAGE_SPEC_JSON
# channel active, assemble the builder argv (spec-derived flags + worker overlay)
# and print it one token per line, then exit 0 without running any build. It is
# a no-op for the legacy env path (rejected up front — nothing to preview there
# that resolve_build_target/run_*_build don't already assemble byte-identically).
PRINT_ONLY=0
case "${BUILD_IMAGE_SH_PRINT_ONLY:-}" in 1|true|yes|on) PRINT_ONLY=1 ;; esac

log()  { printf '[build-image] %s\n' "$*"; }
warn() { printf '[build-image] WARNING: %s\n' "$*" >&2; }
fail_msg() { printf '[build-image] ERROR: %s\n' "$*" >&2; }

# ── guided --help: the four-choice intents (Studio ModePage parity) ─────────────
# Discoverability only — the parity gap for the CLI/JOB channel is that the operator
# can't SEE the four intents the Studio wizard frames, not that any image path is
# missing (every path is already reachable via env / the make faces). The labels
# mirror the Studio GUI reference (studio/hugmesh_studio/gui/pages/mode.py) so the
# build-matrix TAXO parity check has ONE golden set. This branch fires ONLY on an
# explicit -h/--help/help positional; the real Job invokes with NO positional args
# (env-driven), so resolve_build_target()/run_*_build() below are byte-identical.
print_intents_guide() {
  cat <<'GUIDE'
hugmesh build-image.sh — what do you want to build? (four intents)

This worker is env-driven (IMAGE_TYPE + HARDWARE_CLASS; see the header comment for
the full HARDWARE_CLASS grammar). The four intents the Studio wizard frames map onto
its flags/tokens like this — the same four choices, one clarity layer:

  1. Mesh node — build server node image(s) for a mesh on dedicated hardware
       IMAGE_TYPE=primary|mesh-extension, HARDWARE_CLASS =
         x86.pki | x86.backend | x86.frontend | x86.backend-gpu | x86.omnibus | x86.edge-ai
         | rpi5.<role>[.<board>] | jetson.<role>.<board>
       make face: `make x86-<role>` / `make rpi-<role>` / `make jetson-<role>` /
         `make build-all` / `make build-everything` (the fleet + worklist).

  2. Local Docker mesh — run a mesh on THIS machine in Docker (no image built)
       This builder builds IMAGES ONLY; it never runs a node. For the fourth choice
       run the non-build face instead:
         python3 -m hugmesh_studio.core.local_mesh up --authkey-file <file>
         (or `make mesh-node-up AUTHKEY_FILE=<file>`)
       It reuses the shipped docker-compose.mesh.yml overlay — no image emission.

  3. Mesh desktop client — a branded desktop that JOINS an existing mesh (tailnet+SSO)
       IMAGE_TYPE=client, HARDWARE_CLASS =
         x86.laptop | x86.chromebook | x86.desktop
         | frite.<board>.<flavor> | orangepi5.<...> | orangepizero2.<...>
         | orangepizero2w.<...>
         | orangepizero3.<...> | orangepi3-lts.<...> | orangepi4-lts.<...>
       (the SSO / key-zip client roles). make face: `make x86-<role>` / `make frite`
         / `make orangepi5` / `make orangepizero2` / `make orangepizero2w`
         / `make orangepizero3` / `make orangepi3-lts` / `make orangepi4-lts`.

  4. Standalone Gentoo desktop — hardened personal / UNAFFILIATED desktop (no mesh/SSO)
       HARDWARE_CLASS =
         x86.standalone-thin | x86.standalone-thick | x86.standalone-unaffiliated
         | rpi5.standalone-desktop | frite.<board>.standalone
         | orangepi5.<board>.standalone | orangepizero2.standalone
         | orangepizero2w.standalone
         | orangepizero3.standalone | orangepi3-lts.standalone | orangepi4-lts.standalone
       (the --standalone / --local-user LUKS2 local-login posture). make face:
         `make x86-standalone-thin` … (see the standalone screen in `make menu`).

The three IMAGE intents all resolve through resolve_build_target(); the Local Docker
mesh intent is the ONE non-build face (core/local_mesh.py). To PERMANENTLY enroll a
desktop with an admin keys folder + tray, use the installed end-user appliance
`hugmesh-mesh-node` (clients/docker-mesh-node/install.sh) — a different surface.
GUIDE
}
case "${1:-}" in
  -h|--help|help) print_intents_guide; exit 0 ;;
esac

# ── job env (defaulted to empty so `set -u` never aborts on a merely-absent
#    var; presence/shape is validated explicitly right below) ───────────────
BUILD_ID="${BUILD_ID:-}"
TARGET_USER="${TARGET_USER:-}"
DOMAIN="${DOMAIN:-}"
IMAGE_TYPE="${IMAGE_TYPE:-}"
HARDWARE_CLASS="${HARDWARE_CLASS:-}"
SSH_KEYS_ALLOWED="${SSH_KEYS_ALLOWED:-false}"
# OPTIONAL Tor onion NODE-service toggle (LEGACY channel only; see the header
# contract note). "true" -> the x86 builder's additive --with-tor on an x86 node
# build. Default "false"; validated to the literal true/false below and gated to
# x86 node builds after resolve. Inert when IMAGE_SPEC_JSON drives the build.
TOR_ONION="${TOR_ONION:-false}"
# IDP (LEGACY channel only). Mesh-node identity provider for token validation.
# casdoor (default) = built-in, emits nothing. entra|aws|oidc = external OIDC:
# forwarded to the x86/rpi5 node builders as --idp/--idp-issuer/--idp-client-id
# [--idp-jwks] (both take them). INERT in spec mode (the spec's own idp fields
# already rode through --print-command). Secrets never travel here.
IDP="${IDP:-casdoor}"
IDP_ISSUER="${IDP_ISSUER:-}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-}"
IDP_JWKS="${IDP_JWKS:-}"
INGEST_URL="${INGEST_URL:-}"
INTERNAL_TOKEN="${INTERNAL_TOKEN:-}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"
# OPTIONAL, additive spec channel (see the image-spec.json channel header note).
# Empty -> the legacy IMAGE_TYPE/HARDWARE_CLASS path runs byte-identically.
IMAGE_SPEC_JSON="${IMAGE_SPEC_JSON:-}"
# OPTIONAL, additive progress side channel (see forward_and_wait). When set (the
# Job templates it to admin-bff-api #206's non-terminal /progress endpoint, the
# same way it renders INGEST_URL), the builder's stdout is teed through a
# phase->percent parser and throttled progress frames are POSTed best-effort.
# Empty (today's Job) -> forward_and_wait runs the current `"$@" &; wait` verbatim
# and behavior is byte-identical. It is OPTIONAL, so it is deliberately NOT added
# to the required-env loop below, and it never touches send_ingest / the terminal
# COMPLETED contract. PROGRESS_MIN_INTERVAL (sec) throttles the on-percent frames;
# PROGRESS_CURL_TIMEOUT (sec) bounds each fire-and-forget progress POST.
PROGRESS_URL="${PROGRESS_URL:-}"
PROGRESS_MIN_INTERVAL="${PROGRESS_MIN_INTERVAL:-1}"
PROGRESS_CURL_TIMEOUT="${PROGRESS_CURL_TIMEOUT:-2}"
# OPTIONAL generator revision, reported (not consumed) in the spec-channel
# terminal message. Empty unless the image build/Job supplies it.
GENERATOR_REV="${GENERATOR_REV:-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

# ── ingest report state (single terminal call — see send_ingest) ────────────
IMAGE_REF=""
KEYS_REF=""
DEVICE_ID=""
MACHINE_KEY_FP=""
HOSTNAME_OUT=""
DIAL_USER_OUT=""
HOST_KEY_PUB=""
HOST_KEY_FP=""
DIAL_PUB_FP=""
DIAL_PUB_KEY=""
VAULT_REF=""
K8S_SECRET_NAME=""
MESSAGE_OUT=""
ERROR_OUT=""
INGEST_SENT=0
SCRATCH_DIR=""

# resolve_build_target() / resolve_spec_target() output
BUILD_MODE="legacy"     # "legacy" (env scalars) | "spec" (IMAGE_SPEC_JSON)
SPEC_CMD=""             # spec mode: the Studio's shlex-quoted native build command
PLATFORM=""
BUILD_ROLE=""
RPI5_BOARD_OUT=""
RPI5_STANDALONE=false
FRITE_BOARD_OUT=""
FRITE_FLAVOR_OUT=""
FRITE_STANDALONE=false
JETSON_BOARD_OUT=""
ORANGEPI5_BOARD_OUT=""
ORANGEPI5_FLAVOR_OUT=""
ORANGEPI5_STANDALONE=false
ORANGEPIZERO2_FLAVOR_OUT=""
ORANGEPIZERO2_STANDALONE=false
ORANGEPIZERO2W_FLAVOR_OUT=""
ORANGEPIZERO2W_STANDALONE=false
ORANGEPIZERO3_FLAVOR_OUT=""
ORANGEPIZERO3_STANDALONE=false
ORANGEPI3LTS_FLAVOR_OUT=""
ORANGEPI3LTS_STANDALONE=false
ORANGEPI4LTS_FLAVOR_OUT=""
ORANGEPI4LTS_STANDALONE=false
KEYS_ROLE=""

cleanup_scratch() {
  [ -n "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR" 2>/dev/null || true
}

# send_ingest STATUS — build the JSON body (via python3, always present: it is
# a portage runtime dependency in every Gentoo stage3) and POST it exactly
# once. Never includes anything private-key-shaped: only fingerprints, public
# keys and pointers ever populate the *_FP / *_PUB / *REF variables above.
send_ingest() {
  status="$1"
  if [ "$INGEST_SENT" = "1" ]; then
    warn "a terminal ingest report was already sent for this build — refusing to send a second one (status=${status} suppressed)"
    return 0
  fi
  if [ -z "$INGEST_URL" ]; then
    fail_msg "INGEST_URL is empty — cannot report status=${status} to the BFF (only possible when running outside the real Job)"
    return 1
  fi

  body_file="$(mktemp)"
  resp_file="$(mktemp)"
  STATUS="$status" IMAGE_REF="$IMAGE_REF" KEYS_REF="$KEYS_REF" DEVICE_ID="$DEVICE_ID" \
  MACHINE_KEY_FP="$MACHINE_KEY_FP" HOSTNAME_OUT="$HOSTNAME_OUT" DIAL_USER_OUT="$DIAL_USER_OUT" \
  HOST_KEY_PUB="$HOST_KEY_PUB" HOST_KEY_FP="$HOST_KEY_FP" DIAL_PUB_FP="$DIAL_PUB_FP" \
  VAULT_REF="$VAULT_REF" K8S_SECRET_NAME="$K8S_SECRET_NAME" MESSAGE_OUT="$MESSAGE_OUT" \
  ERROR_OUT="$ERROR_OUT" python3 - "$body_file" <<'PY'
import json, os, sys

def g(key):
    val = os.environ.get(key, "")
    return val if val != "" else None

body = {
    "status": os.environ["STATUS"],
    "imageRef": g("IMAGE_REF"),
    "keysRef": g("KEYS_REF"),
    "deviceId": g("DEVICE_ID"),
    "machineKeyFp": g("MACHINE_KEY_FP"),
    "hostname": g("HOSTNAME_OUT"),
    "dialUser": g("DIAL_USER_OUT"),
    "hostKeyPub": g("HOST_KEY_PUB"),
    "hostKeyFp": g("HOST_KEY_FP"),
    "dialPubFp": g("DIAL_PUB_FP"),
    "vaultRef": g("VAULT_REF"),
    "k8sSecretName": g("K8S_SECRET_NAME"),
    "message": g("MESSAGE_OUT"),
    "error": g("ERROR_OUT"),
}
with open(sys.argv[1], "w") as fh:
    json.dump(body, fh)
PY

  set -- -sS -o "$resp_file" -w '%{http_code}' --max-time 60 \
         --retry 3 --retry-delay 5 --retry-connrefused \
         -X POST "$INGEST_URL" -H 'Content-Type: application/json'
  if [ -n "$INTERNAL_TOKEN" ]; then
    set -- "$@" -H "X-Internal-Token: ${INTERNAL_TOKEN}"
  fi
  set -- "$@" --data-binary "@${body_file}"

  # Capture curl's -w output via redirection into a file, not a command
  # substitution: curl still writes "000" for %{http_code} on a total
  # connection failure, and running it inside `var="$(curl ... || echo 000)"`
  # would concatenate that with the fallback's own "000" into "000000". The
  # `if ... ; then :; fi` form (unlike a bare assignment) is also the one
  # that is exempt from `set -e`, whatever curl's exit status turns out to be.
  code_file="$(mktemp)"
  if curl "$@" >"$code_file" 2>/dev/null; then
    :
  fi
  http_code="$(cat "$code_file" 2>/dev/null)"
  rm -f "$code_file"
  [ -n "$http_code" ] || http_code="000"
  log "ingest POST ${INGEST_URL} status=${status} http=${http_code}"
  if [ "$http_code" != "200" ]; then
    warn "ingest response body: $(head -c 2000 "$resp_file" 2>/dev/null | tr '\n' ' ')"
  fi
  rm -f "$body_file" "$resp_file"
  INGEST_SENT=1
  [ "$http_code" = "200" ]
}

# die STATUS MESSAGE — report a terminal failure and exit non-zero. STATUS is
# "FAILED" for a well-formed request this worker legitimately cannot satisfy
# (bad role combo, the underlying build script failed) or "ERROR" for an
# infra/prerequisite problem (bad env, unwritable artifacts mount, etc).
die() {
  die_status="$1"
  die_msg="$2"
  fail_msg "$die_msg"
  # PRINT_ONLY is a command-preview: there is no BFF to report to, so fail fast
  # with the reason on stderr rather than attempting a terminal ingest POST.
  if [ "$PRINT_ONLY" = "1" ]; then
    exit 1
  fi
  if [ "$die_status" = "FAILED" ]; then
    MESSAGE_OUT="$die_msg"
  else
    ERROR_OUT="$die_msg"
  fi
  send_ingest "$die_status" || warn "could not deliver the terminal ${die_status} ingest report — see the log lines above"
  exit 1
}

# Safety net: if the script exits for ANY reason (including an uncaught `set
# -e` abort somewhere we did not wrap in an explicit check) without having
# already sent the one terminal report, send a best-effort ERROR report rather
# than leaving the BFF's image_build row stuck forever with no signal.
on_exit() {
  ec=$?
  # PRINT_ONLY is a dev/CI command-preview: there is no build and no BFF to
  # report to, so never attempt a terminal ingest — just tidy up and exit.
  if [ "$PRINT_ONLY" = "1" ]; then
    cleanup_scratch
    exit "$ec"
  fi
  if [ "$INGEST_SENT" != "1" ]; then
    if [ -z "$ERROR_OUT" ]; then
      ERROR_OUT="build-image.sh exited unexpectedly (code ${ec}) before it could report a terminal status"
    fi
    send_ingest ERROR || true
  fi
  cleanup_scratch
  # A trap registered for INT/TERM (as opposed to the EXIT pseudo-signal) does
  # NOT terminate the process on its own once it returns — bash/POSIX sh just
  # resume execution where the signal interrupted it. Exiting explicitly here
  # makes both cases (a real INT/TERM and a normal `exit`) actually stop the
  # script; re-invoking `exit` from inside a handler already bound to EXIT
  # does not recurse (the shell does not re-enter the same trap while running
  # it) and is a no-op for the ordinary "we already called exit" path.
  exit "$ec"
}
trap on_exit EXIT INT TERM

# ── 1. validate required env ────────────────────────────────────────────────
missing=""
for v in BUILD_ID TARGET_USER DOMAIN IMAGE_TYPE INGEST_URL ARTIFACT_DIR; do
  eval "v_val=\${$v}"
  [ -n "$v_val" ] || missing="${missing} ${v}"
done
[ -n "$missing" ] && die ERROR "missing required env var(s):${missing}"

case "$SSH_KEYS_ALLOWED" in
  true|false) ;;
  *) die ERROR "SSH_KEYS_ALLOWED must be the literal string 'true' or 'false' (got '${SSH_KEYS_ALLOWED}')" ;;
esac

case "$TOR_ONION" in
  true|false) ;;
  *) die ERROR "TOR_ONION must be the literal string 'true' or 'false' (got '${TOR_ONION}')" ;;
esac

# IDP validation. casdoor (default) = no-op; external needs an https issuer + a
# client id (secrets are never env/flags). Validated unconditionally: only the
# legacy channel forwards IDP_* onto the builder (dispatch_node_builder), and the
# spec channel never sets IDP (defaults to casdoor), so validating here is
# correct for both — a nonsensical IDP=entra with a spec build is rejected, not
# silently ignored.
case "$IDP" in
  casdoor)
    if [ -n "${IDP_ISSUER}${IDP_CLIENT_ID}${IDP_JWKS}" ]; then
      die ERROR "IDP_ISSUER/IDP_CLIENT_ID/IDP_JWKS require an external IDP (entra|aws|oidc); the casdoor default derives its own issuer"
    fi ;;
  entra|aws|oidc)
    case "$IDP_ISSUER" in
      https://*) ;;
      *) die ERROR "IDP=${IDP} requires IDP_ISSUER as an https:// URL (baked into the node's idp.conf and issuer/JWKS pins)" ;;
    esac
    [ -n "$IDP_CLIENT_ID" ] || die ERROR "IDP=${IDP} requires IDP_CLIENT_ID (a public client identifier; secrets are never passed here)" ;;
  *) die ERROR "IDP must be casdoor|entra|aws|oidc (got '${IDP}')" ;;
esac

case "$IMAGE_TYPE" in
  primary|mesh-extension|client) ;;
  *) die FAILED "unsupported IMAGE_TYPE '${IMAGE_TYPE}' (must be primary|mesh-extension|client)" ;;
esac

# Defense in depth: admin-bff-api already enforces these charsets at the DTO
# and yamlSafe() layers, but a worker that trusts its env blindly is one
# render-time bug away from executing an unexpected value.
case "$TARGET_USER" in
  *[!A-Za-z0-9._@/-]*) die ERROR "TARGET_USER contains characters outside [A-Za-z0-9._@/-]" ;;
esac
if [ -n "$HARDWARE_CLASS" ]; then
  case "$HARDWARE_CLASS" in
    *[!A-Za-z0-9._-]*) die ERROR "HARDWARE_CLASS contains characters outside [A-Za-z0-9._-]" ;;
  esac
fi

expected_artifact_dir="/artifacts/build-${BUILD_ID}"
if [ "$ARTIFACT_DIR" != "$expected_artifact_dir" ]; then
  die ERROR "ARTIFACT_DIR ('${ARTIFACT_DIR}') does not match the expected '${expected_artifact_dir}' for BUILD_ID='${BUILD_ID}'"
fi

# root + the runtime tool set are EXECUTION prerequisites (chroot/loop/mount,
# the ingest POST, key derivation, the tarball). PRINT_ONLY only assembles and
# prints the builder argv, so it skips them — but the spec channel still needs
# python3 to run the Studio's --print-command translator, so require that always.
if [ "$PRINT_ONLY" != "1" ]; then
  if [ "$(id -u)" != "0" ]; then
    die ERROR "must run as root (uid 0) — the generator's build scripts require root for chroot/loop/mount work. NOTE: the current image-gen-job.yaml sets securityContext.runAsNonRoot=true/runAsUser=65532, which is incompatible with this; an operator must adjust the Job's security context before real builds can run (tracked as a follow-up, out of scope for this worker-image change)."
  fi
  for tool in curl python3 ssh-keygen tar find; do
    command -v "$tool" >/dev/null 2>&1 || die ERROR "required tool '${tool}' not found in the image"
  done
else
  command -v python3 >/dev/null 2>&1 || die ERROR "required tool 'python3' not found (the IMAGE_SPEC_JSON channel needs it for --print-command)"
fi

[ -d "$GENERATOR_DIR" ] || die ERROR "GENERATOR_DIR '${GENERATOR_DIR}' not found (broken image build?)"
for f in build-x86-host-stage4.sh build-rpi5-stage4.sh build-frite-stage4.sh build-jetson-stage4.sh \
         build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh \
         build-orangepi-zero3-stage4.sh build-orangepi3-lts-stage4.sh \
         build-orangepi4-lts-stage4.sh; do
  [ -x "${GENERATOR_DIR}/${f}" ] || die ERROR "generator build script missing/not executable: ${GENERATOR_DIR}/${f}"
done

# ── 2. artifacts + scratch dirs ──────────────────────────────────────────────
# SCRATCH_DIR is always computed (its -w value appears in the assembled builder
# command) but only materialized when a real build follows — PRINT_ONLY previews
# the command without touching the PVC.
SCRATCH_DIR="${SCRATCH_PARENT}/${BUILD_ID}"
if [ "$PRINT_ONLY" != "1" ]; then
  mkdir -p "$ARTIFACT_DIR" 2>/dev/null || die ERROR "cannot create ARTIFACT_DIR ${ARTIFACT_DIR} (artifacts PVC not mounted?)"
  [ -w "$ARTIFACT_DIR" ] || die ERROR "ARTIFACT_DIR ${ARTIFACT_DIR} is not writable"

  # The heavy sysroot/distfiles/pkgdir build tree is intentionally kept OUTSIDE
  # ARTIFACT_DIR (a sibling scratch dir on the same PVC, since it is the only
  # volume with enough space) and removed at the end (on_exit -> cleanup_scratch)
  # so the shared artifacts PVC never permanently accumulates multi-GB build
  # trees per build.
  rm -rf "$SCRATCH_DIR" 2>/dev/null || true
  mkdir -p "$SCRATCH_DIR/work" "$SCRATCH_DIR/keys-bundle" || die ERROR "cannot create scratch dir ${SCRATCH_DIR} (artifacts PVC full/unwritable?)"
fi

# ── 3. resolve TARGET_USER -> optional brand org + local name ───────────────
case "$TARGET_USER" in
  */*) BRAND_ORG="${TARGET_USER%%/*}"; TARGET_NAME="${TARGET_USER#*/}" ;;
  *)   BRAND_ORG="";                    TARGET_NAME="$TARGET_USER" ;;
esac
BRAND_FLAGS_CFG=""
if [ -n "$BRAND_ORG" ] && [ -f "${GENERATOR_DIR}/brands/${BRAND_ORG}.conf" ]; then
  BRAND_FLAGS_CFG="brands/${BRAND_ORG}.conf"
fi

# ── 4. map IMAGE_TYPE + HARDWARE_CLASS -> a generator build target ──────────
# See the header comment for the full HARDWARE_CLASS convention.
resolve_build_target() {
  # ARM standalone-posture flags — always defaulted false here (before any
  # platform-specific case arm runs) so every call starts from a clean slate,
  # regardless of which platform ends up matching. Only the rpi5 arm's
  # "standalone-desktop" role token and the frite/orangepi5/orangepizero2 arms'
  # "standalone" flavor token ever flip one of these to true.
  RPI5_STANDALONE=false
  FRITE_STANDALONE=false
  ORANGEPI5_STANDALONE=false
  ORANGEPIZERO2_STANDALONE=false
  ORANGEPIZERO2W_STANDALONE=false
  ORANGEPIZERO3_STANDALONE=false
  ORANGEPI3LTS_STANDALONE=false
  ORANGEPI4LTS_STANDALONE=false

  if [ -z "$HARDWARE_CLASS" ]; then
    case "$IMAGE_TYPE" in
      primary|mesh-extension) PLATFORM="x86"; BUILD_ROLE="backend-gpu" ;;
      client)                 PLATFORM="x86"; BUILD_ROLE="desktop" ;;
    esac
  else
    hw="$HARDWARE_CLASS"
    p1="${hw%%.*}"
    rest="${hw#*.}"
    [ "$rest" = "$hw" ] && rest=""
    p2="${rest%%.*}"
    rest2="${rest#*.}"
    [ "$rest2" = "$rest" ] && rest2=""
    p3="$rest2"

    case "$p1" in
      x86)
        case "$IMAGE_TYPE" in
          primary|mesh-extension)
            if [ -z "$p2" ]; then
              BUILD_ROLE="backend-gpu"
            elif ! BUILD_ROLE="$(hugmesh_role_for x86 "$p2")"; then
              return 1
            fi
            case " pki backend frontend backend-gpu omnibus edge-ai " in
              *" ${BUILD_ROLE} "*) ;;
              *) return 1 ;;                # a client role is not a node role
            esac
            ;;
          client)
            case "$p2" in
              laptop|chromebook|desktop|standalone-thin|standalone-thick|standalone-unaffiliated) BUILD_ROLE="$p2" ;;
              *) return 1 ;;
            esac
            ;;
        esac
        PLATFORM="x86"
        ;;
      rpi5)
        [ "$IMAGE_TYPE" = "client" ] && return 1
        case "$p2" in
          standalone-desktop)
            # A COMPOSITE alias: it carries a SECOND axis, so it must never go
            # through the plain spelling-alias path (that would silently drop the
            # FDE posture). --role desktop AND --standalone; RPI5_STANDALONE makes
            # run_rpi5_build append --standalone/--local-user below.
            BUILD_ROLE="desktop"
            RPI5_STANDALONE=true
            ;;
          "") BUILD_ROLE="backend" ;;
          *)
            # `be`/`fe` resolve here now: docs/catalog/image-catalog.json publishes
            # them for platform rpi5, and this channel used to answer `rpi5.be` with
            # a flat "unsupported" while the spec channel translated it correctly.
            if ! BUILD_ROLE="$(hugmesh_role_for rpi5 "$p2")"; then
              return 1
            fi ;;
        esac
        RPI5_BOARD_OUT="${p3:-rpi5}"
        case "$RPI5_BOARD_OUT" in rpi5|rpi4|rpi3) ;; *) return 1 ;; esac
        # board=rpi3 is DESKTOP-ONLY (1 GB RAM has no headroom for the k8s
        # cluster-node stack) — mirrors build-rpi5-stage4.sh's own hard-error.
        if [ "$RPI5_BOARD_OUT" = "rpi3" ] && [ "$BUILD_ROLE" != "desktop" ]; then
          return 1
        fi
        PLATFORM="rpi5"
        ;;
      frite)
        [ "$IMAGE_TYPE" != "client" ] && return 1
        FRITE_BOARD_OUT="${p2:-la-frite}"
        FRITE_FLAVOR_OUT="${p3:-installer}"
        case "$FRITE_BOARD_OUT" in la-frite|le-potato|sweet-potato) ;; *) return 1 ;; esac
        # "both" is deliberately NOT accepted: build-frite-stage4.sh's
        # flavor=both produces TWO artifacts (live + installer), and the
        # ingest contract's imageRef is a single path with no multi-artifact
        # support. Rejecting it here (a clean FAILED ingest via the
        # resolve_build_target caller below) is strictly better than
        # nondeterministically keeping one artifact and silently discarding
        # the other — see the header comment's frite convention note.
        case "$FRITE_FLAVOR_OUT" in
          standalone)
            # build-frite-stage4.sh's --standalone already forces the
            # installer flavor on internally (LUKS2 FDE only happens via the
            # installer path) — normalize here so FRITE_FLAVOR_OUT always
            # carries a real --flavor value, never the job-only sentinel.
            FRITE_STANDALONE=true
            FRITE_FLAVOR_OUT="installer"
            ;;
          live|installer) ;;
          *) return 1 ;;
        esac
        PLATFORM="frite"
        ;;
      jetson)
        [ "$IMAGE_TYPE" = "client" ] && return 1
        if ! BUILD_ROLE="$(hugmesh_role_for jetson "${p2:-edge-ai}")"; then return 1; fi
        JETSON_BOARD_OUT="${p3:-orin-nano}"
        case "$JETSON_BOARD_OUT" in orin-nano|orin-nano-4gb|orin-nx-8gb|orin-nx-16gb) ;; *) return 1 ;; esac
        PLATFORM="jetson"
        ;;
      orangepi5)
        [ "$IMAGE_TYPE" != "client" ] && return 1
        ORANGEPI5_BOARD_OUT="${p2:-orange-pi-5-plus}"
        ORANGEPI5_FLAVOR_OUT="${p3:-installer}"
        case "$ORANGEPI5_BOARD_OUT" in orange-pi-5-plus|orange-pi-5) ;; *) return 1 ;; esac
        # "both" rejected for the same single-imageRef reason as frite above.
        case "$ORANGEPI5_FLAVOR_OUT" in
          standalone)
            # --standalone forces the installer flavor internally, same as
            # frite above — normalize so ORANGEPI5_FLAVOR_OUT always carries a
            # real --flavor value.
            ORANGEPI5_STANDALONE=true
            ORANGEPI5_FLAVOR_OUT="installer"
            ;;
          live|installer) ;;
          *) return 1 ;;
        esac
        PLATFORM="orangepi5"
        ;;
      orangepizero2)
        [ "$IMAGE_TYPE" != "client" ] && return 1
        ORANGEPIZERO2_FLAVOR_OUT="${p2:-installer}"
        # "both" rejected for the same single-imageRef reason as frite above.
        case "$ORANGEPIZERO2_FLAVOR_OUT" in
          standalone)
            # --standalone forces the installer flavor internally, same as
            # frite/orangepi5 above.
            ORANGEPIZERO2_STANDALONE=true
            ORANGEPIZERO2_FLAVOR_OUT="installer"
            ;;
          live|installer) ;;
          *) return 1 ;;
        esac
        PLATFORM="orangepizero2"
        ;;
      orangepizero2w)
        [ "$IMAGE_TYPE" != "client" ] && return 1
        ORANGEPIZERO2W_FLAVOR_OUT="${p2:-installer}"
        # "both" rejected for the same single-imageRef reason as frite above.
        case "$ORANGEPIZERO2W_FLAVOR_OUT" in
          standalone)
            # --standalone forces the installer flavor internally, same as
            # frite/orangepi5/orangepizero2 above.
            ORANGEPIZERO2W_STANDALONE=true
            ORANGEPIZERO2W_FLAVOR_OUT="installer"
            ;;
          live|installer) ;;
          *) return 1 ;;
        esac
        PLATFORM="orangepizero2w"
        ;;
      orangepizero3)
        [ "$IMAGE_TYPE" != "client" ] && return 1
        ORANGEPIZERO3_FLAVOR_OUT="${p2:-installer}"
        # "both" rejected for the same single-imageRef reason as frite above.
        case "$ORANGEPIZERO3_FLAVOR_OUT" in
          standalone)
            # --standalone forces the installer flavor internally, same as
            # frite/orangepi5/orangepizero2 above.
            ORANGEPIZERO3_STANDALONE=true
            ORANGEPIZERO3_FLAVOR_OUT="installer"
            ;;
          live|installer) ;;
          *) return 1 ;;
        esac
        PLATFORM="orangepizero3"
        ;;
      orangepi3-lts)
        [ "$IMAGE_TYPE" != "client" ] && return 1
        ORANGEPI3LTS_FLAVOR_OUT="${p2:-installer}"
        # "both" rejected for the same single-imageRef reason as frite above.
        case "$ORANGEPI3LTS_FLAVOR_OUT" in
          standalone)
            # --standalone forces the installer flavor internally, same as
            # frite/orangepi5/orangepizero2 above.
            ORANGEPI3LTS_STANDALONE=true
            ORANGEPI3LTS_FLAVOR_OUT="installer"
            ;;
          live|installer) ;;
          *) return 1 ;;
        esac
        PLATFORM="orangepi3-lts"
        ;;
      orangepi4-lts)
        [ "$IMAGE_TYPE" != "client" ] && return 1
        ORANGEPI4LTS_FLAVOR_OUT="${p2:-installer}"
        # "both" rejected for the same single-imageRef reason as frite above.
        case "$ORANGEPI4LTS_FLAVOR_OUT" in
          standalone)
            # --standalone forces the installer flavor internally, same as
            # frite/orangepi5/orangepizero2 above.
            ORANGEPI4LTS_STANDALONE=true
            ORANGEPI4LTS_FLAVOR_OUT="installer"
            ;;
          live|installer) ;;
          *) return 1 ;;
        esac
        PLATFORM="orangepi4-lts"
        ;;
      *)
        # Bare legacy token, no platform prefix -> x86 alias.
        case "$IMAGE_TYPE" in
          primary|mesh-extension)
            if ! BUILD_ROLE="$(hugmesh_role_for x86 "$p1")"; then return 1; fi
            case " pki backend frontend backend-gpu omnibus edge-ai " in
              *" ${BUILD_ROLE} "*) ;;
              *) return 1 ;;                # a client role is not a node role
            esac
            ;;
          client)
            case "$p1" in
              laptop|chromebook|desktop|standalone-thin|standalone-thick|standalone-unaffiliated) BUILD_ROLE="$p1" ;;
              *) return 1 ;;
            esac
            ;;
        esac
        PLATFORM="x86"
        ;;
    esac
  fi

  [ -n "$PLATFORM" ] || return 1

  if [ "$IMAGE_TYPE" = "mesh-extension" ]; then
    KEYS_ROLE="mesh-extension"
  else
    # No blanket `*) -> host` catch-all: that silently gave omnibus, edge-ai,
    # generic and every client role the plain worker keys profile — a node
    # provisioned with the wrong credentials, reported as success.
    #
    # ONE declared exception, and it is a rule rather than a guess: the seven
    # free-slug boards have NO role axis at all, so BUILD_ROLE is legitimately empty
    # for them. They provision as client appliances from the plain `host` worker
    # profile — the same rule scripts/build-all-roles.sh applies in its own
    # per-platform keys blocks (keys-frite, keys-orangepi5, …).
    if [ -z "$BUILD_ROLE" ]; then
      case "$PLATFORM" in
        frite|orangepi5|orangepi4-lts|orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts)
          KEYS_ROLE="host" ;;
        *)
          die ERROR "platform '${PLATFORM}' resolved with an EMPTY role, but it has a role axis — refusing to pick a KEYS profile for a role nobody named" ;;
      esac
    else
      KEYS_ROLE="$(hugmesh_role_keyprofile "$BUILD_ROLE")" \
        || die ERROR "no KEYS profile is declared for role '${BUILD_ROLE}' — add it to HUGMESH_ROLE_KEYPROFILE in scripts/_roles-lib.sh (refusing to guess: a wrong keys profile provisions the node with the wrong credentials)"
    fi
  fi
  return 0
}

# resolve_spec_target — the IMAGE_SPEC_JSON channel's twin of resolve_build_target.
# Instead of mapping the 6 env scalars, it asks the Studio to translate the full
# materialized ImageConfig into a native build command and reads the platform +
# role back off that command. It NEVER re-derives builder flags itself — the
# Studio is the single translation source; run_spec_build() runs that exact
# command with only the worker overlay appended.
resolve_spec_target() {
  spec_err="$(mktemp)"
  # Studio lives at ${GENERATOR_DIR}/studio (docker/Dockerfile.image-gen `COPY .
  # .`). --print-command is Qt-free and fails loudly (exit 2, reason on stderr)
  # on a worklist envelope or an invalid identity — surface that as a FAILED
  # ingest, never a silent default.
  if SPEC_CMD="$(PYTHONPATH="${GENERATOR_DIR}/studio${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m hugmesh_studio --print-command \
        --config "$IMAGE_SPEC_JSON" --backend native \
        --generator-dir "$GENERATOR_DIR" 2>"$spec_err")"; then
    rm -f "$spec_err"
  else
    spec_reason="$(head -c 2000 "$spec_err" 2>/dev/null | tr '\n' ' ')"
    rm -f "$spec_err"
    die FAILED "could not derive a build command from IMAGE_SPEC_JSON=${IMAGE_SPEC_JSON} via the Studio --print-command translator: ${spec_reason}"
  fi

  # Re-parse the Studio's shlex-quoted command back into argv. --print-command
  # emits shell-safe quoting (Python shlex.quote) over values that already passed
  # the Studio's own validation (atom/domain/username allowlists), so `eval` here
  # only reconstructs that exact argv — single-quoted metacharacters stay literal
  # and cannot inject shell behaviour. This is the standard POSIX idiom for
  # re-tokenising a trusted shell-quoted string.
  eval "set -- $SPEC_CMD"
  # command() prefixes native output with `sudo` only when it is NOT already root
  # (i.e. in dev/CI). The worker runs the build as root, so drop any leading sudo.
  [ "${1:-}" = "sudo" ] && shift

  # Identify the builder script token -> PLATFORM (the `env K=V`/`bash` prefix and
  # every flag are skipped; only the ./build-*-stage4.sh token matches).
  PLATFORM=""
  for _tok in "$@"; do
    case "$_tok" in
      */build-x86-host-stage4.sh|build-x86-host-stage4.sh)         PLATFORM="x86" ;;
      */build-rpi5-stage4.sh|build-rpi5-stage4.sh)                 PLATFORM="rpi5" ;;
      */build-frite-stage4.sh|build-frite-stage4.sh)               PLATFORM="frite" ;;
      */build-jetson-stage4.sh|build-jetson-stage4.sh)             PLATFORM="jetson" ;;
      */build-orangepi5-stage4.sh|build-orangepi5-stage4.sh)       PLATFORM="orangepi5" ;;
      */build-orangepi-zero2-stage4.sh|build-orangepi-zero2-stage4.sh) PLATFORM="orangepizero2" ;;
      */build-orangepi-zero2w-stage4.sh|build-orangepi-zero2w-stage4.sh) PLATFORM="orangepizero2w" ;;
      */build-orangepi-zero3-stage4.sh|build-orangepi-zero3-stage4.sh) PLATFORM="orangepizero3" ;;
      */build-orangepi3-lts-stage4.sh|build-orangepi3-lts-stage4.sh) PLATFORM="orangepi3-lts" ;;
      */build-orangepi4-lts-stage4.sh|build-orangepi4-lts-stage4.sh) PLATFORM="orangepi4-lts" ;;
    esac
    [ -n "$PLATFORM" ] && break
  done
  [ -n "$PLATFORM" ] || die FAILED "the Studio --print-command output did not name a known generator build script, so the image-spec could not be mapped to a platform: ${SPEC_CMD}"

  # Best-effort role/board/flavor purely for logging + the non-secret metadata
  # bundle + build_desc. These NEVER affect the executed argv (that is SPEC_CMD
  # verbatim + the worker overlay) — they are just a human-readable summary.
  BUILD_ROLE=""; _sb=""; _sf=""; _prev=""
  for _tok in "$@"; do
    case "$_prev" in
      -r|--role)   BUILD_ROLE="$_tok" ;;
      -b|--board)  _sb="$_tok" ;;
      --flavor)    _sf="$_tok" ;;
    esac
    _prev="$_tok"
  done

  # ── fail-closed spec validation (the legacy guards resolve_build_target has,
  #    which the spec channel was missing) ──────────────────────────────────────
  # The Studio validates identity (atoms/domains/usernames) but NOT role×platform
  # or the frite/orangepi5/orangepizero2 single-artifact flavor invariant. So a
  # flat/minimal ImageConfig can materialize an off-platform role (the x86 base
  # default `standalone-thick` on a jetson, since ImageConfig.role defaults to an
  # x86 client role) or the two-artifact `--flavor both` (the Studio's unset-flavor
  # default). Relaying either is strictly worse than the legacy channel: jetson
  # with a bad role wastes the whole multi-hour build then the builder exits
  # non-zero, and flavor=both builds BOTH live+installer ISOs and then the artifact
  # collector die-ERRORs (>1 imageRef). resolve_build_target rejects both cases up
  # front (jetson role allowlist; `both` rejected, unset flavor defaults to
  # installer); mirror that here as a clean FAILED ingest before any builder runs.
  case "$PLATFORM" in
    jetson)
      # build-jetson-stage4.sh accepts exactly these (the Studio already maps its
      # jetson-desktop role id down to the builder's `desktop`).
      _js="$BUILD_ROLE"
      if ! BUILD_ROLE="$(hugmesh_role_for jetson "$_js")"; then
        die FAILED "the image-spec resolved to platform=jetson with role='${_js:-<none>}', which build-jetson-stage4.sh rejects (it accepts only: ${HUGMESH_ROLES_JETSON}, plus the aliases declared in scripts/_roles-lib.sh). The Studio does not validate role×platform, so a jetson ImageConfig that leaves role at the base default materializes the x86 client role 'standalone-thick' — set a jetson role explicitly."
      fi
      ;;
    frite|orangepi5|orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts|orangepi4-lts)
      # --flavor both emits TWO artifacts (live + installer); the ingest contract
      # carries a single imageRef, so the collector would die at artifact
      # collection AFTER the full build. Reject it here like resolve_build_target
      # does (which also defaults an unset flavor to installer — the Studio instead
      # defaults it to the unbuildable-on-this-channel `both`).
      case "$_sf" in
        live|installer) ;;
        both) die FAILED "the image-spec resolved to platform=${PLATFORM} with --flavor both, which produces two artifacts (a live ISO and an installer ISO). The worker's ingest contract supports exactly one imageRef per build, so request --flavor live or --flavor installer instead (the Studio's unset-flavor default of 'both' is not buildable on this channel)." ;;
        *)    die FAILED "the image-spec resolved to platform=${PLATFORM} with --flavor='${_sf:-<none>}', which the arm64 builder does not accept (it accepts only: live | installer)." ;;
      esac
      ;;
  esac

  case "$PLATFORM" in
    frite|orangepi5) build_desc="${_sb:-?}.${_sf:-?}" ;;
    orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts|orangepi4-lts)   build_desc="${_sf:-?}" ;;
    *)               build_desc="${BUILD_ROLE:-spec}" ;;
  esac

  # KEYS_ROLE mirrors resolve_build_target's mapping (IMAGE_TYPE still comes from
  # the Job env and is authoritative for the keys profile).
  if [ "$IMAGE_TYPE" = "mesh-extension" ]; then
    KEYS_ROLE="mesh-extension"
  else
    # No blanket `*) -> host` catch-all: that silently gave omnibus, edge-ai,
    # generic and every client role the plain worker keys profile — a node
    # provisioned with the wrong credentials, reported as success.
    #
    # ONE declared exception, and it is a rule rather than a guess: the seven
    # free-slug boards have NO role axis at all, so BUILD_ROLE is legitimately empty
    # for them. They provision as client appliances from the plain `host` worker
    # profile — the same rule scripts/build-all-roles.sh applies in its own
    # per-platform keys blocks (keys-frite, keys-orangepi5, …).
    if [ -z "$BUILD_ROLE" ]; then
      case "$PLATFORM" in
        frite|orangepi5|orangepi4-lts|orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts)
          KEYS_ROLE="host" ;;
        *)
          die ERROR "platform '${PLATFORM}' resolved with an EMPTY role, but it has a role axis — refusing to pick a KEYS profile for a role nobody named" ;;
      esac
    else
      KEYS_ROLE="$(hugmesh_role_keyprofile "$BUILD_ROLE")" \
        || die ERROR "no KEYS profile is declared for role '${BUILD_ROLE}' — add it to HUGMESH_ROLE_KEYPROFILE in scripts/_roles-lib.sh (refusing to guess: a wrong keys profile provisions the node with the wrong credentials)"
    fi
  fi
}

if [ -n "$IMAGE_SPEC_JSON" ]; then
  [ -f "$IMAGE_SPEC_JSON" ] || die ERROR "IMAGE_SPEC_JSON is set to '${IMAGE_SPEC_JSON}' but no such file exists (the BFF must mount the per-build image-spec ConfigMap there)"
  BUILD_MODE="spec"
  resolve_spec_target
else
  BUILD_MODE="legacy"
  resolve_build_target || die FAILED "unsupported IMAGE_TYPE='${IMAGE_TYPE}' / HARDWARE_CLASS='${HARDWARE_CLASS}' combination — see build-image.sh's header comment for the supported HARDWARE_CLASS convention"
fi

HOSTNAME_OUT="sdimg-$(printf '%s' "$BUILD_ID" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-8)"
log "resolved: platform=${PLATFORM} role=${BUILD_ROLE:-<n/a>} keys_role=${KEYS_ROLE} imageType=${IMAGE_TYPE} hardwareClass=${HARDWARE_CLASS:-<default>} hostname=${HOSTNAME_OUT}"
[ "$BUILD_MODE" = "spec" ] && log "image-spec channel active: builder flags derived from ${IMAGE_SPEC_JSON} via the Studio; worker overlays --cluster-domain/-H/-w/-j/--env (+ the single-artifact --no-*iso/--no-tar policy)"

# TOR_ONION (LEGACY channel only). The Tor v3 onion is a k8s cluster NODE service
# the x86 builder folds via the additive, idempotent --with-tor flag
# (build-x86-host-stage4.sh:755/923). It has NO dedicated flag on rpi5 (there tor
# rides --optional-services, an allow-list that would clobber the node's default
# service set from this minimal env path) and no expression at all on
# frite/jetson/orangepi5/orangepizero2 — so restrict TOR_ONION to x86 node builds
# and fail LOUDLY elsewhere, pointing at the richer IMAGE_SPEC_JSON channel where the
# Studio already emits the correct per-platform tor mechanism. In spec mode the
# spec's own tor_onion_service rode through --print-command, so TOR_ONION is inert.
if [ "$TOR_ONION" = "true" ]; then
  if [ "$BUILD_MODE" = "spec" ]; then
    log "TOR_ONION=true ignored in image-spec mode: the spec is authoritative for image content (its tor_onion_service already rode through --print-command)"
  elif [ "$IMAGE_TYPE" = "client" ]; then
    die FAILED "TOR_ONION=true is invalid for imageType=client — the Tor onion is a cluster NODE service, not a client-image feature"
  elif [ "$PLATFORM" != "x86" ]; then
    die FAILED "TOR_ONION=true is only supported for x86 node builds on the legacy env channel (resolved platform='${PLATFORM}'); for an rpi5/edge Tor-onion node use the IMAGE_SPEC_JSON channel, where the Studio emits the correct per-platform tor mechanism"
  else
    log "TOR_ONION=true: the x86 node build will expose fe-gateway as a Tor v3 .onion (--with-tor)"
  fi
fi

case "$PLATFORM" in
  jetson|orangepi5|orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts|orangepi4-lts)
    warn "${PLATFORM} is EXPERIMENTAL in the generator (hardware validation pending) — proceeding anyway since it was explicitly requested"
    ;;
esac

# ── 5. run the real build (delegates to the SAME generator scripts the local
#    `make` targets use — no image-building logic is duplicated here) ───────
cd "$GENERATOR_DIR"

run_x86_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --role "$BUILD_ROLE" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" --no-live-iso --no-tar
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  case "$BUILD_ROLE" in
    standalone-thin|standalone-thick|standalone-unaffiliated)
      [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
      ;;
  esac
  # Tor v3 onion NODE service (legacy channel). --with-tor is additive + idempotent
  # (folds 'tor' onto any x86 node role; build-x86-host-stage4.sh:923). Validated to
  # x86 + a non-client imageType by the TOR_ONION gate after resolve; the guard here
  # keeps run_x86_build self-consistent. Spec mode carries tor through the spec.
  if [ "$BUILD_MODE" = "legacy" ] && [ "$TOR_ONION" = "true" ] && [ "$IMAGE_TYPE" != "client" ]; then
    set -- "$@" --with-tor
  fi
  dispatch_node_builder ./build-x86-host-stage4.sh "$@"
}

# dispatch_node_builder BUILDER ARG... — dispatch_builder plus the external-IdP
# flags. This file runs under /bin/sh (the k8s Job invokes it as
# `/bin/sh /builder/build-image.sh`), and POSIX sh has no arrays — a global
# IDP_EXTRA_ARGS array here was a hard parse error on dash/ash, masked only by
# hosts that link /bin/sh -> bash (tests/posix-sh-no-arrays.sh now gates this).
# A function can't mutate its CALLER's $@ either, so instead of an argv array
# both node builders route through this helper, which appends the IdP flags
# onto its OWN positional params (`set --`) before dispatching. casdoor/
# spec-mode appends nothing => argv byte-identical. Both node builders take
# --idp/--idp-issuer/--idp-client-id [--idp-jwks].
dispatch_node_builder() {
  if [ "$BUILD_MODE" = "legacy" ] && [ "$IDP" != "casdoor" ]; then
    set -- "$@" --idp "$IDP" --idp-issuer "$IDP_ISSUER" --idp-client-id "$IDP_CLIENT_ID"
    if [ -n "$IDP_JWKS" ]; then
      set -- "$@" --idp-jwks "$IDP_JWKS"
    fi
  fi
  dispatch_builder "$@"
}

run_rpi5_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --role "$BUILD_ROLE" --board "$RPI5_BOARD_OUT" \
         --env "$IMG_BUILD_ENV" --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" --no-iso --no-tar
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$RPI5_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_node_builder ./build-rpi5-stage4.sh "$@"
}

run_frite_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --board "$FRITE_BOARD_OUT" --flavor "$FRITE_FLAVOR_OUT"
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$FRITE_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_builder ./build-frite-stage4.sh "$@"
}

run_jetson_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --role "$BUILD_ROLE" --board "$JETSON_BOARD_OUT" --kernel-flavor mainline
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  dispatch_builder ./build-jetson-stage4.sh "$@"
}

run_orangepi5_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --board "$ORANGEPI5_BOARD_OUT" --flavor "$ORANGEPI5_FLAVOR_OUT"
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$ORANGEPI5_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_builder ./build-orangepi5-stage4.sh "$@"
}

run_orangepizero2_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --flavor "$ORANGEPIZERO2_FLAVOR_OUT"
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$ORANGEPIZERO2_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_builder ./build-orangepi-zero2-stage4.sh "$@"
}

run_orangepizero2w_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --flavor "$ORANGEPIZERO2W_FLAVOR_OUT"
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$ORANGEPIZERO2W_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_builder ./build-orangepi-zero2w-stage4.sh "$@"
}

run_orangepizero3_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --flavor "$ORANGEPIZERO3_FLAVOR_OUT"
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$ORANGEPIZERO3_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_builder ./build-orangepi-zero3-stage4.sh "$@"
}

run_orangepi3lts_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --flavor "$ORANGEPI3LTS_FLAVOR_OUT"
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$ORANGEPI3LTS_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_builder ./build-orangepi3-lts-stage4.sh "$@"
}

run_orangepi4lts_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --flavor "$ORANGEPI4LTS_FLAVOR_OUT"
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$ORANGEPI4LTS_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  dispatch_builder ./build-orangepi4-lts-stage4.sh "$@"
}

# dispatch_builder ARGV... — execute the fully-assembled builder command, OR
# (BUILD_IMAGE_SH_PRINT_ONLY) print it, one token per line, framed by markers,
# and return WITHOUT executing. One-token-per-line survives values with spaces
# (e.g. a brand title) with no shell re-quoting, so the image-spec parity fixture
# can slice the argv between the markers and diff it against the Studio's
# --print-command tokens. BOTH channels route through this: run_spec_build (the
# image-spec parity fixture) and the six legacy run_*_build() functions (so the
# legacy IMAGE_TYPE/HARDWARE_CLASS command is CI-previewable too — e.g. asserting
# TOR_ONION=true adds --with-tor on x86). In a real build (PRINT_ONLY unset) it just
# execs the assembled command, byte-identically to a direct `./build-*.sh "$@"`.
dispatch_builder() {
  if [ "$PRINT_ONLY" = "1" ]; then
    printf '__BUILDER_ARGV_BEGIN__\n'
    printf '%s\n' "$@"
    printf '__BUILDER_ARGV_END__\n'
    return 0
  fi
  "$@"
}

# run_spec_build — the IMAGE_SPEC_JSON channel's runner. It re-parses the Studio's
# native build command (SPEC_CMD) and appends the worker overlay. The six builders
# parse repeated scalar flags LAST-WINS, so the appended values authoritatively
# override anything the same-named flag carried in the spec — that is how
# --cluster-domain stays server-derived (I6) while everything else (role, board,
# flavor, branding, package deltas, users, domains) rides through as spec content.
run_spec_build() {
  # Trusted re-tokenisation of the Studio's shlex-quoted command — see the safety
  # note in resolve_spec_target (values are already validated + single-quoted).
  eval "set -- $SPEC_CMD"
  [ "${1:-}" = "sudo" ] && shift   # worker builds as root; drop any dev/CI sudo
  set -- "$@" -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
             --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT"
  # Single-artifact ingest policy, matching the legacy run_*_build() functions:
  # x86 defaults to a live ISO and rpi5 to an installer ISO on top of the .img, so
  # both are disabled to leave exactly one .img for the contract's single imageRef.
  # frite/orangepi5/orangepizero2 emit the ISO AS the artifact (legacy passes no
  # --no-iso for them either), and jetson emits only a .img — so no overlay there.
  case "$PLATFORM" in
    x86)  set -- "$@" --no-live-iso --no-tar ;;
    rpi5) set -- "$@" --no-iso --no-tar ;;
  esac
  dispatch_builder "$@"
}

# forward_and_wait CMD... — run the (potentially hours-long) real build in the
# background and `wait` for it explicitly, forwarding INT/TERM to it while we
# wait. A trap only runs between commands: if we ran the build as an ordinary
# *foreground* command, a k8s SIGTERM (e.g. activeDeadlineSeconds firing)
# arriving while the shell is blocked in that foreground wait() would sit
# unhandled until the build exits on its own, leaving on_exit's best-effort
# ERROR report no chance to run before the pod's grace period ends and it is
# SIGKILLed outright. Waiting on an explicit background pid is interruptible,
# so the forwarded signal (and then our own trap) actually run promptly.
# progress_tap_run — the stdout tap, entered ONLY when PROGRESS_URL is set (see
# forward_and_wait). Its stdin is the builder's stdout (fd8, via `<&8` on the call
# site); it re-emits every line to THIS process's stdout (the pod/Job log, byte-for-
# byte and in order) and POSTs throttled phase->percent frames to PROGRESS_URL as a
# best-effort, NON-TERMINAL side channel. It execs the baked docker/progress-tap.py
# (which REUSES the Studio ProgressParser + progress-tables.json via PYTHONPATH — no
# regex or table is copied worker-side). The trailing `|| cat` is the last-ditch
# safety net: if python3 cannot even start, `cat` still drains+echoes stdin so the
# build never blocks and the Job log stays complete. PROGRESS_PLATFORM=$PLATFORM
# (already resolved before the build runs, both channels) picks the phase table;
# unknown/spec platforms fall back to the x86 table inside the parser. Only public
# pointers ride the wire: buildId + phase integers/label, never a key or path.
progress_tap_run() {
  PROGRESS_URL="$PROGRESS_URL" \
  BUILD_ID="$BUILD_ID" \
  INTERNAL_TOKEN="$INTERNAL_TOKEN" \
  PROGRESS_PLATFORM="$PLATFORM" \
  PROGRESS_MIN_INTERVAL="$PROGRESS_MIN_INTERVAL" \
  PROGRESS_CURL_TIMEOUT="$PROGRESS_CURL_TIMEOUT" \
  PYTHONPATH="${GENERATOR_DIR}/studio" \
    python3 "${GENERATOR_DIR}/docker/progress-tap.py" || cat
}

forward_and_wait() {
  if [ "$PRINT_ONLY" = "1" ]; then
    # command preview (spec channel only): the runner just prints the argv, so
    # run it synchronously — there is no long-lived child to background, wait on,
    # or forward signals to.
    "$@"
    return $?
  fi

  # ── OPTIONAL progress side channel ────────────────────────────────────────
  # When PROGRESS_URL is set, route the builder's STDOUT through a tap that both
  # re-emits every line to the Job log unchanged AND POSTs throttled progress
  # frames. The builder stays the single tracked $child_pid (so its real rc and
  # SIGTERM forwarding are preserved byte-for-byte); only its stdout is teed via a
  # FIFO the parent pins open at both ends — the pinned writer (fd9, opened
  # READ-WRITE so the open never blocks) makes the builder's `>fifo` open succeed
  # instantly and a tap crash can never SIGPIPE the builder, and (closed only
  # AFTER the builder is reaped) is what finally hands the tap its EOF; the reader
  # (fd8) feeds the tap. stderr never enters the FIFO, so it streams direct and
  # unaltered. NOTE (design correction): the tap and builder must NOT inherit the
  # pinned writer (fd9) or the FIFO would never reach EOF and `wait $tap_pid`
  # would hang — verified empirically — so both are launched with `9>&-` (and the
  # builder additionally drops the reader with `8<&-`). Likewise fd9 is opened
  # `<>` (rw) rather than write-only, since a bare `8<fifo`/`9>fifo` pair blocks
  # on the first open with no peer yet. This whole branch is gated on PROGRESS_URL:
  # unset (today's Job) skips it and runs the current `"$@" &; wait` path verbatim,
  # and a failed mkfifo falls through to that same path too.
  progress_fifo=""
  if [ -n "$PROGRESS_URL" ]; then
    progress_fifo="${SCRATCH_DIR}/progress.fifo"
    rm -f "$progress_fifo" 2>/dev/null || true
    if ! mkfifo "$progress_fifo" 2>/dev/null; then
      progress_fifo=""   # FIFO unavailable -> fall through to the direct path
    fi
  fi

  # Pin the FIFO fds under an `if` so a (near-impossible) open failure can't trip set -e
  # into a spurious terminal ERROR: mkfifo already succeeded and the rw open of fd9 makes
  # the fd8 read-open succeed instantly, so this always passes in practice — but on an
  # exotic filesystem where the open fails, drop both fds and fall through to the direct
  # path rather than aborting the build.
  if [ -n "$progress_fifo" ] && ! exec 9<>"$progress_fifo" 8<"$progress_fifo"; then
    exec 9>&- 8<&- 2>/dev/null || true
    rm -f "$progress_fifo" 2>/dev/null || true
    progress_fifo=""
  fi

  if [ -n "$progress_fifo" ]; then
    progress_tap_run <&8 9>&- &                  # tap reads fd8; must not hold the writer
    tap_pid=$!
    "$@" >"$progress_fifo" 8<&- 9>&- &           # builder stdout->fifo; stderr direct
    child_pid=$!
    trap "kill -TERM ${child_pid} 2>/dev/null" TERM INT
    if wait "$child_pid"; then                   # builder's REAL rc, unchanged
      child_rc=0
    else
      child_rc=$?
    fi
    trap on_exit EXIT INT TERM
    exec 9>&-                                     # drop the pinned writer -> tap EOFs
    wait "$tap_pid" 2>/dev/null || true
    exec 8<&-
    rm -f "$progress_fifo" 2>/dev/null || true
    return "$child_rc"
  fi

  "$@" &
  child_pid=$!
  trap "kill -TERM ${child_pid} 2>/dev/null" TERM INT
  if wait "$child_pid"; then
    child_rc=0
  else
    child_rc=$?
  fi
  trap on_exit EXIT INT TERM
  return "$child_rc"
}

# build_desc is a human-readable summary for logs/messages. Spec mode already set
# it in resolve_spec_target (from the Studio-derived role/board/flavor); only the
# legacy path derives it from the resolve_build_target output vars here.
if [ "$BUILD_MODE" != "spec" ]; then
  case "$PLATFORM" in
    frite)         build_desc="${FRITE_BOARD_OUT}.${FRITE_FLAVOR_OUT}" ;;
    orangepi5)     build_desc="${ORANGEPI5_BOARD_OUT}.${ORANGEPI5_FLAVOR_OUT}" ;;
    orangepizero2) build_desc="${ORANGEPIZERO2_FLAVOR_OUT}" ;;
    orangepizero2w) build_desc="${ORANGEPIZERO2W_FLAVOR_OUT}" ;;
    orangepizero3) build_desc="${ORANGEPIZERO3_FLAVOR_OUT}" ;;
    orangepi3-lts) build_desc="${ORANGEPI3LTS_FLAVOR_OUT}" ;;
    orangepi4-lts) build_desc="${ORANGEPI4LTS_FLAVOR_OUT}" ;;
    *)             build_desc="${BUILD_ROLE}" ;;
  esac
fi

build_ok=true
if [ "$BUILD_MODE" = "spec" ]; then
  # ONE runner for every platform: the Studio already picked the builder script
  # and its content flags; run_spec_build just appends the worker overlay.
  forward_and_wait run_spec_build || build_ok=false
else
  case "$PLATFORM" in
    x86)           forward_and_wait run_x86_build           || build_ok=false ;;
    rpi5)          forward_and_wait run_rpi5_build           || build_ok=false ;;
    frite)         forward_and_wait run_frite_build          || build_ok=false ;;
    jetson)        forward_and_wait run_jetson_build         || build_ok=false ;;
    orangepi5)     forward_and_wait run_orangepi5_build      || build_ok=false ;;
    orangepizero2) forward_and_wait run_orangepizero2_build  || build_ok=false ;;
    orangepizero2w) forward_and_wait run_orangepizero2w_build || build_ok=false ;;
    orangepizero3) forward_and_wait run_orangepizero3_build || build_ok=false ;;
    orangepi3-lts) forward_and_wait run_orangepi3lts_build || build_ok=false ;;
    orangepi4-lts) forward_and_wait run_orangepi4lts_build || build_ok=false ;;
  esac
fi
if [ "$build_ok" = "false" ]; then
  die FAILED "the ${PLATFORM} build (role=${build_desc}) exited non-zero — see this Job pod's logs for the full build output"
fi

# PRINT_ONLY (spec channel dev/CI preview): the assembled builder argv has been
# printed above between the __BUILDER_ARGV_*__ markers; there is no artifact to
# copy and no ingest to send. on_exit skips the terminal report for PRINT_ONLY.
if [ "$PRINT_ONLY" = "1" ]; then
  log "print-only: assembled builder command emitted above; no build was run"
  exit 0
fi

# ── 6. locate the produced artifact + copy it into ARTIFACT_DIR ─────────────
case "$PLATFORM" in
  x86|rpi5|jetson)             artifact_glob='*.img'; artifact_glob_xz='*.img.xz' ;;
  frite|orangepi5|orangepizero2|orangepizero2w|orangepizero3|orangepi3-lts|orangepi4-lts) artifact_glob='*.iso'; artifact_glob_xz='*.iso.xz' ;;
esac
# Fail loud (never nondeterministically pick-and-silently-discard) if the
# build tree holds anything other than EXACTLY one matching artifact. The
# frite flavor=both case that used to make >1 matches possible is already
# rejected up front in resolve_build_target, but this check stays as defense
# in depth against any other source of ambiguity (a stale file left in a
# reused scratch dir, a generator-script change, etc.) — see BUG 3 in the
# header's frite convention note.
matches_file="$(mktemp)"
# Match both the raw artifact and its `xz` compressed form (image.img.xz /
# image.iso.xz): when the spec carries compress=true, the Studio emits --compress
# and the builder renames the product to <name>.img.xz (removing the raw .img), so
# a *.img-only glob would find 0 matches and die ERROR on a fully-successful build,
# discarding the deliverable. `-name '*.img'` never matches a `*.img.xz` basename,
# and the .stage4.tar.xz / .fs.tar.xz siblings match neither pattern, so exactly
# one file still matches either way.
find "${SCRATCH_DIR}/work" -maxdepth 1 -type f \( -name "$artifact_glob" -o -name "$artifact_glob_xz" \) 2>/dev/null >"$matches_file" || true
match_count="$(wc -l <"$matches_file" | tr -d ' ')"
case "$match_count" in
  0)
    rm -f "$matches_file"
    die ERROR "the build reported success but no ${artifact_glob} (or ${artifact_glob_xz}) artifact was found under ${SCRATCH_DIR}/work"
    ;;
  1)
    produced_file="$(cat "$matches_file")"
    rm -f "$matches_file"
    ;;
  *)
    found_list="$(tr '\n' ' ' <"$matches_file")"
    rm -f "$matches_file"
    die ERROR "the build reported success but produced ${match_count} ${artifact_glob}/${artifact_glob_xz} artifacts under ${SCRATCH_DIR}/work (ambiguous — this worker's ingest contract supports exactly one imageRef per build): ${found_list}"
    ;;
esac
if [ ! -f "$produced_file" ]; then
  die ERROR "the build reported success but the located artifact '${produced_file}' is not a regular file"
fi
# Preserve the FULL suffix, including the compound `.img.xz` / `.iso.xz` of a
# compressed build — a single-extension `${produced_file##*.}` split would yield
# just `xz` and mislabel the deliverable `image.xz`, losing the .img/.iso type.
case "$produced_file" in
  *.img.xz) image_basename="image.img.xz" ;;
  *.iso.xz) image_basename="image.iso.xz" ;;
  *.img)    image_basename="image.img" ;;
  *.iso)    image_basename="image.iso" ;;
  *)        image_basename="image.${produced_file##*.}" ;;
esac
cp "$produced_file" "${ARTIFACT_DIR}/${image_basename}" || die ERROR "failed to copy the produced artifact into ${ARTIFACT_DIR}"
IMAGE_REF="build-${BUILD_ID}/${image_basename}"
log "artifact: ${produced_file} -> ${ARTIFACT_DIR}/${image_basename} (imageRef=${IMAGE_REF})"

# ── 7. dial-key handling (per contract: read-only, derive-only, never store) ─
seed_dial_key() {
  if [ "$SSH_KEYS_ALLOWED" != "true" ]; then
    log "SSH_KEYS_ALLOWED=false — no SSH dial access provisioned for this build"
    return 0
  fi

  dial_priv_file=""
  if [ -d "$DIAL_SECRET_DIR" ]; then
    if [ -f "${DIAL_SECRET_DIR}/dial_private_key" ]; then
      dial_priv_file="${DIAL_SECRET_DIR}/dial_private_key"
    else
      # A k8s Secret volume projects each key as a SYMLINK
      # (<key> -> ..data/<key> -> ..<ts>_data/<key>), so a plain `find -type f`
      # tests the link node itself (type l) and matches NOTHING — silently
      # yielding no key and shipping an image with no dial pubkey while still
      # reporting COMPLETED. Follow the links (-L, matching the primary
      # `[ -f dial_private_key ]` branch, which also follows symlinks) and skip
      # the k8s bookkeeping entries (..data and ..<ts>_data).
      dial_priv_file="$(find -L "$DIAL_SECRET_DIR" -maxdepth 1 -type f ! -name '*.pub' ! -name '..*' 2>/dev/null | head -n1)"
    fi
  fi
  if [ -z "$dial_priv_file" ]; then
    log "no dial-key secret mounted at ${DIAL_SECRET_DIR} — proceeding without SSH dial access for this build"
    return 0
  fi

  derived_pub="$(ssh-keygen -y -f "$dial_priv_file" 2>/dev/null)" || {
    warn "dial key mounted at ${dial_priv_file} but its public half could not be derived (unsupported/corrupt key format) — continuing without SSH dial access"
    return 0
  }
  pub_tmp="${SCRATCH_DIR}/dial_key.pub"
  printf '%s\n' "$derived_pub" > "$pub_tmp"
  DIAL_PUB_FP="$(ssh-keygen -lf "$pub_tmp" | awk '{print $2}')"
  DIAL_PUB_KEY="$derived_pub"
  DIAL_USER_OUT="$DIAL_USER_DEFAULT"
  DEVICE_ID="dev-$(printf '%s' "$BUILD_ID" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-12)"
  # VAULT_REF is intentionally left unset (-> null in the ingest body) here.
  # This script has no real, authoritative source for where the dial key
  # actually lives in Vault: DIAL_SECRET_DIR is a plain k8s secret VOLUME
  # MOUNT, not a Vault client, and this worker never talks to Vault directly
  # or receives a Vault path from the Job env. An earlier string-formatting
  # guess here (secret/${DOMAIN}/device/${DEVICE_ID}/ssh/dial_private_key)
  # was just that — a plausible-looking fabrication with no real backing —
  # and reporting it as vaultRef could mislead an operator or the BFF into
  # treating it as authoritative. An honest "we don't know" (null) is
  # strictly better. If a real, already-known Vault path or secret-name ever
  # becomes available to this script (e.g. passed through as a Job env var
  # by admin-bff-api, not derived by guesswork here), wire it in here instead.
  rm -f "$pub_tmp"
  log "dial key present: device_id=${DEVICE_ID} dial_user=${DIAL_USER_OUT} dial_pub_fp=${DIAL_PUB_FP} (private key read only, never copied out of ${DIAL_SECRET_DIR})"
}
seed_dial_key

# ── 8. write the NON-SECRET keys bundle (public key + fingerprint pointers
#    only — see header comment for why no private key material, including the
#    device host identity, is ever produced by this script) ─────────────────
build_keys_bundle() {
  stage="${SCRATCH_DIR}/keys-bundle"
  if [ -n "$DIAL_PUB_KEY" ]; then
    printf '%s\n' "$DIAL_PUB_KEY" > "${stage}/dial_${DIAL_USER_OUT}.pub"
  fi
  BUILD_ID="$BUILD_ID" DOMAIN="$DOMAIN" IMAGE_TYPE="$IMAGE_TYPE" HARDWARE_CLASS="$HARDWARE_CLASS" \
  TARGET_USER="$TARGET_USER" DEVICE_ID="$DEVICE_ID" DIAL_USER_OUT="$DIAL_USER_OUT" \
  DIAL_PUB_FP="$DIAL_PUB_FP" VAULT_REF="$VAULT_REF" HOSTNAME_OUT="$HOSTNAME_OUT" \
  PLATFORM="$PLATFORM" BUILD_ROLE="$BUILD_ROLE" python3 - "${stage}/metadata.json" <<'PY'
import json, os, sys

def g(key):
    val = os.environ.get(key, "")
    return val if val != "" else None

meta = {
    "buildId": g("BUILD_ID"),
    "domain": g("DOMAIN"),
    "imageType": g("IMAGE_TYPE"),
    "hardwareClass": g("HARDWARE_CLASS"),
    "platform": g("PLATFORM"),
    "buildRole": g("BUILD_ROLE"),
    "targetUser": g("TARGET_USER"),
    "deviceId": g("DEVICE_ID"),
    "dialUser": g("DIAL_USER_OUT"),
    "dialPubFp": g("DIAL_PUB_FP"),
    "vaultRef": g("VAULT_REF"),
    "hostname": g("HOSTNAME_OUT"),
    "note": "Non-secret metadata only (public keys + fingerprints). No private key material is ever included in this bundle.",
}
with open(sys.argv[1], "w") as fh:
    json.dump(meta, fh, indent=2)
    fh.write("\n")
PY
  tar -C "$stage" -cf "${ARTIFACT_DIR}/keys.tar" .
  KEYS_REF="build-${BUILD_ID}/keys.tar"
}
build_keys_bundle
log "keys bundle: ${ARTIFACT_DIR}/keys.tar (keysRef=${KEYS_REF})"

# ── 9. terminal report ───────────────────────────────────────────────────────
MESSAGE_OUT="image build completed: platform=${PLATFORM} role=${build_desc} imageType=${IMAGE_TYPE} hardwareClass=${HARDWARE_CLASS:-<default>}"
if [ "$BUILD_MODE" = "spec" ]; then
  # Report the richer channel (and, when the BFF supplies it, the generator
  # revision baked into this image) so an operator can tell a spec-derived build
  # from a legacy env-scalar one. GENERATOR_REV is optional/best-effort — the
  # baked tree carries no VCS metadata (.dockerignore strips it), so this stays
  # empty unless the image build passed it in.
  MESSAGE_OUT="${MESSAGE_OUT} (image-spec channel${GENERATOR_REV:+; generator ${GENERATOR_REV}})"
fi
if send_ingest COMPLETED; then
  log "done: imageRef=${IMAGE_REF} keysRef=${KEYS_REF}"
  exit 0
else
  fail_msg "build succeeded (imageRef=${IMAGE_REF}) but the terminal COMPLETED ingest POST to ${INGEST_URL} did not succeed after retries — the BFF's image_build row will remain stuck; an operator must investigate/replay the ingest manually"
  exit 1
fi
