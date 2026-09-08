#!/usr/bin/env bash
# ── intltool build-order pre-seed guard (lxde-base/lxde-common) ───────────────
# Session 20260908T070203Z (standalone-thick, x86) lost a full payload run to an
# ORDERING bug that no keyword or USE change can fix:
#
#   lxde-base/lxde-common-0.99.2-r1's configure requires intltool >= 0.40.0, but
#   its ebuild's BDEPEND names only sys-devel/gettext and virtual/pkgconfig. The
#   resolver therefore placed lxde-common at 101/896 and dev-util/intltool at
#   290/896 (pulled in 189 places later as lxappearance's and lxsession's OWN
#   BDEPEND). lxde-common died at configure —
#     ./configure: line 5215: intltool-update: command not found
#     configure: error: Your intltool is too old.
#   — and --keep-going dropped lxde-base/lxsession with it, because lxsession
#   RDEPENDs on >=lxde-common-0.99.2-r1. lxsession is a REQUESTED atom, so the
#   requested-atom completeness gate failed the build HOURS after the fact.
#
# Declaring dev-util/intltool as a top-level atom would NOT fix it: portage may
# schedule an unrelated top-level atom anywhere. The fix merges it in the SYSTEM
# group, before the image payload — and that ordering is what this guard pins.
#
# It bites on every way to break the fix: the block vanishing, the lxde gate
# widening to every role or narrowing to none, the emission being dropped
# (defined-but-never-emitted is inert), the emission drifting AFTER the image
# group (too late to matter), and the pre-seed becoming fatal (a build tool that
# aborts the run is worse than the hole it closes).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
X86="${GEN}/build-x86-host-stage4.sh"
DESKLIST="${GEN}/specs-x86/portage/packages-desktop.list"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
echo "== intltool build-order pre-seed guard =="

# 1. The desktop list must still request an lxde-base atom — if LXDE is ever
#    dropped from the payload this whole guard is moot, and saying so out loud
#    beats leaving a guard that silently protects nothing.
if [ -f "${DESKLIST}" ] && grep -qE '^lxde-base/' "${DESKLIST}"; then
    ok "packages-desktop.list still requests lxde-base atoms (guard is live)"
else
    bad "no lxde-base atom in packages-desktop.list — retire this guard, or the LXDE set moved"
fi

# 2. EXECUTED: extract the host-side selector and run it both ways. This is the
#    part that decides, so it is run rather than grepped.
sed -n '/^INTLTOOL_PRESEED=""$/,/^esac$/p' "${X86}" > "${TMP}/sel.sh"
if [ -s "${TMP}/sel.sh" ] && grep -q '^esac$' "${TMP}/sel.sh"; then
    ok "pre-seed selector extracted from the builder"
else
    bad "could not extract the INTLTOOL_PRESEED selector (anchors moved?)"
fi

out_with="$(PKGS='x11-base/xorg-server lxde-base/lxsession app-editors/vim' \
    bash -c "source '${TMP}/sel.sh'; printf '%s' \"\${INTLTOOL_PRESEED}\"" 2>&1)"
out_without="$(PKGS='x11-base/xorg-server app-editors/vim sys-process/htop' \
    bash -c "source '${TMP}/sel.sh'; printf '%s' \"\${INTLTOOL_PRESEED}\"" 2>&1)"

if printf '%s' "${out_with}" | grep 'emerge .*dev-util/intltool' >/dev/null; then
    ok "a payload carrying lxde-base/* pre-seeds dev-util/intltool"
else
    bad "an lxde-base payload does NOT pre-seed intltool — the 20260908 failure is back"
fi
if [ -z "${out_without}" ]; then
    ok "a payload with no lxde-base atom pre-seeds nothing (no build tool for roles that never need it)"
else
    bad "the pre-seed fires for a non-lxde payload: ${out_without}"
fi
# Non-fatal: a pre-seed that aborts the run is worse than the hole it closes.
if printf '%s' "${out_with}" | grep '|| echo' >/dev/null; then
    ok "the pre-seed is non-fatal (falls back to a WARN)"
else
    bad "the pre-seed lost its || fallback — a tree hiccup would now kill the build"
fi

# 3. Emission: defined-but-never-emitted is inert, and emitted too late is
#    useless. It must appear BETWEEN the system-group banner and the image one.
sys_ln=$(grep -n '^echo "==> Emerge group: system"$' "${X86}" | head -1 | cut -d: -f1)
img_ln=$(grep -n '^echo "==> Emerge group: image"$' "${X86}" | head -1 | cut -d: -f1)
emit_ln=$(grep -n '^\${INTLTOOL_PRESEED}$' "${X86}" | head -1 | cut -d: -f1)
if [ -n "${emit_ln}" ]; then
    ok "the builder emits \${INTLTOOL_PRESEED} into the chroot payload"
else
    bad "INTLTOOL_PRESEED is defined but never emitted — an inert pre-seed"
fi
if [ -n "${emit_ln}" ] && [ -n "${sys_ln}" ] && [ -n "${img_ln}" ] \
   && [ "${emit_ln}" -gt "${sys_ln}" ] && [ "${emit_ln}" -lt "${img_ln}" ]; then
    ok "the pre-seed runs in the system group, before the image payload (line ${emit_ln} in ${sys_ln}..${img_ln})"
else
    bad "the pre-seed is not between the system and image group banners (emit=${emit_ln} system=${sys_ln} image=${img_ln}) — too late to order anything"
fi

# 4. Heredoc safety: the emitted text lands in the UNQUOTED chroot heredoc, so
#    an unescaped $ or a backtick in it would expand on the HOST.
if printf '%s' "${out_with}" | grep -E '[`]|[^\\]\$' >/dev/null; then
    bad "the emitted pre-seed carries an unescaped \$ or a backtick — it would expand on the host"
else
    ok "the emitted pre-seed is free of host-expanding \$ and backticks"
fi

echo "== intltool-preseed: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
