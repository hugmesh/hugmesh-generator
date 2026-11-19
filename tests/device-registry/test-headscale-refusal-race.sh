#!/usr/bin/env bash
# test-headscale-refusal-race.sh — a refused headscale cannot be restarted onto its refused configuration,
# and the CP DNS edit cannot leave a half-written config (hugmesh-generator#1036).
#
# THE TWO DEFECTS (both LOW findings of the #986 refute).
#  1. headscale_refuse_config stopped headscale, removed it from the runlevel and only THEN moved
#     /etc/headscale/config.* aside. The Layer-A policy-sync apply leg restarts headscale every minute and
#     OpenRC's `restart` starts a stopped service, so a restart landing between the stop and the move started
#     headscale on the configuration the gate had just refused.
#  2. publish_cp_dns_record edited /etc/headscale/config.yaml in place. A write that failed part-way
#     (I/O error, full disk) returned BEFORE the second config gate, so a half-written file was never
#     re-checked before a later restart.
#
# THE FIX. The refusal leaves HEADSCALE_REFUSED_MARK BEFORE it stops anything; the init script's start_pre and
# gen-headscale-policy.sh's restart_headscale both refuse while it exists. publish_cp_dns_record writes a temp
# file and renames it, and runs the gate whether or not the write landed.
#
# No docker, no headscale: the REAL functions are lifted out of specs/etc/keys-provision/provision.sh,
# specs/usr/sbin/gen-headscale-policy.sh and specs/etc/init.d/headscale and run against a sandbox, with a small
# model of OpenRC's `restart` (stop, then start_pre, then start) and a python3 shim that fails a write part-way.
#   (A) the race: a cron restart fired from INSIDE `rc-service headscale stop` (the window) does not start
#       headscale; neither does an operator's direct `rc-service headscale restart`; CONTROL: with the marker
#       write removed the same restart starts headscale on the refused config (the model bites);
#   (B) the marker is cleared once a configuration passes the gate (static order check in provision_headscale)
#       and by the disabled branch;
#   (C) publish_cp_dns_record: a normal edit lands and leaves no temp file; a write that fails part-way leaves
#       config.yaml byte for byte as it was, no temp file, the gate STILL runs, no restart; if the old file
#       fails the gate it is refused; CONTROL/MUTATION: the old in-place write leaves a truncated config.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
GEN="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
INIT="${REPO}/specs/etc/init.d/headscale"
P=0; F=0
ok()  { echo "  ok   $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

for t in bash python3 awk sed cmp; do
  command -v "${t}" >/dev/null 2>&1 || { echo "  FAIL ${t} is required (refusing to skip)"; exit 2; }
done
for f in "${PROV}" "${GEN}" "${INIT}"; do [ -r "${f}" ] || { echo "  FAIL ${f} is missing"; exit 2; }; done
REALPY="$(command -v python3)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-hs-refusal-race.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "== headscale refusal: the restart race and the atomic CP DNS edit =="

# ── lift the real code, pointed at a sandbox ────────────────────────────────────────────
SB="${WORK}/sb"
lift_fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^}/ {exit}' "$1"; }
sandbox() { sed "s#/etc/headscale#${SB}/etc/headscale#g; s#/run/hugmesh#${SB}/run/hugmesh#g"; }
{
  grep -E '^HEADSCALE_REFUSED_MARK=' "${PROV}"
  lift_fn "${PROV}" headscale_policy_unprotected
  lift_fn "${PROV}" headscale_refuse_config
} | sandbox > "${WORK}/refuse.sh"
lift_fn "${PROV}" publish_cp_dns_record | sandbox > "${WORK}/publish.sh"
lift_fn "${GEN}" restart_headscale | sandbox > "${WORK}/restart.sh"
lift_fn "${INIT}" start_pre | sandbox > "${WORK}/start_pre.sh"
for f in refuse publish restart start_pre; do
  [ -s "${WORK}/${f}.sh" ] && bash -n "${WORK}/${f}.sh" 2>/dev/null && ok "lifted ${f} from the real file" || bad "could not lift ${f} (renamed or reshaped?)"
done
grep -q 'HEADSCALE_REFUSED_MARK' "${WORK}/refuse.sh" || bad "the lifted headscale_refuse_config does not mention HEADSCALE_REFUSED_MARK"

# ── (A) the race ────────────────────────────────────────────────────────────────────────
# A model of OpenRC: `restart` = stop, start_pre (a non-zero return aborts the start), start. `start` records
# which configuration it would start on. `stop` fires the registered hook (the cron) INSIDE the window.
cat > "${WORK}/model.sh" <<'EOF'
SVC_STATE=stopped; STARTED_ON=""; CRON_FIRED=0
log() { :; }; warn() { echo "WARN: $*" >> "${SB}/warn.log"; }
have() { [ "$1" = rc-service ] || command -v "$1" >/dev/null 2>&1; }
eerror() { echo "EERROR: $*" >> "${SB}/warn.log"; }
rc-update() { :; }; logger() { :; }
getent() { return 0; }; groupadd() { :; }; useradd() { :; }; checkpath() { :; }
svc_start() {
  start_pre || return 1
  SVC_STATE=started; STARTED_ON="$(ls "${SB}/etc/headscale" 2>/dev/null | tr '\n' ' ')"
}
rc-service() { # rc-service headscale <stop|start|restart>
  case "$2" in
    stop)    SVC_STATE=stopped
             # the window: the policy-sync cron fires while the config is still in place
             if [ -n "${IN_WINDOW:-}" ] && [ "${CRON_FIRED}" = 0 ]; then CRON_FIRED=1; "${IN_WINDOW}"; fi ;;
    start)   svc_start ;;
    restart) SVC_STATE=stopped; svc_start ;;
  esac
}
EOF
setup_sb() {
  rm -rf "${SB}"; mkdir -p "${SB}/etc/headscale" "${SB}/run/hugmesh"
  printf 'server_url: http://x\npolicy:\n  mode: file\n  path: /etc/headscale/acl.hujson\n' > "${SB}/etc/headscale/config.yaml"
}
cron_restart() { restart_headscale; }          # gen-headscale-policy.sh's apply leg
op_restart()   { rc-service headscale restart; } # an operator, or any other caller

race() { # race <refuse.sh> <window-hook>
  setup_sb
  ( set +u; . "${WORK}/model.sh"; . "${WORK}/start_pre.sh"; . "${WORK}/restart.sh"; . "$1"
    IN_WINDOW="$2"; headscale_refuse_config "test refusal"
    echo "STATE=${SVC_STATE} STARTED_ON=${STARTED_ON:-<never>} CRON=${CRON_FIRED}" > "${SB}/result" )
}
race "${WORK}/refuse.sh" cron_restart
R="$(cat "${SB}/result" 2>/dev/null)"
[ "${R}" = "STATE=stopped STARTED_ON=<never> CRON=1" ] && ok "a policy-sync restart fired inside the stop window does not start headscale (${R})" || bad "cron restart in the window: ${R:-<no result>}"
[ ! -e "${SB}/etc/headscale/config.yaml" ] && [ -f "${SB}/etc/headscale/config.yaml.refused" ] && ok "and the refused config.yaml is set aside" || bad "the refused config is still in place"
grep -q '^reason=test refusal' "${SB}/run/hugmesh/headscale.refused" 2>/dev/null && ok "the marker names the reason" || bad "no marker with the reason"
grep -q 'not restarting it' "${SB}/warn.log" 2>/dev/null && ok "restart_headscale said it refused" || bad "restart_headscale did not refuse by itself: $(cat "${SB}/warn.log" 2>/dev/null)"
race "${WORK}/refuse.sh" op_restart
R="$(cat "${SB}/result" 2>/dev/null)"
[ "${R}" = "STATE=stopped STARTED_ON=<never> CRON=1" ] && grep -q 'EERROR: headscale: keys-provision refused its configuration' "${SB}/warn.log" \
  && ok "a DIRECT rc-service restart in the window is stopped by the init script's start_pre" || bad "direct restart in the window: ${R}: $(cat "${SB}/warn.log" 2>/dev/null)"
# CONTROL: the same race with the marker write removed starts headscale on the refused configuration.
sed '/^    printf .since=/,/could not write/d' "${WORK}/refuse.sh" > "${WORK}/refuse-nomark.sh"
cmp -s "${WORK}/refuse.sh" "${WORK}/refuse-nomark.sh" && bad "control: the marker write was not removed (anchor drifted)" || {
  bash -n "${WORK}/refuse-nomark.sh" 2>/dev/null || bad "control: the mutated refuse function does not parse"
  race "${WORK}/refuse-nomark.sh" cron_restart
  R="$(cat "${SB}/result" 2>/dev/null)"
  case "${R}" in "STATE=started STARTED_ON=config.yaml"*) ok "CONTROL: without the marker the same cron restart STARTS headscale on config.yaml (${R})" ;;
    *) bad "CONTROL: the race model does not bite without the marker: ${R}" ;; esac; }
# CONTROL 2: restart_headscale without its marker check, init script without its start_pre check -> started.
sed '/headscale.refused}"\? \]/,/^    fi$/d' "${WORK}/restart.sh" > "${WORK}/restart-nocheck.sh"
sed '/-e \/run\/hugmesh\/headscale.refused\|-e .*headscale.refused/,/^    fi$/d' "${WORK}/start_pre.sh" > "${WORK}/start_pre-nocheck.sh"
if cmp -s "${WORK}/restart.sh" "${WORK}/restart-nocheck.sh" || cmp -s "${WORK}/start_pre.sh" "${WORK}/start_pre-nocheck.sh"; then
  bad "control 2: a marker check was not removed (anchor drifted)"
else
  setup_sb
  ( set +u; . "${WORK}/model.sh"; . "${WORK}/start_pre-nocheck.sh"; . "${WORK}/restart-nocheck.sh"; . "${WORK}/refuse.sh"
    IN_WINDOW=cron_restart; headscale_refuse_config "test refusal"
    echo "STATE=${SVC_STATE} STARTED_ON=${STARTED_ON:-<never>}" > "${SB}/result" )
  R="$(cat "${SB}/result" 2>/dev/null)"
  case "${R}" in "STATE=started STARTED_ON=config.yaml"*) ok "CONTROL: with both consumers' checks removed the marker alone does not save it (${R})" ;;
    *) bad "CONTROL 2: ${R}" ;; esac
fi

# ── (B) the marker is cleared ────────────────────────────────────────────────────────────
gate_ln="$(grep -n 'headscale_refuse_config "${cfg_fail} (the KEYS headscale/config.yaml must keep' "${PROV}" | head -1 | cut -d: -f1)"
clear_ln="$(awk -v s="${gate_ln:-0}" 'NR > s && /rm -f "\$\{HEADSCALE_REFUSED_MARK/ {print NR; exit}' "${PROV}")"
start_ln="$(awk -v s="${gate_ln:-0}" 'NR > s && /rc-service headscale start/ {print NR; exit}' "${PROV}")"
[ -n "${gate_ln}" ] && [ -n "${clear_ln}" ] && [ -n "${start_ln}" ] && [ "${clear_ln}" -gt "${gate_ln}" ] && [ "${clear_ln}" -lt "${start_ln}" ] \
  && ok "provision_headscale clears the marker after the gate passes and before it starts headscale (lines ${gate_ln} < ${clear_ln} < ${start_ln})" \
  || bad "the marker is not cleared between the gate and the start (gate=${gate_ln:-?} clear=${clear_ln:-?} start=${start_ln:-?})"
grep -qF 'rm -f "${HEADSCALE_DERP_STUN_MARKER}" "${HEADSCALE_REFUSED_MARK' "${PROV}" && ok "the manifest-disabled branch clears it too" || bad "the disabled branch leaves a stale marker"

# ── (C) the CP DNS edit ──────────────────────────────────────────────────────────────────
mkdir -p "${WORK}/pybin"
cat > "${WORK}/pybin/python3" <<EOF
#!/usr/bin/env bash
exec "${REALPY}" -c '
import sys, os, builtins, errno
src = sys.stdin.read(); sys.argv = ["-"] + sys.argv[2:]
if os.environ.get("PYFAIL") == "write":
    real_open = builtins.open
    class W:
        def __init__(self, f): self.f = f
        def write(self, d):
            self.f.write(d[: len(d) // 2]); self.f.flush()
            raise OSError(errno.ENOSPC, "No space left on device")
        def __enter__(self): return self
        def __exit__(self, *a): self.f.close(); return False
        def __getattr__(self, n): return getattr(self.f, n)
    def op(path, mode="r", *a, **k):
        f = real_open(path, mode, *a, **k)
        return W(f) if ("w" in mode and str(path).endswith(("config.yaml", ".hugmesh-new"))) else f
    builtins.open = op
exec(compile(src, "<heredoc>", "exec"), {"__name__": "__main__"})
' "\$@"
EOF
chmod +x "${WORK}/pybin/python3"
cat > "${WORK}/dns_model.sh" <<'EOF'
log() { :; }; warn() { echo "WARN: $*" >> "${SB}/warn.log"; }
have() { command -v "$1" >/dev/null 2>&1 || [ "$1" = headscale ]; }
resolve_cp_dns_name() { echo kube-api.test.internal; }
tailscale() { [ "$1 ${2:-}" = "ip -4" ] && echo 100.64.0.1; return 0; }
headscale_tls_cover_address() { return 0; }
chown() { :; }
rc-service() { echo "rc-service $*" >> "${SB}/rc"; }
headscale_config_gate() { echo gate >> "${SB}/calls"; if [ "${GATE_RC:-0}" != 0 ]; then echo "old file fails the gate"; return 1; fi; return 0; }
headscale_refuse_config() { echo "refuse: $1" >> "${SB}/calls"; }
EOF
CFG0=$'server_url: http://x\ndns:\n  magic_dns: true\npolicy:\n  mode: file\n  path: /etc/headscale/policy.hujson\n'
dns() { # dns <publish.sh> [PYFAIL=..] [GATE_RC=..]
  local fn="$1"; shift
  rm -rf "${SB}"; mkdir -p "${SB}/etc/headscale"; printf '%s' "${CFG0}" > "${SB}/etc/headscale/config.yaml"
  cp "${SB}/etc/headscale/config.yaml" "${SB}/config.before"; : > "${SB}/rc"; : > "${SB}/calls"
  ( set +u; export PATH="${WORK}/pybin:${PATH}" SB; for kv in "$@"; do export "${kv?}"; done
    . "${WORK}/dns_model.sh"; . "${fn}"; publish_cp_dns_record; echo "rc=$?" > "${SB}/rc.exit" )
}
tmpleft() { ls "${SB}/etc/headscale" | grep -c 'hugmesh-new' || true; }
restarts() { grep -c 'rc-service headscale restart' "${SB}/rc" || true; }
gates() { grep -c '^gate$' "${SB}/calls" || true; }

dns "${WORK}/publish.sh"
grep -q 'name: "kube-api.test.internal"' "${SB}/etc/headscale/config.yaml" && grep -q 'value: "100.64.0.1"' "${SB}/etc/headscale/config.yaml" \
  && [ "$(tmpleft)" = 0 ] && [ "$(gates)" = 1 ] && [ "$(restarts)" = 1 ] \
  && ok "a normal edit: the record is in config.yaml, no temp file left, the gate ran once, headscale restarted once" \
  || bad "normal edit: tmp=$(tmpleft) gates=$(gates) restarts=$(restarts): $(cat "${SB}/etc/headscale/config.yaml")"
stat -c %a "${SB}/etc/headscale/config.yaml" >/dev/null 2>&1 && ok "config.yaml is still a regular readable file" || bad "config.yaml is gone"

dns "${WORK}/publish.sh" PYFAIL=write
cmp -s "${SB}/config.before" "${SB}/etc/headscale/config.yaml" && ok "a write that fails part-way leaves config.yaml byte for byte as it was" \
  || bad "a failed write changed config.yaml: $(cat "${SB}/etc/headscale/config.yaml")"
[ "$(tmpleft)" = 0 ] && ok "and no temp file is left in /etc/headscale" || bad "a temp file was left: $(ls "${SB}/etc/headscale")"
[ "$(gates)" = 1 ] && ok "the gate STILL ran after the failed write" || bad "the gate did not run after the failed write (gates=$(gates))"
[ "$(restarts)" = 0 ] && grep -q '^rc=0$' "${SB}/rc.exit" && ok "no restart for a change that never landed (returns 0)" || bad "restarts=$(restarts) exit=$(cat "${SB}/rc.exit")"
grep -q 'was left as it was' "${SB}/warn.log" && ok "the failure is reported" || bad "the failed write was not reported"
dns "${WORK}/publish.sh" PYFAIL=write GATE_RC=1
grep -q '^refuse: after the CP DNS record was written: old file fails the gate' "${SB}/calls" && [ "$(restarts)" = 0 ] \
  && ok "a failed write over a config the gate refuses: refused, not restarted" || bad "failed write + failing gate: $(cat "${SB}/calls") restarts=$(restarts)"
# MUTATION: the old in-place write. The same failed write now leaves a truncated config.yaml.
python3 - "${WORK}/publish.sh" "${WORK}/publish-inplace.sh" <<'PYEOF'
import sys, re
s = open(sys.argv[1]).read()
a = s.index('tmp = p + ".hugmesh-new"'); b = s.index("\nPY\n", a)
open(sys.argv[2], "w").write(s[:a] + 'open(p, "w").write("".join(out))' + s[b:])
PYEOF
bash -n "${WORK}/publish-inplace.sh" 2>/dev/null || bad "mutation: the in-place copy does not parse"
dns "${WORK}/publish-inplace.sh" PYFAIL=write
cmp -s "${SB}/config.before" "${SB}/etc/headscale/config.yaml" && bad "mutation in-place-write: NOT caught (config.yaml unchanged)" \
  || ok "mutation in-place-write: caught (the failed write leaves a truncated config.yaml)"

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
