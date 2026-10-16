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
#     hugmesh-update into DEFAULT_SVCS UNCONDITIONALLY (plumbing on every node).
#   * frite (client) builder: same — copies + links unconditionally (client target).
#   * provision.sh: main() calls provision_update; provision_update has NO opt-in
#     return gate AND NO disable branch — it ALWAYS bakes the cron plumbing (the
#     poller is the runtime gate); enabled is read RAW (no // true / // false).
#   * the hugmesh-update-policy ConfigMap is DEFAULT-OFF (enabled:false) and lives
#     under the binhost ArgoCD app's synced path (a superadmin sets enabled:true).
#   * x86 builder: copies the poller + OpenRC service inside the ! UNAFFILIATED
#     platform-tools block and links hugmesh-update into BOTH SVCS arrays (client
#     affiliated arm, cluster-node array gated on ${UNAFFILIATED}).
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
[ -x "${SPECS}/usr/local/sbin/hugmesh-update" ] && ok "specs: poller present + executable" || bad "specs: poller missing/non-exec"
[ -x "${SPECS}/etc/init.d/hugmesh-update" ]     && ok "specs: OpenRC service present + executable" || bad "specs: OpenRC service missing/non-exec"
CRON="${SPECS}/etc/cron.d/hugmesh-update"
[ -f "${CRON}" ] && ok "specs: cron drop-in present" || bad "specs: cron drop-in missing"
# An ACTIVE cron line (plumbing): a line whose first field is a cron schedule,
# invoking the poller. The poller gates default-off at runtime, not the cron presence.
grep -qE '^[^#].*\* .*/usr/local/sbin/hugmesh-update' "${CRON}" 2>/dev/null \
    && ok "specs: cron drop-in is ACTIVE plumbing (uncommented schedule invoking the poller)" || bad "cron drop-in not active"
# The OpenRC service is cronie/OpenRC, NOT systemd.
has '#!/sbin/openrc-run' "${SPECS}/etc/init.d/hugmesh-update" && ok "service is OpenRC (not systemd)" || bad "service is not OpenRC"

# ── rpi5 host/node builder: bake + UNCONDITIONAL runlevel link (plumbing) ──────
has 'usr/local/sbin/hugmesh-update' "${RPI5}" && ok "rpi5: copies the poller" || bad "rpi5: poller not baked"
has 'etc/init.d/hugmesh-update'     "${RPI5}" && ok "rpi5: copies the OpenRC service" || bad "rpi5: service not baked"
has 'DEFAULT_SVCS+=(hugmesh-update)' "${RPI5}" && ok "rpi5: links hugmesh-update into DEFAULT_SVCS" || bad "rpi5: not linked into DEFAULT_SVCS"
# UNCONDITIONAL plumbing: the link line must NOT be guarded by an _opt_selected / flag
# check. Assert it is at base indentation (column-0) — the egress-vpn link IS indented.
grep -qE '^DEFAULT_SVCS\+=\(hugmesh-update\)' "${RPI5}" \
    && ok "rpi5: the update link is UNCONDITIONAL plumbing (column-0, not gated by a flag)" || bad "rpi5: update link appears gated/indented"

# ── frite client builder: bake + UNCONDITIONAL runlevel link (plumbing) ────────
has 'usr/local/sbin/hugmesh-update' "${FRITE}" && ok "frite(client): copies the poller" || bad "frite: poller not baked"
has 'etc/init.d/hugmesh-update'     "${FRITE}" && ok "frite(client): copies the OpenRC service" || bad "frite: service not baked"
grep -qE '^DEFAULT_SVCS\+=\(hugmesh-update\)' "${FRITE}" \
    && ok "frite(client): links hugmesh-update UNCONDITIONALLY (plumbing)" || bad "frite: update link missing/gated"

# ── provision.sh wiring + opt-in shape ─────────────────────────────────────────
has 'provision_update' "${PROV}" && ok "provision.sh: provision_update defined" || bad "provision_update missing"
grep -qE '^\s*provision_update' "${PROV}" && grep -q 'main()' "${PROV}" \
    && awk '/^main\(\)/{m=1} m&&/provision_update/{print "found"; exit}' "${PROV}" | grep found >/dev/null \
    && ok "provision.sh: main() calls provision_update" || bad "main() does not call provision_update"
# OPT-IN: provision_update must ALWAYS bake the cron plumbing — NO provision-time
# disable branch (no `rm -f .../hugmesh-update`); the poller is the runtime gate.
grep -q 'rm -f /etc/cron.d/hugmesh-update' "${PROV}" \
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
assert d["metadata"]["name"] == "hugmesh-update-policy", "wrong name"
assert d["metadata"]["namespace"] == "devops", "wrong ns"
pol = json.loads(d["data"]["policy.json"])
assert pol["enabled"] is False, f"not default-off: {pol['enabled']!r}"
sys.exit(0)
PY
else
  has 'name: hugmesh-update-policy' "${CM}" && has '"enabled": false' "${CM}" && ok "ConfigMap default-off (grep)" || bad "ConfigMap not default-off (grep)"
fi
# The binhost ArgoCD app syncs the whole manifests/binhost dir => the CM is deployed.
has 'path: specs/cluster/manifests/binhost' "${REPO}/specs/cluster/apps/02-binhost.yaml" \
    && ok "ConfigMap is under the binhost ArgoCD app's synced path (auto-deployed)" || bad "ConfigMap not in a synced path"

# ── x86 host + client builder: bake + runlevel link in BOTH SVCS arrays ─────────
# build-x86-host-stage4.sh used to bake neither, so provision_update took its
# "poller not baked" branch and only staged /etc/hugmesh/cron-update.staged. The
# poller + OpenRC service are platform machinery (they read /etc/hugmesh), so they
# are baked INSIDE the `! UNAFFILIATED` block and both runlevel links are gated the
# same way (a link to an unbaked init script would dangle). Structural check, not
# a bare grep: the copy must sit between the `if ! ${UNAFFILIATED}; then` that opens
# the platform-tools block and the `fi   # ! UNAFFILIATED (...backup...)` that closes
# it; the client link must be in the affiliated arm of the client SVCS assignment;
# the host link must be gated on ${UNAFFILIATED}.
has 'usr/local/sbin/hugmesh-backup' "${X86}" \
    && ok "x86: runs the shared provision.sh + backup engine (so provision_update WILL run)" \
    || bad "x86: backup engine anchor missing (test anchor drifted)"
if command -v python3 >/dev/null 2>&1; then
  _x86out="$(python3 - "${X86}" <<'PY'
import re, sys
L = open(sys.argv[1]).read().split("\n")
def idx(pred, start=0):
    for n in range(start, len(L)):
        if pred(L[n]): return n
    return -1
def check(label, cond):
    print(("  PASS " if cond else "  FAIL ") + label)
    return 0 if cond else 1
bad = 0
bk = idx(lambda l: "usr/local/sbin/hugmesh-backup" in l and l.startswith("cp "))
end = idx(lambda l: l.startswith("fi") and "! UNAFFILIATED" in l and "backup" in l, bk)
op = max((n for n in range(bk) if L[n].startswith("if ! ${UNAFFILIATED}; then")), default=-1)
bad += check("x86: located the platform-tools block (opens before the backup copy, closes after it)", 0 <= op < bk < end)
blk = L[op:end+1] if end > 0 else []
cp_poller = [l for l in blk if l.startswith("cp ") and "/usr/local/sbin/hugmesh-update" in l and "${SYSROOT}/usr/local/sbin/hugmesh-update" in l and "chmod +x" in l]
cp_init   = [l for l in blk if l.startswith("cp ") and "/etc/init.d/hugmesh-update" in l and "${SYSROOT}/etc/init.d/hugmesh-update" in l and "chmod +x" in l]
bad += check("x86: copies + chmods the poller inside the ! UNAFFILIATED block", len(cp_poller) == 1)
bad += check("x86: copies + chmods the OpenRC service inside the ! UNAFFILIATED block", len(cp_init) == 1)
# Client array: the SVCS assignment in the `else` of `if ${UNAFFILIATED}` must be followed
# (before the closing fi) by the update link.
cl = idx(lambda l: re.match(r"^\s+SVCS=\(.*keys-provision auditd local dbus elogind display-manager\)", l))
bad += check("x86 client: located the affiliated client SVCS array", cl > 0)
arm = L[cl+1:cl+4] if cl > 0 else []
fi_n = next((n for n, l in enumerate(arm) if re.match(r"^    fi\s*$", l)), -1)
bad += check("x86 client: hugmesh-update linked in the affiliated arm (before the closing fi)",
             any(re.match(r"^\s+SVCS\+=\(hugmesh-update\)\s*$", l) for l in (arm[:fi_n] if fi_n >= 0 else [])))
un = idx(lambda l: re.match(r"^\s+SVCS=\(.*growroot auditd local dbus elogind display-manager\)", l))
bad += check("x86 client: the UNAFFILIATED client array exists and does NOT carry it",
             un > 0 and "hugmesh-update" not in L[un] and not re.match(r"^\s+SVCS\+=\(hugmesh-update\)", L[un+1]))
ho = idx(lambda l: re.match(r"^    SVCS=\(.*hugmesh-go-live-reconcile containerd kubelet auditd local\)", l))
bad += check("x86 host: located the cluster-node SVCS array", ho > 0)
hn = L[ho+1:ho+6] if ho > 0 else []
bad += check("x86 host: hugmesh-update linked, gated on ${UNAFFILIATED} (no dangling link)",
             any(re.match(r"^\s+\$\{UNAFFILIATED\} \|\| SVCS\+=\(hugmesh-update\)\s*$", l) for l in hn))
sys.exit(1 if bad else 0)
PY
)"
  _x86rc=$?
  printf '%s\n' "${_x86out}"
  P=$((P + $(printf '%s\n' "${_x86out}" | grep -c '^  PASS ')))
  F=$((F + $(printf '%s\n' "${_x86out}" | grep -c '^  FAIL ')))
  [ "${_x86rc}" -eq 0 ] || [ "${F}" -gt 0 ] || bad "x86 structural check exited ${_x86rc} without reporting a failure"
else
  has 'usr/local/sbin/hugmesh-update' "${X86}" && has 'etc/init.d/hugmesh-update' "${X86}" \
      && ok "x86 bakes the poller + service (grep; python3 absent)" || bad "x86 does not bake the poller"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
