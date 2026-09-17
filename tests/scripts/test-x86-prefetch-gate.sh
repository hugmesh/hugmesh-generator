#!/usr/bin/env bash
# test-x86-prefetch-gate.sh — the payload PRE-FETCH pass, EXECUTED.
#
# Issue #322 slice 2 (decision 24 on #347: "A: fetch everything first"). Slice 1
# (PR #393, tests/scripts/test-x86-fetchcommand-bound.sh) put a measured rate
# floor under each individual URI; this suite covers the pass that runs the whole
# payload's downloads BEFORE the first merge, so an unfetchable file is a loud
# failure in minute two rather than a package silently dropped by --keep-going
# and discovered hours later at the requested-atom completeness gate.
#
# WHAT IS ACTUALLY RUN. scripts/_emerge-prefetch-lib.sh is SOURCED — the real
# file, not a copy — and driven against a STUB `emerge` on PATH that reproduces
# portage's own output shapes: a clean fetch, a fetch failure naming a distfile,
# a resolver wall, a transient failure that clears on retry, and a bare non-zero
# exit with no recognisable text. No portage, no network, no chroot, no root.
#
# Plus the CALL-SITE pins: a lib nothing calls is the defect this repo keeps
# finding (the one-line `bake_vault_conf` deletion that left every gate green).
# The staging cp, the in-chroot source, the call itself, its position BEFORE the
# first merge, its argument parity with the two real merges, and the
# --allow-missing-packages branch are each pinned against the builder text.
#
# HOST TRAPS this file is written against: no `| grep -q` under pipefail (drain
# to /dev/null and branch on the status); `grep -a` everywhere (grep fails OPEN
# on a NUL byte); one name per `local` (bash 5.3 localises before assigning);
# every dynamic leg runs under `timeout` so a REGRESSION fails the job instead of
# parking it for six hours (the landing finding on PR #393).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TEST_DIR}/../.." && pwd)"
LIB="${REPO}/scripts/_emerge-prefetch-lib.sh"
BUILDER="${REPO}/build-x86-host-stage4.sh"
WALL="${WALL:-30}"          # per-leg wall clock; the whole suite is sub-second

P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }

TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR}"' EXIT

[ -f "${LIB}" ] || { echo "MISSING: ${LIB}"; exit 2; }
[ -f "${BUILDER}" ] || { echo "MISSING: ${BUILDER}"; exit 2; }

echo "== payload pre-fetch: the lib, executed =="

# ── the stub emerge ──────────────────────────────────────────────────────────
# MODE is read from a file, not the environment, so the "transient" mode can
# flip itself between attempts — that is what proves the retry loop re-runs the
# fetcher rather than re-reading a cached verdict.
mkdir -p "${TDIR}/bin"
cat > "${TDIR}/bin/emerge" <<'STUB'
#!/usr/bin/env bash
mode="$(cat "${STUB_STATE}/mode" 2>/dev/null || echo ok)"
n="$(cat "${STUB_STATE}/calls" 2>/dev/null || echo 0)"
n=$((n+1)); echo "${n}" > "${STUB_STATE}/calls"
printf '%s\n' "$*" >> "${STUB_STATE}/argv"
case "${mode}" in
  ok)
    echo ">>> Fetching (1 of 3) media-fonts/noto-20260701"
    echo ">>> Fetching (2 of 3) sys-apps/portage-3.0.82.2"
    exit 0 ;;
  fetch)
    echo ">>> Fetching (1 of 3) media-fonts/noto-20260701"
    echo "!!! Couldn't download 'noto-20260701.tar.gz'. Aborting."
    echo "!!! Fetch failed for 'media-fonts/noto-20260701', Log file:"
    exit 1 ;;
  resolve)
    echo "!!! All ebuilds that could satisfy \"dev-qt/qtbase\" have been masked."
    echo "The following keyword changes are necessary to proceed:"
    exit 1 ;;
  transient)
    if [ "${n}" -lt 2 ]; then
      echo "!!! Couldn't download 'noto-20260701.tar.gz'. Aborting."
      exit 1
    fi
    echo ">>> Fetching (1 of 3) media-fonts/noto-20260701"
    exit 0 ;;
  silent)
    echo "something went wrong in a way portage did not spell out"
    exit 1 ;;
esac
exit 0
STUB
chmod +x "${TDIR}/bin/emerge"

# run_prefetch <mode> -> prints the captured output; returns the lib's verdict
run_prefetch() {
    local mode
    mode="$1"
    rm -rf "${TDIR}/state"; mkdir -p "${TDIR}/state"
    echo "${mode}" > "${TDIR}/state/mode"
    STUB_STATE="${TDIR}/state" \
    PATH="${TDIR}/bin:${PATH}" \
    HUGMESH_PREFETCH_RETRY_DELAY=0 \
    HUGMESH_PREFETCH_ATTEMPTS=3 \
    HUGMESH_PREFETCH_LOG="${TDIR}/state/prefetch.log" \
    timeout "${WALL}" bash -c '
        set -uo pipefail
        . "$1"
        hugmesh_prefetch_payload --update --deep --newuse --keep-going @world sys-apps/foo
    ' bash "${LIB}" 2>&1
}

# ── A1: a clean fetch ────────────────────────────────────────────────────────
OUT="$(run_prefetch ok)"; RC=$?
[ "${RC}" -eq 0 ] && ok "a1: a clean pre-fetch returns 0" \
  || bad "a1: a clean pre-fetch returned ${RC}"
printf '%s' "${OUT}" | grep -a "Pre-fetch OK" >/dev/null \
  && ok "a1: it says so in one greppable line" || bad "a1: no 'Pre-fetch OK' line"
[ "$(cat "${TDIR}/state/calls")" = "1" ] \
  && ok "a1: exactly ONE emerge invocation (no pointless retry on success)" \
  || bad "a1: ${TDIR}/state/calls = $(cat "${TDIR}/state/calls") (want 1)"

# ── A2: an unfetchable distfile is FATAL, named, and the partial is untouched ─
# the fixture partial lives OUTSIDE ${TDIR}/state, which run_prefetch resets
# between legs — putting it there made this probe pass for the wrong reason
# (the harness deleted it, not the lib).
mkdir -p "${TDIR}/distdir"
touch "${TDIR}/distdir/noto-20260701.tar.gz.__download__"
OUT="$(run_prefetch fetch)"; RC=$?
[ "${RC}" -ne 0 ] && ok "a2: an unfetchable distfile FAILS the pass (rc=${RC})" \
  || bad "a2: an unfetchable distfile returned 0 — the gate failed OPEN"
printf '%s' "${OUT}" | grep -a "noto-20260701.tar.gz" >/dev/null \
  && ok "a2: the failing distfile is NAMED in the error" \
  || bad "a2: the error does not name the file"
# ERROR block specifically: the retry WARN line also mentions the partial, so a
# whole-output grep stayed GREEN when the final advice was deleted (measured).
printf '%s' "${OUT}" | grep -a "ERROR:" | grep -a "__download__" >/dev/null \
  && ok "a2: the FINAL error tells the operator not to delete the partial" \
  || bad "a2: the error block does not warn against deleting the .__download__"
[ -f "${TDIR}/distdir/noto-20260701.tar.gz.__download__" ] \
  && ok "a2: the pass removed NOTHING from the fixture DISTDIR" \
  || bad "a2: a partial download was deleted"
[ "$(cat "${TDIR}/state/calls")" = "3" ] \
  && ok "a2: a fetch failure is RETRIED to the configured attempt count (3)" \
  || bad "a2: ${TDIR}/state/calls attempts (want 3)"

# ── A3: a resolver wall is a loud SKIP, never a retry, never a build failure ──
OUT="$(run_prefetch resolve)"; RC=$?
[ "${RC}" -eq 0 ] && ok "a3: a resolver wall returns 0 (the merge crosses it; #223 judges it)" \
  || bad "a3: a resolver wall failed the build (rc=${RC})"
printf '%s' "${OUT}" | grep -a "PRE-FETCH SKIPPED" >/dev/null \
  && ok "a3: it is LOUD about having downloaded nothing" \
  || bad "a3: the skip is silent"
printf '%s' "${OUT}" | grep -a "UNPROTECTED" >/dev/null \
  && ok "a3: it says the build continues without the pre-fetch floor" \
  || bad "a3: the honest limit is not stated"
[ "$(cat "${TDIR}/state/calls")" = "1" ] \
  && ok "a3: a resolver wall is NOT retried (retrying cannot change a slot conflict)" \
  || bad "a3: retried a resolver wall $(cat "${TDIR}/state/calls") times"

# ── A4: a transient failure clears on the retry ──────────────────────────────
OUT="$(run_prefetch transient)"; RC=$?
[ "${RC}" -eq 0 ] && ok "a4: a transient fetch failure clears on attempt 2" \
  || bad "a4: transient failure was fatal (rc=${RC})"
[ "$(cat "${TDIR}/state/calls")" = "2" ] \
  && ok "a4: exactly two invocations — the retry really re-ran the fetcher" \
  || bad "a4: $(cat "${TDIR}/state/calls") invocations (want 2)"

# ── A5: a bare non-zero exit with no recognisable text still FAILS ───────────
# This is the tee/PIPESTATUS fail-open: `tee` always exits 0, so a lib reading
# `$?` instead of PIPESTATUS[0] would call every one of these a success.
OUT="$(run_prefetch silent)"; RC=$?
[ "${RC}" -ne 0 ] && ok "a5: an unexplained non-zero emerge FAILS (no tee fail-open)" \
  || bad "a5: an unexplained non-zero emerge passed — PIPESTATUS is not being read"

# ── A5b: the verdict must not DEPEND on pipefail ─────────────────────────────
# The production chroot runs `bash -eo pipefail`, where a plain `$?` after
# `emerge | tee` happens to be right. That is what makes this worth an explicit
# leg: with pipefail OFF, `$?` is tee's 0 and every unfetchable file passes.
# Measured — a `rc="$?"` mutation survived the whole suite until this existed.
run_prefetch_nopipefail() {
    rm -rf "${TDIR}/state"; mkdir -p "${TDIR}/state"
    echo "$1" > "${TDIR}/state/mode"
    STUB_STATE="${TDIR}/state" \
    PATH="${TDIR}/bin:${PATH}" \
    HUGMESH_PREFETCH_RETRY_DELAY=0 \
    HUGMESH_PREFETCH_ATTEMPTS=1 \
    HUGMESH_PREFETCH_LOG="${TDIR}/state/prefetch.log" \
    timeout "${WALL}" bash -c '
        set +o pipefail
        . "$1"
        hugmesh_prefetch_payload --update --deep --newuse --keep-going @world sys-apps/foo
    ' bash "${LIB}" 2>&1
}
OUT="$(run_prefetch_nopipefail fetch)"; RC=$?
[ "${RC}" -ne 0 ] \
  && ok "a5b: an unfetchable distfile FAILS with pipefail OFF too (PIPESTATUS, not \$?)" \
  || bad "a5b: with pipefail off the pass returned 0 — the tee status is being read"
OUT="$(run_prefetch_nopipefail ok)"; RC=$?
[ "${RC}" -eq 0 ] \
  && ok "a5b: control — a clean fetch still passes with pipefail off" \
  || bad "a5b: a clean fetch failed with pipefail off (rc=${RC})"

# ── A5c: it is safe under the production shell (`bash -eo pipefail`) ─────────
# The chroot heredoc runs `bash -eo pipefail`. A bare failing pipeline inside the
# lib would abort the whole chroot with no message; the caller's `if` and the
# lib's own `if` are what keep the failure a RETURN VALUE.
run_prefetch_prodshell() {
    rm -rf "${TDIR}/state"; mkdir -p "${TDIR}/state"
    echo "$1" > "${TDIR}/state/mode"
    STUB_STATE="${TDIR}/state" \
    PATH="${TDIR}/bin:${PATH}" \
    HUGMESH_PREFETCH_RETRY_DELAY=0 \
    HUGMESH_PREFETCH_ATTEMPTS=1 \
    HUGMESH_PREFETCH_LOG="${TDIR}/state/prefetch.log" \
    timeout "${WALL}" bash -eo pipefail -c '
        . "$1"
        if hugmesh_prefetch_payload --update --deep --newuse --keep-going @world sys-apps/foo; then
            echo "VERDICT=pass"
        else
            echo "VERDICT=fail"
        fi
        echo "REACHED_END=yes"
    ' bash "${LIB}" 2>&1
}
OUT="$(run_prefetch_prodshell fetch)"
printf '%s' "${OUT}" | grep -a "VERDICT=fail" >/dev/null \
  && ok "a5c: under bash -eo pipefail the failure is a RETURN VALUE, not an abort" \
  || bad "a5c: no VERDICT line — set -e aborted the caller instead"
printf '%s' "${OUT}" | grep -a "REACHED_END=yes" >/dev/null \
  && ok "a5c: the caller keeps running after a failed pre-fetch (it decides fatality)" \
  || bad "a5c: the caller never reached its next statement"

# ── A6: the classifier, directly ─────────────────────────────────────────────
classify_of() {
    printf '%s\n' "$2" > "${TDIR}/c.log"
    ( . "${LIB}"; hugmesh_prefetch_classify "${TDIR}/c.log" )
}
[ "$(classify_of x "!!! Couldn't download 'a.tar.gz'. Aborting.")" = "fetch" ] \
  && ok "a6: 'Couldn't download' classifies as fetch" || bad "a6: fetch misclassified"
[ "$(classify_of x "The following keyword changes are necessary to proceed:")" = "resolve" ] \
  && ok "a6: a keyword wall classifies as resolve" || bad "a6: resolve misclassified"
[ "$(classify_of x "nothing recognisable here")" = "unknown" ] \
  && ok "a6: unrecognised output classifies as unknown (never as a pass)" \
  || bad "a6: unknown misclassified"
[ "$(( $(. "${LIB}" >/dev/null 2>&1; hugmesh_prefetch_classify /nonexistent-log >/dev/null 2>&1; echo 0) ))" = "0" ] \
  && ok "a6: a missing log does not crash the classifier" || bad "a6: classifier crashed"

# ── A7: nothing in the lib removes a DISTDIR partial ─────────────────────────
if grep -aE '(^|[^[:alnum:]_])rm[[:space:]]' "${LIB}" | grep -av '^[[:space:]]*#' | grep -a . >/dev/null; then
    bad "a7: the lib contains an rm outside a comment"
else
    ok "a7: the lib contains no rm at all (a partial is cleared by killing the fetcher)"
fi

echo "== payload pre-fetch: the CALL SITES in the builder =="

# ── A8: staged, sourced, called ──────────────────────────────────────────────
grep -a 'scripts/_emerge-prefetch-lib.sh' "${BUILDER}" >/dev/null \
  && ok "a8: the builder STAGES the lib into the sysroot" \
  || bad "a8: the lib is never staged"
grep -a '\. /tmp/hugmesh-emerge-prefetch-lib.sh' "${BUILDER}" >/dev/null \
  && ok "a8: the builder SOURCES it inside the chroot" \
  || bad "a8: the lib is never sourced in-chroot"
grep -a 'hugmesh_prefetch_payload ' "${BUILDER}" >/dev/null \
  && ok "a8: the builder CALLS hugmesh_prefetch_payload" \
  || bad "a8: the lib is staged and sourced but never CALLED (the inert-feature defect)"
# a failed staging cp must be FATAL — a silently-skipped pre-fetch is the whole bug
grep -a -A2 'cp "\${SCRIPT_DIR}/scripts/_emerge-prefetch-lib.sh"' "${BUILDER}" \
  | grep -a 'exit 1' >/dev/null \
  && ok "a8: a failed staging cp aborts the build (never a silent skip)" \
  || bad "a8: staging failure degrades silently"

# ── A9: it runs BEFORE every PAYLOAD merge, and AFTER the overlay sync ───────
# Placement is not cosmetic, and the ORIGINAL placement (directly above the
# system group) made the pass a guaranteed no-op on the default build: --steam
# native is the default and --role standalone-thick sets ROLE_CLIENT, so
# games-util/steam-launcher is inside ${PKGS} — and it lives in the steam-overlay,
# which nothing enables until ${STEAM_OVERLAY_SETUP} runs. Resolving above that
# ends in "there are no ebuilds to satisfy", the lib classifies it as a resolver
# wall, and the pass prints "PRE-FETCH SKIPPED" and returns 0. Both bounds, so
# neither direction can drift.
call_ln="$(grep -an '^if hugmesh_prefetch_payload ' "${BUILDER}" | head -n1 | cut -d: -f1)"
ovl_ln="$(grep -an '^\${STEAM_OVERLAY_SETUP}$' "${BUILDER}" | head -n1 | cut -d: -f1)"
world_ln="$(grep -an '^emerge --update --deep --newuse --keep-going --exclude sys-apps/portage' "${BUILDER}" | head -n1 | cut -d: -f1)"
image_ln="$(grep -an '^echo "==> Emerge group: image"' "${BUILDER}" | head -n1 | cut -d: -f1)"
if [ -n "${call_ln}" ] && [ -n "${ovl_ln}" ] && [ "${call_ln}" -gt "${ovl_ln}" ]; then
    ok "a9: the pre-fetch call (line ${call_ln}) runs AFTER the steam-overlay sync (line ${ovl_ln}), so an overlay atom in \${PKGS} can resolve"
else
    bad "a9: call=${call_ln:-<none>} overlay=${ovl_ln:-<none>} — resolving before the overlay sync makes the pass a guaranteed PRE-FETCH SKIPPED on every default --steam native build"
fi
if [ -n "${call_ln}" ] && [ -n "${world_ln}" ] && [ "${call_ln}" -lt "${world_ln}" ]; then
    ok "a9: it precedes the @world merge (line ${world_ln})"
else
    bad "a9: call=${call_ln:-<none>} world=${world_ln:-<none>} — the pre-fetch does not precede the world payload"
fi
if [ -n "${call_ln}" ] && [ -n "${image_ln}" ] && [ "${call_ln}" -lt "${image_ln}" ]; then
    ok "a9: it precedes the image group (line ${image_ln})"
else
    bad "a9: call=${call_ln:-<none>} image=${image_ln:-<none>} — the pre-fetch does not precede the role payload"
fi
# and the fact the placement rests on: steam-launcher really is in the payload
# and really is overlay-only, so this leg fails loudly if either ever changes.
if grep -a 'packages-steam-native.list' "${BUILDER}" >/dev/null \
   && grep -a 'games-util/steam-launcher' "${REPO}/specs-x86/portage/packages-steam-native.list" >/dev/null; then
    if grep -ra 'steam-overlay' "${REPO}/specs-x86/portage/repos.conf" >/dev/null 2>&1; then
        ok "a9: steam-overlay is pre-seeded in specs-x86 — the ordering bound above is belt-and-braces"
    else
        ok "a9: games-util/steam-launcher is in \${PKGS} and the overlay is NOT pre-seeded in specs-x86 — the ordering bound above is load-bearing"
    fi
else
    bad "a9: the steam-native payload premise no longer holds — re-derive the pre-fetch placement"
fi

# ── A10: argument parity with the two real merges ────────────────────────────
# The graph fetched must be the graph merged. Read the call's own argv out of the
# builder rather than restating it here.
call_argv="$(sed -n "${call_ln:-1},$(( ${call_ln:-1} + 1 ))p" "${BUILDER}" | tr '\n' ' ')"
parity_ok=true
for tok in -- '--update' '--deep' '--newuse' '--keep-going' '--exclude sys-apps/portage' '${EMERGE_EXCLUDE}' '@world' '${PKGS}'; do
    [ "${tok}" = "--" ] && continue
    case "${call_argv}" in
        *"${tok}"*) ;;
        *) bad "a10: the pre-fetch argv is missing '${tok}' — it would resolve a different graph than the merge"; parity_ok=false ;;
    esac
done
${parity_ok} && ok "a10: the pre-fetch argv carries every resolver flag the two real merges use, and both sets"
case "${call_argv}" in
    *autounmask*) bad "a10: the pre-fetch passes an autounmask flag — it would write package.use against the PRE-update portage" ;;
    *) ok "a10: it passes NO autounmask flag (deliberate; the lib explains why)" ;;
esac

# ── A11: --allow-missing-packages is the one honoured opt-out ────────────────
grep -a 'HUGMESH_ALLOW_MISSING_PACKAGES=\${ALLOW_MISSING_PACKAGES}' "${BUILDER}" >/dev/null \
  && ok "a11: the host's --allow-missing-packages is carried into the chroot" \
  || bad "a11: ALLOW_MISSING_PACKAGES never reaches the chroot (the opt-out is inert)"
grep -a 'HUGMESH_ALLOW_MISSING_PACKAGES.*= *"true"' "${BUILDER}" >/dev/null \
  && ok "a11: a pre-fetch failure is non-fatal under --allow-missing-packages" \
  || bad "a11: the opt-out branch is missing"
grep -a -A9 '^if hugmesh_prefetch_payload ' "${BUILDER}" | grep -a 'exit 1' >/dev/null \
  && ok "a11: without it, a pre-fetch failure ABORTS before the first merge" \
  || bad "a11: a pre-fetch failure does not abort the build"

# ── A12: the lib's OWN emerge argv — the pass must FETCH, not merge ─────────
# Nothing above reads the lib's own command line: A10 reads the BUILDER's call
# line. Deleting "--fetchonly " from the lib turns this pass into a real merge of
# @world + ${PKGS} executed before the portage self-update, the baselayout
# update, the gettext downgrade and the steam-overlay sync — and every other leg
# in this file stays green, because the stub emerge does not care what it is
# asked to do. Read the real emerge invocation out of the lib and pin it.
lib_emerge="$(grep -a '"\${HUGMESH_PREFETCH_EMERGE}"' "${LIB}" | head -n1)"
case "${lib_emerge}" in
    *--fetchonly*) ok "a12: the lib invokes emerge with --fetchonly (it downloads; it never merges)" ;;
    *) bad "a12: the lib's emerge argv has NO --fetchonly — this pass would MERGE the whole payload before the system group: ${lib_emerge}" ;;
esac
case "${lib_emerge}" in
    *--pretend*|*-p\ *) bad "a12: the lib passes --pretend — it would resolve and download NOTHING while reporting success" ;;
    *) ok "a12: it does not degrade to --pretend" ;;
esac
# 2>&1 is what puts portage's ERROR text (which goes to stderr) in front of the
# classifier. Without it a resolver wall classifies as "unknown", which means 3
# attempts with sleeps and then a FALSE abort of the build.
case "${lib_emerge}" in
    *2\>\&1*) ok "a12: stderr is folded into the captured log, so the classifier can see portage's error text" ;;
    *) bad "a12: the lib does not redirect stderr into the log — a resolver wall would classify as 'unknown' and FALSELY abort the build" ;;
esac
# the production default for the retry count, which every dynamic leg overrides
# and therefore never pins.
if grep -a 'HUGMESH_PREFETCH_ATTEMPTS="\${HUGMESH_PREFETCH_ATTEMPTS:-3}"' "${LIB}" >/dev/null; then
    ok "a12: the production retry default is 3 attempts"
else
    bad "a12: the production HUGMESH_PREFETCH_ATTEMPTS default is not 3 — every dynamic leg sets it explicitly, so nothing else would notice"
fi

# ── A13: the CHROOT heredoc expands nothing the HOST does not have ──────────
# This is the leg that would have caught the landing blocker. The payload chroot
# is opened with an UNQUOTED delimiter, so the HOST shell expands every
# unescaped ${NAME} in its 500+ lines before the chroot ever starts, and the
# builder runs under `set -euo pipefail`. A chroot-LOCAL name spelled without a
# backslash is therefore not a chroot bug: it is an immediate
# "NAME: unbound variable" that kills the build at the chroot command, before a
# single package is merged. tests/build-matrix/check.sh's EGB probe does NOT
# cover this — it only inspects comment runs that mention an emerge group plus
# the banner lines themselves, so a plain code line like the pre-fetch call is
# flushed unselected. Sweep the WHOLE heredoc instead.
hd_out="${TDIR}/heredoc-sweep.txt"
"${PYTHON:-python3}" - "${BUILDER}" > "${hd_out}" 2>&1 <<'PYSWEEP'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
start = end = None
for i, l in enumerate(src, 1):
    if start is None and re.match(r'^chroot "\$\{SYSROOT\}" /bin/bash -eo pipefail <<CHROOT\s*$', l):
        start = i
    elif start is not None and end is None and l.rstrip() == 'CHROOT':
        end = i
        break
if start is None or end is None:
    print("SWEEP-ERROR: could not find the chroot heredoc bounds")
    sys.exit(2)
# every name the HOST assigns anywhere above the heredoc, in any spelling
host = set()
for l in src[:start - 1]:
    for m in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]*)=', l):
        host.add(m.group(1))
    for m in re.finditer(r'\b(?:for|read)\s+(?:-r\s+)?([A-Za-z_][A-Za-z0-9_]*)', l):
        host.add(m.group(1))
host |= {'PWD', 'HOME', 'PATH', 'IFS', 'UID', 'USER', 'HOSTNAME', 'SHELL', 'LANG',
         'TMPDIR', 'RANDOM', 'SECONDS', 'PIPESTATUS', 'BASH_SOURCE', 'FUNCNAME',
         'LINENO', 'OPTARG', 'OPTIND', 'BASHPID', 'PPID'}
bad = []
for off, l in enumerate(src[start:end - 1]):
    ln = start + 1 + off
    for m in re.finditer(r'(?<!\\)\$\{([A-Za-z_][A-Za-z0-9_]*)([^}]*)\}', l):
        name, rest = m.group(1), m.group(2)
        if name in host:
            continue
        if rest[:2] in (':-', ':=', ':?', ':+') or rest[:1] in ('-', '=', '?', '+'):
            continue
        bad.append("%d: ${%s} -- %s" % (ln, name, l.strip()[:90]))
print("heredoc %d..%d" % (start, end))
for b in bad:
    print("UNBOUND " + b)
print("COUNT %d" % len(bad))
PYSWEEP
hd_rc=$?
hd_n="$(grep -a '^COUNT ' "${hd_out}" | awk '{print $2}')"
if [ "${hd_rc}" -eq 0 ] && [ "${hd_n:-x}" = "0" ]; then
    ok "a13: every unescaped \${NAME} in the chroot heredoc is a name the HOST sets ($(grep -a '^heredoc ' "${hd_out}"))"
else
    bad "a13: the chroot heredoc expands host-unset names on the HOST side — under set -euo pipefail this kills the build at the chroot command, before anything is merged:"
    grep -a '^UNBOUND \|^SWEEP-ERROR' "${hd_out}" | sed 's/^/        /'
fi
# and the specific name this pass introduced, positively: it must be ESCAPED at
# its read site (chroot-side) and UNESCAPED at its assignment RHS (host value in).
if grep -a 'elif \[ "\\\${HUGMESH_ALLOW_MISSING_PACKAGES}" = "true" \]' "${BUILDER}" >/dev/null; then
    ok "a13: the opt-out is read with an ESCAPED \${HUGMESH_ALLOW_MISSING_PACKAGES} (chroot-side)"
else
    bad "a13: the opt-out read site is not escaped — the HOST would expand a name only the chroot has"
fi


echo
if [ "${F}" -eq 0 ]; then
    echo "x86-prefetch-gate: ${P} passed, 0 failed"
else
    echo "x86-prefetch-gate: ${P} passed, ${F} FAILED"
fi
[ "${F}" -eq 0 ]
