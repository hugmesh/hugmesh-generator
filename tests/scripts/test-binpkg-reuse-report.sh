#!/usr/bin/env bash
# test-binpkg-reuse-report.sh -- regression test for scripts/binpkg-reuse-report.py,
# the instrument that turns two builder logs (cold pool, warm pool) into the
# compile-once speedup docs/SHARED-BINPKG.md lists as UNPROVEN.
#
# HERMETIC: runs the real script over SYNTHETIC fixture logs in
# tests/scripts/fixtures/binpkg-reuse/ (hand-written in the shape of a builder log,
# NOT captures of a real build). What this proves is that the arithmetic and the
# refusal rules are right. It proves nothing about the speedup of a real board: that
# is operator_only, protocol in docs/BINPKG-MEASUREMENT-PLAN.md.
#
# Fixture truth table (10 merges per build: 4 in `system`, 6 in `image`):
#   cold.log          10 compiled, 0 from the pool, guard silent
#   warm-full.log      0 compiled, 10 from the pool
#   warm-partial.log   2 compiled (samba again = a pool MISS; newlib = new work), 9 pool
#   cold-notcold.log   8 of 10 from a pool + the guard's "adopting an UNSTAMPED" warning
#   warm-mismatch.log  the guard's FATAL ABI-MISMATCH text
#   warm-failed.log    a ">>> Failed to emerge" line
#   empty.log          no portage lines at all
#   host-cold/host-warm.log  one atom merged twice ("to /" host tool, "for <sysroot>" target),
#                     the host line repeated once as a --resume would: 2 merges, not 1 or 3
#   session-two-builds.log  cold then warm in ONE file (the shared build.log shape)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
TOOL="${REPO}/scripts/binpkg-reuse-report.py"
FX="${HERE}/fixtures/binpkg-reuse"
[ -f "${TOOL}" ] || { echo "  FAIL tool missing: ${TOOL}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
run() { python3 -I "${TOOL}" "$@"; }          # stdout+stderr to caller, rc preserved

# jq-free JSON field read: jget <file> <python expr over d>
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

expect_eq() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: got '$2', want '$3'"; fi
}

echo "== binpkg-reuse-report (compile-once measurement harness) =="

# -- (1) full reuse: every number exact -------------------------------------------
J="${TMP}/full.json"
run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall 2h --warm-wall 30m --json >"${J}"; rc=$?
expect_eq "full reuse: exit status" "${rc}" 0
expect_eq "full reuse: valid" "$(jget "${J}" 'd["valid"]')" True
expect_eq "full reuse: cold compiled" "$(jget "${J}" 'd["cold"]["compiled"]')" 10
expect_eq "full reuse: warm compiled" "$(jget "${J}" 'd["warm"]["compiled"]')" 0
expect_eq "full reuse: warm binary" "$(jget "${J}" 'd["warm"]["binary"]')" 10
expect_eq "full reuse: warm reuse pct" "$(jget "${J}" 'd["warm_reuse_pct"]')" 100.0
expect_eq "full reuse: compile reduction pct" "$(jget "${J}" 'd["compile_reduction_pct"]')" 100.0
expect_eq "full reuse: wall speedup (2h / 30m)" "$(jget "${J}" 'd["wall_speedup"]')" 4.0
expect_eq "full reuse: per-group image warm binary" "$(jget "${J}" 'd["per_group"]["image"]["warm_binary"]')" 6
# the ANSI-wrapped banner and the " for <root>" tails must not hide the group or the atom
expect_eq "full reuse: groups found (ANSI banner parsed)" "$(jget "${J}" 'sorted(d["per_group"])')" "['image', 'system']"

# -- (2) partial reuse: a real pool MISS and new work are separated -----------------
J="${TMP}/partial.json"
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" --json >"${J}"; rc=$?
expect_eq "partial: exit status" "${rc}" 0
expect_eq "partial: warm compiled" "$(jget "${J}" 'd["warm"]["compiled"]')" 2
expect_eq "partial: warm binary" "$(jget "${J}" 'd["warm"]["binary"]')" 9
expect_eq "partial: warm reuse pct (9 of 11)" "$(jget "${J}" 'd["warm_reuse_pct"]')" 81.8
expect_eq "partial: compile reduction pct (10 -> 2)" "$(jget "${J}" 'd["compile_reduction_pct"]')" 80.0
expect_eq "partial: hit rate on cold's set (9 of 10)" "$(jget "${J}" 'd["common_set"]["hit_rate_pct"]')" 90.0
expect_eq "partial: the one miss is samba" "$(jget "${J}" '[x.split()[0] for x in d["recompiled_despite_pool"]]')" "['net-fs/samba-4.22.3']"
expect_eq "partial: the one new compile is newlib" "$(jget "${J}" '[x.split()[0] for x in d["new_compiles_in_warm"]]')" "['dev-libs/newlib-1.0']"
expect_eq "partial: wall speedup unknown without walls" "$(jget "${J}" 'd["wall_speedup"]')" None

# -- (3) gates: pass, fail, and an UNKNOWN figure never passes ----------------------
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" --min-reuse 80 >/dev/null; rc=$?
expect_eq "gate --min-reuse 80 met (81.8)" "${rc}" 0
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" --min-reuse 90 >/dev/null; rc=$?
expect_eq "gate --min-reuse 90 not met (81.8) -> exit 1" "${rc}" 1
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" --min-speedup 2 >/dev/null; rc=$?
expect_eq "gate --min-speedup with no wall supplied -> exit 1 (unknown never passes)" "${rc}" 1
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" --cold-wall 3600 --warm-wall 1800 --min-speedup 2 >/dev/null; rc=$?
expect_eq "gate --min-speedup 2 met at exactly 2.0x" "${rc}" 0

# -- (4) invalid measurements are refused (exit 2), not reported as a speedup -------
run --cold "${FX}/cold-notcold.log" --warm "${FX}/warm-full.log" >"${TMP}/o.txt" 2>&1; rc=$?
expect_eq "cold run that was not cold -> exit 2" "${rc}" 2
case "$(cat "${TMP}/o.txt")" in *"cold run is not cold"*) ok "not-cold: names the 80% pool share";; *) bad "not-cold: reason missing";; esac
case "$(cat "${TMP}/o.txt")" in *"UNSTAMPED"*) ok "not-cold: the guard's unstamped-pool warning is used";; *) bad "not-cold: UNSTAMPED warning not used";; esac
run --cold "${FX}/cold.log" --warm "${FX}/warm-mismatch.log" >"${TMP}/o.txt" 2>&1; rc=$?
expect_eq "fingerprint-guard refusal in the warm log -> exit 2" "${rc}" 2
case "$(cat "${TMP}/o.txt")" in *"ABI MISMATCH"*) ok "mismatch: reason names the guard";; *) bad "mismatch: reason missing";; esac
run --cold "${FX}/cold.log" --warm "${FX}/warm-failed.log" >"${TMP}/o.txt" 2>&1; rc=$?
expect_eq "failed emerge in the warm log -> exit 2" "${rc}" 2
run --cold "${FX}/empty.log" --warm "${FX}/warm-full.log" >"${TMP}/o.txt" 2>&1; rc=$?
expect_eq "log with no Emerging line -> exit 2" "${rc}" 2
run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --min-reuse 1 --cold-max-binary-pct 0 \
    --warm "${FX}/warm-failed.log" >/dev/null 2>&1; rc=$?
expect_eq "an invalid run never reaches the gates (exit 2, not 0/1)" "${rc}" 2

# -- (5) segments: cold and warm taken from ONE session-shared log -----------------
run --list-segments --cold "${FX}/session-two-builds.log" --warm "${FX}/session-two-builds.log" >"${TMP}/seg.txt"; rc=$?
expect_eq "list-segments: exit status" "${rc}" 0
expect_eq "list-segments: 2 builds per log (headers counted, preamble dropped)" "$(grep -c '^cold ' "${TMP}/seg.txt")" 2
J="${TMP}/seg.json"
run --cold "${FX}/session-two-builds.log" --cold-segment 1 --warm "${FX}/session-two-builds.log" --warm-segment 2 --json >"${J}"; rc=$?
expect_eq "segments 1 vs 2: valid" "$(jget "${J}" 'd["valid"]')" True
expect_eq "segments 1 vs 2: cold compiled / warm binary" "$(jget "${J}" '(d["cold"]["compiled"], d["warm"]["binary"])')" "(10, 10)"
J="${TMP}/seglast.json"
run --cold "${FX}/session-two-builds.log" --cold-segment 1 --warm "${FX}/session-two-builds.log" --json >"${J}"
expect_eq "default warm segment is the LAST build" "$(jget "${J}" 'd["warm"]["binary"]')" 10
run --cold "${FX}/session-two-builds.log" --cold-segment 9 --warm "${FX}/warm-full.log" >/dev/null 2>&1; rc=$?
expect_eq "segment out of range -> non-zero" "$([ "${rc}" -ne 0 ] && echo nonzero || echo zero)" nonzero
# the whole file (both builds merged into one) must NOT pass as a cold run: that is the
# silent-merge error segment support exists to prevent
run --cold "${FX}/session-two-builds.log" --cold-segment 2 --warm "${FX}/warm-full.log" >/dev/null 2>&1; rc=$?
expect_eq "picking the WARM build as cold -> exit 2" "${rc}" 2

# -- (5b) the same atom merged to / AND into the sysroot is two merges; a repeat is one --
J="${TMP}/host.json"
run --cold "${FX}/host-cold.log" --warm "${FX}/host-warm.log" --json >"${J}"; rc=$?
expect_eq "host+target merge of one atom: cold compiled (2, repeat ignored)" "$(jget "${J}" 'd["cold"]["compiled"]')" 2
expect_eq "host+target merge of one atom: warm binary" "$(jget "${J}" 'd["warm"]["binary"]')" 2
expect_eq "host+target merge of one atom: hit rate on cold's set" "$(jget "${J}" 'd["common_set"]["hit_rate_pct"]')" 100.0

expect_eq "host+target merge: by_root host warm binary" "$(jget "${J}" 'd["by_root"]["host"]["warm_binary"]')" 1
expect_eq "host+target merge: by_root target warm binary" "$(jget "${J}" 'd["by_root"]["target"]["warm_binary"]')" 1
expect_eq "host+target merge: by_root host cold compiled" "$(jget "${J}" 'd["by_root"]["host"]["cold_compiled"]')" 1

# -- (6) wall spellings --------------------------------------------------------------
for spelling in "7200" "2:00:00" "2h" "120:00" "1h60m"; do
    J="${TMP}/w.json"
    run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall "${spelling}" --warm-wall 3600 --json >"${J}" 2>/dev/null
    expect_eq "wall spelling '${spelling}' = 7200 s" "$(jget "${J}" 'd["cold"]["wall_s"]')" 7200.0
done
printf '2h\n' > "${TMP}/cold.wall"
J="${TMP}/w.json"; run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall "@${TMP}/cold.wall" --warm-wall 1h --json >"${J}"
expect_eq "wall from @FILE" "$(jget "${J}" 'd["wall_speedup"]')" 2.0
run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall banana >/dev/null 2>&1; rc=$?
expect_eq "unreadable wall -> exit 2" "${rc}" 2

# -- (7) text report carries the headline numbers ------------------------------------
run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall 2h --warm-wall 30m >"${TMP}/t.txt"
case "$(cat "${TMP}/t.txt")" in *"4.00x whole-run"*) ok "text report prints the speedup";; *) bad "text report lacks the speedup";; esac
case "$(cat "${TMP}/t.txt")" in *"MEASUREMENT VALID"*) ok "text report prints the verdict";; *) bad "text report lacks the verdict";; esac

echo "== binpkg-reuse-report: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
