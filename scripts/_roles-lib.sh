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
# Only the three platforms with a real role axis. The other seven builders
# (frite, orangepi5, orangepi4-lts, orangepi-zero2/-zero2w/-zero3, orangepi3-lts)
# have NO role axis: --role there is a free-form hostname/marker validated by a
# slug regex only. They are handled by hugmesh_role_reject_node_role below.
HUGMESH_ROLES_X86="pki backend frontend backend-gpu omnibus edge-ai laptop chromebook desktop standalone-thin standalone-thick standalone-unaffiliated"
HUGMESH_ROLES_RPI5="generic pki backend frontend desktop"
HUGMESH_ROLES_JETSON="edge-ai backend-gpu omnibus desktop"

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
# The three x86/legacy exceptions are retained ON PURPOSE — a rename must not
# re-point a default, only re-spell one:
#   backend-gpu  -> ${BRAND}-host       legacy; flashers/launchers/gen-keys examples
#   standalone-thick -> ${BRAND}-standalone
#   rpi5 generic -> gentoo-${BOARD}     the ONE role that drops the brand entirely
#                                       (not expressible here; see hugmesh_role_hostname)
# The jetson names keep their platform prefix exactly as the builder had them.
HUGMESH_ROLE_HOSTNAME_SUFFIX="
x86:backend-gpu=host
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
# because two different rules key off it: the seven free-slug boards refuse them
# (they cannot build a node image), and scripts/flash-disk.sh anchors its artifact
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

# hugmesh_role_reject_node_role <role> — for the seven free-slug boards, whose
# --role is a hostname/marker with no vocabulary. `--role backend` on an Orange Pi
# is silently accepted today and becomes a hostname; that names a node image the
# board cannot build. rc=1 (with a message on stderr) for any canonical NODE role
# or an alias of one. Custom markers stay available via --hostname.
hugmesh_role_reject_node_role() {
    local _r="$1"
    local _c
    _c="$(hugmesh_role_canonicalize "${_r}")" || return 0     # not in the vocabulary: fine
    if hugmesh_role_is_node_role "${_c}"; then
        printf "ERROR: --role '%s' names the cluster node role '%s', which this board does not build.\\n" \
            "${_r}" "${_c}" >&2
        printf '       This platform has no role axis — --role is only a hostname/marker here.\n' >&2
        printf '       Use --hostname NAME for a custom name.\n' >&2
        return 1
    fi
    return 0
}
