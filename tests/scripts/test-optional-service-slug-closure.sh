#!/usr/bin/env bash
# test-optional-service-slug-closure.sh — the gate for "the OPTIONAL-service slug set
# disagrees with itself across the five surfaces that must agree about it".
#
# WHY THIS EXISTS. The registry was described everywhere as a "closed 1:1 set". It was
# measured on 2026-08-26 and found to be FIVE different cardinalities at once:
# 17 installed-services ConfigMap booleans, 14 13a ApplicationSet elements, 13 CRD
# spec.slug enum values, 13 seed CRs, 12 entries in the admin-bff Java registry. Three
# live defects fell out of the gaps:
#
#   (a) character-forge was a SILENTLY INERT toggle. The CRD enum accepted it, a seed
#       CR shipped for it, it had a 13a element and a ConfigMap key — and the Java
#       OptionalServiceRegistry omitted it. So the API server ACCEPTED the write,
#       `kubectl get optionalservices` reported enabled:true, and the reconciler logged
#       "unknown slug — ignoring", wrote NEITHER target, and `continue`d past that CR's
#       status update, so not even .status.phase recorded the no-op. Nothing anywhere
#       observed that the toggle did nothing. A slug in the enum but not the registry is
#       strictly WORSE than one missing from both.
#   (b) apps/16-reserved-prefixes-policy.yaml carried 12 ignoreDifferences pointers
#       against 14 elements, so a successful runtime toggle of the two unlisted slugs
#       would be selfHealed back to git's baseline within a sync interval.
#   (c) meshbridge had a 13a element and a ConfigMap key but was in neither the enum nor
#       the seed CRs, so the API server rejected `spec.slug: meshbridge` outright. That
#       one at least failed LOUD, which is why it was the one already flagged in-repo.
#
# THE SET IS DERIVED, NOT LISTED. The checker recomputes
#     G = { slug : has a 13a element AND an installed-services ConfigMap boolean }
# and requires the CRD enum, the seed CRs, apps/16's pointers and the Java registry to
# equal it. Nothing here hard-codes the 14 slugs, so the NEXT slug cannot repeat this:
# add it to 13a + the ConfigMap and this gate names every surface still missing it.
# ArgoCD Application manifests in apps/ have no templating (app-of-apps syncs them as
# static files), so apps/16 cannot compute its own pointer list — this guard is the
# derivation, enforced from outside.
#
# THE SERVICE CHECKOUT IS PART OF THE GATE, NOT A CONVENIENCE. Defect (a) is invisible
# from inside this repo: all four in-repo surfaces agree with each other and the fifth
# is in hugmesh-admin-bff-api. Without that checkout there is nothing to compare on the
# leg that matters most, so the checker exits 3 INCOMPLETE and this script FAILS rather
# than reporting four green legs out of five.
#
# THIS GATE COMPARED NOTHING FROM 2026-08-26 TO 2026-09-23 (hugmesh-generator #584).
# The checker's first regex matched a ONE-line THREE-argument `new Entry(...)`; the
# Java ENTRIES table was born TWO-line FIVE-argument (admin-bff b8ed324, 23 minutes
# after the checker's aed812b9). Every run exited 3 INCOMPLETE at the first step, so
# not one control below ever executed and the header's "expected red" was a parser
# that could not read its input. It failed closed, which is the only reason it was
# visible. Section P below now pins the parser to a VERBATIM copy of the controller
# file (tests/fixtures/optional-service-slug-closure/OptionalServiceRegistry.java.fixture)
# and runs FIRST, with or without the service checkout, so the parser can never again
# drift off the real shape while the gate reports "INCOMPLETE" for a different reason.
#
# ⚠ EXPECTED RED (re-measured 2026-09-23 against hugmesh-admin-bff-api origin/main
# 86cdf79c, whose OptionalServiceRegistry.java last changed in b8ed324): the first
# comparison this gate ever made found TWO live cross-repo defects, both in the
# controller, both named by a leg below —
#   * meshbridge is in G (13a element, ConfigMap boolean, CRD enum, seed CR — all
#     since aed812b9) but the Java registry keeps it in NOT_TOGGLEABLE with reason
#     NOT_IN_CRD_ENUM, which has been FALSE since that commit. isKnown("meshbridge")
#     is false, so the reconciler logs "unknown slug — ignoring" for the seeded CR and
#     skips its /status: defect (a) again, for meshbridge. Legs [java-registry] and
#     [java-not-toggleable].
#   * character-forge carries configMapSelfHealProtected=false although apps/16 has
#     carried /data/character-forge since aed812b9, so the admin surface raises a
#     false selfHeal warning. Leg [java-selfheal-flag].
# The fix is in hugmesh-admin-bff-api (#106), NOT a weaker guard or allow_failure.
# Control 20 stages exactly that landing and requires the whole gate to go GREEN, so
# the guard is provably not always-red and the exit criterion is executable. WHEN #106
# LANDS: the live run goes green and control 20 passes on that alone; refresh the
# fixture from the new controller file and P1's `entries=13 not_toggleable=4` pin with
# it (P1 keeps passing on the OLD fixture, so nothing forces this — the fixture must
# track the controller's shape, not its contents), and rewrite this paragraph.
#
# Negative controls: one per assertion family, each planted into a STAGED copy of the
# current corpus so it cannot go stale; the vacuity controls (an empty derived list
# must be INCOMPLETE, never a pass); comment-token inversion (a slug named only in Java
# prose must NOT count as registered); an absent checkout; and a positive control.
#
# SAFETY. Every control writes ONLY inside its own `mktemp -d`. The corpus is staged
# FILE BY FILE with `cat` — never `cp -a` of a checkout — so no control can follow a
# symlinked worktree back into a real tree. (An earlier repo guard that did `cp -a` a
# tree of symlinked checkouts and then ran `find -delete` through one emptied 64 real
# files. Nothing here copies a directory.)
#
# Offline: reads files, writes only mktemp dirs. No cluster, no kubectl, no network.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${REPO}/tests/scripts/optional_service_slug_closure.py"
CLUSTER="${REPO}/specs/cluster"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }
[ -d "${CLUSTER}" ] || { echo "  FAIL missing cluster tree: ${CLUSTER}"; exit 1; }

FAILED=0
TMPS=()
cleanup() { for d in "${TMPS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "${d}"; done; }
trap cleanup EXIT

RELS=(
  "apps/13a-optional-services.yaml"
  "apps/16-reserved-prefixes-policy.yaml"
  "manifests/policy/installed-services-configmap.yaml"
  "manifests/optional-services-operator/crd-optionalservice.yaml"
  "manifests/optional-services-operator/seed-optionalservices.yaml"
  "manifests/admin-bff-api/deployment.yaml"
  "apps/31-admin-bff-api.yaml"
  "optional-services.yaml"
)
JAVA_REL="src/main/java/net/hugmesh/adminbff/optionalservices/OptionalServiceRegistry.java"

# Verbatim `git show origin/main:<REGISTRY>` from hugmesh-admin-bff-api 86cdf79c (the
# file last changed in b8ed324, 2026-08-26). It pins the PARSER to the real shape; it
# is never a substitute for the live checkout, which the comparison below still reads.
# When the controller file changes shape, refresh this copy with the parser.
FIXTURE="${REPO}/tests/fixtures/optional-service-slug-closure/OptionalServiceRegistry.java.fixture"
[ -f "${FIXTURE}" ] || { echo "  FAIL missing parser fixture: ${FIXTURE}"; exit 1; }

echo "== optional-service slug closure: five surfaces, one derived set =="

# py <staged-dir> <relative-path-under-staged-dir> <python-body-operating-on-s>
py() {
  local d="$1" rel="$2" body="$3"
  D="${d}" REL="${rel}" BODY="${body}" python3 - <<'PY'
import io, os
p = os.path.join(os.environ["D"], os.environ["REL"])
s = io.open(p, encoding="utf-8").read()
before = s
ns = {"s": s}
exec(os.environ["BODY"], ns)
s = ns["s"]
if s == before:
    raise SystemExit("MUTATION WAS A NO-OP: " + p)
io.open(p, "w", encoding="utf-8").write(s)
PY
}

# ── P. THE PARSER SELF-TEST. Runs first and needs no service checkout. ───────────
# The fixture is a verbatim copy of the controller's OptionalServiceRegistry.java. If
# the parser cannot read it, every leg below is comparing a parse, not the registry.
echo "-- P: the parser reads the controller's REAL ENTRIES shape (fixture, no checkout needed) --"
PTMP="$(mktemp -d)"; TMPS+=("${PTMP}")
# pexpect <want-rc> <label> <file> <pattern>...  — every pattern must match the output.
pexpect() {
  local want="$1" label="$2" f="$3"; shift 3
  local out rc pat ok=1
  out="$(python3 "${CHECKER}" --parse-registry "${f}" 2>&1)"; rc=$?
  [ "${rc}" -eq "${want}" ] || ok=0
  for pat in "$@"; do
    printf '%s\n' "${out}" | grep -a -E -- "${pat}" >/dev/null || { ok=0; echo "         missing /${pat}/"; }
  done
  if [ "${ok}" -eq 1 ]; then echo "  PASS ${label}"
  else
    echo "  FAIL ${label}: wanted rc=${want}, got rc=${rc}"
    printf '%s\n' "${out}" | sed 's/^/         | /'
    FAILED=1
  fi
}
# pmutate <body> — writes a mutated COPY of the fixture and sets F to its path. Called
# directly, NEVER inside $(...): a subshell would swallow both the FAIL line and
# FAILED=1, so a no-op mutation would silently skip its control.
pmutate() {
  F="$(mktemp "${PTMP}/m.XXXXXX")"
  cat "${FIXTURE}" > "${F}"
  py "${PTMP}" "$(basename "${F}")" "$1" >/dev/null || { echo "  FAIL control setup: parser mutation was a no-op"; FAILED=1; return 1; }
}

# P1. the committed fixture parses whole: 13 managed entries, 4 not-toggleable, and
#     the fields the gate compares come out right (a null mount is None, not "null").
pexpect 0 "P1 the verbatim controller file parses as 13 entries + 4 not-toggleable reasons" "${FIXTURE}" \
  '^entries=13 not_toggleable=4 duplicates=0$' \
  '^ENTRY	akkoma	hugmesh-backend	/social/mastodon	Akkoma \(Mastodon\)	true$' \
  '^ENTRY	anubis	hugmesh-frontend	<null>	' \
  '^ENTRY	coturn	hugmesh-backend	<null>	' \
  '^ENTRY	character-forge	hugmesh-backend	/character-forge	Character Forge \(3D\)	false$' \
  '^ENTRY	edge-ai-tts	hugmesh-inference	/admin/edge-ai-tts	' \
  '^NOT_TOGGLEABLE	meshbridge	NOT_IN_CRD_ENUM$' \
  '^NOT_TOGGLEABLE	headwind	NO_APPLICATIONSET_ELEMENT$'
# P1b. prose does not register: the javadoc names egress-vpn and tor as exclusions.
pexpect 0 "P1b slugs named only in the javadoc (egress-vpn, tor) are NOT parsed as entries" "${FIXTURE}" \
  '^entries=13 '
if python3 "${CHECKER}" --parse-registry "${FIXTURE}" 2>&1 | grep -a -E '	(tor|egress-vpn)	' >/dev/null; then
  echo "  FAIL P1b: a javadoc-only slug was parsed as registered"; FAILED=1
fi
# P2. the SAME table collapsed onto one line per entry still parses (whitespace is not shape).
pmutate 'import re; s = re.sub(r",\n\s+\"", ", \"", s)' &&
pexpect 0 "P2 one-line-per-entry spelling of the same table parses identically" "${F}" '^entries=13 not_toggleable=4 '
# P3. a displayName holding "//" and an escaped quote does not truncate the parse.
pmutate 's = s.replace("\"HugMesh Games\"", "\"HugMesh \\\"Games\\\" // https://x\"", 1)' &&
pexpect 0 "P3 a displayName with // and an escaped quote still parses (strings are not comments)" "${F}" '^entries=13 ' '^ENTRY	games	'
# P4. ONE entry with a sixth argument: the record changed shape -> INCOMPLETE, never 12-of-13.
pmutate 's = s.replace("\"Owncast (live streaming)\", true)", "\"Owncast (live streaming)\", true, 7)", 1)' &&
pexpect 3 "P4 one entry off the five-field shape is INCOMPLETE (no partial comparison)" "${F}" 'INCOMPLETE.*13 .new Entry\(. call.*only 12 parse'
# P5. the OLD three-argument shape the first parser expected is not the record -> INCOMPLETE.
pmutate 'import re; s = re.sub(r",\s*\n\s*\"[^\"\n]*\", (true|false)\)", ")", s)' &&
pexpect 3 "P5 the pre-#584 three-argument shape is INCOMPLETE, not silently accepted" "${F}" 'INCOMPLETE'
# P6. a NOT_TOGGLEABLE.put the parser cannot read -> INCOMPLETE (its reasons are checked claims).
pmutate 's = s.replace("NotToggleable.NOT_IN_CRD_ENUM);", "reasonFor(\"meshbridge\"));", 1)' &&
pexpect 3 "P6 an unparseable NOT_TOGGLEABLE.put is INCOMPLETE" "${F}" 'INCOMPLETE.*NOT_TOGGLEABLE.put'
# P7. an entry commented out with // leaves its continuation line behind; it must not count.
pmutate 's = s.replace("            new Entry(\"coturn\",", "            // new Entry(\"coturn\",", 1)' &&
pexpect 0 "P7 a //-commented entry is not registered (its dangling second line is not an entry either)" "${F}" '^entries=12 ' &&
if python3 "${CHECKER}" --parse-registry "${F}" 2>&1 | grep -a -E '^ENTRY	coturn	' >/dev/null; then
  echo "  FAIL P7: the commented-out coturn entry was parsed as registered"; FAILED=1
fi

# ── 0. Resolve the corpus. An absent checkout is a FAILURE, never a skip. ─────────
echo "-- positive: the live tree's five surfaces must agree on the derived set --"
OUT="$(python3 "${CHECKER}" "${CLUSTER}" 2>&1)"; RC=$?
echo "${OUT}" | sed 's/^/  /'
if [ "${RC}" -eq 3 ]; then
  echo
  echo "== slug-closure gate: INCOMPLETE =="
  echo "   This gate compares this repo's four in-repo surfaces against the admin-bff"
  echo "   Java registry. Without that checkout the leg that catches a SILENTLY INERT"
  echo "   toggle is not run at all. Set SERVICE_SRC_ROOT (CI clones it; locally a"
  echo "   sibling checkout beside this repo is found automatically)."
  echo "   A green run without it would be a lie, so this is a FAIL."
  [ "${FAILED}" -eq 0 ] || echo "== optional-service slug closure: FAIL (section P also failed — see above) =="
  exit 1
fi
[ "${RC}" -eq 0 ] || { echo "  FAIL the tree violates slug closure (rc=${RC}) — see the FAIL line(s) above"; FAILED=1; }

# The resolved source root, reused to stage the Java surface below.
SRC="$(printf '%s\n' "${OUT}" | sed -n 's/^  sources: //p' | head -1)"
[ -n "${SRC}" ] && [ -d "${SRC}" ] || { echo "  FAIL could not resolve the service-source root"; exit 1; }
JAVA_SRC="${SRC}/hugmesh-admin-bff-api/${JAVA_REL}"
[ -f "${JAVA_SRC}" ] || { echo "  FAIL resolved root has no ${JAVA_REL}"; exit 1; }

# ── staging: build a MINIMAL corpus, file by file. Never cp -a a checkout. ────────
# stage — sets D to a fresh staged corpus. Called directly, NOT as stage: in a
# subshell the TMPS+= never reached the parent, so cleanup() leaked every staged tree.
stage() {
  local d; d="$(mktemp -d)"; TMPS+=("${d}")
  local rel
  for rel in "${RELS[@]}"; do
    mkdir -p "${d}/specs/cluster/$(dirname "${rel}")"
    cat "${CLUSTER}/${rel}" > "${d}/specs/cluster/${rel}"
  done
  mkdir -p "${d}/src/hugmesh-admin-bff-api/$(dirname "${JAVA_REL}")"
  cat "${JAVA_SRC}" > "${d}/src/hugmesh-admin-bff-api/${JAVA_REL}"
  D="${d}"
}

# expect <want-rc> <pattern> <label> -- <staged-dir>
expect() {
  local want="$1" pat="$2" label="$3" _dash="$4" d="$5"
  local out rc
  out="$(python3 "${CHECKER}" "${d}/specs/cluster" --src-root "${d}/src" 2>&1)"; rc=$?
  # NOT `grep -Eq`: -q exits on the first match, SIGPIPEs printf, and under
  # `set -o pipefail` that makes a match the checker DID find report failure.
  # Drain the match into /dev/null so the writer always completes.
  if [ "${rc}" -eq "${want}" ] && printf '%s' "${out}" | grep -E -- "${pat}" >/dev/null; then
    echo "  PASS ${label}"
  else
    echo "  FAIL ${label}: wanted rc=${want} + /${pat}/, got rc=${rc}"
    printf '%s\n' "${out}" | sed 's/^/         | /'
    FAILED=1
  fi
}

mutate() {  # mutate <dir> <rel> <body>; aborts the suite if the edit changed nothing
  py "$@" || { echo "  FAIL control setup: mutation did not change the file ($2)"; FAILED=1; return 1; }
}

echo
echo "-- negative controls: each planted defect must make the checker RED --"

# ── 1. apps/16: a MISSING ignoreDifferences pointer (defect b, verbatim) ─────────
stage
mutate "${D}" specs/cluster/apps/16-reserved-prefixes-policy.yaml \
  's = s.replace("        - /data/meshbridge\n", "", 1)' &&
expect 1 'apps16-ignorediff.*missing.*/data/meshbridge' \
  "the verbatim defect (b): a slug with no ignoreDifferences pointer is selfHealed back" -- "${D}"

# ── 2. apps/16: an EXTRA pointer for a slug outside G ────────────────────────────
stage
mutate "${D}" specs/cluster/apps/16-reserved-prefixes-policy.yaml \
  's = s.replace("        - /data/akkoma\n", "        - /data/akkoma\n        - /data/headwind\n", 1)' &&
expect 1 'apps16-ignorediff.*extra.*/data/headwind' \
  "an ignoreDifferences pointer for a key no controller owns" -- "${D}"

# ── 3. CRD enum: a slug in G but NOT in the enum (defect c, verbatim) ────────────
stage
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  's = s.replace("                    - meshbridge\n", "", 1)' &&
expect 1 'crd-enum.*missing.*meshbridge' \
  "the verbatim defect (c): a slug with a 13a element the CRD enum rejects" -- "${D}"

# ── 4. CRD enum: a slug the enum accepts that is in no other surface ─────────────
stage
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  's = s.replace("                    - anubis\n", "                    - anubis\n                    - ghostservice\n", 1)' &&
expect 1 'crd-enum.*extra.*ghostservice' \
  "an enum value with no element, no boolean and no registry entry" -- "${D}"

# ── 5. CRD enum: a DUPLICATE (a set comparison alone would not see it) ──────────
stage
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  's = s.replace("                    - anubis\n", "                    - anubis\n                    - anubis\n", 1)' &&
expect 1 'dupes.*CRD enum' \
  "a duplicated enum value (set equality alone is blind to it)" -- "${D}"

# ── 6. seed CRs: a missing seed CR ──────────────────────────────────────────────
stage
mutate "${D}" specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml \
  's = s.replace("  slug: coturn\n", "  slug: edge-ai-tts\n", 1)' &&
expect 1 'seed-crs.*missing.*coturn' \
  "a slug in G with no seed CR row to edit in place" -- "${D}"

# ── 7. seed CRs: metadata.name drifted off spec.slug ────────────────────────────
stage
mutate "${D}" specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml \
  's = s.replace("  name: coturn\n", "  name: turn-server\n", 1)' &&
expect 1 'seed-crs.*metadata.name != spec.slug' \
  "a seed CR whose name no longer matches its slug (status names the wrong service)" -- "${D}"

# ── 8. Java registry: the defect-(a) shape — enum accepts, registry ignores ─────
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  'import re; s, n = re.subn(r"\n\s*new Entry\(\"coturn\",.*?true\),", "", s, count=1, flags=re.S)' &&
expect 1 'java-registry.*missing.*coturn' \
  "the defect-(a) shape: a slug the enum accepts and the registry silently ignores" -- "${D}"

# ── 9. COMMENT-TOKEN INVERSION: the slug named only in Java PROSE ───────────────
# The catalogued failure mode: a test satisfied by a token appearing in a comment.
# The registry's own javadoc already names slugs it deliberately does NOT carry.
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  'import re; s = re.sub(r"\n(\s*)(new Entry\(\"coturn\",.*?true\),)", lambda m: "\n" + m.group(1) + "/* " + m.group(2) + " coturn is registered here */", s, count=1, flags=re.S)' &&
expect 1 'java-registry.*missing.*coturn' \
  "comment-token inversion: a slug in Java prose only must NOT count as registered" -- "${D}"

# ── 10. ConfigMap: a boolean with no 13a element and no recorded reason ────────
stage
mutate "${D}" specs/cluster/manifests/policy/installed-services-configmap.yaml \
  's = s.replace("  akkoma: \"true\"\n", "  akkoma: \"true\"\n  newthing: \"false\"\n", 1)' &&
expect 1 'configmap->13a.*newthing' \
  "a sixth cardinality: a new ConfigMap boolean with no element and no reason" -- "${D}"

# ── 11. 13a: an element with no ConfigMap boolean ─────────────────────────────
stage
mutate "${D}" specs/cluster/apps/13a-optional-services.yaml \
  's = s.replace("          - { slug: coturn,", "          - { slug: nogrey, path: specs/cluster/manifests/nogrey, namespace: hugmesh-backend, installed: \"false\" }\n          - { slug: coturn,", 1)' &&
expect 1 '13a->configmap.*nogrey' \
  "an ApplicationSet element whose greying mirror has no key to flip" -- "${D}"

# ── 12. BUILD_DETERMINED gone stale (the exclusion excuses nothing) ────────────
stage
mutate "${D}" specs/cluster/manifests/policy/installed-services-configmap.yaml \
  's = s.replace("  headwind: \"false\"\n", "", 1)' &&
expect 1 'BUILD_DETERMINED names slug' \
  "a stale exclusion entry — a recorded reason for a key that no longer exists" -- "${D}"

# ── 13. namespace drift between 13a and services.json ─────────────────────────
stage
mutate "${D}" specs/cluster/apps/13a-optional-services.yaml \
  's = s.replace("- { slug: owncast, path: specs/cluster/manifests/owncast,       namespace: hugmesh-owncast,", "- { slug: owncast, path: specs/cluster/manifests/owncast,       namespace: hugmesh-elsewhere,", 1)' &&
expect 1 'namespace. owncast' \
  "a 13a element deploying where the console does not look" -- "${D}"

# ── 14. mountAt drift between services.json and the Java registry ─────────────
stage
mutate "${D}" specs/cluster/manifests/policy/installed-services-configmap.yaml \
  's = s.replace("\"mountAt\": \"/tube\"", "\"mountAt\": \"/localtube\"", 1)' &&
expect 1 'mountAt. tube' \
  "a mount path that disagrees with the controller registry" -- "${D}"

# ── 15. the reconciler master switch DELETED from the Deployment ───────────────
# The pre-2026-08-26 state, verbatim: the flag exists only as a ":false" default
# inside the BFF's own application.yml and is settable from nowhere at all.
stage
mutate "${D}" specs/cluster/manifests/admin-bff-api/deployment.yaml \
  's = s.replace("            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"false\" }\n", "", 1)' &&
expect 1 'reconciler-flag.*declared 0 time' \
  "the dark-with-no-lever state: the master switch declared by no manifest at all" -- "${D}"

# ── 16. the switch declared TWICE (a merge patch keeps an arbitrary one) ───────
stage
mutate "${D}" specs/cluster/manifests/admin-bff-api/deployment.yaml \
  's = s.replace("            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"false\" }\n", "            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"false\" }\n            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"true\" }\n", 1)' &&
expect 1 'reconciler-flag.*declared 2 time' \
  "two declarations of the same env name — the overlay keeps one and it is not defined which" -- "${D}"

# ── 17. the index-addressed env exemption this design REFUSES ─────────────────
# The tempting "fix" for a reverted `kubectl set env`: exempt the env slot from
# selfHeal. The pointer is positional, so it migrates onto another variable — and
# this container's env carries secretKeyRefs.
stage
mutate "${D}" specs/cluster/apps/31-admin-bff-api.yaml \
  's = s.replace("    syncOptions: [CreateNamespace=true]\n", "    syncOptions: [CreateNamespace=true]\n  ignoreDifferences:\n    - group: apps\n      kind: Deployment\n      name: admin-bff-api\n      jsonPointers:\n        - /spec/template/spec/containers/0/env/57\n", 1)' &&
expect 1 'reconciler-flag.*ARRAY INDEX' \
  "an index-addressed env exemption (it silently migrates onto a secretKeyRef)" -- "${D}"

# ── 21. a stale NOT_IN_CRD_ENUM reason: the meshbridge shape, planted on a clean slug ─
# Move coturn from ENTRIES to NOT_TOGGLEABLE with NOT_IN_CRD_ENUM while the enum
# still carries it: missing from the registry AND a false reason.
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  'import re; s = re.sub(r"\n\s*new Entry\(\"coturn\",.*?true\),", "", s, count=1, flags=re.S).replace("        NOT_TOGGLEABLE.put(\"headwind\"", "        NOT_TOGGLEABLE.put(\"coturn\", NotToggleable.NOT_IN_CRD_ENUM);\n        NOT_TOGGLEABLE.put(\"headwind\"", 1)' &&
expect 1 "java-not-toggleable.*classifies \\[[^]]*'coturn'[^]]*\\] as NOT_IN_CRD_ENUM" \
  "a NOT_IN_CRD_ENUM reason for a slug the CRD enum carries is named as stale" -- "${D}"
expect 1 "java-registry.*missing=\\[[^]]*'coturn'" \
  "...and the same staged tree really moved coturn OUT of ENTRIES (compound-mutation check)" -- "${D}"

# ── 22. a stale NO_APPLICATIONSET_ELEMENT reason ─────────────────────────────
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  's = s.replace("NOT_TOGGLEABLE.put(\"headwind\"", "NOT_TOGGLEABLE.put(\"tube\", NotToggleable.NO_APPLICATIONSET_ELEMENT);\n        NOT_TOGGLEABLE.put(\"headwind\"", 1)' &&
expect 1 "classifies \\['tube'\\] as NO_APPLICATIONSET_ELEMENT, but apps/13a HAS" \
  "a NO_APPLICATIONSET_ELEMENT reason for a slug with a 13a element is named as stale" -- "${D}"
expect 1 "both in ENTRIES and NOT_TOGGLEABLE: \\['tube'\\]" \
  "a slug in BOTH halves of the registry (refused by the admin surface, actuated by the reconciler)" -- "${D}"

# ── 23. a reason the gate does not know how to verify ─────────────────────────
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  's = s.replace("NOT_TOGGLEABLE.put(\"headwind\", NotToggleable.NO_APPLICATIONSET_ELEMENT)", "NOT_TOGGLEABLE.put(\"headwind\", NotToggleable.OPERATOR_SAYS_SO)", 1)' &&
expect 1 "cannot verify: \\['OPERATOR_SAYS_SO'\\]" \
  "an unverifiable NOT_TOGGLEABLE reason is a FAIL until this gate is taught what it claims" -- "${D}"

# ── 24. configMapSelfHealProtected drift: true while apps/16 lost the pointer ─
stage
mutate "${D}" specs/cluster/apps/16-reserved-prefixes-policy.yaml \
  's = s.replace("        - /data/akkoma\n", "", 1)' &&
expect 1 'java-selfheal-flag. akkoma: Java configMapSelfHealProtected=true but apps/16 does NOT carry' \
  "the Java selfHeal flag claims protection apps/16 no longer gives (a hidden revert)" -- "${D}"

# ── 25. a DUPLICATE Java entry (the LinkedHashMap keeps the last; the first is dead) ─
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  's = s.replace("            new Entry(\"anubis\",", "            new Entry(\"coturn\", \"hugmesh-backend\", null, \"dup\", true),\n            new Entry(\"anubis\",", 1)' &&
expect 1 "dupes. Java registry ENTRIES contains duplicate slugs: \\['coturn'\\]" \
  "a duplicated Java ENTRIES row (a set comparison alone is blind to it)" -- "${D}"

# ── 26. the DELIBERATE EXCLUSION, leaked: tor in the CRD enum ─────────────────
# tor is a node service (catalogue scope: node). In the enum it would be accepted by
# the API server and reconciled by nothing — defect (a) for a node service.
stage
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  's = s.replace("                    - anubis\n", "                    - anubis\n                    - tor\n", 1)' &&
expect 1 "node-scope. catalogue scope:node slug.s. \\['tor'\\] appear in CRD enum" \
  "tor (scope: node) leaking into the CRD enum is named as a node-scope violation" -- "${D}"

# ── 27. the DELIBERATE EXCLUSION, leaked: tor as a Java managed entry ─────────
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  's = s.replace("            new Entry(\"anubis\",", "            new Entry(\"tor\", \"hugmesh-backend\", null, \"Tor\", true),\n            new Entry(\"anubis\",", 1)' &&
expect 1 "java-registry.*extra=\\['tor'\\]" \
  "tor as a Java managed entry is named by the registry-equality leg" -- "${D}"
expect 1 "node-scope. catalogue scope:node slug.s. \\['tor'\\] appear in Java ENTRIES" \
  "tor as a Java managed entry trips the node-scope leg itself, not only set equality" -- "${D}"

# ── 28. the DELIBERATE EXCLUSION, leaked: egress-vpn as a ConfigMap boolean ───
stage
mutate "${D}" specs/cluster/manifests/policy/installed-services-configmap.yaml \
  's = s.replace("  akkoma: \"true\"\n", "  akkoma: \"true\"\n  egress-vpn: \"false\"\n", 1)' &&
expect 1 "node-scope. catalogue scope:node slug.s. \\['egress-vpn'\\] appear in configmap booleans" \
  "egress-vpn (scope: node) as a greying boolean is a node-scope violation" -- "${D}"

# ── 29. the exclusion is REPORTED, not merely unmentioned ────────────────────
stage
expect "${RC}" 'deliberate exclusions .*: egress-vpn tor$' \
  "the gate prints tor and egress-vpn as the deliberate node-scope exclusions" -- "${D}"

echo
echo "-- vacuity controls: an EMPTY derived list must be INCOMPLETE, never a pass --"

# ── 15. an empty 13a element list ────────────────────────────────────────────
stage
mutate "${D}" specs/cluster/apps/13a-optional-services.yaml \
  'import re; s = re.sub(r"^ *- \{ slug: .*\n", "", s, flags=re.M).replace("        elements:", "        elements: []")' &&
expect 3 'INCOMPLETE' \
  "vacuity: no ApplicationSet elements is INCOMPLETE (G would be empty and every set equal)" -- "${D}"

# ── 16. an empty CRD enum ────────────────────────────────────────────────────
stage
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  'import re; s = re.sub(r"^                    - [a-z0-9-]+\n", "", s, flags=re.M).replace("                  enum:", "                  enum: []")' &&
expect 3 'INCOMPLETE' \
  "vacuity: an empty spec.slug enum is INCOMPLETE, not 'nothing disagrees'" -- "${D}"

# ── 17. a Java registry whose ENTRIES table parses to nothing ────────────────
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  'import re; s = re.sub(r"new Entry\(", "new Removed(", s)' &&
expect 3 'INCOMPLETE.*ZERO registry entries' \
  "vacuity: a registry that parses to zero entries is INCOMPLETE, never a silent pass" -- "${D}"

# ── 18. apps/16 with NO ignoreDifferences at all ─────────────────────────────
# The keystone's TOTAL ABSENCE must not read as "no pointers to disagree with".
stage
mutate "${D}" specs/cluster/apps/16-reserved-prefixes-policy.yaml \
  'i = s.index("  ignoreDifferences:"); j = s.index("  # Health: ArgoCD treats"); s = s[:i] + s[j:]' &&
expect 3 'INCOMPLETE' \
  "vacuity: apps/16 with the whole keystone deleted is INCOMPLETE, not green" -- "${D}"

# ── 18b. a catalogue with NO scope:node slug (the exclusion leg would be vacuous) ─
stage
mutate "${D}" specs/cluster/optional-services.yaml \
  'import re; s = re.sub(r"^(\s+)scope: node\b", r"\1scope: cluster", s, flags=re.M)' &&
expect 3 'INCOMPLETE.*no .scope: node. slug' \
  "vacuity: a catalogue with no node-scoped slug is INCOMPLETE, not 'nothing leaked'" -- "${D}"

# ── 18c. a registry whose NOT_TOGGLEABLE half parses to nothing ──────────────
stage
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  'import re; s = re.sub(r"\n\s*NOT_TOGGLEABLE\.put\([^;]*;", "", s)' &&
expect 3 'INCOMPLETE.*ZERO NOT_TOGGLEABLE' \
  "vacuity: a NOT_TOGGLEABLE half that parses to nothing is INCOMPLETE" -- "${D}"

# ── 19. an absent service checkout ───────────────────────────────────────────
stage
rm -rf "${D}/src/hugmesh-admin-bff-api"
expect 3 'INCOMPLETE' \
  "absent checkout is INCOMPLETE (rc 3), never four-of-five green" -- "${D}"

echo
echo "-- positive control: the guard is not always-red --"

# ── 20. the CROSS-REPO EXIT CRITERION, executable ────────────────────────────
# Stage the landing of the controller fix this gate names (re-measured 2026-09-23):
# meshbridge gets a managed ENTRIES row and loses its stale NOT_IN_CRD_ENUM line, and
# character-forge's configMapSelfHealProtected becomes true (apps/16 carries its
# pointer). The WHOLE gate must go green — this is what "done" looks like, and it
# proves every other leg above is already satisfied by the live tree.
# Once hugmesh-admin-bff-api#106 lands the LIVE tree is green, and planting meshbridge
# again would plant a DUPLICATE (the [dupes] leg would fire and this control would go
# red for the wrong reason — the trap the first version of this control fell into
# when character-forge landed upstream). A green live run IS the exit criterion met.
if [ "${RC}" -eq 0 ]; then
  echo "  PASS the live tree is already GREEN — the exit criterion control 20 stages is met"
else
  stage
  mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
    's = s if "new Entry(\"meshbridge\"" in s else s.replace("            new Entry(\"anubis\",", "            new Entry(\"meshbridge\",       \"hugmesh-backend\",   null,\n                    \"Mesh radio bridge (Meshtastic \u2194 Matrix)\", true),\n            new Entry(\"anubis\",", 1); s = s.replace("        NOT_TOGGLEABLE.put(\"meshbridge\", NotToggleable.NOT_IN_CRD_ENUM);\n", "", 1).replace("\"Character Forge (3D)\", false)", "\"Character Forge (3D)\", true)", 1)' &&
  expect 0 'all [0-9]+ assertion' \
    "with meshbridge managed + character-forge's selfHeal flag true the whole gate goes GREEN" -- "${D}"
  # Each part is idempotent, so a PARTIAL upstream fix (say meshbridge added, the flag
  # not yet flipped) stages only what is still missing instead of planting a duplicate.
  # The staged fix must have changed all three things, or the green above is not the fix.
  grep -a -c 'NOT_TOGGLEABLE.put("meshbridge"' "${D}/src/hugmesh-admin-bff-api/${JAVA_REL}" >/dev/null &&
    { echo "  FAIL control 20 setup: the meshbridge NOT_TOGGLEABLE line survived"; FAILED=1; }
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "== optional-service slug closure: PASS =="
  exit 0
fi
echo "== optional-service slug closure: FAIL =="
exit 1
