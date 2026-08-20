#!/usr/bin/env bash
# avc-report.sh — turn a raw AVC harvest into the narrowing worksheet:
# denials grouped by SOURCE TYPE -> the specs/selinux/*.te file that OWNS that
# type, so narrowing the rules tagged
#   '# INFERRED-WIDE: narrow after QEMU enforcing AVC pass'
# becomes mechanical: open the module the report names, find the tagged rule
# the denial tuple corresponds to, replace the wide interface with the exact
# type/port/perm the tuple shows.
#
#   Usage: avc-report.sh <raw-avc-file> [<specs-selinux-dir>]
#
# <raw-avc-file> holds ausearch output, dmesg lines, or a mix — anything with
# 'avc: denied { ... }' + scontext=/tcontext=/tclass= fields (AVC and USER_AVC
# records both match). Pure text processing: no root, no QEMU, no SELinux
# userland needed on the host — which is what makes it hermetically testable
# (tests/qemu/avc-workout_test.sh).
#
# OWNERSHIP RESOLUTION, strongest first:
#   1. an explicit `type foo_t;` / `type foo_t,` declaration in a .te wins;
#   2. else the LONGEST module basename that prefixes the source type
#      (hugmesh_vpn_reconcile_t -> hugmesh_vpn.te; also covers types minted by
#      container_domain_template, e.g. localpath_provisioner_t, which no .te
#      declares with a bare `type` line);
#   3. else the denial is reported under '(unowned)' — base/distro policy, NOT
#      a hugmesh module's job to narrow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RAW="${1:?usage: avc-report.sh <raw-avc-file> [<specs-selinux-dir>]}"
SPECS="${2:-${REPO_DIR}/specs/selinux}"

[ -f "${RAW}" ]   || { echo "avc-report: raw AVC file not found: ${RAW}" >&2; exit 1; }
[ -d "${SPECS}" ] || { echo "avc-report: specs/selinux dir not found: ${SPECS}" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── ownership maps, derived from the .te sources at report time (never a
#    hardcoded table that drifts when a module is added/renamed) ─────────────
: > "${TMP}/types.map"    # "<declared type> <te-basename>"
: > "${TMP}/modules.map"  # "<module name> <te-basename>"
: > "${TMP}/iw.count"     # "<te-basename> <INFERRED-WIDE line count>"
for te in "${SPECS}"/*.te; do
    [ -e "${te}" ] || continue
    base="$(basename "${te}")"
    mod="${base%.te}"
    echo "${mod} ${base}" >> "${TMP}/modules.map"
    # Explicit declarations: `type foo_t;` or `type foo_t, attr...;`
    sed -n 's/^[[:space:]]*type[[:space:]]\+\([a-z0-9_]*_t\)[;,].*/\1/p' "${te}" \
        | while read -r t; do echo "${t} ${base}"; done >> "${TMP}/types.map"
    echo "${base} $(grep -c 'INFERRED-WIDE' "${te}" || true)" >> "${TMP}/iw.count"
done
sort -o "${TMP}/modules.map" "${TMP}/modules.map"

awk -v typesfile="${TMP}/types.map" \
    -v modsfile="${TMP}/modules.map" \
    -v iwfile="${TMP}/iw.count" \
    -v specs="${SPECS}" '
BEGIN {
    nmods = 0
    while ((getline line < typesfile) > 0) { split(line, f, " "); typeowner[f[1]] = f[2] }
    close(typesfile)
    while ((getline line < modsfile) > 0)  { split(line, f, " "); nmods++; modname[nmods] = f[1]; modfile[f[1]] = f[2] }
    close(modsfile)
    while ((getline line < iwfile) > 0)    { split(line, f, " "); iw[f[1]] = f[2] }
    close(iwfile)
    total = 0
}
/avc:[[:space:]]*denied/ {
    scon = ""; tcon = ""; tclass = ""; perms = ""; comm = ""; path = ""
    if (match($0, /scontext=[^ ]+/))  scon   = substr($0, RSTART + 9, RLENGTH - 9)
    if (match($0, /tcontext=[^ ]+/))  tcon   = substr($0, RSTART + 9, RLENGTH - 9)
    if (match($0, /tclass=[^ '\'']+/)) tclass = substr($0, RSTART + 7, RLENGTH - 7)
    if (match($0, /denied[[:space:]]*\{[^}]*\}/)) {
        perms = substr($0, RSTART, RLENGTH)
        sub(/^denied[[:space:]]*\{[[:space:]]*/, "", perms)
        sub(/[[:space:]]*\}$/, "", perms)
    }
    if (match($0, /comm="[^"]*"/))    comm = substr($0, RSTART, RLENGTH)
    if (match($0, /path="[^"]*"/))    path = substr($0, RSTART, RLENGTH)
    else if (match($0, /name="[^"]*"/)) path = substr($0, RSTART, RLENGTH)

    n = split(scon, a, ":"); stype = (n >= 3) ? a[3] : scon
    n = split(tcon, b, ":"); ttype = (n >= 3) ? b[3] : tcon
    if (stype == "") next
    total++

    # ── resolve the owner ──
    owner = ""
    if (stype in typeowner) owner = typeowner[stype]
    else {
        best = ""
        for (i = 1; i <= nmods; i++) {
            m = modname[i]
            if (index(stype, m "_") == 1 && length(m) > length(best)) best = m
        }
        if (best != "") owner = modfile[best]
    }
    if (owner == "") owner = "(unowned)"

    key = owner SUBSEP stype SUBSEP ttype SUBSEP tclass SUBSEP perms
    cnt[key]++
    if (!(key in example)) {
        ex = comm
        if (path != "") ex = ex ((ex != "") ? " " : "") path
        example[key] = ex
    }
    owned[owner] = 1
    ownertotal[owner]++
    unique[owner SUBSEP stype] = 1
}
END {
    nuniq = 0; for (k in cnt) nuniq++
    printf "== AVC report: %d denial line(s), %d unique (source -> target:class {perms}) tuple(s) ==\n", total, nuniq
    if (total == 0) {
        print ""
        print "No denials in the harvest. Either the workload really is clean under the"
        print "loaded policy, or the workout never exercised the confined domains — check"
        print "the probe log before celebrating."
        exit 0
    }
    # Owned modules first (sorted module order), then (unowned) last.
    for (i = 1; i <= nmods + 1; i++) {
        if (i <= nmods) { owner = modfile[modname[i]] } else { owner = "(unowned)" }
        if (!(owner in owned)) continue
        if (owner in printed) continue
        printed[owner] = 1
        print ""
        if (owner == "(unowned)") {
            printf "-- (unowned) : %d denial(s) from types no specs/selinux module declares --\n", ownertotal[owner]
            print "   Base/distro policy domains. NOT narrowing input for the hugmesh modules;"
            print "   an unexpected entry here can also mean a module FAILED TO LOAD and its"
            print "   workload ran unconfined (init_t/initrc_t sources are the tell)."
        } else {
            printf "-- %s : %d denial(s) --\n", owner, ownertotal[owner]
            if ((owner in iw) && iw[owner] > 0)
                printf "   %d INFERRED-WIDE line(s) to narrow:  grep -n INFERRED-WIDE %s/%s\n", iw[owner], specs, owner
        }
        for (key in cnt) {
            split(key, kf, SUBSEP)
            if (kf[1] != owner) continue
            printf "  %4dx  %s -> %s:%s { %s }\n", cnt[key], kf[2], kf[3], kf[4], kf[5]
            if (example[key] != "") printf "         e.g. %s\n", example[key]
        }
    }
    print ""
    print "Narrowing recipe: for each tuple above, open the owning .te, find the"
    print "INFERRED-WIDE rule that currently allows it wholesale, and replace it with"
    print "the exact type/class/perm the tuple shows (audit2allow -w on the raw line"
    print "explains which rule matched). Re-run the workout until the module'\''s section"
    print "here is empty, then the enforce-gate'\''s check_avc_clean() can pass for real."
}' "${RAW}"
