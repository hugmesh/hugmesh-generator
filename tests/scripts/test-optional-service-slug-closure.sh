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
# ⚠ EXPECTED RED (2026-08-26): the [java-registry] leg FAILS against the current
# committed hugmesh-admin-bff-api — its registry still has 12 entries and omits
# character-forge and meshbridge. That failure is defect (a), live, and this gate
# exists to name it. The fix is to land the two registry entries (in flight on
# hugmesh-admin-bff-api's feat/superadmin-optional-services-endpoint), NOT to weaken
# this guard or wave it through with allow_failure. Control 18 below stages exactly
# that landing and requires the whole gate to go GREEN, so the guard is provably not
# always-red and the exit criterion is executable rather than asserted.
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
)
JAVA_REL="src/main/java/net/hugmesh/adminbff/optionalservices/OptionalServiceRegistry.java"

echo "== optional-service slug closure: five surfaces, one derived set =="

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
  exit 1
fi
[ "${RC}" -eq 0 ] || { echo "  FAIL the tree violates slug closure (rc=${RC}) — see the FAIL line(s) above"; FAILED=1; }

# The resolved source root, reused to stage the Java surface below.
SRC="$(printf '%s\n' "${OUT}" | sed -n 's/^  sources: //p' | head -1)"
[ -n "${SRC}" ] && [ -d "${SRC}" ] || { echo "  FAIL could not resolve the service-source root"; exit 1; }
JAVA_SRC="${SRC}/hugmesh-admin-bff-api/${JAVA_REL}"
[ -f "${JAVA_SRC}" ] || { echo "  FAIL resolved root has no ${JAVA_REL}"; exit 1; }

# ── staging: build a MINIMAL corpus, file by file. Never cp -a a checkout. ────────
stage() {
  local d; d="$(mktemp -d)"; TMPS+=("${d}")
  local rel
  for rel in "${RELS[@]}"; do
    mkdir -p "${d}/specs/cluster/$(dirname "${rel}")"
    cat "${CLUSTER}/${rel}" > "${d}/specs/cluster/${rel}"
  done
  mkdir -p "${d}/src/hugmesh-admin-bff-api/$(dirname "${JAVA_REL}")"
  cat "${JAVA_SRC}" > "${d}/src/hugmesh-admin-bff-api/${JAVA_REL}"
  printf '%s' "${d}"
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

mutate() {  # mutate <dir> <rel> <body>; aborts the suite if the edit changed nothing
  py "$@" || { echo "  FAIL control setup: mutation did not change the file ($2)"; FAILED=1; return 1; }
}

echo
echo "-- negative controls: each planted defect must make the checker RED --"

# ── 1. apps/16: a MISSING ignoreDifferences pointer (defect b, verbatim) ─────────
D="$(stage)"
mutate "${D}" specs/cluster/apps/16-reserved-prefixes-policy.yaml \
  's = s.replace("        - /data/meshbridge\n", "", 1)' &&
expect 1 'apps16-ignorediff.*missing.*/data/meshbridge' \
  "the verbatim defect (b): a slug with no ignoreDifferences pointer is selfHealed back" -- "${D}"

# ── 2. apps/16: an EXTRA pointer for a slug outside G ────────────────────────────
D="$(stage)"
mutate "${D}" specs/cluster/apps/16-reserved-prefixes-policy.yaml \
  's = s.replace("        - /data/akkoma\n", "        - /data/akkoma\n        - /data/headwind\n", 1)' &&
expect 1 'apps16-ignorediff.*extra.*/data/headwind' \
  "an ignoreDifferences pointer for a key no controller owns" -- "${D}"

# ── 3. CRD enum: a slug in G but NOT in the enum (defect c, verbatim) ────────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  's = s.replace("                    - meshbridge\n", "", 1)' &&
expect 1 'crd-enum.*missing.*meshbridge' \
  "the verbatim defect (c): a slug with a 13a element the CRD enum rejects" -- "${D}"

# ── 4. CRD enum: a slug the enum accepts that is in no other surface ─────────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  's = s.replace("                    - anubis\n", "                    - anubis\n                    - ghostservice\n", 1)' &&
expect 1 'crd-enum.*extra.*ghostservice' \
  "an enum value with no element, no boolean and no registry entry" -- "${D}"

# ── 5. CRD enum: a DUPLICATE (a set comparison alone would not see it) ──────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  's = s.replace("                    - anubis\n", "                    - anubis\n                    - anubis\n", 1)' &&
expect 1 'dupes.*CRD enum' \
  "a duplicated enum value (set equality alone is blind to it)" -- "${D}"

# ── 6. seed CRs: a missing seed CR ──────────────────────────────────────────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml \
  's = s.replace("  slug: coturn\n", "  slug: edge-ai-tts\n", 1)' &&
expect 1 'seed-crs.*missing.*coturn' \
  "a slug in G with no seed CR row to edit in place" -- "${D}"

# ── 7. seed CRs: metadata.name drifted off spec.slug ────────────────────────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml \
  's = s.replace("  name: coturn\n", "  name: turn-server\n", 1)' &&
expect 1 'seed-crs.*metadata.name != spec.slug' \
  "a seed CR whose name no longer matches its slug (status names the wrong service)" -- "${D}"

# ── 8. Java registry: the defect-(a) shape — enum accepts, registry ignores ─────
D="$(stage)"
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  's = s.replace("new Entry(\"coturn\",           \"hugmesh-backend\",   null),\n", "", 1)' &&
expect 1 'java-registry.*missing.*coturn' \
  "the defect-(a) shape: a slug the enum accepts and the registry silently ignores" -- "${D}"

# ── 9. COMMENT-TOKEN INVERSION: the slug named only in Java PROSE ───────────────
# The catalogued failure mode: a test satisfied by a token appearing in a comment.
# The registry's own javadoc already names slugs it deliberately does NOT carry.
D="$(stage)"
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  's = s.replace("new Entry(\"coturn\",           \"hugmesh-backend\",   null),\n", "// new Entry(\"coturn\", \"hugmesh-backend\", null),  coturn is registered here\n", 1)' &&
expect 1 'java-registry.*missing.*coturn' \
  "comment-token inversion: a slug in Java prose only must NOT count as registered" -- "${D}"

# ── 10. ConfigMap: a boolean with no 13a element and no recorded reason ────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/policy/installed-services-configmap.yaml \
  's = s.replace("  akkoma: \"true\"\n", "  akkoma: \"true\"\n  newthing: \"false\"\n", 1)' &&
expect 1 'configmap->13a.*newthing' \
  "a sixth cardinality: a new ConfigMap boolean with no element and no reason" -- "${D}"

# ── 11. 13a: an element with no ConfigMap boolean ─────────────────────────────
D="$(stage)"
mutate "${D}" specs/cluster/apps/13a-optional-services.yaml \
  's = s.replace("          - { slug: coturn,", "          - { slug: nogrey, path: specs/cluster/manifests/nogrey, namespace: hugmesh-backend, installed: \"false\" }\n          - { slug: coturn,", 1)' &&
expect 1 '13a->configmap.*nogrey' \
  "an ApplicationSet element whose greying mirror has no key to flip" -- "${D}"

# ── 12. BUILD_DETERMINED gone stale (the exclusion excuses nothing) ────────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/policy/installed-services-configmap.yaml \
  's = s.replace("  headwind: \"false\"\n", "", 1)' &&
expect 1 'BUILD_DETERMINED names slug' \
  "a stale exclusion entry — a recorded reason for a key that no longer exists" -- "${D}"

# ── 13. namespace drift between 13a and services.json ─────────────────────────
D="$(stage)"
mutate "${D}" specs/cluster/apps/13a-optional-services.yaml \
  's = s.replace("- { slug: owncast, path: specs/cluster/manifests/owncast,       namespace: hugmesh-owncast,", "- { slug: owncast, path: specs/cluster/manifests/owncast,       namespace: hugmesh-elsewhere,", 1)' &&
expect 1 'namespace. owncast' \
  "a 13a element deploying where the console does not look" -- "${D}"

# ── 14. mountAt drift between services.json and the Java registry ─────────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/policy/installed-services-configmap.yaml \
  's = s.replace("\"mountAt\": \"/tube\"", "\"mountAt\": \"/localtube\"", 1)' &&
expect 1 'mountAt. tube' \
  "a mount path that disagrees with the controller registry" -- "${D}"

# ── 15. the reconciler master switch DELETED from the Deployment ───────────────
# The pre-2026-08-26 state, verbatim: the flag exists only as a ":false" default
# inside the BFF's own application.yml and is settable from nowhere at all.
D="$(stage)"
mutate "${D}" specs/cluster/manifests/admin-bff-api/deployment.yaml \
  's = s.replace("            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"false\" }\n", "", 1)' &&
expect 1 'reconciler-flag.*declared 0 time' \
  "the dark-with-no-lever state: the master switch declared by no manifest at all" -- "${D}"

# ── 16. the switch declared TWICE (a merge patch keeps an arbitrary one) ───────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/admin-bff-api/deployment.yaml \
  's = s.replace("            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"false\" }\n", "            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"false\" }\n            - { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: \"true\" }\n", 1)' &&
expect 1 'reconciler-flag.*declared 2 time' \
  "two declarations of the same env name — the overlay keeps one and it is not defined which" -- "${D}"

# ── 17. the index-addressed env exemption this design REFUSES ─────────────────
# The tempting "fix" for a reverted `kubectl set env`: exempt the env slot from
# selfHeal. The pointer is positional, so it migrates onto another variable — and
# this container's env carries secretKeyRefs.
D="$(stage)"
mutate "${D}" specs/cluster/apps/31-admin-bff-api.yaml \
  's = s.replace("    syncOptions: [CreateNamespace=true]\n", "    syncOptions: [CreateNamespace=true]\n  ignoreDifferences:\n    - group: apps\n      kind: Deployment\n      name: admin-bff-api\n      jsonPointers:\n        - /spec/template/spec/containers/0/env/57\n", 1)' &&
expect 1 'reconciler-flag.*ARRAY INDEX' \
  "an index-addressed env exemption (it silently migrates onto a secretKeyRef)" -- "${D}"

echo
echo "-- vacuity controls: an EMPTY derived list must be INCOMPLETE, never a pass --"

# ── 15. an empty 13a element list ────────────────────────────────────────────
D="$(stage)"
mutate "${D}" specs/cluster/apps/13a-optional-services.yaml \
  'import re; s = re.sub(r"^ *- \{ slug: .*\n", "", s, flags=re.M).replace("        elements:", "        elements: []")' &&
expect 3 'INCOMPLETE' \
  "vacuity: no ApplicationSet elements is INCOMPLETE (G would be empty and every set equal)" -- "${D}"

# ── 16. an empty CRD enum ────────────────────────────────────────────────────
D="$(stage)"
mutate "${D}" specs/cluster/manifests/optional-services-operator/crd-optionalservice.yaml \
  'import re; s = re.sub(r"^                    - [a-z0-9-]+\n", "", s, flags=re.M).replace("                  enum:", "                  enum: []")' &&
expect 3 'INCOMPLETE' \
  "vacuity: an empty spec.slug enum is INCOMPLETE, not 'nothing disagrees'" -- "${D}"

# ── 17. a Java registry whose ENTRIES table parses to nothing ────────────────
D="$(stage)"
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  'import re; s = re.sub(r"new Entry\(", "new Removed(", s)' &&
expect 3 'INCOMPLETE.*ZERO registry entries' \
  "vacuity: a registry that parses to zero entries is INCOMPLETE, never a silent pass" -- "${D}"

# ── 18. apps/16 with NO ignoreDifferences at all ─────────────────────────────
# The keystone's TOTAL ABSENCE must not read as "no pointers to disagree with".
D="$(stage)"
mutate "${D}" specs/cluster/apps/16-reserved-prefixes-policy.yaml \
  'i = s.index("  ignoreDifferences:"); j = s.index("  # Health: ArgoCD treats"); s = s[:i] + s[j:]' &&
expect 3 'INCOMPLETE' \
  "vacuity: apps/16 with the whole keystone deleted is INCOMPLETE, not green" -- "${D}"

# ── 19. an absent service checkout ───────────────────────────────────────────
D="$(stage)"
rm -rf "${D}/src/hugmesh-admin-bff-api"
expect 3 'INCOMPLETE' \
  "absent checkout is INCOMPLETE (rc 3), never four-of-five green" -- "${D}"

echo
echo "-- positive control: the guard is not always-red --"

# ── 20. the CROSS-REPO EXIT CRITERION, executable ────────────────────────────
# Stage the landing of defect (a)'s fix: the two entries the admin-bff registry
# still owes. The WHOLE gate must go green — this is what "done" looks like, and
# it proves every other leg above is already satisfied by the live tree.
D="$(stage)"
mutate "${D}" "src/hugmesh-admin-bff-api/${JAVA_REL}" \
  's = s.replace("new Entry(\"anubis\",", "new Entry(\"character-forge\",  \"hugmesh-backend\",   \"/character-forge\"),\n            new Entry(\"meshbridge\",       \"hugmesh-backend\",   null),\n            new Entry(\"anubis\",", 1)' &&
expect 0 'all [0-9]+ assertion' \
  "with character-forge + meshbridge in the registry the whole gate goes GREEN" -- "${D}"

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "== optional-service slug closure: PASS =="
  exit 0
fi
echo "== optional-service slug closure: FAIL =="
exit 1
