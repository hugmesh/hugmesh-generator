#!/bin/sh
# build-image.sh — the admin-bff-api image-gen builder worker entrypoint.
#
# Baked into the image at /builder/build-image.sh (see docker/Dockerfile.image-gen)
# and run by admin-bff-api's k8s Job as: /bin/sh /builder/build-image.sh
# (jobs/image-gen-job.yaml in snapdragon-admin-bff-api — read-only source of
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
#   INGEST_URL        the fully-substituted terminal-report POST URL.
#   INTERNAL_TOKEN    OPTIONAL (secretKeyRef optional:true) — may be absent.
#   ARTIFACT_DIR      /artifacts/build-${BUILD_ID} — where products are written.
#   IMAGE_SPEC_JSON   OPTIONAL, additive. Path to ONE materialized flat
#                     ImageConfig JSON (the Studio worklist's per-image entry),
#                     mounted from the per-build ConfigMap image-spec-${BUILD_ID}
#                     at /etc/snapdragon/image-spec.json. When set (and the file
#                     exists) this worker derives the ENTIRE builder invocation
#                     from that spec via the Studio's own `--print-command`
#                     translator, instead of from the 6 IMAGE_TYPE/HARDWARE_CLASS
#                     env scalars. Absent/empty -> the legacy env path runs
#                     byte-identically. See the image-spec.json channel section
#                     below.
#
# Volumes:
#   /artifacts             the snapdragon-image-artifacts PVC, read-write.
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
# The Studio (studio/snapdragon_studio) already owns the ONE authoritative
# ImageConfig->builder-flags translation, and this worker image bakes the whole
# generator tree — studio/ and python3 included (docker/Dockerfile.image-gen
# `COPY . .`; python3 is already a hard requirement below). So when a richer,
# fully-materialized spec is available, we reuse that single translator rather
# than re-deriving flags a second, drifting way here.
#
#   * The admin-bff-api ImageBuildOrchestrator writes ONE materialized flat
#     ImageConfig JSON to a per-build ConfigMap (image-spec-${BUILD_ID}), mounts
#     it read-only at /etc/snapdragon/image-spec.json, and sets the Job env
#     IMAGE_SPEC_JSON to that path. Rich values ride the FILE, never yamlSafe env
#     scalars (the [A-Za-z0-9._-] env charset cannot carry a theme name or a
#     domain list).
#   * When IMAGE_SPEC_JSON names an existing file, this worker derives the exact
#     builder invocation with the Studio's own headless translator:
#         python3 -m snapdragon_studio --print-command \
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
#                        orangepi5, orangepizero2}
#
#   x86 node roles      (primary | mesh-extension): pki | be | fe | be-gpu
#                        (-> --role be+gpu) | omnibus | edge_ai
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
#                        edge_ai (default) | gpu-host | full | desktop; board =
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
#
#   A bare token with no platform prefix (e.g. HARDWARE_CLASS="pki") is
#   accepted as a legacy/convenience alias for the matching x86 role.
#   Empty HARDWARE_CLASS defaults to: primary/mesh-extension -> x86.be+gpu
#   (the Makefile's own "host" default role); client -> x86.desktop.
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
GENERATOR_DIR="${GENERATOR_DIR:-/opt/snapdragon-generator}"
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

# ── job env (defaulted to empty so `set -u` never aborts on a merely-absent
#    var; presence/shape is validated explicitly right below) ───────────────
BUILD_ID="${BUILD_ID:-}"
TARGET_USER="${TARGET_USER:-}"
DOMAIN="${DOMAIN:-}"
IMAGE_TYPE="${IMAGE_TYPE:-}"
HARDWARE_CLASS="${HARDWARE_CLASS:-}"
SSH_KEYS_ALLOWED="${SSH_KEYS_ALLOWED:-false}"
INGEST_URL="${INGEST_URL:-}"
INTERNAL_TOKEN="${INTERNAL_TOKEN:-}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"
# OPTIONAL, additive spec channel (see the image-spec.json channel header note).
# Empty -> the legacy IMAGE_TYPE/HARDWARE_CLASS path runs byte-identically.
IMAGE_SPEC_JSON="${IMAGE_SPEC_JSON:-}"
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
         build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh; do
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

  if [ -z "$HARDWARE_CLASS" ]; then
    case "$IMAGE_TYPE" in
      primary|mesh-extension) PLATFORM="x86"; BUILD_ROLE="be+gpu" ;;
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
            case "$p2" in
              pki|be|fe|omnibus|edge_ai) BUILD_ROLE="$p2" ;;
              be-gpu|"")                 BUILD_ROLE="be+gpu" ;;
              *) return 1 ;;
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
          pki|backend|frontend|desktop) BUILD_ROLE="$p2" ;;
          standalone-desktop)
            # Composes onto the same --role desktop the plain "desktop" token
            # resolves to (build-rpi5-stage4.sh's own --standalone hard-errors
            # on every OTHER role) — this token just also flips RPI5_STANDALONE
            # so run_rpi5_build appends --standalone/--local-user below.
            BUILD_ROLE="desktop"
            RPI5_STANDALONE=true
            ;;
          "")                           BUILD_ROLE="backend" ;;
          *) return 1 ;;
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
        BUILD_ROLE="${p2:-edge_ai}"
        JETSON_BOARD_OUT="${p3:-orin-nano}"
        case "$BUILD_ROLE" in edge_ai|gpu-host|full|desktop) ;; *) return 1 ;; esac
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
      *)
        # Bare legacy token, no platform prefix -> x86 alias.
        case "$IMAGE_TYPE" in
          primary|mesh-extension)
            case "$p1" in
              pki|be|fe|omnibus|edge_ai) BUILD_ROLE="$p1" ;;
              be-gpu)                    BUILD_ROLE="be+gpu" ;;
              *) return 1 ;;
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
    case "$BUILD_ROLE" in
      pki)          KEYS_ROLE="pki" ;;
      be|backend)   KEYS_ROLE="backend" ;;
      fe|frontend)  KEYS_ROLE="frontend" ;;
      *)            KEYS_ROLE="host" ;;
    esac
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
        python3 -m snapdragon_studio --print-command \
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
  case "$PLATFORM" in
    frite|orangepi5) build_desc="${_sb:-?}.${_sf:-?}" ;;
    orangepizero2)   build_desc="${_sf:-?}" ;;
    *)               build_desc="${BUILD_ROLE:-spec}" ;;
  esac

  # KEYS_ROLE mirrors resolve_build_target's mapping (IMAGE_TYPE still comes from
  # the Job env and is authoritative for the keys profile).
  if [ "$IMAGE_TYPE" = "mesh-extension" ]; then
    KEYS_ROLE="mesh-extension"
  else
    case "$BUILD_ROLE" in
      pki)          KEYS_ROLE="pki" ;;
      be|backend)   KEYS_ROLE="backend" ;;
      fe|frontend)  KEYS_ROLE="frontend" ;;
      *)            KEYS_ROLE="host" ;;
    esac
  fi
}

if [ -n "$IMAGE_SPEC_JSON" ]; then
  [ -f "$IMAGE_SPEC_JSON" ] || die ERROR "IMAGE_SPEC_JSON is set to '${IMAGE_SPEC_JSON}' but no such file exists (the BFF must mount the per-build image-spec ConfigMap there)"
  BUILD_MODE="spec"
  resolve_spec_target
else
  BUILD_MODE="legacy"
  # PRINT_ONLY is a spec-channel preview only; the legacy path has nothing extra
  # to preview (resolve_build_target + run_*_build already assemble the command
  # byte-identically, and printing it would still run no build here).
  if [ "$PRINT_ONLY" = "1" ]; then
    die ERROR "BUILD_IMAGE_SH_PRINT_ONLY requires the IMAGE_SPEC_JSON channel (there is no legacy command to preview)"
  fi
  resolve_build_target || die FAILED "unsupported IMAGE_TYPE='${IMAGE_TYPE}' / HARDWARE_CLASS='${HARDWARE_CLASS}' combination — see build-image.sh's header comment for the supported HARDWARE_CLASS convention"
fi

HOSTNAME_OUT="sdimg-$(printf '%s' "$BUILD_ID" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-8)"
log "resolved: platform=${PLATFORM} role=${BUILD_ROLE:-<n/a>} keys_role=${KEYS_ROLE} imageType=${IMAGE_TYPE} hardwareClass=${HARDWARE_CLASS:-<default>} hostname=${HOSTNAME_OUT}"
[ "$BUILD_MODE" = "spec" ] && log "image-spec channel active: builder flags derived from ${IMAGE_SPEC_JSON} via the Studio; worker overlays --cluster-domain/-H/-w/-j/--env (+ the single-artifact --no-*iso/--no-tar policy)"
case "$PLATFORM" in
  jetson|orangepi5|orangepizero2)
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
  ./build-x86-host-stage4.sh "$@"
}

run_rpi5_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --role "$BUILD_ROLE" --board "$RPI5_BOARD_OUT" \
         --env "$IMG_BUILD_ENV" --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" --no-iso --no-tar
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  if [ "$RPI5_STANDALONE" = "true" ]; then
    set -- "$@" --standalone
    [ -n "$TARGET_NAME" ] && set -- "$@" --local-user "$TARGET_NAME"
  fi
  ./build-rpi5-stage4.sh "$@"
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
  ./build-frite-stage4.sh "$@"
}

run_jetson_build() {
  set -- -w "${SCRATCH_DIR}/work" -j "$JOBS" --env "$IMG_BUILD_ENV" \
         --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" \
         --role "$BUILD_ROLE" --board "$JETSON_BOARD_OUT" --kernel-flavor mainline
  [ -n "$BRAND_FLAGS_CFG" ] && set -- "$@" --config "$BRAND_FLAGS_CFG"
  ./build-jetson-stage4.sh "$@"
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
  ./build-orangepi5-stage4.sh "$@"
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
  ./build-orangepi-zero2-stage4.sh "$@"
}

# dispatch_builder ARGV... — execute the fully-assembled builder command, OR
# (BUILD_IMAGE_SH_PRINT_ONLY) print it, one token per line, framed by markers,
# and return WITHOUT executing. One-token-per-line survives values with spaces
# (e.g. a brand title) with no shell re-quoting, so the image-spec parity fixture
# can slice the argv between the markers and diff it against the Studio's
# --print-command tokens. Only the spec path (run_spec_build) routes through this;
# the legacy run_*_build() functions exec their script directly and are unchanged.
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
forward_and_wait() {
  if [ "$PRINT_ONLY" = "1" ]; then
    # command preview (spec channel only): the runner just prints the argv, so
    # run it synchronously — there is no long-lived child to background, wait on,
    # or forward signals to.
    "$@"
    return $?
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
  x86|rpi5|jetson)             artifact_glob='*.img' ;;
  frite|orangepi5|orangepizero2) artifact_glob='*.iso' ;;
esac
# Fail loud (never nondeterministically pick-and-silently-discard) if the
# build tree holds anything other than EXACTLY one matching artifact. The
# frite flavor=both case that used to make >1 matches possible is already
# rejected up front in resolve_build_target, but this check stays as defense
# in depth against any other source of ambiguity (a stale file left in a
# reused scratch dir, a generator-script change, etc.) — see BUG 3 in the
# header's frite convention note.
matches_file="$(mktemp)"
find "${SCRATCH_DIR}/work" -maxdepth 1 -type f -name "$artifact_glob" 2>/dev/null >"$matches_file" || true
match_count="$(wc -l <"$matches_file" | tr -d ' ')"
case "$match_count" in
  0)
    rm -f "$matches_file"
    die ERROR "the build reported success but no ${artifact_glob} artifact was found under ${SCRATCH_DIR}/work"
    ;;
  1)
    produced_file="$(cat "$matches_file")"
    rm -f "$matches_file"
    ;;
  *)
    found_list="$(tr '\n' ' ' <"$matches_file")"
    rm -f "$matches_file"
    die ERROR "the build reported success but produced ${match_count} ${artifact_glob} artifacts under ${SCRATCH_DIR}/work (ambiguous — this worker's ingest contract supports exactly one imageRef per build): ${found_list}"
    ;;
esac
if [ ! -f "$produced_file" ]; then
  die ERROR "the build reported success but the located artifact '${produced_file}' is not a regular file"
fi
image_ext="${produced_file##*.}"
image_basename="image.${image_ext}"
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
      dial_priv_file="$(find "$DIAL_SECRET_DIR" -maxdepth 1 -type f ! -name '*.pub' 2>/dev/null | head -n1)"
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
