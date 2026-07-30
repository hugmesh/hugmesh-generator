#!/usr/bin/env bash
# test-sunshine-fence.sh — composition test for the thin-desktop (Sunshine)
# mesh fence: specs/usr/sbin/hugmesh-sunshine-firewall (the nftables renderer)
# and specs/usr/bin/hugmesh-sunshine-session (the in-session launcher).
#
# Both scripts are the SUT and are executed for real; only their external
# dependencies (nft, sunshine, ip, pgrep, logger) are PATH stubs, so the
# rendered ruleset text and the fail-closed handshake between the two halves
# are genuinely exercised.
#
# REGRESSION COVERAGE (each of these FAILED on the shipped origin/main):
#
#  (A) DUAL-STACK ADMIT. The tailnet is dual-stack (etc/headscale/config.yaml
#      prefixes v4 100.64.0.0/10 + v6 fd7a:115c:a1e0::/48) and inside an
#      nftables `inet` table an `ip saddr` match carries an implicit ipv4
#      dependency — it can NEVER match an IPv6 packet. The shipped fence had
#      ONLY `ip saddr` accepts plus family-agnostic catch-all drops, so every
#      Moonlight connection that resolved the host's MagicDNS AAAA record was
#      silently dropped. Assert an `ip6 saddr <v6 prefix>` accept exists for
#      BOTH the TCP port set and the UDP range, on the tailscale iface, and
#      that the v6 prefix agrees with the headscale config.
#
#  (B) FAIL-CLOSED COMPOSITION. The fence is the only thing that scopes
#      Sunshine to the tailnet (Sunshine has no bind-to-interface option), yet
#      the shipped renderer exited 0 on every error path and the launcher
#      started Sunshine unconditionally — a fail-OPEN pair that binds
#      47984/47989/48010 + UDP 47998-48002 on every LAN/WAN address. Assert:
#        * a successful load writes the fence-ready marker and exits 0;
#        * `nft -f` failing => non-zero exit, marker REMOVED, ruleset untouched;
#        * nft missing entirely => non-zero exit, marker REMOVED;
#        * a load that "succeeds" but leaves no table => non-zero, no marker;
#        * the launcher REFUSES (non-zero, sunshine never exec'd) with no
#          marker, with a stale marker naming a different table, and PROCEEDS
#          only when the marker matches.
#
#  (C) LOOPBACK PIN. 47990 (pairing web UI / PIN entry) stays loopback-only.
#
# NEGATIVE CONTROLS are built in: (A)'s grep assertions are re-run against a
# staged IPv4-only copy of the renderer and must FAIL there, and (B)'s launcher
# gate is re-run against a staged copy with the gate removed and must let
# Sunshine through — so a green run cannot be a tautology.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FENCE="${REPO}/specs/usr/sbin/hugmesh-sunshine-firewall"
SESSION="${REPO}/specs/usr/bin/hugmesh-sunshine-session"
HEADSCALE="${REPO}/specs/etc/headscale/config.yaml"

for f in "${FENCE}" "${SESSION}" "${HEADSCALE}"; do
  [ -f "$f" ] || { echo "  FAIL missing SUT: $f"; exit 1; }
done

P=0; F=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"; mkdir -p "${BIN}"

echo "== thin-desktop (Sunshine) mesh-fence composition test =="

# ── stubs ────────────────────────────────────────────────────────────────────
# nft: records the rendered ruleset, and simulates load/list outcomes via
# NFT_LOAD_RC / NFT_LIST_RC so the error paths are reachable without root.
cat > "${BIN}/nft" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -f) cat "${2}" > "${NFT_RENDER_OUT}"; exit "${NFT_LOAD_RC:-0}" ;;
  list) exit "${NFT_LIST_RC:-0}" ;;
esac
exit 0
STUB
# sunshine: records that it was launched (the thing the gate must prevent).
cat > "${BIN}/sunshine" <<'STUB'
#!/usr/bin/env bash
echo "LAUNCHED $*" >> "${SUNSHINE_LAUNCH_LOG}"
exit 0
STUB
cat > "${BIN}/ip" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "${BIN}/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "${BIN}/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${BIN}"/*

# Run the fence renderer with the stub PATH ahead of the real one.
# $1 = state-file path, $2 = where the stub nft records the rendered ruleset.
# Globals NFT_LOAD_RC / NFT_LIST_RC steer the simulated nft outcome;
# FENCE_SUT overrides which copy of the script is executed.
NFT_LOAD_RC=0
NFT_LIST_RC=0
FENCE_SUT="${FENCE}"
SESSION_SUT="${SESSION}"
run_fence() {
  local state="$1" render="$2"
  env PATH="${BIN}:${PATH}" \
      NFT_RENDER_OUT="${render}" \
      NFT_LOAD_RC="${NFT_LOAD_RC}" \
      NFT_LIST_RC="${NFT_LIST_RC}" \
      HUGMESH_SUNSHINE_FENCE_STATE="${state}" \
      bash "${FENCE_SUT}" >/dev/null 2>&1
}

# Run the launcher; echoes its exit code. $1 = state-file path.
run_session() {
  local state="$1" launchlog="$2" home="${WORK}/home"
  mkdir -p "${home}"
  env PATH="${BIN}:${PATH}" \
      HOME="${home}" XDG_STATE_HOME="${home}/state" \
      SUNSHINE_LAUNCH_LOG="${launchlog}" \
      HUGMESH_SUNSHINE_FENCE_STATE="${state}" \
      bash "${SESSION_SUT}" >/dev/null 2>&1
  echo $?
}

# ── (A) dual-stack admit ─────────────────────────────────────────────────────
echo "-- (A) dual-stack tailnet admit --"

V6_PREFIX="$(awk '/^prefixes:/{p=1;next} p&&/^[^ ]/{p=0} p&&/v6:/{print $2;exit}' "${HEADSCALE}")"
[ -n "${V6_PREFIX}" ] || { echo "  FAIL could not read prefixes.v6 from ${HEADSCALE}"; exit 1; }
V4_PREFIX="$(awk '/^prefixes:/{p=1;next} p&&/^[^ ]/{p=0} p&&/v4:/{print $2;exit}' "${HEADSCALE}")"
ok "headscale tailnet prefixes: v4=${V4_PREFIX} v6=${V6_PREFIX}"

RENDER="${WORK}/ruleset.nft"
STATE="${WORK}/fence.state"
NFT_LOAD_RC=0; NFT_LIST_RC=0; run_fence "${STATE}" "${RENDER}"
[ -s "${RENDER}" ] || { echo "  FAIL renderer produced no ruleset"; exit 1; }

# Assertions run as a function so the negative control can re-use them.
assert_dualstack() { # <ruleset-file> <report-fn>
  local rs="$1" rep="$2"
  local tcpports='47984, 47989, 48010' udprange='47998-48002'
  if grep -Eq "iifname \"tailscale0\" ip saddr ${V4_PREFIX//./\\.} tcp dport \{ ${tcpports} \} accept" "${rs}"; then
    "${rep}" "v4 TCP accept present"
  else "${rep}" "v4 TCP accept MISSING"; fi
  if grep -Eq "iifname \"tailscale0\" ip saddr ${V4_PREFIX//./\\.} udp dport ${udprange} accept" "${rs}"; then
    "${rep}" "v4 UDP accept present"
  else "${rep}" "v4 UDP accept MISSING"; fi
  if grep -Eq "iifname \"tailscale0\" ip6 saddr ${V6_PREFIX} tcp dport \{ ${tcpports} \} accept" "${rs}"; then
    "${rep}" "v6 TCP accept present (IPv6 streams reach Sunshine)"
  else "${rep}" "v6 TCP accept MISSING — every IPv6/MagicDNS-AAAA stream is dropped"; fi
  if grep -Eq "iifname \"tailscale0\" ip6 saddr ${V6_PREFIX} udp dport ${udprange} accept" "${rs}"; then
    "${rep}" "v6 UDP accept present (IPv6 video/audio/mic reach Sunshine)"
  else "${rep}" "v6 UDP accept MISSING — IPv6 media is dropped"; fi
}
report_pos() { case "$1" in *MISSING*) bad "$1";; *) ok "$1";; esac; }
report_neg() { case "$1" in *MISSING*) NEG_MISSING=$((NEG_MISSING+1));; esac; }
assert_dualstack "${RENDER}" report_pos

# (C) loopback pin — same render
if grep -q 'iifname "lo" tcp dport 47990 accept' "${RENDER}" && \
   grep -q '^\s*tcp dport 47990 drop' "${RENDER}"; then
  ok "(C) pairing web UI 47990 is loopback-only (accept on lo + unconditional drop)"
else
  bad "(C) 47990 loopback pin missing from the rendered ruleset"
fi
# The catch-all drops must stay family-agnostic (that is what makes (A) load-bearing).
if grep -Eq '^\s*tcp dport \{ 47984, 47989, 48010 \} drop' "${RENDER}" && \
   grep -Eq '^\s*udp dport 47998-48002 drop' "${RENDER}"; then
  ok "(A) catch-all drops are family-agnostic (v4 AND v6 non-tailnet traffic dropped)"
else
  bad "(A) catch-all drops missing/family-qualified — non-tailnet traffic would be accepted"
fi

# NEGATIVE CONTROL: strip the ip6 rules from a staged copy; (A) must FAIL there.
STAGED_V4ONLY="${WORK}/fence-v4only"
grep -v 'ip6 saddr' "${FENCE}" > "${STAGED_V4ONLY}"
RENDER_NEG="${WORK}/ruleset-v4only.nft"
FENCE_SUT="${STAGED_V4ONLY}"; NFT_LOAD_RC=0; NFT_LIST_RC=0
run_fence "${WORK}/neg.state" "${RENDER_NEG}"
FENCE_SUT="${FENCE}"
NEG_MISSING=0
assert_dualstack "${RENDER_NEG}" report_neg
if [ "${NEG_MISSING}" -eq 2 ]; then
  ok "(A) negative control: an IPv4-only fence trips exactly the 2 v6 assertions"
else
  bad "(A) negative control did NOT fire as expected (${NEG_MISSING} of 2 v6 assertions failed) — the checks are tautological"
fi

# ── (B) fail-closed composition ──────────────────────────────────────────────
echo "-- (B) fail-closed composition (renderer marker <-> launcher gate) --"

# B1 happy path: marker written, exit 0.
rm -f "${STATE}"
NFT_LOAD_RC=0; NFT_LIST_RC=0; run_fence "${STATE}" "${RENDER}"; rc=$?
if [ "${rc}" -eq 0 ] && grep -qx 'table=hugmesh_thin_desktop' "${STATE}" 2>/dev/null; then
  ok "(B1) successful load => exit 0 + fence-ready marker naming the table"
else
  bad "(B1) successful load did not produce a valid marker (rc=${rc})"
fi

# B2 nft -f fails: non-zero, marker gone.
NFT_LOAD_RC=1; NFT_LIST_RC=0; run_fence "${STATE}" "${WORK}/ignored.nft"; rc=$?
if [ "${rc}" -ne 0 ] && [ ! -e "${STATE}" ]; then
  ok "(B2) nft -f failure => non-zero exit + marker REMOVED (fail-closed)"
else
  bad "(B2) nft -f failure left rc=${rc} / marker present=$([ -e "${STATE}" ] && echo yes || echo no)"
fi

# B3 load "succeeds" but the table is not actually present.
NFT_LOAD_RC=0; NFT_LIST_RC=0; run_fence "${STATE}" "${RENDER}"            # re-arm marker
NFT_LOAD_RC=0; NFT_LIST_RC=1; run_fence "${STATE}" "${RENDER}"; rc=$?
if [ "${rc}" -ne 0 ] && [ ! -e "${STATE}" ]; then
  ok "(B3) table absent after load => non-zero exit + marker REMOVED"
else
  bad "(B3) missing table was accepted (rc=${rc}) — marker written on nft's exit code alone"
fi

# B4 nft binary missing entirely.
NOFT="${WORK}/nonft"; mkdir -p "${NOFT}"
cp "${BIN}/sunshine" "${BIN}/ip" "${BIN}/pgrep" "${BIN}/logger" "${NOFT}/"
NFT_LOAD_RC=0; NFT_LIST_RC=0; run_fence "${STATE}" "${RENDER}"            # re-arm marker
env PATH="${NOFT}:/usr/bin:/bin" HUGMESH_SUNSHINE_FENCE_STATE="${STATE}" \
    bash "${FENCE}" >/dev/null 2>&1; rc=$?
if [ "${rc}" -ne 0 ] && [ ! -e "${STATE}" ]; then
  ok "(B4) nft absent => non-zero exit + marker REMOVED (no silent exit 0)"
else
  bad "(B4) nft absent still reported success (rc=${rc}) / marker present=$([ -e "${STATE}" ] && echo yes || echo no)"
fi

# B5 launcher refuses with NO marker.
LAUNCHLOG="${WORK}/launch.log"; : > "${LAUNCHLOG}"; rm -f "${STATE}"
rc="$(run_session "${STATE}" "${LAUNCHLOG}")"
if [ "${rc}" -ne 0 ] && [ ! -s "${LAUNCHLOG}" ]; then
  ok "(B5) no fence marker => launcher exits ${rc} and NEVER execs sunshine"
else
  bad "(B5) launcher started Sunshine with no fence loaded (rc=${rc}, launches=$(wc -l < "${LAUNCHLOG}"))"
fi

# B6 launcher refuses on a STALE/foreign marker (different table name).
: > "${LAUNCHLOG}"; printf 'table=some_other_table\n' > "${STATE}"
rc="$(run_session "${STATE}" "${LAUNCHLOG}")"
if [ "${rc}" -ne 0 ] && [ ! -s "${LAUNCHLOG}" ]; then
  ok "(B6) marker naming a foreign table => launcher still refuses"
else
  bad "(B6) launcher accepted a marker for a different nftables table (rc=${rc})"
fi

# B7 launcher proceeds when the real renderer armed the marker.
: > "${LAUNCHLOG}"; rm -f "${STATE}"
NFT_LOAD_RC=0; NFT_LIST_RC=0; run_fence "${STATE}" "${RENDER}"
rc="$(run_session "${STATE}" "${LAUNCHLOG}")"
if [ "${rc}" -eq 0 ] && grep -q '^LAUNCHED' "${LAUNCHLOG}"; then
  ok "(B7) fence armed by the real renderer => launcher execs sunshine (gate is not a brick)"
else
  bad "(B7) launcher refused despite a valid fence marker (rc=${rc})"
fi

# NEGATIVE CONTROL for the launcher gate: strip the gate, confirm Sunshine runs
# with no marker — i.e. B5/B6 are detecting the gate, not an unrelated failure.
STAGED_NOGATE="${WORK}/session-nogate"
awk '/if ! grep -qx/{skip=1} skip{ if ($0 == "fi") skip=0; next } {print}' \
    "${SESSION}" > "${STAGED_NOGATE}"
grep -q 'grep -qx' "${STAGED_NOGATE}" && { echo "  FAIL negative-control staging did not remove the gate"; exit 1; }
: > "${LAUNCHLOG}"; rm -f "${STATE}"
SESSION_SUT="${STAGED_NOGATE}"
rc="$(run_session "${STATE}" "${LAUNCHLOG}")"
SESSION_SUT="${SESSION}"
if [ "${rc}" -eq 0 ] && grep -q '^LAUNCHED' "${LAUNCHLOG}"; then
  ok "(B) negative control: with the gate removed Sunshine DOES start unfenced (B5/B6 are real)"
else
  bad "(B) negative control failed to launch (rc=${rc}) — B5/B6 may be passing for the wrong reason"
fi

echo
echo "== sunshine fence: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
