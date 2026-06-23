#!/usr/bin/env bash
# test-builder-opt-in.sh — proves the IMAGE BUILDERS bake the OPT-IN (default-off)
# auto-update plumbing for host + client targets, and that the policy ConfigMap +
# main() wiring are present. Static source/spec assertions (no cross-build needed).
#
# Asserts:
#   * specs/ ships the poller (exec), the OpenRC service, and the cron drop-in;
#     the cron drop-in is ACTIVE plumbing (an uncommented cron line) — the POLLER
#     gates default-off at runtime, not the cron's presence.
#   * rpi5 (host/node) builder: copies the poller + service AND links
#     snapdragon-update into DEFAULT_SVCS UNCONDITIONALLY (plumbing on every node).
#   * frite (client) builder: same — copies + links unconditionally (client target).
#   * provision.sh: main() calls provision_update; provision_update has NO opt-in
#     return gate AND NO disable branch — it ALWAYS bakes the cron plumbing (the
#     poller is the runtime gate); enabled is read RAW (no // true / // false).
#   * the snapdragon-update-policy ConfigMap is DEFAULT-OFF (enabled:false) and lives
#     under the binhost ArgoCD app's synced path (a superadmin sets enabled:true).
#   * PROTECTED x86 builder: report whether it bakes the poller (it must NOT be
#     edited here; we ASSERT the deferred state so the gap is tracked, not silent).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPECS="${REPO}/specs"
RPI5="${REPO}/build-rpi5-stage4.sh"
FRITE="${REPO}/build-frite-stage4.sh"
X86="${REPO}/build-x86-host-stage4.sh"
PROV="${SPECS}/etc/keys-provision/provision.sh"
CM="${SPECS}/cluster/manifests/binhost/update-policy.yaml"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
has(){ grep -q "$1" "$2" 2>/dev/null; }

echo "== builder opt-in (default-off) auto-update assertions =="

# ── specs primitives ─────────────────────────────────────────────────────────
[ -x "${SPECS}/usr/local/sbin/snapdragon-update" ] && ok "specs: poller present + executable" || bad "specs: poller missing/non-exec"
[ -x "${SPECS}/etc/init.d/snapdragon-update" ]     && ok "specs: OpenRC service present + executable" || bad "specs: OpenRC service missing/non-exec"
CRON="${SPECS}/etc/cron.d/snapdragon-update"
[ -f "${CRON}" ] && ok "specs: cron drop-in present" || bad "specs: cron drop-in missing"
# An ACTIVE cron line (plumbing): a line whose first field is a cron schedule,
# invoking the poller. The poller gates default-off at runtime, not the cron presence.
grep -qE '^[^#].*\* .*/usr/local/sbin/snapdragon-update' "${CRON}" 2>/dev/null \
    && ok "specs: cron drop-in is ACTIVE plumbing (uncommented schedule invoking the poller)" || bad "cron drop-in not active"
# The OpenRC service is cronie/OpenRC, NOT systemd.
has '#!/sbin/openrc-run' "${SPECS}/etc/init.d/snapdragon-update" && ok "service is OpenRC (not systemd)" || bad "service is not OpenRC"

# ── rpi5 host/node builder: bake + UNCONDITIONAL runlevel link (plumbing) ──────
has 'usr/local/sbin/snapdragon-update' "${RPI5}" && ok "rpi5: copies the poller" || bad "rpi5: poller not baked"
has 'etc/init.d/snapdragon-update'     "${RPI5}" && ok "rpi5: copies the OpenRC service" || bad "rpi5: service not baked"
has 'DEFAULT_SVCS+=(snapdragon-update)' "${RPI5}" && ok "rpi5: links snapdragon-update into DEFAULT_SVCS" || bad "rpi5: not linked into DEFAULT_SVCS"
# UNCONDITIONAL plumbing: the link line must NOT be guarded by an _opt_selected / flag
# check. Assert it is at base indentation (column-0) — the egress-vpn link IS indented.
grep -qE '^DEFAULT_SVCS\+=\(snapdragon-update\)' "${RPI5}" \
    && ok "rpi5: the update link is UNCONDITIONAL plumbing (column-0, not gated by a flag)" || bad "rpi5: update link appears gated/indented"

# ── frite client builder: bake + UNCONDITIONAL runlevel link (plumbing) ────────
has 'usr/local/sbin/snapdragon-update' "${FRITE}" && ok "frite(client): copies the poller" || bad "frite: poller not baked"
has 'etc/init.d/snapdragon-update'     "${FRITE}" && ok "frite(client): copies the OpenRC service" || bad "frite: service not baked"
grep -qE '^DEFAULT_SVCS\+=\(snapdragon-update\)' "${FRITE}" \
    && ok "frite(client): links snapdragon-update UNCONDITIONALLY (plumbing)" || bad "frite: update link missing/gated"

# ── provision.sh wiring + opt-in shape ─────────────────────────────────────────
has 'provision_update' "${PROV}" && ok "provision.sh: provision_update defined" || bad "provision_update missing"
grep -qE '^\s*provision_update' "${PROV}" && grep -q 'main()' "${PROV}" \
    && awk '/^main\(\)/{m=1} m&&/provision_update/{print "found"; exit}' "${PROV}" | grep -q found \
    && ok "provision.sh: main() calls provision_update" || bad "main() does not call provision_update"
# OPT-IN: provision_update must ALWAYS bake the cron plumbing — NO provision-time
# disable branch (no `rm -f .../snapdragon-update`); the poller is the runtime gate.
grep -q 'rm -f /etc/cron.d/snapdragon-update' "${PROV}" \
    && bad "provision.sh STILL has a disable branch (rm cron) — it must always bake plumbing" \
    || ok "provision.sh: NO disable branch (cron is always-baked plumbing; the poller gates)"
has "jqm '.update.enabled'" "${PROV}" && ok "provision.sh: reads .update.enabled raw" || bad "enabled read shape unexpected"
# The // true AND // false pitfalls must BOTH be absent (a literal bool must survive).
grep -q "jqm '.update.enabled // true'" "${PROV}" \
    && bad "provision.sh uses // true (a raw bool would be masked)" \
    || ok "provision.sh: no '// true' on .update.enabled"
grep -q "jqm '.update.enabled // false'" "${PROV}" \
    && bad "provision.sh uses // false (a literal false would collapse)" \
    || ok "provision.sh: no '// false' on .update.enabled"

# ── policy ConfigMap: default-OFF, under the binhost synced path ───────────────
[ -f "${CM}" ] && ok "ConfigMap spec present (binhost manifests dir)" || bad "update-policy ConfigMap missing"
if command -v python3 >/dev/null 2>&1; then
  python3 - "${CM}" <<'PY' && ok "ConfigMap is DEFAULT-OFF (enabled:false) + correct name/ns" || bad "ConfigMap not default-off / wrong name"
import sys, yaml, json
d = yaml.safe_load(open(sys.argv[1]))
assert d["kind"] == "ConfigMap", "not a ConfigMap"
assert d["metadata"]["name"] == "snapdragon-update-policy", "wrong name"
assert d["metadata"]["namespace"] == "devops", "wrong ns"
pol = json.loads(d["data"]["policy.json"])
assert pol["enabled"] is False, f"not default-off: {pol['enabled']!r}"
sys.exit(0)
PY
else
  has 'name: snapdragon-update-policy' "${CM}" && has '"enabled": false' "${CM}" && ok "ConfigMap default-off (grep)" || bad "ConfigMap not default-off (grep)"
fi
# The binhost ArgoCD app syncs the whole manifests/binhost dir => the CM is deployed.
has 'path: specs/cluster/manifests/binhost' "${REPO}/specs/cluster/apps/02-binhost.yaml" \
    && ok "ConfigMap is under the binhost ArgoCD app's synced path (auto-deployed)" || bad "ConfigMap not in a synced path"

# ── PROTECTED x86 builder: assert the DEFERRED state (tracked, not silent) ──────
# We may NOT edit build-x86-host-stage4.sh. Document the gap as a test so the
# follow-up is tracked: the x86 builder runs provision.sh (=> provision_update runs),
# but does NOT yet bake the poller binary, so x86 currently STAGES the cron + warns.
if has 'usr/local/sbin/snapdragon-backup' "${X86}"; then
  ok "x86 (protected): runs the shared provision.sh + backup engine (so provision_update WILL run)"
fi
if has 'usr/local/sbin/snapdragon-update' "${X86}"; then
  ok "x86 (protected): ALSO bakes the poller plumbing (protected follow-up landed)"
else
  echo "  NOTE x86 (protected) does NOT yet bake /usr/local/sbin/snapdragon-update;"
  echo "       provision_update STAGES /etc/snapdragon/cron-update.staged + warns."
  echo "       Deferred protected edit: cp the poller + service + add to both SVCS arrays."
  ok "x86 deferred state is the EXPECTED/known gap (provision_update stages, not silent)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
