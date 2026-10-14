#!/usr/bin/env bash
# test-binpkg-reuse-report.sh -- regression test for scripts/binpkg-reuse-report.py,
# the instrument that turns two builder logs (cold pool, warm pool) into the
# compile-once speedup docs/SHARED-BINPKG.md lists as UNPROVEN.
#
# HERMETIC: runs the real script over fixture logs in tests/scripts/fixtures/binpkg-reuse/.
# Most are SYNTHETIC (hand-written in the shape of a builder log, NOT captures of a real
# build); the real-*.log files are verbatim EXCERPTS of real Pi and x86 builder logs
# (their first line says which, and which lines were derived). The synthetic ones fix
# the arithmetic and the refusal rules; the real-shape ones fix the line shape the
# host/target split reads, which a hand-written fixture got wrong once (it used
# " to /", a tail no real log has). It proves nothing about the speedup of a real board: that
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
#   host-cold/host-warm.log  one atom merged twice (a literal " to /" host tool, "for <sysroot>"
#                     target), the host line repeated once as a --resume would: 2 merges, not 1 or 3
#   real-pi5-cold.log   22 real Pi merges: 6 host (NO tail) + 16 target (" for /out/wl-pki.rpi5/sysroot/")
#   real-pi5-warm.log   the same, sysroot dir renamed (wl-pki-2.rpi5), 20 from the pool, host
#                     libseccomp and target readline compiled again
#   real-pi5-warm-short.log  its system group only: 8 atoms of the cold set never merged
#   (generated in the test) warm-trunc = warm-full cut after its first merge; cold-trunc = cold cut
#                     after its first merge. The truncated-run cases below.
#   real-x86-cold/warm.log   5 real native-chroot merges, no tail anywhere
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
case "$(cat "${TMP}/o.txt")" in *"retried"*) ok "failed emerge: says a retried failure counts too";; *) bad "failed emerge: retry caveat missing";; esac
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

# -- (5c) REAL line shapes: a Pi build prints NO tail for a host tool and " for <sysroot>/" for
# the target; the sysroot directory differs between two Studio builds ---------------------
J="${TMP}/pi.json"
run --cold "${FX}/real-pi5-cold.log" --warm "${FX}/real-pi5-warm.log" --json >"${J}"; rc=$?
expect_eq "real pi: exit status" "${rc}" 0
expect_eq "real pi: valid" "$(jget "${J}" 'd["valid"]')" True
expect_eq "real pi: by_root keys" "$(jget "${J}" 'sorted(d["by_root"])')" "['host', 'target']"
expect_eq "real pi: host (tail-less) cold compiled" "$(jget "${J}" 'd["by_root"]["host"]["cold_compiled"]')" 6
expect_eq "real pi: target cold compiled" "$(jget "${J}" 'd["by_root"]["target"]["cold_compiled"]')" 16
expect_eq "real pi: host warm binary / compiled" "$(jget "${J}" '(d["by_root"]["host"]["warm_binary"], d["by_root"]["host"]["warm_compiled"])')" "(5, 1)"
expect_eq "real pi: host warm reuse pct" "$(jget "${J}" 'd["by_root"]["host"]["warm_reuse_pct"]')" 83.3
expect_eq "real pi: target warm binary / compiled" "$(jget "${J}" '(d["by_root"]["target"]["warm_binary"], d["by_root"]["target"]["warm_compiled"])')" "(15, 1)"
# the sysroot directory was renamed between the runs: every target atom must still be matched
expect_eq "real pi: renamed sysroot: hit rate on cold's set (20 of 22)" "$(jget "${J}" 'd["common_set"]["hit_rate_pct"]')" 90.9
expect_eq "real pi: renamed sysroot: nothing absent from warm" "$(jget "${J}" 'd["common_set"]["absent_from_warm"]')" 0
expect_eq "real pi: renamed sysroot: no phantom new work" "$(jget "${J}" 'd["new_compiles_in_warm"]')" "[]"
expect_eq "real pi: the two pool misses, one per role" "$(jget "${J}" 'd["recompiled_despite_pool"]')" "['sys-libs/libseccomp-2.6.1 [system] host', 'sys-libs/readline-8.3_p6 [system] target']"
# a genuine miss under a renamed sysroot is a MISS, not new work (the skeptic's case)
sed -e 's/^>>> Emerging binary (\(1[0-9]*\) of 137) \(sys-apps\/attr\)/>>> Emerging (\1 of 137) \2/' \
    "${FX}/real-pi5-warm.log" >"${TMP}/pi-warm-miss.log"
run --cold "${FX}/real-pi5-cold.log" --warm "${TMP}/pi-warm-miss.log" --json >"${J}"
expect_eq "real pi: a miss under a renamed sysroot is named a MISS (3 misses)" "$(jget "${J}" 'len(d["recompiled_despite_pool"])')" 3
expect_eq "real pi: ...and is not new work" "$(jget "${J}" 'd["new_compiles_in_warm"]')" "[]"
# atoms cold compiled that warm never merged count AGAINST the hit rate, and say so
J="${TMP}/pishort.json"
run --cold "${FX}/real-pi5-cold.log" --warm "${FX}/real-pi5-warm-short.log" --json >"${J}"; rc=$?
expect_eq "short warm: 8 of 22 atoms never merged -> not the same package set, exit 2" "${rc}" 2
expect_eq "short warm: 8 atoms absent" "$(jget "${J}" 'd["common_set"]["absent_from_warm"]')" 8
expect_eq "short warm: hit rate counts absent as not reused (12 of 22)" "$(jget "${J}" 'd["common_set"]["hit_rate_pct"]')" 54.5
expect_eq "short warm: hit rate of those warm merged (12 of 14)" "$(jget "${J}" 'd["common_set"]["hit_rate_of_merged_pct"]')" 85.7
expect_eq "short warm: a note names the absent atoms" "$(jget "${J}" 'any("never merged in the warm run" in n for n in d["notes"])')" True
run --cold "${FX}/real-pi5-cold.log" --warm "${FX}/real-pi5-warm-short.log" >"${TMP}/t.txt"
case "$(cat "${TMP}/t.txt")" in *"of those warm merged     85.7%"*) ok "text report prints both hit rates";; *) bad "text report lacks the second hit rate";; esac
# a native (x86 chroot) build prints no tail on any line: ONE root, not "everything is a host tool"
J="${TMP}/x86.json"
run --cold "${FX}/real-x86-cold.log" --warm "${FX}/real-x86-warm.log" --json >"${J}"; rc=$?
expect_eq "real x86: exit status" "${rc}" 0
expect_eq "real x86: by_root is one native root" "$(jget "${J}" 'sorted(d["by_root"])')" "['native']"
expect_eq "real x86: native cold compiled / warm binary" "$(jget "${J}" '(d["by_root"]["native"]["cold_compiled"], d["by_root"]["native"]["warm_binary"])')" "(5, 5)"
expect_eq "real x86: a note says there is no host/target split" "$(jget "${J}" 'any("native build" in n for n in d["notes"])')" True
# one run with a root tail and one without is not a comparable split
run --cold "${FX}/real-pi5-cold.log" --warm "${FX}/real-x86-warm.log" --json >"${J}"
expect_eq "tail in one run only: a note says the split is not comparable" "$(jget "${J}" 'any("not comparable" in n for n in d["notes"])')" True

# -- (5d) a run that stopped early: EVERY figure counts the atoms it never merged as not reused,
# and the runs are refused as two different package sets. A warm-only denominator read 100%
# beside nine atoms warm never merged, and --min-reuse 90 passed on it. -------------------------
head -8 "${FX}/warm-full.log" >"${TMP}/warm-trunc.log"     # header, plan, system group, 1 binary merge
head -8 "${FX}/cold.log" >"${TMP}/cold-trunc.log"
J="${TMP}/trunc.json"
run --cold "${FX}/cold.log" --warm "${TMP}/warm-trunc.log" --min-reuse 90 --min-compile-reduction 90 \
    --min-hit-rate 90 --json >"${J}"; rc=$?
expect_eq "truncated warm: refused, exit 2 (the gates are never reached)" "${rc}" 2
expect_eq "truncated warm: not valid" "$(jget "${J}" 'd["valid"]')" False
expect_eq "truncated warm: the problem names the package set" "$(jget "${J}" 'any("same package set" in p for p in d["problems"])')" True
# the figures themselves, with the refusal switched off (--max-set-diff-pct 100)
run --cold "${FX}/cold.log" --warm "${TMP}/warm-trunc.log" --max-set-diff-pct 100 --json >"${J}"; rc=$?
expect_eq "truncated warm, tolerated: exit 0 with no gate" "${rc}" 0
expect_eq "truncated warm: warm reuse counts the 9 absent atoms (1 of 1+9)" "$(jget "${J}" 'd["warm_reuse_pct"]')" 10.0
expect_eq "truncated warm: compile reduction counts them as still compiled" "$(jget "${J}" 'd["compile_reduction_pct"]')" 10.0
expect_eq "truncated warm: hit rate (1 of 10)" "$(jget "${J}" 'd["common_set"]["hit_rate_pct"]')" 10.0
expect_eq "truncated warm: per-group system reuse (1 of 1+3 missing)" "$(jget "${J}" 'd["per_group"]["system"]["warm_reuse_pct"]')" 25.0
expect_eq "truncated warm: per-group image reuse (0 merges, 6 missing) is 0, not n/a" "$(jget "${J}" 'd["per_group"]["image"]["warm_reuse_pct"]')" 0.0
expect_eq "truncated warm: by-root target reuse is 0, not n/a" "$(jget "${J}" 'd["by_root"]["target"]["warm_reuse_pct"]')" 0.0
expect_eq "truncated warm: by-root host reuse (1 of 1+3 missing)" "$(jget "${J}" 'd["by_root"]["host"]["warm_reuse_pct"]')" 25.0
for g in "--min-reuse 90" "--min-compile-reduction 90" "--min-hit-rate 90"; do
    # shellcheck disable=SC2086
    run --cold "${FX}/cold.log" --warm "${TMP}/warm-trunc.log" --max-set-diff-pct 100 ${g} >/dev/null; rc=$?
    expect_eq "truncated warm, tolerated: gate ${g} fails -> exit 1" "${rc}" 1
done
run --cold "${FX}/cold.log" --warm "${TMP}/warm-trunc.log" --max-set-diff-pct 100 --cold-wall 2h --warm-wall 10m \
    --min-speedup 2 --json >"${J}"; rc=$?
expect_eq "truncated warm: the 12x wall is not comparable" "$(jget "${J}" 'd["wall_speedup_comparable"]')" False
expect_eq "truncated warm: --min-speedup 2 fails on a not-comparable wall -> exit 1" "${rc}" 1
run --cold "${FX}/cold.log" --warm "${TMP}/warm-trunc.log" --max-set-diff-pct 100 --cold-wall 2h --warm-wall 10m >"${TMP}/t.txt"
case "$(cat "${TMP}/t.txt")" in *"NOT COMPARABLE"*) ok "truncated warm: the text report says the wall is not comparable";; *) bad "truncated warm: text report lacks NOT COMPARABLE";; esac
expect_eq "full warm: the wall IS comparable" "$(run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall 2h --warm-wall 30m --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["wall_speedup_comparable"])')" True
# the other direction: a COLD run that stopped early makes every warm merge look like reuse
run --cold "${TMP}/cold-trunc.log" --warm "${FX}/warm-full.log" --min-reuse 90 >"${TMP}/o.txt" 2>&1; rc=$?
expect_eq "truncated cold: refused, exit 2" "${rc}" 2
case "$(cat "${TMP}/o.txt")" in *"same package set"*"warm run merged"*) ok "truncated cold: names the warm atoms cold never merged";; *) bad "truncated cold: reason missing";; esac
# a small, tolerated difference (1 new compile of 11 warm merges, inside the default 10 %) is still valid
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" >/dev/null; rc=$?
expect_eq "one new atom in warm (9.1 % of its set, inside the default 10 %): valid" "${rc}" 0
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" --max-set-diff-pct 5 >/dev/null; rc=$?
expect_eq "the same pair with --max-set-diff-pct 5: refused" "${rc}" 2
# notes that read the two runs against each other
run --cold "${FX}/cold.log" --warm "${TMP}/warm-trunc.log" --max-set-diff-pct 100 --json >"${J}"
expect_eq "note: emerge groups differ" "$(jget "${J}" 'any("emerge groups differ" in n for n in d["notes"])')" True
expect_eq "note: the warm plan said 4 binary, the log shows 1" "$(jget "${J}" 'any("warm plan said 4 binary" in n for n in d["notes"])')" True
run --cold "${FX}/cold.log" --warm "${FX}/warm-partial.log" --json >"${J}"
expect_eq "note: total merges differ (10 vs 11) and no longer says the rate 'is still valid'" "$(jget "${J}" '[("total merges differ" in n, "still valid" in n) for n in d["notes"] if "total merges" in n]')" "[(True, False)]"
# an atom cold got from the pool (1 of 10: inside the cold limit) that warm compiles is not "new work"
sed -e 's/^>>> Emerging (\(.*\)) sys-apps\/portage/>>> Emerging binary (\1) sys-apps\/portage/' "${FX}/cold.log" >"${TMP}/cold-1bin.log"
sed -e 's/^>>> Emerging binary (\(.*\)) sys-apps\/portage/>>> Emerging (\1) sys-apps\/portage/' "${FX}/warm-full.log" >"${TMP}/warm-1src.log"
run --cold "${TMP}/cold-1bin.log" --warm "${TMP}/warm-1src.log" --json >"${J}"
expect_eq "cold-binary atom compiled in warm: cold has 1 binary merge" "$(jget "${J}" 'd["cold"]["binary"]')" 1
expect_eq "cold-binary atom compiled in warm: not listed as new work" "$(jget "${J}" 'd["new_compiles_in_warm"]')" "[]"
expect_eq "cold-binary atom compiled in warm: not a pool MISS either (cold never compiled it)" "$(jget "${J}" 'd["recompiled_despite_pool"]')" "[]"
# boundaries: exactly 10 % is inside both limits (cold pool share, set difference); over is not
run --cold "${TMP}/cold-1bin.log" --warm "${FX}/warm-full.log" >/dev/null; rc=$?
expect_eq "cold with exactly 10 % pool merges (limit 10) is still cold: exit 0" "${rc}" 0
run --cold "${TMP}/cold-1bin.log" --warm "${FX}/warm-full.log" --cold-max-binary-pct 9.9 >/dev/null; rc=$?
expect_eq "cold with 10 % pool merges against a 9.9 limit: not cold, exit 2" "${rc}" 2
grep -v 'app-admin/sudo' "${FX}/warm-full.log" >"${TMP}/warm-swap.log"
echo '>>> Emerging (7 of 7) dev-libs/newlib-1.0::gentoo for /out/wl-pki.pi5/sysroot/' >>"${TMP}/warm-swap.log"
J="${TMP}/swap.json"
run --cold "${FX}/cold.log" --warm "${TMP}/warm-swap.log" --json >"${J}"; rc=$?
expect_eq "one atom swapped for another (10 % of each set): exactly at the limit, valid" "${rc}" 0
run --cold "${FX}/cold.log" --warm "${TMP}/warm-swap.log" --max-set-diff-pct 9.9 >/dev/null; rc=$?
expect_eq "...and over a 9.9 limit: not the same package set, exit 2" "${rc}" 2
# an atom the COLD run got from the pool counts as a merge the warm run owed, too
grep -v 'sys-apps/portage' "${FX}/warm-full.log" >"${TMP}/warm-noportage.log"
run --cold "${TMP}/cold-1bin.log" --warm "${TMP}/warm-noportage.log" --json >"${J}"
expect_eq "cold-binary atom missing from warm: counted in the warm reuse denominator (9 of 9+1)" "$(jget "${J}" 'd["warm_reuse_pct"]')" 90.0
# one run with a tail and one without: the split stays host/target (not "native") either way round
run --cold "${FX}/real-x86-cold.log" --warm "${FX}/real-pi5-warm.log" --json >"${J}"
expect_eq "tail in warm only: still host/target, not native" "$(jget "${J}" 'sorted(d["by_root"])')" "['host', 'target']"
run --cold "${FX}/real-pi5-cold.log" --warm "${FX}/real-x86-warm.log" --json >"${J}"
expect_eq "tail in cold only: still host/target, not native" "$(jget "${J}" 'sorted(d["by_root"])')" "['host', 'target']"
# the default segment is the LAST build, for the cold side too: cold = the warm build -> not cold
run --cold "${FX}/session-two-builds.log" --warm "${FX}/session-two-builds.log" >/dev/null 2>&1; rc=$?
expect_eq "default cold segment is the last build (the warm one): not cold -> exit 2" "${rc}" 2

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
J="${TMP}/w.json"; run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall 1:30:00 --warm-wall 0:45:00 --json >"${J}"
expect_eq "wall 1:30:00 = 5400 s (the minute field is 60 s)" "$(jget "${J}" 'd["cold"]["wall_s"]')" 5400.0
run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --warm-wall 0 >/dev/null 2>&1; rc=$?
expect_eq "a zero wall -> exit 2 (it would divide)" "${rc}" 2

# -- (7) text report carries the headline numbers ------------------------------------
run --cold "${FX}/cold.log" --warm "${FX}/warm-full.log" --cold-wall 2h --warm-wall 30m >"${TMP}/t.txt"
case "$(cat "${TMP}/t.txt")" in *"4.00x whole-run"*) ok "text report prints the speedup";; *) bad "text report lacks the speedup";; esac
case "$(cat "${TMP}/t.txt")" in *"MEASUREMENT VALID"*) ok "text report prints the verdict";; *) bad "text report lacks the verdict";; esac

# -- (8) the make target: every value reaches the shell single-quoted; none runs ---------------
# Real make over the real Makefile, in a scratch dir. A value that breaks out of its quoting would
# create a file there (the raw "$(COLD)" in the usage test line did exactly that).
if command -v make >/dev/null 2>&1; then
    INJ="${TMP}/inj"; mkdir -p "${INJ}"
    mk() { make -s -C "${REPO}" binpkg-reuse-report "$@" >"${TMP}/mk.out" 2>&1; }
    mk COLD="x\"; touch ${INJ}/dq; \"" WARM=w
    mk COLD="x'; touch ${INJ}/sq; '" WARM=w
    mk COLD="x\`touch ${INJ}/bt\`" WARM=w
    mk COLD="x\$\$(touch ${INJ}/sub)" WARM=w
    mk COLD="${FX}/cold.log" WARM="w\"; touch ${INJ}/dq2; \"" 
    mk COLD="${FX}/cold.log" WARM="${FX}/warm-full.log" COLD_WALL="1h\"; touch ${INJ}/dq3; \"" 
    mk COLD="${FX}/cold.log" WARM="${FX}/warm-full.log" MIN_REUSE="1'; touch ${INJ}/sq2; '"
    mk COLD="${FX}/cold.log" WARM="${FX}/warm-full.log" MIN_HIT_RATE="1'; touch ${INJ}/sq3; '"
    expect_eq "make: no injected command ran (quote, backtick, \$(...) in any value)" "$(ls "${INJ}" | tr '\n' ' ')" ""
    # a real path holding a space and both quote kinds is read as ONE argument
    ODD="${TMP}/it's a \"cold\" log.log"; cp "${FX}/cold.log" "${ODD}"
    make -s -C "${REPO}" binpkg-reuse-report COLD="${ODD}" WARM="${FX}/warm-full.log" >"${TMP}/mk.out" 2>&1; rc=$?
    expect_eq "make: a path with a space and both quote kinds is passed intact (exit 0)" "${rc}" 0
    make -s -C "${REPO}" binpkg-reuse-report COLD="${FX}/cold.log" WARM="${FX}/warm-partial.log" MIN_HIT_RATE=95 >"${TMP}/mk.out" 2>&1; rc=$?
    # make turns the script's exit 1 into its own exit 2; the gate line is the proof it arrived
    case "$(cat "${TMP}/mk.out")" in *"GATE --min-hit-rate"*"want >= 95.0"*"got 90.0"*"FAIL"*) ok "make: MIN_HIT_RATE=95 reaches the gate (partial is 90.0 -> FAIL)";; *) bad "make: MIN_HIT_RATE did not reach the gate";; esac
    expect_eq "make: a failed gate fails the target" "$([ "${rc}" -ne 0 ] && echo nonzero)" nonzero
    make -s -C "${REPO}" binpkg-reuse-report COLD="${FX}/cold.log" >"${TMP}/mk.out" 2>&1; rc=$?
    expect_eq "make: a missing WARM is a usage error (exit 2)" "${rc}" 2
    case "$(cat "${TMP}/mk.out")" in *"usage: make binpkg-reuse-report"*) ok "make: the usage line is printed";; *) bad "make: usage line missing";; esac
else
    echo "  SKIP make not installed: the Makefile quoting cases not run"
fi

# -- (8b) the make wrapper hands paths and walls to the script as ONE word each ---------------
# A path with a quote and a space must arrive intact; a wall holding shell syntax must not run.
if command -v make >/dev/null 2>&1 && [ -f "${REPO}/Makefile" ]; then
    QD="${TMP}/it's a dir"; mkdir -p "${QD}"
    cp "${FX}/cold.log" "${QD}/cold.log"; cp "${FX}/warm-full.log" "${QD}/warm.log"
    make -s -C "${REPO}" binpkg-reuse-report COLD="${QD}/cold.log" WARM="${QD}/warm.log" \
        COLD_WALL=2h WARM_WALL=30m >"${TMP}/mk.txt" 2>&1; rc=$?
    expect_eq "make wrapper: quoted+spaced path reaches the script (exit)" "${rc}" 0
    case "$(cat "${TMP}/mk.txt")" in *"4.00x whole-run"*) ok "make wrapper: walls forwarded";; *) bad "make wrapper: walls not forwarded";; esac
    make -s -C "${REPO}" binpkg-reuse-report COLD="${QD}/cold.log" WARM="${QD}/warm.log" \
        COLD_WALL="1h; touch ${TMP}/pwned" >"${TMP}/mk.txt" 2>&1; rc=$?
    expect_eq "make wrapper: a wall holding shell syntax is a usage error (exit 2)" "${rc}" 2
    if [ -e "${TMP}/pwned" ]; then bad "make wrapper: a wall value was executed as shell"; else ok "make wrapper: a wall value is not executed as shell"; fi
else
    echo "  SKIP make wrapper checks (no make or no Makefile)"
fi

echo "== binpkg-reuse-report: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
