#!/usr/bin/env bash
# ============================================================================
# publish-images.sh — LOCAL image-publishing export verb (Phase 1 of the
# image-publishing outline recorded on hugmesh-host-shell#19).
# ============================================================================
#
# Exports the SHAREABLE artifacts of one Studio/CLI build session
# (out/sessions/<id>/) into a flat, verifiable publish tree:
#
#   <dest>/
#     <brand>-<platform>-<arch>-<role>-<env>-<stamp>.{img.xz,iso,fs.tar.xz,stage4.tar.xz}
#     hugmesh-mesh-manifest.json      # the session's own mesh manifest, verbatim
#     publish-manifest.json           # versioned manifest: per-file id/role/platform/
#                                     #   flavor/bytes/sha256/builtAt + provenance stamp
#     publish-manifest.json.sig       # detached Ed25519 (only when PROVENANCE_SIGNING_KEY set)
#     SHA256SUMS                      # `sha256sum -c`-able, relative names
#
# and echoes one parseable line per exported file (cloud-package.manifest's
# line grammar, FORMAT token -> IMAGE id):
#
#   IMAGE <role>.<platform> FILE <path> BYTES <n> SHA256 <hex>
#
# ── THE HARD LINE: this tool is STRUCTURALLY INCAPABLE of shipping secrets ──
#
# A session tree intermixes publishable images with NEVER-publishable material:
# keys-<role>.<platform>/ (device provisioning keys), secureboot/ (SB signing
# material), wl-<role>.<platform>/ (build worklists with full sysroot trees),
# plus build logs. A naive "share this folder" leaks all of it. This script
# never recurses into the session tree AT ALL: candidates are top-level
# REGULAR files only (find -maxdepth 1), matched against a closed allow-list
# of builder artifact suffixes — the deny-listed trees are directories, so
# they are unreachable by construction, not by filtering. On top of that,
# every candidate must pass ALL of (fail-closed, whole export REFUSED — never
# "skip and continue" — on the first hit, and the staging dir is deleted):
#
#   1. regular file, never a symlink (a link wearing an artifact name could
#      smuggle key bytes from keys-*/ into the copy),
#   2. basename NOT matching the deny-list (keys-*, secureboot*, wl-*,
#      *sysroot*, *.log, *.lock, *.pem, *.key, id_*, *secret*, *token*,
#      *password*, *credential*, shadow* — deny beats allow BY DESIGN),
#   3. the builders' <brand>-<platform>-<arch>-<role>-<env>-<stamp>.<kind>
#      naming shape (an artifact-suffixed file of unknown provenance is
#      poison, mirroring cloud-package.sh's x86-provenance refusal),
#   4. content magic: xz artifacts must open with the xz magic, .iso with
#      ISO9660's CD001 — a PEM/text file wearing an image name is refused,
#   5. non-empty (a hollow artifact is a lie, not a publish).
#
# The staged output is then swept (no subdirectories, no symlinks, no file
# outside the expected set, deny-list re-checked) and every staged TEXT file
# (both manifests + SHA256SUMS) goes through scripts/secret-scan.sh
# FAIL-CLOSED before the tree is moved into place. The binary artifacts are
# excluded from the entropy scanner ON PURPOSE: compressed images are 100%
# high-entropy (every byte would "find"), their integrity is SHA256SUMS' job
# and their identity is the shape+magic gates' job. There is NO override flag
# for any of this — later "publish to the mesh" phases (hugmesh-host-shell#19)
# build on this same tree, so what leaves here must already be clean.
#
# Usage:
#   scripts/publish-images.sh <session-id|session-dir> --dest <dir>
#       [--images id,...] [--hardlink] [--produced-at ISO8601]
#
#   --dest DIR        Where the publish tree lands. REFUSED if it already
#                     exists (no clobber) or sits inside the session dir.
#   --images id,...   Only these image ids (<role>.<platform>, e.g. pki.x86,
#                     be.rpi5 — the mesh manifest's ids; the rpi5 builder's
#                     long role spellings backend/frontend are normalized to
#                     be/fe). An id matching nothing is a FATAL typo, never a
#                     silent empty publish.
#   --hardlink        Hardlink artifacts instead of copying (same-filesystem
#                     fast path; falls back to copy per file when ln fails).
#   --produced-at TS  Explicit deterministic producedAt stamp. Default:
#                     SOURCE_DATE_EPOCH, else the newest builtAt among the
#                     exported files — NEVER wall-clock `date` (idempotency:
#                     a re-run over the same session yields a byte-identical
#                     manifest, hence an identical Ed25519 signature).
#
# Env:
#   HUGMESH_SESSIONS_ROOT   session-id lookup root (default <repo>/out/sessions).
#   PROVENANCE_SIGNING_KEY  out-of-band Ed25519 private key; when set the
#                     publish manifest is signed (detached .sig, same family
#                     as provenance.sh); when unset we WARN and ship UNSIGNED
#                     (production key custody is out-of-band).
#   SOURCE_DATE_EPOCH deterministic producedAt fallback (see --produced-at).
#
# Exit codes: 0 = published, 1 = refused/error (staging cleaned up), 2 = usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -t 2 ]; then C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_RST=$'\033[0m'; else C_RED=""; C_YEL=""; C_RST=""; fi
info() { printf '[publish-images] %s\n' "$*"; }
warn() { printf '%s[publish-images] WARNING:%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s[publish-images] REFUSED:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: $0 <session-id|session-dir> --dest <dir> [--images id,...] [--hardlink] [--produced-at ISO8601]

  Exports one build session's image artifacts (*.img.xz, *.iso, *.fs.tar.xz,
  *.stage4.tar.xz) + hugmesh-mesh-manifest.json into <dir>, with SHA256SUMS and
  a versioned publish-manifest.json (optionally Ed25519-signed). Key material
  (keys-*/, secureboot/, wl-*/ sysroots, logs) is structurally unexportable;
  any secret-looking file intersecting the ship set REFUSES the whole export.

Env:
  HUGMESH_SESSIONS_ROOT    session-id lookup root (default <repo>/out/sessions)
  PROVENANCE_SIGNING_KEY   Ed25519 private key -> publish-manifest.json.sig
  SOURCE_DATE_EPOCH        deterministic producedAt fallback
EOF
exit "${1:-0}"
}

# ── args ─────────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || usage 2
case "$1" in -h|--help) usage 0 ;; esac
SESSION_ARG="$1"; shift
DEST="" IMAGES_FILTER="" HARDLINK=0 PRODUCED_AT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)        DEST="${2:?--dest needs a dir}"; shift 2 ;;
        --images)      IMAGES_FILTER="${2:?--images needs id,...}"; shift 2 ;;
        --hardlink)    HARDLINK=1; shift ;;
        --produced-at) PRODUCED_AT="${2:?--produced-at needs a timestamp}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *)             echo "Unknown option: $1" >&2; usage 2 ;;
    esac
done
[ -n "${DEST}" ] || { echo "Missing --dest" >&2; usage 2; }

SECRET_SCAN="${SCRIPT_DIR}/secret-scan.sh"
# The scan gate is load-bearing: a missing scanner is a refusal, never a skip.
[ -f "${SECRET_SCAN}" ] || die "scripts/secret-scan.sh not found next to this script — the fail-closed scan gate cannot run"

# ── resolve the session dir ──────────────────────────────────────────────────
SESSIONS_ROOT="${HUGMESH_SESSIONS_ROOT:-${REPO_ROOT}/out/sessions}"
if [ -d "${SESSION_ARG}" ]; then
    SESSION_DIR="$(cd "${SESSION_ARG}" && pwd)"
elif [ -d "${SESSIONS_ROOT}/${SESSION_ARG}" ]; then
    SESSION_DIR="$(cd "${SESSIONS_ROOT}/${SESSION_ARG}" && pwd)"
else
    die "no such session: '${SESSION_ARG}' (not a directory, and ${SESSIONS_ROOT}/${SESSION_ARG} does not exist)"
fi
SESSION_ID="$(basename "${SESSION_DIR}")"

# ── destination guards ───────────────────────────────────────────────────────
[ -e "${DEST}" ] && die "destination already exists: ${DEST} — refusing to overwrite (remove it or pick another --dest)"
DEST_ABS="$(realpath -m "${DEST}")"
case "${DEST_ABS}/" in
    "${SESSION_DIR}/"*) die "--dest ${DEST} is inside the session dir — the publish tree must not nest into its own source" ;;
esac
DEST_PARENT="$(dirname "${DEST_ABS}")"
mkdir -p "${DEST_PARENT}"

# ── policy tables ────────────────────────────────────────────────────────────
# Allow-list: the builders' artifact suffixes, NOTHING else. (*.iso covers the
# x86 builder's .installer.iso/.live.iso pair.) Raw .img is deliberately absent:
# sessions store compressed artifacts, and every allowed kind is magic-checkable.
ALLOW_SUFFIXES=("*.img.xz" "*.iso" "*.fs.tar.xz" "*.stage4.tar.xz")

# Deny-list (lowercase basename globs). Matching one of these REFUSES the whole
# export when the name also wears an artifact suffix (poison), and is re-swept
# over the staged output as a final invariant. NO flag disables this.
DENY_GLOBS=("keys-*" "secureboot*" "wl-*" "*sysroot*" "*.log" "*.lock"
            "*.pem" "*.key" "id_rsa*" "id_ed25519*" "id_ecdsa*" "id_dsa*"
            "*secret*" "*token*" "*password*" "*credential*" "*passwd*" "shadow*")

MESH_MANIFEST="hugmesh-mesh-manifest.json"
PUB_MANIFEST="publish-manifest.json"
PUB_SIG="publish-manifest.json.sig"
SUMS="SHA256SUMS"

_is_denied() {  # _is_denied <basename> — 0 when the (lowercased) name is deny-listed
    local lc g
    lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for g in "${DENY_GLOBS[@]}"; do
        # shellcheck disable=SC2254
        case "${lc}" in ${g}) return 0 ;; esac
    done
    return 1
}

_matches_allow() {  # _matches_allow <basename> — 0 when the name wears an artifact suffix
    local g
    for g in "${ALLOW_SUFFIXES[@]}"; do
        # shellcheck disable=SC2254
        case "$1" in ${g}) return 0 ;; esac
    done
    return 1
}

# ── candidate enumeration: top-level entries ONLY, no recursion ever ─────────
# Deny-listed material lives in DIRECTORIES (keys-*/, secureboot/, wl-*/); a
# maxdepth-1 file walk cannot reach it. Symlinks are enumerated so a link
# wearing an artifact name is REFUSED rather than silently skipped or followed.
CANDIDATES=()
EXCLUDED=0
while IFS= read -r -d '' entry; do
    base="$(basename "${entry}")"
    if ! _matches_allow "${base}"; then
        EXCLUDED=$((EXCLUDED+1))    # logs, locks, manifests, stray notes: not ours to ship
        continue
    fi
    # From here the entry IS in the ship set — every defect is a refusal.
    [ -L "${entry}" ] && die "poisoned session tree: ${base} is a SYMLINK wearing an artifact name (-> $(readlink "${entry}" || true)) — a link can smuggle key material into the export"
    [ -f "${entry}" ] || die "poisoned session tree: ${base} wears an artifact name but is not a regular file"
    if _is_denied "${base}"; then
        die "poisoned session tree: ${base} matches both the artifact allow-list and the secret deny-list — refusing the whole export"
    fi
    CANDIDATES+=("${entry}")
done < <(find "${SESSION_DIR}" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 | sort -z)

[ "${#CANDIDATES[@]}" -gt 0 ] || die "session ${SESSION_ID} has no publishable image artifacts (*.img.xz, *.iso, *.fs.tar.xz, *.stage4.tar.xz at the session root)"

# ── mesh-manifest brand (best-effort, names the platform token) ──────────────
BRAND=""
MESH_SRC="${SESSION_DIR}/${MESH_MANIFEST}"
if [ -f "${MESH_SRC}" ] && [ ! -L "${MESH_SRC}" ]; then
    if command -v jq >/dev/null 2>&1; then
        BRAND="$(jq -r '.brand // empty' "${MESH_SRC}" 2>/dev/null || true)"
    else
        BRAND="$(sed -n 's/.*"brand"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${MESH_SRC}" | head -1)"
    fi
fi

# ── per-candidate gates: shape, magic, non-empty; derive the metadata ────────
# Builder naming: <brand>-<platform>-<arch>-<role>-<env>-<stamp>.<kind>, where
# platform and role may themselves contain hyphens (jetson-orin-nano,
# standalone-unaffiliated) — the arch token and the trailing stamp anchor the
# parse. The rpi5 builder stamps the LONG role spellings; normalize to the mesh
# manifest's short ids so --images speaks one language.
SHAPE='^([a-z0-9][a-z0-9-]*)-(amd64|arm64)-([a-z0-9_-]+)-([a-z0-9_]+)-([0-9]{8}T[0-9]{6}Z)\.(img\.xz|installer\.iso|live\.iso|iso|fs\.tar\.xz|stage4\.tar\.xz)$'
XZ_MAGIC="fd377a585a00"

_role_alias() { case "$1" in backend) echo be ;; frontend) echo fe ;; *) echo "$1" ;; esac; }

F_PATH=(); F_BASE=(); F_ID=(); F_ROLE=(); F_PLATFORM=(); F_KIND=(); F_BUILT=()
for f in "${CANDIDATES[@]}"; do
    base="$(basename "${f}")"
    [ -s "${f}" ] || die "poisoned session tree: ${base} is EMPTY (0 bytes) — refusing to publish a hollow artifact"
    [[ "${base}" =~ ${SHAPE} ]] || die "poisoned session tree: ${base} wears an artifact suffix but not the builders' <brand>-<platform>-<arch>-<role>-<env>-<stamp> naming — cannot confirm provenance, refusing the whole export"
    brandplat="${BASH_REMATCH[1]}"; role="${BASH_REMATCH[3]}"
    stamp="${BASH_REMATCH[5]}";     kind="${BASH_REMATCH[6]}"
    # Content magic: the name says image, the bytes must agree.
    case "${kind}" in
        *xz)
            magic="$(head -c 6 "${f}" | od -An -tx1 | tr -d ' \n')"
            [ "${magic}" = "${XZ_MAGIC}" ] || die "poisoned session tree: ${base} claims xz but carries no xz magic (got 0x${magic:-nothing}) — refusing the whole export"
            ;;
        *iso)
            [ "$(stat -c %s "${f}")" -ge 32774 ] || die "poisoned session tree: ${base} is too small to be an ISO9660 image — refusing the whole export"
            cd001="$(dd if="${f}" bs=1 skip=32769 count=5 2>/dev/null)"
            [ "${cd001}" = "CD001" ] || die "poisoned session tree: ${base} claims ISO but carries no ISO9660 signature — refusing the whole export"
            ;;
    esac
    platform="${brandplat}"
    if [ -n "${BRAND}" ] && [ "${brandplat}" != "${BRAND}" ]; then
        platform="${brandplat#"${BRAND}"-}"
    else
        platform="${brandplat#*-}"
    fi
    F_PATH+=("${f}"); F_BASE+=("${base}")
    F_ROLE+=("$(_role_alias "${role}")"); F_PLATFORM+=("${platform}")
    F_ID+=("$(_role_alias "${role}").${platform}"); F_KIND+=("${kind}")
    F_BUILT+=("${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z")
done

# ── --images filter (typo = fatal, never a silent empty publish) ─────────────
if [ -n "${IMAGES_FILTER}" ]; then
    IFS=',' read -r -a WANT <<< "${IMAGES_FILTER}"
    for w in "${WANT[@]}"; do
        found=0
        for id in "${F_ID[@]}"; do [ "${id}" = "${w}" ] && found=1; done
        [ "${found}" -eq 1 ] || die "--images ${w}: no artifact of session ${SESSION_ID} has that id (available: $(printf '%s\n' "${F_ID[@]}" | sort -u | paste -sd' ' -))"
    done
    K_PATH=(); K_BASE=(); K_ID=(); K_ROLE=(); K_PLATFORM=(); K_KIND=(); K_BUILT=()
    for i in "${!F_PATH[@]}"; do
        keep=0
        for w in "${WANT[@]}"; do [ "${F_ID[$i]}" = "${w}" ] && keep=1; done
        if [ "${keep}" -eq 1 ]; then
            K_PATH+=("${F_PATH[$i]}"); K_BASE+=("${F_BASE[$i]}"); K_ID+=("${F_ID[$i]}")
            K_ROLE+=("${F_ROLE[$i]}"); K_PLATFORM+=("${F_PLATFORM[$i]}")
            K_KIND+=("${F_KIND[$i]}"); K_BUILT+=("${F_BUILT[$i]}")
        fi
    done
    F_PATH=("${K_PATH[@]}"); F_BASE=("${K_BASE[@]}"); F_ID=("${K_ID[@]}")
    F_ROLE=("${K_ROLE[@]}"); F_PLATFORM=("${K_PLATFORM[@]}")
    F_KIND=("${K_KIND[@]}"); F_BUILT=("${K_BUILT[@]}")
fi

# ── stage (sibling of --dest, atomically moved into place at the end) ────────
STAGE="$(mktemp -d "${DEST_ABS}.staging.XXXXXX")"
SCANVIEW=""
FINALIZED=0
trap '[ "${FINALIZED}" -eq 1 ] || rm -rf "${STAGE}"; [ -z "${SCANVIEW}" ] || rm -rf "${SCANVIEW}"' EXIT

info "session ${SESSION_ID}: exporting ${#F_PATH[@]} artifact(s), ${EXCLUDED} top-level non-artifact entr(y/ies) excluded"
info "policy-excluded and structurally unreachable: keys-*/, secureboot/, wl-*/ (sysroots), *.log, *.lock"

for i in "${!F_PATH[@]}"; do
    src="${F_PATH[$i]}"; dst="${STAGE}/${F_BASE[$i]}"
    if [ "${HARDLINK}" -eq 1 ] && ln "${src}" "${dst}" 2>/dev/null; then
        :
    else
        cp --reflink=auto --sparse=auto "${src}" "${dst}"
    fi
done

# Hash every staged artifact EXACTLY ONCE (these are 1-20GB files); the
# manifest, SHA256SUMS and the parseable output lines all reuse these values.
F_BYTES=(); F_SHA=()
for i in "${!F_PATH[@]}"; do
    sf="${STAGE}/${F_BASE[$i]}"
    F_BYTES+=("$(stat -c %s "${sf}")")
    F_SHA+=("$(sha256sum "${sf}" | awk '{print $1}')")
done

# The mesh manifest is TEXT that ships — scan it fail-closed BEFORE it stages.
if [ -f "${MESH_SRC}" ] && [ ! -L "${MESH_SRC}" ]; then
    "${SECRET_SCAN}" "${MESH_SRC}" >/dev/null \
        || die "poisoned session tree: ${MESH_MANIFEST} failed the secret scan — refusing the whole export"
    cp "${MESH_SRC}" "${STAGE}/${MESH_MANIFEST}"
elif [ -L "${MESH_SRC}" ]; then
    die "poisoned session tree: ${MESH_MANIFEST} is a symlink — refusing the whole export"
else
    warn "session carries no ${MESH_MANIFEST} — publishing without it (older/unmanaged session?)"
fi

# ── publish-manifest.json (versioned, deterministic, jesc'd at the sink) ─────
_jesc() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

if [ -z "${PRODUCED_AT}" ] && [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    PRODUCED_AT="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")"
fi
if [ -z "${PRODUCED_AT}" ]; then
    # Newest builtAt among the exported files: a pure function of the inputs,
    # NEVER wall-clock `date` (re-runs must be byte-identical => re-signable).
    PRODUCED_AT="$(printf '%s\n' "${F_BUILT[@]}" | sort | tail -1)"
fi
GEN_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "")"
RUNNER="$(id -un 2>/dev/null || echo unknown)@$(hostname 2>/dev/null || echo unknown)"

_flavor_for() {  # _flavor_for <id> — mesh-manifest flavor when jq can join it, else ""
    if command -v jq >/dev/null 2>&1 && [ -f "${STAGE}/${MESH_MANIFEST}" ]; then
        jq -r --arg id "$1" '(.images // [])[] | select(.id == $id) | .flavor // empty' \
            "${STAGE}/${MESH_MANIFEST}" 2>/dev/null | head -1
    fi
}

{
    printf '{\n'
    printf '  "schema": "hugmesh.net/publish-images/v1",\n'
    printf '  "session": { "id": "%s" },\n' "$(_jesc "${SESSION_ID}")"
    printf '  "producedAt": "%s",\n' "$(_jesc "${PRODUCED_AT}")"
    printf '  "generator": {\n'
    printf '    "producedBy": "hugmesh-generator",\n'
    printf '    "commit": "%s",\n' "$(_jesc "${GEN_COMMIT}")"
    printf '    "runner": "%s"\n' "$(_jesc "${RUNNER}")"
    printf '  },\n'
    printf '  "excludedByPolicy": ["keys-*/", "secureboot/", "wl-*/", "*sysroot*", "*.log", "*.lock"],\n'
    printf '  "images": [\n'
    for i in "${!F_PATH[@]}"; do
        bytes="${F_BYTES[$i]}"
        sha="${F_SHA[$i]}"
        flavor="$(_flavor_for "${F_ID[$i]}" || true)"
        printf '    {\n'
        printf '      "id": "%s",\n'       "$(_jesc "${F_ID[$i]}")"
        printf '      "role": "%s",\n'     "$(_jesc "${F_ROLE[$i]}")"
        printf '      "platform": "%s",\n' "$(_jesc "${F_PLATFORM[$i]}")"
        printf '      "flavor": "%s",\n'   "$(_jesc "${flavor}")"
        printf '      "kind": "%s",\n'     "$(_jesc "${F_KIND[$i]}")"
        printf '      "file": "%s",\n'     "$(_jesc "${F_BASE[$i]}")"
        printf '      "bytes": %s,\n'      "${bytes}"
        printf '      "sha256": "%s",\n'   "${sha}"
        printf '      "builtAt": "%s"\n'   "$(_jesc "${F_BUILT[$i]}")"
        if [ "$i" -lt $(( ${#F_PATH[@]} - 1 )) ]; then printf '    },\n'; else printf '    }\n'; fi
    done
    printf '  ]\n'
    printf '}\n'
} > "${STAGE}/${PUB_MANIFEST}"

# Well-formedness self-check (fail-closed like provenance.sh): a malformed
# manifest must never ship.
if command -v jq >/dev/null 2>&1; then
    jq -e . "${STAGE}/${PUB_MANIFEST}" >/dev/null 2>&1 || die "emitted ${PUB_MANIFEST} is not valid JSON"
elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${STAGE}/${PUB_MANIFEST}" >/dev/null 2>&1 \
        || die "emitted ${PUB_MANIFEST} is not valid JSON"
fi

# ── SHA256SUMS over everything that ships (relative names, -c-able) ──────────
# Artifact hashes are reused from the single hashing pass above; only the small
# text sidecars are hashed here.
{
    for i in "${!F_PATH[@]}"; do
        printf '%s  %s\n' "${F_SHA[$i]}" "${F_BASE[$i]}"
    done
    [ -f "${STAGE}/${MESH_MANIFEST}" ] && ( cd "${STAGE}" && sha256sum "${MESH_MANIFEST}" )
    ( cd "${STAGE}" && sha256sum "${PUB_MANIFEST}" )
} | sort -k2 > "${STAGE}/${SUMS}"

# ── optional Ed25519 signature over the manifest (provenance.sh's family) ────
# The manifest embeds every artifact's sha256, so the one detached signature
# transitively covers the whole publish tree.
if [ -n "${PROVENANCE_SIGNING_KEY:-}" ]; then
    command -v openssl >/dev/null 2>&1 || die "PROVENANCE_SIGNING_KEY set but openssl not found"
    [ -f "${PROVENANCE_SIGNING_KEY}" ] || die "PROVENANCE_SIGNING_KEY points at no file (out-of-band key custody; never committed)"
    openssl pkeyutl -sign -inkey "${PROVENANCE_SIGNING_KEY}" -rawin \
        -in "${STAGE}/${PUB_MANIFEST}" -out "${STAGE}/${PUB_SIG}" 2>/dev/null \
        || die "ed25519 sign failed"
    info "signed ${PUB_MANIFEST} -> ${PUB_SIG} (detached Ed25519)"
else
    warn "publish manifest UNSIGNED (PROVENANCE_SIGNING_KEY unset — key custody is out-of-band)"
fi

# ── final sweep: the staged tree must be EXACTLY what we meant to ship ───────
# Flat (no dirs), no symlinks, no unexpected names, deny-list re-verified.
stray="$(find "${STAGE}" -mindepth 1 ! -type f -print)"
[ -z "${stray}" ] || die "staged output is not a flat file tree (found: ${stray}) — refusing to publish"
while IFS= read -r -d '' sf; do
    base="$(basename "${sf}")"
    case "${base}" in
        "${MESH_MANIFEST}"|"${PUB_MANIFEST}"|"${PUB_SIG}"|"${SUMS}") : ;;
        *)  expected=0
            for b in "${F_BASE[@]}"; do
                if [ "${b}" = "${base}" ]; then expected=1; fi
            done
            [ "${expected}" -eq 1 ] || die "unexpected file materialized in the staged output: ${base} — refusing to publish"
            ;;
    esac
    if _is_denied "${base}"; then
        die "deny-listed name in the staged output: ${base} — refusing to publish"
    fi
done < <(find "${STAGE}" -mindepth 1 -maxdepth 1 -type f -print0)

# Secret-scan every staged TEXT file fail-closed, on a MASKED VIEW: the
# shape-validated artifact basenames are replaced by a placeholder first,
# because a stamped builder name (hugmesh-rpi5-arm64-backend-test-<stamp>) is
# itself a 40+-char mixed token whose Shannon entropy crosses the scanner's
# generic high-entropy threshold — a false positive by construction, since
# every one of these names already passed the naming-shape + content-magic
# gates above. Everything ELSE in the sidecars (session id, runner, flavor,
# any prose a poisoned tree smuggled in) is scanned verbatim; the mesh
# manifest was additionally scanned UNMASKED before it staged. The binary
# image payloads and the raw-byte .sig never enter the view (pure entropy,
# integrity is SHA256SUMS' job, identity is the shape+magic gates' job).
SCANVIEW="$(mktemp -d "${STAGE}.scanview.XXXXXX")"
for tf in "${PUB_MANIFEST}" "${SUMS}" "${MESH_MANIFEST}"; do
    [ -f "${STAGE}/${tf}" ] || continue
    cp "${STAGE}/${tf}" "${SCANVIEW}/${tf}"
    for b in "${F_BASE[@]}"; do
        sed -i "s/${b//./\\.}/VALIDATED_ARTIFACT_NAME/g" "${SCANVIEW}/${tf}"
    done
done
"${SECRET_SCAN}" "${SCANVIEW}" >/dev/null \
    || die "staged output failed the secret scan — refusing to publish"
rm -rf "${SCANVIEW}"; SCANVIEW=""

# Verify the staged copies against SHA256SUMS before declaring them real.
( cd "${STAGE}" && sha256sum -c "${SUMS}" >/dev/null ) \
    || die "staged output fails its own SHA256SUMS — refusing to publish a corrupt tree"

# ── finalize ─────────────────────────────────────────────────────────────────
mv "${STAGE}" "${DEST_ABS}"
FINALIZED=1

for i in "${!F_PATH[@]}"; do
    printf 'IMAGE %s FILE %s BYTES %s SHA256 %s\n' \
        "${F_ID[$i]}" "${DEST_ABS}/${F_BASE[$i]}" "${F_BYTES[$i]}" "${F_SHA[$i]}"
done
info "published session ${SESSION_ID} -> ${DEST_ABS} (verify: cd '${DEST_ABS}' && sha256sum -c ${SUMS})"
info "next (needs operator confirmation, hugmesh-host-shell#19): checksums at ingest, user-facing download routes, visibility model"
