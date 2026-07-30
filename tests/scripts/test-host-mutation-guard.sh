#!/usr/bin/env bash
# ── HOST-MUTATION container-gate guard ───────────────────────────────────────
# Every site that mutates the root the builder RUNS ON must be gated on a proof
# that the root is disposable — not merely on `id -u`. Until 2026-07-17 the ARM
# builders seeded HOST /etc/portage (including "*/* PYTHON_TARGETS:
# python3_12 python3_13", a WILDCARD system-wide python-target change) and ran a
# HOST `emerge` behind nothing but `[ "$(id -u)" -eq 0 ] && [ -d /etc/portage ]`.
# It never fired only because build_driver.py's preflight() blocked every native
# build — an accidental shield that PR #382 removed. A revert of any hostguard
# call below silently re-arms the reconfiguration of the operator's desktop, so
# each one is asserted here.
#
# EVERY grep is ^-ANCHORED to a LIVE line. An unanchored `grep -qF` also matches
# a commented-out occurrence and would pass against dead code — that exact hole
# was found in #380's log guard, so it is not repeated here.
#
# Three classes, mirroring scripts/_host-guard-lib.sh:
#   A  HOST /etc/portage seeds        (6 ARM builders; +2 cross-host-selinux)
#   B  HOST emerge                    (6 ARM builders)
#   C  KERNEL-GLOBAL binfmt_misc      (scripts/_dracut-cross-lib.sh)
#   D  host-tool honesty              (x86/frite/opi5/zero2/jetson)
# plus the lib<->Dockerfile marker sync.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== host-mutation container-gate guard =="

ARM=(build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh
     build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh build-jetson-stage4.sh)
LIB="${GEN}/scripts/_host-guard-lib.sh"
DXC="${GEN}/scripts/_dracut-cross-lib.sh"
DOCKERFILE="${GEN}/Dockerfile.build"

# ── the library itself ──────────────────────────────────────────────
if [ -f "${LIB}" ]; then
    ok "scripts/_host-guard-lib.sh exists"
    # /.dockerenv is THE load-bearing signal: it is the only container proof the
    # operator's already-built (stale) hugmesh-builder image carries, and the
    # Docker daemon creates it at run time so it cannot go stale. Losing it
    # breaks every fleet build until the image is rebuilt.
    grep -qE '^HOSTGUARD_DOCKER_MARKER="/\.dockerenv"$' "${LIB}" \
        && ok "lib: pins /.dockerenv (stale-image-safe signal)" \
        || bad "lib: lost the /.dockerenv marker constant"
    grep -qE '^HOSTGUARD_PODMAN_MARKER="/run/\.containerenv"$' "${LIB}" \
        && ok "lib: pins /run/.containerenv (podman)" \
        || bad "lib: lost the /run/.containerenv marker constant"
    # Fail-safe by construction: the predicate's fallthrough must be `return 1`
    # (= treat an unproven runtime as the operator's real machine).
    if awk '/^hostguard_in_container\(\)/{g=1} g{print} g&&/^}$/{exit}' "${LIB}" \
         | grep -qE '^[[:space:]]*return 1$'; then
        ok "lib: hostguard_in_container falls through to 'return 1' (fail safe)"
    else
        bad "lib: hostguard_in_container lost its fail-safe 'return 1' fallthrough"
    fi
    # MUTATION-PROVEN DEAD SIGNAL: /proc/1/cgroup reads '0::/' (cgroup v2) inside
    # hugmesh-builder:latest — no "docker" substring. Relying on it would
    # declare the FLEET CONTAINER a host and brick every build. It must never
    # come back as a decision input.
    if grep -vE '^[[:space:]]*#' "${LIB}" | grep -q '/proc/1/cgroup'; then
        bad "lib: uses /proc/1/cgroup — mutation-proven dead (cgroup v2 '0::/' in the builder image)"
    else
        ok "lib: does not consult /proc/1/cgroup (proven dead heuristic)"
    fi
    # The escape hatch must live ONLY in hostguard_mutation_allowed. If
    # hostguard_in_container itself honoured an env var, an env-forgeable path
    # into a host emerge would reopen the exact bug this library closes.
    if awk '/^hostguard_in_container\(\)/{g=1} g{print} g&&/^}$/{exit}' "${LIB}" \
         | grep -vE '^[[:space:]]*#' | grep -q 'HUGMESH_ASSUME_CONTAINER'; then
        bad "lib: hostguard_in_container consults HUGMESH_ASSUME_CONTAINER (must be mutation_allowed only)"
    else
        ok "lib: HUGMESH_ASSUME_CONTAINER never reaches hostguard_in_container"
    fi
    # NO ENV VAR MAY AUTHORIZE MUTATION. A `container=docker|podman|lxc|...` arm
    # shipped here in review and was mutation-proven to write the `*/*
    # PYTHON_TARGETS` wildcard on a marker-less root, SILENTLY, purely because an
    # env var was exported — while the deliberate hatch warns. An env var is
    # forgeable; the file markers are runtime-created. Pin the arm out in BOTH
    # directions (static + behavioural, below) so it cannot be re-added unnoticed.
    if awk '/^hostguard_in_container\(\)/{g=1} g{print} g&&/^}$/{exit}' "${LIB}" \
         | grep -vE '^[[:space:]]*#' | grep -qE '\$\{container|"\$container'; then
        bad "lib: hostguard_in_container consults the forgeable \$container env var (env must never authorize a host emerge)"
    else
        ok "lib: no \$container env arm in hostguard_in_container (env never authorizes mutation)"
    fi
    grep -qE '^hostguard_mutation_allowed\(\)' "${LIB}" \
        && ok "lib: defines hostguard_mutation_allowed" \
        || bad "lib: missing hostguard_mutation_allowed"
    grep -qE '^hostguard_require_host_portage\(\)' "${LIB}" \
        && ok "lib: defines hostguard_require_host_portage" \
        || bad "lib: missing hostguard_require_host_portage"
    grep -qE '^hostguard_require_host_tools\(\)' "${LIB}" \
        && ok "lib: defines hostguard_require_host_tools" \
        || bad "lib: missing hostguard_require_host_tools"
    # THE central asymmetry: `*/* PYTHON_TARGETS ...` is correct in a throwaway
    # container and is a system-wide reconfiguration of a live desktop. The
    # native advice path must never print it. (Comments may discuss it; a LIVE
    # line that emits it is the bug.)
    if grep -vE '^[[:space:]]*#' "${LIB}" | grep -qE '\*/\* PYTHON_TARGETS'; then
        bad "lib: a LIVE line emits the '*/* PYTHON_TARGETS' wildcard — never advise this on a host"
    else
        ok "lib: never advises the '*/* PYTHON_TARGETS' wildcard on a host"
    fi
else
    bad "scripts/_host-guard-lib.sh missing"
fi

# ── CLASS A + B: the 6 ARM builders ─────────────────────────────────
for s in "${ARM[@]}"; do
    f="${GEN}/${s}"
    if [ ! -f "${f}" ]; then bad "${s}: script missing"; continue; fi

    grep -qE '^source "\$\{SCRIPT_DIR\}/scripts/_host-guard-lib\.sh"$' "${f}" \
        && ok "${s}: sources _host-guard-lib.sh" \
        || bad "${s}: does not source _host-guard-lib.sh"

    # CLASS A — the portage seed opens on the container proof, NOT on id -u.
    grep -qE '^if hostguard_mutation_allowed; then$' "${f}" \
        && ok "${s}: Class A seed is container-gated" \
        || bad "${s}: Class A seed lost its hostguard_mutation_allowed gate"
    # ...and the old 2-way gate must NOT be the opener any more. It survives only
    # as the `elif` (native root -> read-only verify), so a bare `if` form means
    # the guard was reverted.
    if grep -qE '^if \[ "\$\(id -u\)" -eq 0 \] && \[ -d /etc/portage \]; then$' "${f}"; then
        bad "${s}: Class A seed still opens on the bare id -u/-d /etc/portage gate (guard reverted)"
    else
        ok "${s}: bare 'id -u + /etc/portage' opener is gone"
    fi
    grep -qE '^elif \[ "\$\(id -u\)" -eq 0 \] && \[ -d /etc/portage \]; then$' "${f}" \
        && ok "${s}: native root falls to the read-only verify branch" \
        || bad "${s}: lost the native-root elif branch"
    grep -qE '^[[:space:]]*hostguard_require_host_portage \|\| exit 1$' "${f}" \
        && ok "${s}: native root verifies read-only (never writes)" \
        || bad "${s}: native root does not call hostguard_require_host_portage"

    # CLASS B — the host emerge.
    grep -qE '^[[:space:]]*if hostguard_mutation_allowed && \[ "\$\(id -u\)" -eq 0 \] && command -v emerge &>/dev/null; then$' "${f}" \
        && ok "${s}: Class B host emerge is container-gated" \
        || bad "${s}: Class B host emerge lost its hostguard gate"
    if grep -qE '^[[:space:]]*if \[ "\$\(id -u\)" -eq 0 \] && command -v emerge &>/dev/null; then$' "${f}"; then
        bad "${s}: Class B still has an UNGATED 'id -u + emerge' condition (guard reverted)"
    else
        ok "${s}: no ungated host-emerge condition remains"
    fi
    # The honest else-branch is the whole point of the one-token Class B fix:
    # a native root host must land on a copy-pasteable emerge, not a silent skip.
    grep -qE '^[[:space:]]*err "Install on the BUILD host' "${f}" \
        && ok "${s}: native root gets the copy-pasteable emerge line" \
        || bad "${s}: lost the 'Install on the BUILD host' else-branch"

    # The wildcard must still be present in the CONTAINER seed body (it is why
    # fleet builds work); this asserts the restructure did not drop it.
    grep -qE '^\*/\* PYTHON_TARGETS: python3_12 python3_13$' "${f}" \
        && ok "${s}: container seed still carries the PYTHON_TARGETS line" \
        || bad "${s}: container seed LOST '*/* PYTHON_TARGETS: python3_12 python3_13'"
done

# ── CLASS A (cont): the separate cross-host-selinux seed ────────────
# NOT 5-way symmetric — only jetson and rpi5 have a separate block; frite/opi5/
# zero2 carry the same two USE lines inside their Class-A heredoc. Assert only
# what actually exists, or this guard rots into a false alarm.
if [ -f "${GEN}/build-jetson-stage4.sh" ]; then
    grep -qE '^if \[ "\$\{ROLE_K8S\}" != "none" \] && hostguard_mutation_allowed && \[ "\$\(id -u\)" -eq 0 \]; then$' \
        "${GEN}/build-jetson-stage4.sh" \
        && ok "jetson: cross-host-selinux seed is container-gated" \
        || bad "jetson: cross-host-selinux seed lost its hostguard gate"
fi
if [ -f "${GEN}/build-rpi5-stage4.sh" ]; then
    grep -qE '^if hostguard_mutation_allowed && \[ "\$\(id -u\)" -eq 0 \]; then$' \
        "${GEN}/build-rpi5-stage4.sh" \
        && ok "rpi5: cross-host-selinux seed is container-gated" \
        || bad "rpi5: cross-host-selinux seed lost its hostguard gate"
fi
# Nothing may write a HOST /etc/portage path from a live line without the gate.
# (Sysroot writes go to ${SYSROOT}/etc/portage and are correctly out of scope.)
#
# This CONTAINMENT check replaces a counting assertion that shipped in review and
# was vacuous: it counted writes and gates but only asserted `n_gate >= 1`, so a
# brand-new UNGATED `cat > /etc/portage/package.mask/evil` — the exact class of bug
# under repair — sailed through while the message claimed containment. The specific
# greps above catch a REVERT of the known gates; this catches an ADDED site, which
# is precisely how the hazard entered (#380 appended new lines to the seed).
#
# Each write must be INSIDE a hostguard-gated block, not merely co-resident with
# one. The ARM seeds are top-level blocks (`if ... hostguard_mutation_allowed ...
# then` / `elif` / `else` / `fi` all at column 0), so track that nesting: a
# column-0 gated `if` opens containment; a column-0 `elif`/`else`/`fi` closes it
# (the native-root `elif` is READ-ONLY and must never contain a write).
for s in "${ARM[@]}"; do
    f="${GEN}/${s}"; [ -f "${f}" ] || continue
    # The HOST-vs-SYSROOT distinction is the whole point: a HOST write names the
    # LITERAL absolute path (`cat > /etc/portage/...`), while the in-scope-for-
    # nothing sysroot writes name `"${SYSROOT}/etc/portage/...`. Anchor on
    # /etc/portage preceded by whitespace (or line start) so an expansion prefix
    # like ${SYSROOT} never counts as a host write, and a literal one always does.
    ungated="$(awk '
        /^[[:space:]]*#/                          { next }
        /^if .*hostguard_mutation_allowed.*then$/ { gated=1; next }
        /^(elif|else|fi)/                         { gated=0 }
        /^[[:space:]]*(cat >|mkdir -p|tee |install -[Dm]|rm |ln -)/ &&
        /(^|[[:space:]])\/etc\/portage/ {
            if (!gated) print NR": "$0
        }
    ' "${f}")"
    n_open="$(grep -cE '^[[:space:]]*(cat >|mkdir -p) /etc/portage' "${f}" || true)"
    if [ -z "${ungated}" ]; then
        ok "${s}: all ${n_open} host /etc/portage write(s) are INSIDE a hostguard-gated block"
    else
        bad "${s}: UNGATED host /etc/portage write(s):"
        printf '        %s\n' "${ungated}" >&2
    fi
done

# ── CLASS C: kernel-global binfmt_misc ──────────────────────────────
if [ -f "${DXC}" ]; then
    grep -qE '^source "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/_host-guard-lib\.sh"$' "${DXC}" \
        && ok "_dracut-cross-lib.sh: sources the host guard itself" \
        || bad "_dracut-cross-lib.sh: does not source _host-guard-lib.sh"
    grep -qE '^[[:space:]]*if ! hostguard_mutation_allowed; then$' "${DXC}" \
        && ok "_dracut-cross-lib.sh: binfmt write half is container-gated" \
        || bad "_dracut-cross-lib.sh: binfmt mount/register is NOT container-gated"
    # The gate must precede the mount, or the mutation happens anyway.
    g="$(grep -nE '^[[:space:]]*if ! hostguard_mutation_allowed; then$' "${DXC}" | head -1 | cut -d: -f1)"
    m="$(grep -nE '^[[:space:]]*mount -t binfmt_misc none' "${DXC}" | head -1 | cut -d: -f1)"
    if [ -n "${g}" ] && [ -n "${m}" ] && [ "${g}" -lt "${m}" ]; then
        ok "_dracut-cross-lib.sh: gate (line ${g}) precedes the binfmt mount (line ${m})"
    else
        bad "_dracut-cross-lib.sh: gate does not precede the binfmt mount (gate=${g:-none} mount=${m:-none})"
    fi
    # Contract: the function must stay NON-FATAL (always return 0) — callers'
    # fail-fast preflights report the real problem at the right altitude.
    if awk '/^dracut_cross_register_qemu\(\)/{g=1} g{print} g&&/^}$/{exit}' "${DXC}" \
         | grep -qE '^[[:space:]]*exit [0-9]'; then
        bad "_dracut-cross-lib.sh: register_qemu gained an exit — breaks its non-fatal contract"
    else
        ok "_dracut-cross-lib.sh: register_qemu stays non-fatal (no exit)"
    fi
else
    bad "scripts/_dracut-cross-lib.sh missing"
fi

# ── CLASS D: host-tool honesty ──────────────────────────────────────
for s in build-x86-host-stage4.sh build-frite-stage4.sh build-orangepi5-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh build-jetson-stage4.sh; do
    f="${GEN}/${s}"; [ -f "${f}" ] || { bad "${s}: script missing"; continue; }
    grep -qE '^[[:space:]]*(if ! )?hostguard_require_host_tools ' "${f}" \
        && ok "${s}: preflights host tools via hostguard_require_host_tools" \
        || bad "${s}: no hostguard_require_host_tools preflight"
done
# x86 must source the lib (it has no ARM source line to piggyback on).
grep -qE '^source "\$\{SCRIPT_DIR\}/scripts/_host-guard-lib\.sh"$' "${GEN}/build-x86-host-stage4.sh" \
    && ok "build-x86-host-stage4.sh: sources _host-guard-lib.sh" \
    || bad "build-x86-host-stage4.sh: does not source _host-guard-lib.sh"
# The squasher is the proven gap (measured ABSENT on the operator's host while
# PRESENT in the builder image), so assert the alternatives group survives.
for s in build-x86-host-stage4.sh build-frite-stage4.sh build-orangepi5-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh; do
    f="${GEN}/${s}"; [ -f "${f}" ] || continue
    grep -qE '^[[:space:]]*(-- )?"mksquashfs\|tar2sqfs"' "${f}" \
        && ok "${s}: squasher (mksquashfs|tar2sqfs) is preflighted" \
        || bad "${s}: lost the mksquashfs|tar2sqfs preflight"
done

# ── CLASS D (cont): argv purity + the soft/hard split ───────────────
# The <emerge-atoms> arg is interpolated into `emerge ${atoms}`, so it is ARGV,
# not prose. It shipped in review as "sys-fs/squashfs-tools   (or ...-ng for
# tar2sqfs)", whose "copy-pasteable" line was a bash SYNTAX ERROR on paste — and
# mksquashfs is the ONE tool proven absent on the operator's host, so that is the
# message most likely to be seen for real. Prose belongs in --hint (free text).
for s in build-x86-host-stage4.sh build-frite-stage4.sh build-orangepi5-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh build-jetson-stage4.sh; do
    f="${GEN}/${s}"; [ -f "${f}" ] || continue
    # PARSE the atoms arg, don't pattern-match near it. (A first cut here used
    # `grep -q ... | grep -v ...` — a dead pipeline, since -q exits before writing
    # — and PASSED against the exact prose-in-argv string it names. Mutation-proven
    # vacuous, rewritten to this. Same hole class as #380's unanchored log grep.)
    # Join backslash-continuations, then take the SECOND quoted field of each call:
    # arg1 = label (free text), arg2 = emerge atoms (ARGV), arg3+ = --hint/tools.
    bad_atoms=""
    while IFS= read -r call; do
        [ -n "${call}" ] || continue
        atoms="$(printf '%s\n' "${call}" | grep -oE '"[^"]*"' | sed -n '2p' | tr -d '"')"
        [ -n "${atoms}" ] || continue
        # A portage atom set is bare atoms + spaces. Anything else (parentheses,
        # pipes, backticks, $) is prose or injection and breaks `emerge ${atoms}`.
        case "${atoms}" in
            *[!a-zA-Z0-9/+._@\ -]*) bad_atoms="${bad_atoms} [${atoms}]" ;;
        esac
    done < <(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "${f}" \
             | grep -E '(^|[[:space:]!])hostguard_require_host_tools[[:space:]]')
    if [ -n "${bad_atoms}" ]; then
        bad "${s}: emerge-atoms arg is not argv-pure — 'emerge' would not parse it:${bad_atoms}"
    else
        ok "${s}: emerge-atoms args are argv-pure (prose lives in --hint)"
    fi
done
# The x86 --installer-iso site MUST stay --soft: a missing xorriso does not lose
# the artifact, it leaves an installable TREE that the build reports as a
# first-class deliverable ("(tree; no xorriso to wrap an ISO)"). Shipping this
# site WITHOUT --soft turned a native build that SUCCEEDS today into exit 1.
if [ -f "${GEN}/build-x86-host-stage4.sh" ]; then
    grep -qE '^[[:space:]]*if ! hostguard_require_host_tools "--installer-iso" "dev-libs/libisoburn" --soft -- xorriso; then$' \
        "${GEN}/build-x86-host-stage4.sh" \
        && ok "x86: --installer-iso preflight is --soft (tree fallback survives)" \
        || bad "x86: --installer-iso preflight lost --soft — a missing xorriso now KILLS a build that used to leave a tree"
fi
# ...and the ARM LIVE-only xorriso sites likewise leave a tree.
for s in build-frite-stage4.sh build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh; do
    f="${GEN}/${s}"; [ -f "${f}" ] || continue
    grep -qE '^[[:space:]]*hostguard_require_host_tools "the LIVE ISO" "dev-libs/libisoburn" --soft \\$' "${f}" \
        && ok "${s}: LIVE-only xorriso preflight is --soft (tree fallback survives)" \
        || bad "${s}: LIVE-only xorriso preflight is not --soft (would kill a build that leaves a tree)"
done
# The lib must actually implement --soft as NON-EXITING, or the flag is a lie.
if [ -f "${LIB}" ]; then
    if awk '/^hostguard_require_host_tools\(\)/{g=1} g{print} g&&/^}$/{exit}' "${LIB}" \
         | grep -vE '^[[:space:]]*#' | grep -qE '^[[:space:]]*if \[ "\$\{soft\}" -eq 1 \]; then$'; then
        ok "lib: hostguard_require_host_tools implements a non-exiting --soft branch"
    else
        bad "lib: --soft branch is gone — soft sites would exit and kill working builds"
    fi
fi

# ── lib <-> Dockerfile marker sync ──────────────────────────────────
# The builders' host blocks and the image must not drift: the path the lib
# accepts as a container proof must be the path the image actually bakes.
if [ -f "${DOCKERFILE}" ] && [ -f "${LIB}" ]; then
    LIB_MARKER="$(grep -E '^HOSTGUARD_MARKER_FILE="' "${LIB}" | head -1 | sed -e 's/^[^"]*"//' -e 's/"$//')"
    if [ -n "${LIB_MARKER}" ]; then
        ok "lib: marker constant is ${LIB_MARKER}"
        grep -qE "^[[:space:]]*> ${LIB_MARKER}\$" "${DOCKERFILE}" \
            && ok "Dockerfile.build: bakes ${LIB_MARKER}" \
            || bad "Dockerfile.build: does not bake the lib's marker (${LIB_MARKER})"
    else
        bad "lib: HOSTGUARD_MARKER_FILE constant not found"
    fi
    grep -qE '^LABEL org\.hugmesh\.builder-container="1"$' "${DOCKERFILE}" \
        && ok "Dockerfile.build: carries the auditable builder-container LABEL" \
        || bad "Dockerfile.build: lost the builder-container LABEL"
    # The marker must be baked in the FINAL stage, after the last crossdev-heavy
    # stage boundary, or it invalidates the hours-long cached layers.
    last_from="$(grep -nE '^FROM ' "${DOCKERFILE}" | tail -1 | cut -d: -f1 || true)"
    # The marker write is a backslash-continued RUN, so anchor on the redirect
    # line itself (the `> /etc/hugmesh-builder-container` target).
    marker_ln="$(grep -nE "^[[:space:]]*> ${LIB_MARKER}\$" "${DOCKERFILE}" | head -1 | cut -d: -f1 || true)"
    if [ -n "${last_from}" ] && [ -n "${marker_ln}" ] && [ "${marker_ln}" -gt "${last_from}" ]; then
        ok "Dockerfile.build: marker is baked in the FINAL stage (line ${marker_ln} > FROM ${last_from})"
    else
        bad "Dockerfile.build: marker is not in the FINAL stage (marker=${marker_ln:-none} lastFROM=${last_from:-none})"
    fi
else
    bad "Dockerfile.build or _host-guard-lib.sh missing"
fi

# ── behavioural: the predicate actually decides correctly ───────────
# Source the lib and drive hostguard_in_container against a FAKE root, so this
# tests behavior rather than text. Never touches the real / .
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
if [ -f "${LIB}" ]; then
    # `rc=0; ( ... ) || rc=$?` — NOT a bare `( ... )` followed by `rc=$?`. Under
    # this file's `set -e` a bare failing subshell ABORTS the suite before rc is
    # ever read, so a misbehaving predicate would kill the run (exit == the probe
    # code) instead of printing a FAIL and letting the remaining assertions report.
    # Mutation-proven: re-adding the $container arm exited the suite with 17 and
    # printed no summary until this form landed.
    rc=0
    # shellcheck source=/dev/null
    ( set +u; source "${LIB}"
      # Point the markers at a scratch dir: all absent -> must report HOST.
      HOSTGUARD_DOCKER_MARKER="${TMP}/dockerenv"
      HOSTGUARD_PODMAN_MARKER="${TMP}/containerenv"
      HOSTGUARD_MARKER_FILE="${TMP}/marker"
      unset container
      if hostguard_in_container; then exit 10; fi          # must NOT claim container
      if hostguard_mutation_allowed; then exit 11; fi       # must NOT allow mutation
      : > "${HOSTGUARD_DOCKER_MARKER}"
      if ! hostguard_in_container; then exit 12; fi         # /.dockerenv -> container
      if ! hostguard_mutation_allowed; then exit 13; fi
      rm -f "${HOSTGUARD_DOCKER_MARKER}"
      if hostguard_in_container; then exit 14; fi
      # Override: NOT a container, but mutation explicitly allowed + warned.
      if ! HUGMESH_ASSUME_CONTAINER=1 hostguard_mutation_allowed 2>/dev/null; then exit 15; fi
      # ...and the override must never make in_container lie.
      if HUGMESH_ASSUME_CONTAINER=1 hostguard_in_container; then exit 16; fi
      # THE FORGEABLE-ENV CASE. With every file marker absent (= a real host), an
      # exported `container=` must NOT buy a container verdict and must NOT
      # authorize mutation. This is the arm cut in review after it was proven to
      # write the wildcard silently on a marker-less root.
      if container=docker hostguard_in_container;       then exit 17; fi
      if container=docker hostguard_mutation_allowed;   then exit 18; fi
      if container=podman hostguard_mutation_allowed;   then exit 19; fi
      if container=systemd-nspawn hostguard_mutation_allowed; then exit 20; fi
      exit 0 ) || rc=$?
    [ "${rc}" -eq 0 ] \
        && ok "lib: predicate behaves (absent->host, /.dockerenv->container, override is mutation-only, \$container never authorizes)" \
        || bad "lib: predicate misbehaved (probe exit ${rc})"
fi

echo "== host-mutation-guard: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
