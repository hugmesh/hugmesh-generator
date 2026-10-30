#!/usr/bin/env bash
# ── _roles-lib.sh — THE role vocabulary. Declared ONCE; every channel derives. ──
#
# An image is identified by a DEVICE PLATFORM and then a ROLE. Before this file the
# role token was spelled independently in ~14 places and the SAME logical node was
# `--role be` on x86 and `--role backend` on rpi5, `--role gpu-host` on jetson and
# `--role be+gpu` on x86, `be-gpu` on the docker job channel and `host` in the
# artifact name. Ten hand-maintained translation tables bridged them, four of which
# were copies of one another and one of which ran backwards.
#
# This file is the reference set. Its consumers:
#   shell   — sourced by all 10 build-*-stage4.sh, scripts/flash-disk.sh,
#             scripts/gen-provision-keys.sh, scripts/build-all-roles.sh,
#             docker/build-image.sh, tests/qemu/*.sh
#   python  — parsed by studio/hugmesh_studio/core/roles.py (a ~60-line reader).
#             The SHELL is the reference and Python reads it, not the other way
#             round: the ten builders must not acquire a Python dependency, while
#             the Studio already runs Python.
#   guard   — tests/scripts/test-role-key-spelling.sh asserts every channel's set
#             equals what is declared here, and that no alias spelling is EMITTED.
#
# ── THE PACKAGED MIRROR ────────────────────────────────────────────────────────
#   A BYTE-IDENTICAL copy of this file is committed inside the Studio package at
#   studio/hugmesh_studio/core/_roles-lib.sh and is shipped as package-data. That
#   is not a second declaration and must never be edited: it exists because an
#   INSTALLED Studio has no repo above it. `pip install ./studio` — which is how
#   both the Flatpak (studio/packaging/flatpak/org.hugmesh.ImageStudio.yml, whose
#   build context is studio/ and cannot even see this directory) and the Windows
#   MSI freeze are built — copies hugmesh_studio/ into site-packages alone, so the
#   reader's checkout-relative path resolves to a `scripts/` dir that does not
#   exist there. core/config.py derives RPI5_ROLE_MAP/JETSON_ROLE_MAP from the
#   vocabulary at MODULE IMPORT time, so an installed bundle without the mirror
#   does not lose a feature, it fails to start.
#
#   EDIT THIS FILE, then re-run the mirror:
#       cp scripts/_roles-lib.sh studio/hugmesh_studio/core/_roles-lib.sh
#   studio/tests/test_roles_lib_packaging.py fails until you do, and the checkout
#   copy is the one a checkout reads, so the mirror can never quietly diverge into
#   being the thing the Studio actually obeys.
#
# NO host tool dependency. Pure bash 4+ string handling: no jq (jq is a TARGET
# package here, never a host prereq), no python, no awk, no external process at
# all. Declarations are flat so the Python reader and `grep` can both parse them.
#
# ── THE RULE ───────────────────────────────────────────────────────────────────
#   Aliases are accepted on INPUT, permanently, on every channel that takes a role.
#   Aliases are FORBIDDEN on OUTPUT — the /etc/hugmesh/role marker, artifact
#   filenames, hostnames, emitted argv, new session records, catalogs and docs all
#   carry the canonical spelling only.
#
# ── WHY LONG, AND WHY HYPHENS ──────────────────────────────────────────────────
#   * The k8s label side is uniformly LONG (hugmesh.net/backend, /frontend) and
#     CANNOT MOVE: scripts/tooling/tokens.json freezes the `hugmesh.net/` namespace,
#     73 files under specs/cluster/ nodeSelector on those keys, two live selector
#     READS fail OPEN on a stale one, and hand-written KEYS USB sticks in the field
#     carry them. There are ZERO `hugmesh.net/be` or `/fe` keys anywhere — the label
#     side never fluctuated; only the CLI did. A short CLI therefore guarantees a
#     PERMANENT translation point. Long deletes it.
#   * `+` is structurally illegal in two charsets this repo already enforces:
#     docker/build-image.sh's HARDWARE_CLASS ([A-Za-z0-9._-]) and the ARM builders'
#     _RE_SLUG. That is the entire reason `be-gpu` existed. `backend-gpu` is legal
#     in both, and deletes the `be+gpu` -> `host` artifact-tag translation.
#   * `edge_ai`'s own hostname is already `-edge-ai` and its own label is already
#     `hugmesh.net/edge-ai`; the underscore also breaks the artifact-name parser.
#
# ── WHAT THIS FILE DELIBERATELY DOES NOT TOUCH ─────────────────────────────────
#   The k8s label keys. `ROLE_LABELS` in build-x86-host-stage4.sh is declared
#   "informational" and its ONLY consumer is one `echo` in the build summary — the
#   CLI token and the label key are ALREADY fully decoupled, so converging the CLI
#   costs ZERO label edits. Renaming a label-key suffix would need 73 cluster
#   manifests, kind, USB sticks nothing in-tree can migrate, and possibly a
#   JVM/operator change in another repo (tokens.json records that label keys are
#   compiled into operators the way `platform.hugmesh.net` is). It is also neither
#   blocked NOR DETECTED by the freeze machinery (token-classifier.js tests the
#   NAMESPACE by substring), which makes it the worst possible risk for no benefit.
#
#   Three unrelated axes share these words and must never be swept:
#     gateway TIERS      hugmesh-be-gateway / hugmesh-fe-gateway, apps/20-gateway-*.yaml
#     reserved HANDLES   specs/cluster/reserved-prefixes.yaml reserves the handle `be`;
#                        `hugmesh.net/be/**` is a live URL PATH, not a label key
#     PERSON roles       user|mod|admin|superadmin (--person-role)
#     k8s TOPOLOGY roles control-plane|master|server|worker|none (.kubernetes.role)
#
# Sourced, never executed. No `set -e` here: the caller owns its shell options.

# ── CANONICAL VOCABULARY ───────────────────────────────────────────────────────
# 13 tokens. Lowercase, hyphens only; no `+`, no `_`.
#
#   CLUSTER NODE ROLES
#     pki           cluster CA / control plane
#     backend       backend k8s worker                       [x86 was `be`]
#     frontend      frontend k8s worker                      [x86 was `fe`]
#     backend-gpu   backend worker + GPU, no inference svc   [was be+gpu / host /
#                                                             be-gpu / gpu-host]
#     omnibus       one node running every cluster role      [jetson called it `full`]
#     edge-ai       GPU inference node (OpenAI-compatible)   [was edge_ai]
#     generic       plain unbranded arm64 server (rpi5 only)
#   CLIENT (person-device desktop) ROLES
#     laptop | chromebook | desktop
#   STANDALONE (no mesh / no SSO) ROLES
#     standalone-thin | standalone-thick | standalone-unaffiliated
HUGMESH_ROLES_CANONICAL="pki backend frontend backend-gpu omnibus edge-ai generic laptop chromebook desktop standalone-thin standalone-thick standalone-unaffiliated"

# ── PER-PLATFORM ACCEPTED SETS ─────────────────────────────────────────────────
# Three platforms have a full role axis (x86, rpi5, jetson). Two Orange Pi boards
# have a NODE axis on top of their desktop (orangepi5 = Orange Pi 5 / 5 Plus,
# orangepi4-lts): a canonical node role in their set builds a cluster node, while
# any token that is not a node role keeps the old meaning there — a free-form
# hostname/marker (default `desktop`), so every existing desktop invocation is
# unchanged. Both are EXPERIMENTAL (no Orange Pi has booted an image from this
# repo; hardware validation pending). The other five builders (frite,
# orangepi-zero2/-zero2w/-zero3, orangepi3-lts) have NO role axis: they are
# handled by hugmesh_role_reject_node_role below, which names the reason.
#
# omnibus on rpi5/orangepi5 is gated on RAM (HUGMESH_ROLE_MIN_RAM_GB below, 16 GB):
# the same image is sold with 1-16 GB (Pi) or 4-32 GB (Orange Pi 5), so the builder
# requires --ram-gb for it, and the Pi 4 (8 GB at most) is refused it. The Orange Pi 4 LTS (one 4 GB SKU, 16 GB eMMC) does
# not list omnibus, pki or backend at all — see HUGMESH_ROLE_REFUSAL.
HUGMESH_ROLES_X86="pki backend frontend backend-gpu omnibus edge-ai laptop chromebook desktop standalone-thin standalone-thick standalone-unaffiliated"
HUGMESH_ROLES_RPI5="generic pki backend frontend omnibus desktop"
HUGMESH_ROLES_JETSON="edge-ai backend-gpu omnibus desktop"
HUGMESH_ROLES_ORANGEPI5="desktop pki backend frontend omnibus"
HUGMESH_ROLES_ORANGEPI4LTS="desktop frontend"

# ── ALIASES (input only, PERMANENT) ────────────────────────────────────────────
# Not a deprecation window. There is no forcing function that would ever let these
# expire: hundreds of saved Studio session records and mesh manifests persist the
# old ids with no schema version and no load-time validation; KEYS USB sticks and
# printed run-books carry them; already-flashed nodes carry the old token in
# /etc/hugmesh/role until they are rebuilt; and external notes carry `--role be`.
# A dated removal would buy nothing and break exactly the humans this change
# protects. What is NOT permanent is the guard's output allowlist.
#
# One alias per line, `alias=canonical`. An alias is accepted on a platform iff its
# CANONICAL target is in that platform's set — one rule, no per-platform table.
HUGMESH_ROLE_ALIASES="
be=backend
fe=frontend
be+gpu=backend-gpu
be-gpu=backend-gpu
host=backend-gpu
gpu-host=backend-gpu
gpu_host=backend-gpu
full=omnibus
edge_ai=edge-ai
standalone-full=standalone-thick
"

# ── COMPOSITE ALIASES (a role PLUS a second axis) ──────────────────────────────
# These are NOT pure spelling aliases: each carries a platform or a flag. They must
# resolve to (canonical role + the extra axis), never to a bare role, or
# `standalone-desktop` silently loses its FDE posture. Deliberately kept OUT of
# hugmesh_role_canonicalize so a builder can never fold one by accident; only the
# callers that understand the extra axis (the Studio, docker/build-image.sh) consult
# hugmesh_role_composite.
#   rpi5-desktop / jetson-desktop  Studio ids that mangle the platform into the role
#                                  string. Retiring them is deferred (it touches the
#                                  persisted session schema); until then they resolve
#                                  through this table rather than a hand-written map.
#   standalone-desktop             docker HARDWARE_CLASS rpi5 token: --role desktop
#                                  AND --standalone.
# One per line, `alias=canonical:axis=value`.
HUGMESH_ROLE_COMPOSITE="
rpi5-desktop=desktop:platform=rpi5
jetson-desktop=desktop:platform=jetson
standalone-desktop=desktop:standalone=true
"

# ── HOSTNAME DEFAULTS ──────────────────────────────────────────────────────────
# The default is DERIVED: "${BRAND}-${ROLE}". Only genuine exceptions are listed,
# `<platform>:<role>=<suffix>` (the part after "${BRAND}-").
# The two x86/legacy exceptions are retained ON PURPOSE — a rename must not
# re-point a default, only re-spell one:
#   standalone-thick -> ${BRAND}-standalone
#   rpi5 generic -> gentoo-${BOARD}     the ONE role that drops the brand entirely
#                                       (not expressible here; see hugmesh_role_hostname)
# x86 backend-gpu USED to be a third (${BRAND}-host, the pre-role-split name). It
# was retired 2026-10-30 as a deliberate DECISION, not a rename side effect: it was
# the only cluster node that booted under a name saying nothing about its role
# (the backend/frontend/pki ISOs of the same run booted as hugmesh-backend/-frontend/
# -pki; backend-gpu booted as hugmesh-host). It now derives ${BRAND}-backend-gpu like
# every other node. Nothing keys on the baked default: a provisioned node takes its
# hostname from the KEYS manifest (tests/qemu/assertions.sh pins exactly that), and
# the launchers' `hugmesh-host-*` globs match ARTIFACT names, not hostnames.
# The jetson names keep their platform prefix exactly as the builder had them.
HUGMESH_ROLE_HOSTNAME_SUFFIX="
x86:standalone-thick=standalone
jetson:edge-ai=jetson-edge-ai
jetson:backend-gpu=jetson-gpu
jetson:omnibus=jetson-full
jetson:desktop=jetson
frite:desktop=frite
frite:generic=frite
orangepi5:desktop=orangepi5
orangepi5:generic=orangepi5
orangepi4-lts:desktop=orangepi4-lts
orangepi4-lts:generic=orangepi4-lts
orangepizero2:appliance=orangepizero2
orangepizero2:generic=orangepizero2
orangepizero2w:appliance=orangepizero2w
orangepizero2w:generic=orangepizero2w
orangepizero3:appliance=orangepizero3
orangepizero3:generic=orangepizero3
orangepi3-lts:appliance=orangepi3-lts
orangepi3-lts:generic=orangepi3-lts
"

# ── KEYS PROFILE ───────────────────────────────────────────────────────────────
# role -> scripts/gen-provision-keys.sh --role profile. A SEMANTIC map, not a
# spelling one: gen-provision-keys knows only {pki, backend, frontend, host,
# control-plane-additional, mesh-extension}. This table was copied THREE times
# (build-x86's printed hints, docker/build-image.sh twice, worklist_driver.py) and
# every copy ended in a `*) -> host` catch-all that silently downgraded an unknown
# role to the worker profile. There is no catch-all here: an unlisted role is an
# ERROR, because the wrong keys profile is not a cosmetic failure.
# CLIENT/STANDALONE desktops are in the table on purpose, with their reason, rather
# than left to a catch-all: a client image provisions from the SAME KEYS USB
# mechanism but is not a cluster member (no users.json, no cluster join), so it takes
# the plain `host` worker profile — break-glass root key + mesh join material only.
# That is exactly the rule scripts/build-all-roles.sh states for its Frite/Orange Pi
# client keys blocks; writing it down here is what lets the catch-all die.
HUGMESH_ROLE_KEYPROFILE="
pki=pki
backend=backend
frontend=frontend
backend-gpu=backend
omnibus=pki
edge-ai=host
generic=host
laptop=host
chromebook=host
desktop=host
standalone-thin=host
standalone-thick=host
standalone-unaffiliated=host
"

# ── functions ──────────────────────────────────────────────────────────────────
# bash 5.3 localises every name in a `local` list BEFORE assigning, so
# `local a="$1" b="${a}"` dies under `set -u`. Every function below uses ONE
# `local` per assignment. No pipelines either: `cmd | grep -q` under pipefail
# reports failure on a match it found.

# _hm_role_lookup <table> <key> — echo the value for `key=value`; rc=1 if absent.
# The unquoted expansion word-splits the table on IFS (whitespace, newlines
# included). Deliberate and safe: every entry is a bare `key=value` with no spaces
# and no glob metacharacters. A `while read <<< "$tbl"` here-string would be
# bash-only, and a pipeline would put the `return` in a subshell —
# docker/build-image.sh runs under /bin/sh, so this file stays POSIX sh.
_hm_role_lookup() {
    local _tbl="$1"
    local _key="$2"
    local _e
    for _e in ${_tbl}; do
        case "${_e}" in
            "${_key}="*) printf '%s\n' "${_e#*=}"; return 0 ;;
        esac
    done
    return 1
}

# hugmesh_role_is_canonical <role>
hugmesh_role_is_canonical() {
    case " ${HUGMESH_ROLES_CANONICAL} " in *" $1 "*) return 0 ;; esac
    return 1
}

# hugmesh_role_platform_set <platform> — echo the accepted canonical set, rc=1 if
# the platform has no role axis.
hugmesh_role_platform_set() {
    case "$1" in
        x86)    printf '%s\n' "${HUGMESH_ROLES_X86}" ;;
        rpi5)   printf '%s\n' "${HUGMESH_ROLES_RPI5}" ;;
        jetson) printf '%s\n' "${HUGMESH_ROLES_JETSON}" ;;
        orangepi5)     printf '%s\n' "${HUGMESH_ROLES_ORANGEPI5}" ;;
        orangepi4-lts) printf '%s\n' "${HUGMESH_ROLES_ORANGEPI4LTS}" ;;
        *)      return 1 ;;
    esac
}

# hugmesh_role_canonicalize <role> — echo the canonical spelling. An already
# canonical token passes through. rc=1 (and echoes nothing) if the token is neither
# canonical nor a declared alias. Composite aliases are NOT folded here.
hugmesh_role_canonicalize() {
    local _r="$1"
    if hugmesh_role_is_canonical "${_r}"; then printf '%s\n' "${_r}"; return 0; fi
    local _c
    _c="$(_hm_role_lookup "${HUGMESH_ROLE_ALIASES}" "${_r}")" || return 1
    printf '%s\n' "${_c}"
}

# hugmesh_role_composite <alias> — echo "canonical<TAB>axis=value" for a composite
# alias; rc=1 otherwise. Callers that cannot honour the extra axis must not use it.
hugmesh_role_composite() {
    local _v
    _v="$(_hm_role_lookup "${HUGMESH_ROLE_COMPOSITE}" "$1")" || return 1
    printf '%s\t%s\n' "${_v%%:*}" "${_v#*:}"
}

# hugmesh_role_aliases_of <canonical> — echo every alias that folds onto it, space
# separated (canonical first). Used by the artifact globbers so an image built
# under the old spelling stays findable by its old name.
hugmesh_role_aliases_of() {
    local _c="$1"
    local _out="$1"
    local _e
    for _e in ${HUGMESH_ROLE_ALIASES}; do
        case "${_e}" in
            *"=${_c}") _out="${_out} ${_e%%=*}" ;;
        esac
    done
    printf '%s\n' "${_out}"
}

# ── ROLE-TOKEN SHADOWING (one spelling contained in another) ───────────────────
# Every artifact consumer finds an image with a `*-<role>-*` glob, because the
# builders name artifacts <brand>-<platform>-<arch>-<role>-<env>-<stamp>. That glob
# is a PREFIX match, and three spellings in this vocabulary contain another spelling
# inside exactly that hyphen window:
#
#     -backend-gpu-      contains  -backend-        canonical inside canonical
#     -be-gpu-           contains  -be-             alias     inside alias
#     -standalone-full-  contains  -full-           alias     inside alias
#
# So `--role backend` also matches the backend-gpu image. That is not a tie broken
# by chance: scripts/build-all-roles.sh builds the DEFAULT x86 fleet in the order
# `pki backend frontend backend-gpu` into ONE work dir, so backend-gpu is always
# the newest, and the launchers' `for c in <glob>` lists expand alphabetically,
# where `backend-gpu` sorts before `backend-<env>`. Both orderings pick the GPU
# image, every time. On scripts/flash-disk.sh that is a whole-physical-disk write
# of the NVIDIA/GPU worker image onto a plain backend node, with no ambiguity
# refusal possible — both artifacts are platform x86, so the platform anchor and
# assert_one_platform cannot see it.
#
# The collision became REACHABLE with this vocabulary: while be+gpu's artifact tag
# was folded to `host`, no emitted name pair collided (`-be-` cannot prefix-match
# `-host-`). It is derived from the declarations below rather than hard-coded, so a
# future canonical role that extends an existing one (`frontend-gpu`) is covered on
# the day it is declared, and so the two alias collisions are covered too.

# hugmesh_role_shadow_tokens <role> — echo every role spelling, space separated,
# whose own `-<token>-` window CONTAINS the `-<role>-` window (or that of one of
# <role>'s aliases) and which belongs to a DIFFERENT canonical role. Empty for all
# but backend/be and omnibus/full. rc=1 for a token outside the vocabulary.
hugmesh_role_shadow_tokens() {
    local _c
    _c="$(hugmesh_role_canonicalize "$1")" || return 1
    local _mine
    _mine="$(hugmesh_role_aliases_of "${_c}")"
    local _all
    _all="${HUGMESH_ROLES_CANONICAL}"
    local _e
    for _e in ${HUGMESH_ROLE_ALIASES}; do
        _all="${_all} ${_e%%=*}"
    done
    local _out
    _out=""
    local _t
    local _tc
    local _s
    for _t in ${_all}; do
        _tc="$(hugmesh_role_canonicalize "${_t}")" || continue
        [ "${_tc}" = "${_c}" ] && continue
        for _s in ${_mine}; do
            [ "${_t}" = "${_s}" ] && continue
            case "-${_t}-" in
                *"-${_s}-"*) _out="${_out}${_out:+ }${_t}"; break ;;
            esac
        done
    done
    printf '%s\n' "${_out}"
}

# hugmesh_role_shadow_filter <role> — a stdin -> stdout filter over artifact PATHS.
# Drops every path whose basename carries one of the shadowing spellings above, i.e.
# whose `-<role>-` match was only the prefix of a longer role. A pass-through `cat`
# for the roles that shadow nothing, so it is safe to apply to EVERY role-scoped
# candidate list — and it must be applied to every one of them, because dropping it
# from any single consumer restores the wrong-image pick there alone.
# Deliberately NOT applied to the fallbacks that ignore the role (`any image for this
# platform`): those have already given up on the role and must keep returning
# something.
hugmesh_role_shadow_filter() {
    local _sh
    _sh="$(hugmesh_role_shadow_tokens "$1" 2>/dev/null || true)"
    if [ -z "${_sh}" ]; then cat; return 0; fi
    local _line
    local _base
    local _t
    local _drop
    while IFS= read -r _line; do
        _base="${_line##*/}"
        _drop=0
        for _t in ${_sh}; do
            case "${_base}" in
                *"-${_t}-"*) _drop=1; break ;;
            esac
        done
        [ "${_drop}" -eq 0 ] && printf '%s\n' "${_line}"
    done
    return 0
}

# hugmesh_role_validate <role> <platform> — THE builder entry point. Echoes the
# canonical role on success. On failure prints a full, alias-aware message to
# stderr and returns 1; the caller decides how to die.
hugmesh_role_validate() {
    local _raw="$1"
    local _plat="$2"
    local _set
    _set="$(hugmesh_role_platform_set "${_plat}")" || {
        printf 'ERROR: no role vocabulary for platform %s\n' "${_plat}" >&2; return 1; }
    local _c
    if ! _c="$(hugmesh_role_canonicalize "${_raw}")"; then
        printf 'ERROR: --role must be one of: %s\n' "${_set}" >&2
        printf '       (accepted aliases: %s)\n' "$(hugmesh_role_alias_help "${_plat}")" >&2
        printf "       got '%s'\\n" "${_raw}" >&2
        return 1
    fi
    case " ${_set} " in
        *" ${_c} "*) printf '%s\n' "${_c}"; return 0 ;;
    esac
    if [ "${_c}" != "${_raw}" ]; then
        printf "ERROR: --role '%s' means '%s', which platform %s does not build\\n" \
            "${_raw}" "${_c}" "${_plat}" >&2
    else
        printf "ERROR: --role '%s' is not a role platform %s builds\\n" "${_raw}" "${_plat}" >&2
    fi
    printf '       --role must be one of: %s\n' "${_set}" >&2
    return 1
}

# hugmesh_role_for <platform> <role> — the SILENT twin of hugmesh_role_validate:
# echoes the canonical role, or returns 1 with nothing on stdout OR stderr. For
# callers that turn a rejection into their own error (docker/build-image.sh answers
# an unresolvable HARDWARE_CLASS with a clean FAILED ingest report, never a message
# on the worker's stderr). Lives HERE rather than in build-image.sh so the two
# harnesses that extract `resolve_build_target()` verbatim
# (tests/build-matrix/check.sh, scripts/emit-image-inventory.py) can source ONE file
# and get every function that body calls — an extracted body missing a helper
# silently rejects every row, which reads exactly like a real regression.
hugmesh_role_for() {
    hugmesh_role_validate "$2" "$1" 2>/dev/null
}

# hugmesh_role_alias_help <platform> — "be=backend, fe=frontend, ..." for the
# aliases valid on that platform. The help text must SAY the alias (requirement:
# every old spelling still accepted, and documented where it is accepted).
hugmesh_role_alias_help() {
    local _set
    _set="$(hugmesh_role_platform_set "$1")" || return 1
    local _out=""
    local _e
    local _a
    local _c
    for _e in ${HUGMESH_ROLE_ALIASES}; do
        _a="${_e%%=*}"
        _c="${_e#*=}"
        case " ${_set} " in
            *" ${_c} "*) _out="${_out}${_out:+, }${_a}=${_c}" ;;
        esac
    done
    printf '%s\n' "${_out}"
}

# hugmesh_role_hostname <platform> <role> <brand> [board] — the default hostname
# with no -H. Canonical role expected (validate first).
hugmesh_role_hostname() {
    local _plat="$1"
    local _role="$2"
    local _brand="$3"
    local _board="${4:-}"
    # The ONE role whose default drops the brand entirely.
    if [ "${_plat}" = "rpi5" ] && [ "${_role}" = "generic" ]; then
        printf 'gentoo-%s\n' "${_board:-rpi5}"; return 0
    fi
    local _sfx
    if _sfx="$(_hm_role_lookup "${HUGMESH_ROLE_HOSTNAME_SUFFIX}" "${_plat}:${_role}")"; then
        printf '%s-%s\n' "${_brand}" "${_sfx}"; return 0
    fi
    printf '%s-%s\n' "${_brand}" "${_role}"
}

# hugmesh_role_keyprofile <role> — the gen-provision-keys.sh profile. rc=1 for a
# role with no declared profile: a WRONG keys profile provisions a node with the
# wrong credentials, so this must never fall back.
hugmesh_role_keyprofile() {
    _hm_role_lookup "${HUGMESH_ROLE_KEYPROFILE}" "$1"
}

# ── CLUSTER NODE ROLES ─────────────────────────────────────────────────────────
# The subset of the vocabulary that names a k8s cluster member. Declared ONCE
# because two different rules key off it: the five free-slug boards refuse them
# (they cannot build a node image; the two Orange Pi node boards refuse the ones
# outside their set), and scripts/flash-disk.sh anchors its artifact
# search to the platforms that build them (a node role identifies its platform, so a
# `--role backend --arch arm64` request can never surface a Jetson image).
HUGMESH_ROLES_NODE="pki backend frontend backend-gpu omnibus edge-ai"

# hugmesh_role_is_node_role <canonical role>
hugmesh_role_is_node_role() {
    case " ${HUGMESH_ROLES_NODE} " in *" $1 "*) return 0 ;; esac
    return 1
}

# hugmesh_role_arch <platform> — the artifact ARCH token a platform's images carry.
# x86 -> x86/amd64; every SBC/Jetson board -> arm64. Used by flash-disk.sh to decide
# which platforms a given --arch can legitimately mean.
hugmesh_role_arch() {
    case "$1" in
        x86) printf 'x86\n' ;;
        *)   printf 'arm64\n' ;;
    esac
}

# hugmesh_role_reject_node_role <role> [platform] — for the five free-slug boards,
# whose --role is a hostname/marker with no vocabulary. `--role backend` on an
# Orange Pi Zero was once silently accepted and became a hostname; that names a node
# image the board cannot build. rc=1 (with a message on stderr) for any canonical
# NODE role or an alias of one; with <platform>, the message also says WHY (from
# HUGMESH_ROLE_REFUSAL). Custom markers stay available via --hostname.
hugmesh_role_reject_node_role() {
    local _r="$1"
    local _plat="${2:-}"
    local _c
    _c="$(hugmesh_role_canonicalize "${_r}")" || return 0     # not in the vocabulary: fine
    if hugmesh_role_is_node_role "${_c}"; then
        printf "ERROR: --role '%s' names the cluster node role '%s', which this board does not build.\\n" \
            "${_r}" "${_c}" >&2
        local _why
        if [ -n "${_plat}" ] && _why="$(hugmesh_role_refusal_reason "${_plat}" "${_c}")"; then
            printf '       Why: %s\n' "${_why}" >&2
        fi
        printf '       This platform has no role axis — --role is only a hostname/marker here.\n' >&2
        printf '       Use --hostname NAME for a custom name.\n' >&2
        return 1
    fi
    return 0
}

# ── BOARD NODE AXIS (orangepi5 / orangepi4-lts) ────────────────────────────────
# hugmesh_role_board_node_role <platform> <role> — for the two Orange Pi builders
# whose --role is EITHER a node role from their platform set OR the old free-form
# hostname/marker. Echoes the canonical node role and returns 0 when <role> names
# a node role the platform builds; returns 2 (silently) when <role> is not a node
# role at all (the caller keeps its desktop/marker path, byte-for-byte as before);
# returns 1 with a reason-naming message on stderr when <role> names a node role
# the platform refuses (e.g. omnibus on the 4 GB Orange Pi 4 LTS).
hugmesh_role_board_node_role() {
    local _plat="$1"
    local _raw="$2"
    local _c
    _c="$(hugmesh_role_canonicalize "${_raw}")" || return 2
    hugmesh_role_is_node_role "${_c}" || return 2
    local _set
    _set="$(hugmesh_role_platform_set "${_plat}")" || {
        hugmesh_role_reject_node_role "${_raw}" "${_plat}"; return 1; }
    case " ${_set} " in
        *" ${_c} "*) printf '%s\n' "${_c}"; return 0 ;;
    esac
    printf "ERROR: --role '%s' (cluster node role '%s') is not built for platform %s.\\n" \
        "${_raw}" "${_c}" "${_plat}" >&2
    local _why
    if _why="$(hugmesh_role_refusal_reason "${_plat}" "${_c}")"; then
        printf '       Why: %s\n' "${_why}" >&2
    fi
    printf '       Node roles this board builds: %s\n' "$(hugmesh_role_node_set "${_plat}")" >&2
    return 1
}

# hugmesh_role_node_set <platform> — the node roles in a platform's set, space
# separated ("none" when it has none).
hugmesh_role_node_set() {
    local _set
    _set="$(hugmesh_role_platform_set "$1" 2>/dev/null)" || { printf 'none\n'; return 0; }
    local _out=""
    local _r
    for _r in ${_set}; do
        hugmesh_role_is_node_role "${_r}" && _out="${_out}${_out:+ }${_r}"
    done
    printf '%s\n' "${_out:-none}"
}

# ── WHY A BOARD REFUSES A NODE ROLE ────────────────────────────────────────────
# `<platform>:<role>=<one-line reason>`; `<platform>:any` covers every other node role
# (not `*`: the lookup word-splits the table UNQUOTED, so a glob character would be
# subject to pathname expansion — and vanish under nullglob).
# Underscores stand for spaces so the table stays flat for the shell loop and the
# Python reader (the reader and hugmesh_role_refusal_reason both turn `_` back into
# a space). The RAM/storage numbers come from each board's specs-*/README.md.
HUGMESH_ROLE_REFUSAL="
orangepi4-lts:omnibus=the_Orange_Pi_4_LTS_has_4_GB_of_RAM_(single_SKU)_and_16_GB_of_eMMC,_below_omnibus's_16_GB_RAM_floor;_it_can_be_a_frontend_worker
orangepi4-lts:pki=the_Orange_Pi_4_LTS_has_16_GB_of_eMMC_and_no_M.2_slot,_too_small_for_the_control_plane's_etcd,_Vault,_Harbor_and_Cassandra_storage;_it_can_be_a_frontend_worker
orangepi4-lts:backend=the_Orange_Pi_4_LTS_has_4_GB_of_RAM,_below_backend's_8_GB_RAM_floor_(the_backend_tier_alone_asks_for_4_GiB);_it_can_be_a_frontend_worker
orangepi4-lts:any=the_Orange_Pi_4_LTS_builds_only_the_frontend_node_role
orangepi5:any=the_Orange_Pi_5_/_5_Plus_builds_the_pki,_backend,_frontend_and_omnibus_node_roles_only
orangepizero2:any=the_Orange_Pi_Zero_2_has_at_most_1_GB_of_RAM_and_boots_from_microSD_only,_not_enough_for_the_hardened_containerd/kubelet_node_stack
orangepizero2w:any=the_Orange_Pi_Zero_2W_has_at_most_4_GB_of_RAM,_microSD-only_storage_and_no_onboard_Ethernet,_not_enough_for_a_cluster_node
orangepizero3:any=the_Orange_Pi_Zero_3_has_at_most_4_GB_of_RAM_and_microSD-only_storage_(no_eMMC_or_NVMe),_not_enough_for_a_cluster_node
orangepi3-lts:any=the_Orange_Pi_3_LTS_has_2_GB_of_RAM_and_its_onboard_Ethernet_does_not_work_on_the_mainline_device_tree,_not_enough_for_a_cluster_node
frite:any=the_Frite_family_(Amlogic_S805X/S905X)_has_512_MB_to_2_GB_of_RAM,_not_enough_for_the_hardened_containerd/kubelet_node_stack
"

# hugmesh_role_refusal_reason <platform> <canonical role> — echo the reason (with
# spaces), rc=1 when none is declared.
hugmesh_role_refusal_reason() {
    local _v
    _v="$(_hm_role_lookup "${HUGMESH_ROLE_REFUSAL}" "$1:$2")" \
        || _v="$(_hm_role_lookup "${HUGMESH_ROLE_REFUSAL}" "$1:any")" || return 1
    # Pure shell (no `tr`: this file runs no external process, and is sourced
    # under /bin/sh by docker/build-image.sh).
    local _out=""
    while :; do
        case "${_v}" in
            *_*) _out="${_out}${_v%%_*} "; _v="${_v#*_}" ;;
            *)   _out="${_out}${_v}"; break ;;
        esac
    done
    printf '%s\n' "${_out}"
}

# ── RAM FLOORS (cluster node roles) ────────────────────────────────────────────
# GB of installed RAM a node role needs. An image cannot see the RAM of the board
# it will be flashed onto (`--board rpi4` is ONE image for the 1, 2, 4 and 8 GB
# Pi 4), so the builders take the RAM as `--ram-gb N`: REQUIRED for omnibus (the
# role that runs every cluster tier on one node), optional for the others (when
# given and below the floor it is refused). A board whose LARGEST RAM size
# (HUGMESH_BOARD_RAM_GB) is below a role's floor is refused that role outright
# (the Pi 4 tops out at 8 GB, so it is never an omnibus).
#
# Evidence: the live kind cluster runs every namespace on ONE node. Measured
# read-only 2026-10-22 00:08 PDT (`kubectl get pods -A -o json`, 68 Running pods;
# `kubectl describe nodes`: "memory 8496Mi" requested), the scheduler is asked for
# 8496 MiB (8.3 GiB) of memory before the OS, and the node's working set was
# 9764 MiB. Per tier (requests / limits, MiB): backend 4096 / 11520,
# pki 1536 / 3328, frontend 1472 / 3200, vault 288, kube-system 490, keda 300,
# kyverno 192, ingress 90. A real ARM node will use more, not less. So:
#   omnibus  16  8.3 GiB of requests + OS + kubelet reserve does not fit a board
#                sold as 8 GB (about 7.6 GiB usable); 16 GB is the next size.
#   backend   8  its tier alone requests 4.0 GiB, more than a 4 GB board can
#                give the scheduler once the OS and kubelet have theirs.
#   pki       4  about 2.4 GiB with Vault, ingress and the control plane.
#   frontend  4  about 2 GiB with the per-node system pods.
# The baked /etc/hugmesh/min-ram-mb records the omnibus floor on the image.
# x86/jetson builders do not take --ram-gb yet.
HUGMESH_ROLE_MIN_RAM_GB="
omnibus=16
pki=4
backend=8
frontend=4
"

# RAM SKUs each board is SOLD with, in GB (comma separated). Used only for a
# WARNING when --ram-gb names a size that is not in the list — never to refuse, so
# a missing SKU here cannot block a real board. The Raspberry Pi and Orange Pi 5
# lists are vendor recollection, NOT read from this repo: confirm against the
# vendors' pages. orangepi4-lts/rpi3 come from their specs-*/README.md.
HUGMESH_BOARD_RAM_GB="
rpi5=1,2,4,8,16
rpi4=1,2,4,8
rpi3=1
orange-pi-5=4,8,16,32
orange-pi-5-plus=4,8,16,32
orange-pi-4-lts=4
"

# hugmesh_role_min_ram_gb <canonical role> — echo the floor; rc=1 for a role with
# none (client/standalone roles).
hugmesh_role_min_ram_gb() {
    _hm_role_lookup "${HUGMESH_ROLE_MIN_RAM_GB}" "$1"
}

# _hm_role_board_max_ram_gb <board> — the largest RAM size <board> is sold with
# (HUGMESH_BOARD_RAM_GB); rc=1 for a board not in the table. Pure shell.
_hm_role_board_max_ram_gb() {
    local _skus _g _max=0
    _skus="$(_hm_role_lookup "${HUGMESH_BOARD_RAM_GB}" "$1")" || return 1
    while :; do
        case "${_skus}" in
            *,*) _g="${_skus%%,*}"; _skus="${_skus#*,}" ;;
            *)   _g="${_skus}"; _skus="" ;;
        esac
        [ "${_g}" -gt "${_max}" ] && _max="${_g}"
        [ -n "${_skus}" ] || break
    done
    printf '%s\n' "${_max}"
}

# hugmesh_role_ram_why <canonical role> — one line saying why the floor is what it
# is (the numbers measured above). Used by every RAM refusal so they all agree.
hugmesh_role_ram_why() {
    case "$1" in
        omnibus)  printf 'The whole stack asks the scheduler for about 8.3 GiB of memory before the operating system (measured), so it does not fit an 8 GB board. Build pki/backend/frontend for this board instead.' ;;
        backend)  printf 'The backend tier alone asks the scheduler for 4 GiB of memory, so it does not fit a 4 GB board next to the operating system and kubelet.' ;;
        *)        printf 'Below that the hardened containerd/kubelet stack plus this tier'"'"'s pods do not fit.' ;;
    esac
}

# hugmesh_role_ram_check <canonical role> <ram-gb or ""> <board> — THE build-time
# RAM gate. rc=0 to proceed; rc=1 with a full message on stderr to refuse.
#   omnibus + no --ram-gb            -> refuse (the image cannot tell which SKU)
#   --ram-gb not a positive integer  -> refuse
#   --ram-gb below the role's floor  -> refuse
#   --ram-gb not a SKU of <board>    -> warning only (the SKU list may be stale)
hugmesh_role_ram_check() {
    local _role="$1"
    local _ram="$2"
    local _board="$3"
    local _floor
    _floor="$(hugmesh_role_min_ram_gb "${_role}")" || return 0
    # A board that is not SOLD with enough RAM for this role is refused the role,
    # whatever --ram-gb says (a larger --ram-gb than the board exists in is a typo).
    local _max
    if _max="$(_hm_role_board_max_ram_gb "${_board}")" && [ "${_max}" -lt "${_floor}" ]; then
        printf 'ERROR: --role %s needs at least %s GB of RAM, and %s is sold with at most %s GB.\n' \
            "${_role}" "${_floor}" "${_board}" "${_max}" >&2
        printf '       %s\n' "$(hugmesh_role_ram_why "${_role}")" >&2
        return 1
    fi
    if [ -z "${_ram}" ]; then
        [ "${_role}" = "omnibus" ] || return 0
        printf 'ERROR: --role omnibus needs --ram-gb N (the GB of RAM on the board you will flash).\n' >&2
        printf '       Omnibus runs every cluster role on one node and needs at least %s GB; the\n' "${_floor}" >&2
        printf '       %s image is the same for every RAM size the board is sold with (%s GB),\n' \
            "${_board}" "$(_hm_role_lookup "${HUGMESH_BOARD_RAM_GB}" "${_board}" || printf 'several')" >&2
        printf '       so the build cannot tell which one you have.\n' >&2
        return 1
    fi
    case "${_ram}" in
        ''|*[!0-9]*|0*)
            printf "ERROR: --ram-gb must be a whole number of GB, e.g. 8 (got '%s')\\n" "${_ram}" >&2
            return 1 ;;
    esac
    if [ "${_ram}" -lt "${_floor}" ]; then
        printf 'ERROR: --role %s needs at least %s GB of RAM (got --ram-gb %s).\n' "${_role}" "${_floor}" "${_ram}" >&2
        printf '       %s\n' "$(hugmesh_role_ram_why "${_role}")" >&2
        return 1
    fi
    local _skus
    if _skus="$(_hm_role_lookup "${HUGMESH_BOARD_RAM_GB}" "${_board}")"; then
        case ",${_skus}," in
            *",${_ram},"*) ;;
            *) printf 'WARNING: --ram-gb %s is not a RAM size %s is known to be sold with (%s GB); continuing.\n' \
                   "${_ram}" "${_board}" "${_skus}" >&2 ;;
        esac
    fi
    return 0
}
