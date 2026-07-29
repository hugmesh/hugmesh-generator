#!/usr/bin/env bash
# build-package-completeness.sh — guards the two fixes for the 2026-07-25
# standalone-unaffiliated build failures:
#
#   A. app-office/libreoffice could never merge. Every package in this stage4
#      compiles as ROOT (make.conf.tmpl sets FEATURES="-userpriv -usersandbox"),
#      and LibreOffice's Makefile refuses a root build unless $container is
#      non-empty. Fix: specs-x86/portage/env/app-office/libreoffice exports it.
#
#   B. that failure shipped SILENTLY. The payload emerge runs --keep-going and
#      the only post-emerge assertion probed a handful of BINARIES, so session
#      20260725-061608-978c99 emitted a full set of "prod" artifacts with no
#      office suite and said nothing. Fix: a requested-atom completeness gate
#      that fails the build listing every atom that did not install.
#
# The load-bearing property of (B) is that the gate's shell actually RUNS: it
# lives inside an UNQUOTED chroot heredoc containing a nested python heredoc, a
# construct `bash -n build-x86-host-stage4.sh` cannot check (to the outer parse
# the whole body is a string). So this test RENDERS the heredoc the way the
# builder does and syntax-checks the result — a broken payload would otherwise
# surface only hours into a real build, inside a chroot.
#
# Pure static + render checks. No emerge, no chroot, no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
BUILDER="${REPO}/build-x86-host-stage4.sh"
ENVFILE="${REPO}/specs-x86/portage/env/app-office/libreoffice"
MKCONF="${REPO}/specs-x86/portage/make.conf.tmpl"
CAPLIST="${REPO}/specs-x86/portage/packages-desktop-capable.list"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== package-completeness + root-build guards =="

echo "-- A) libreoffice root-build escape --"
# The fix is only NEEDED while builds run as root; if someone ever turns
# userpriv back on, this test should tell them the env file is now redundant
# rather than silently keep asserting it.
if grep -qE '^FEATURES=.*-userpriv' "${MKCONF}"; then
  ok "make.conf.tmpl still builds as root (-userpriv) — the escape is required"
  [ -f "${ENVFILE}" ] \
    && ok "env/app-office/libreoffice exists (portage sources it as bash for that package)" \
    || bad "env/app-office/libreoffice MISSING — libreoffice will fail check-if-root as root"
  # Non-empty $container is upstream's own bypass: the guard's first branch is
  # `test -z $container`. Assert an EXPORT (a plain assignment would stay in the
  # ebuild shell and never reach the make recipe that reads it).
  grep -qE '^export container=.+' "${ENVFILE}" \
    && ok "exports a non-empty \$container (upstream's check-if-root bypass)" \
    || bad "does not 'export container=<non-empty>' — the guard would still trip"
  grep -qE '^export container="?"?$' "${ENVFILE}" \
    && bad "container is set EMPTY — 'test -z' would still be true and the guard trips" \
    || ok "container value is not empty"
  # It must NOT be global: other software branches on $container.
  # An ASSIGNMENT only — make.conf legitimately mentions "container" in prose
  # and in USE=containers, neither of which sets the variable.
  grep -qE '^[[:space:]]*(export[[:space:]]+)?container=' "${MKCONF}" \
    && bad "container is ASSIGNED in make.conf.tmpl — that leaks to EVERY package" \
    || ok "scoped to the one package (not assigned in make.conf)"
else
  ok "make.conf.tmpl no longer forces root builds — root-build escape not needed"
fi
# Keep the fix and the package that needs it wired together: if libreoffice is
# ever dropped from the set, this points at dead config instead of rotting.
if grep -qxE 'app-office/libreoffice' "${CAPLIST}"; then
  ok "app-office/libreoffice is still in the --capable set (fix stays relevant)"
else
  echo "  NOTE libreoffice no longer in packages-desktop-capable.list — env file may be removable"
fi

echo "-- B) requested-atom completeness gate --"
grep -q 'REQUESTED-ATOM COMPLETENESS GATE' "${BUILDER}" \
  && ok "gate present in the builder" || bad "completeness gate is GONE"
grep -q 'hugmesh-requested-atoms.txt' "${BUILDER}" \
  && ok "writes the requested atom set" || bad "does not materialize the requested atoms"
grep -q 'ALLOW_MISSING_PACKAGES=false' "${BUILDER}" \
  && ok "defaults to FAILING on a degraded image" || bad "the gate is not fail-by-default"
grep -q -- '--allow-missing-packages) ALLOW_MISSING_PACKAGES=true' "${BUILDER}" \
  && ok "--allow-missing-packages opt-out is parsed" || bad "opt-out flag not wired"
grep -q -- '--allow-missing-packages  Ship the image even if' "${BUILDER}" \
  && ok "opt-out is documented in --help" || bad "opt-out missing from usage text"
# The gate must sit AFTER the payload emerge (checking before it merges proves
# nothing) and BEFORE image assembly (failing after the .iso is written defeats
# the point).
gate_ln=$(grep -n 'REQUESTED-ATOM COMPLETENESS GATE' "${BUILDER}" | head -1 | cut -d: -f1)
emerge_ln=$(grep -n 'autounmask-continue=y' "${BUILDER}" | head -1 | cut -d: -f1)
asm_ln=$(grep -n 'packages-only: binpkg pool prebuilt' "${BUILDER}" | head -1 | cut -d: -f1)
if [ -n "${gate_ln}" ] && [ -n "${emerge_ln}" ] && [ -n "${asm_ln}" ] \
   && [ "${gate_ln}" -gt "${emerge_ln}" ] && [ "${gate_ln}" -lt "${asm_ln}" ]; then
  ok "gate runs after the payload emerge (${emerge_ln}) and before image assembly (${asm_ln})"
else
  bad "gate is mis-ordered (gate=${gate_ln} emerge=${emerge_ln} assembly=${asm_ln})"
fi

echo "-- C) the chroot payload still RENDERS to valid bash --"
# Extract the payload emerge heredoc (the one carrying the gate) and expand it
# exactly as the builder does: an unquoted heredoc, so the HOST shell
# interpolates ${...} and leaves \${...} for the chroot shell.
START=$(grep -n 'chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT' "${BUILDER}" | head -1 | cut -d: -f1)
if [ -z "${START}" ]; then
  bad "could not find the payload chroot heredoc"
else
  END=$(awk -v s="${START}" 'NR>s && /^CHROOT$/ {print NR; exit}' "${BUILDER}")
  if [ -z "${END}" ]; then
    bad "payload heredoc has no closing CHROOT delimiter"
  else
    ok "payload heredoc spans lines ${START}-${END}"
    BODY="$(mktemp)"; RENDER="$(mktemp)"
    trap 'rm -f "${BODY}" "${RENDER}"' EXIT
    sed -n "$((START+1)),$((END-1))p" "${BUILDER}" > "${BODY}"
    # Host-side values the heredoc interpolates. Values are representative, not
    # authoritative — the point is that the RESULT parses for any of them.
    (
      EMERGE_JOBS=1 JOBS=8 GO_PROCS=2 EMERGE_EXCLUDE="--exclude sys-devel/gcc" \
      PKGS="app-office/libreoffice sys-apps/portage" SNAP_ROLE_BINS="Xorg lightdm openbox" \
      ALLOW_MISSING_PACKAGES=false STEAM_OVERLAY_SETUP="" SYSROOT=/nonexistent \
      DISTDIR_SRC="" REL_VERSION="test" ROLE="desktop" \
      bash -c 'eval "cat <<CHROOT
$(cat "$1")
CHROOT"' _ "${BODY}" > "${RENDER}"
    ) 2>/dev/null
    if [ -s "${RENDER}" ]; then
      ok "heredoc rendered ($(wc -l < "${RENDER}") lines)"
      if bash -n "${RENDER}" 2>/tmp/hugmesh-render-err; then
        ok "rendered chroot payload is VALID bash"
      else
        bad "rendered chroot payload is INVALID bash: $(head -3 /tmp/hugmesh-render-err | tr '\n' ' ')"
      fi
      # The gate's own python must survive the render (an unescaped $ in the
      # heredoc would have been eaten by the host shell).
      grep -q 'vardb.match(atom)' "${RENDER}" \
        && ok "the gate's python survived interpolation" \
        || bad "the gate's python did not survive the heredoc render"
      grep -q 'EROOT' "${RENDER}" \
        && ok "portage EROOT lookup intact" || bad "EROOT lookup was mangled by the render"
      # ALLOW_MISSING_PACKAGES is threaded HOST-side, so the rendered text must
      # carry the literal value, not an unexpanded reference.
      grep -q '"false" = "true"' "${RENDER}" || grep -q '= "true" \]' "${RENDER}" \
        && ok "opt-out value was interpolated host-side" \
        || bad "ALLOW_MISSING_PACKAGES did not interpolate"
    else
      bad "heredoc render produced nothing"
    fi
  fi
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
