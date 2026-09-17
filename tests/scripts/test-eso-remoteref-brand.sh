#!/usr/bin/env bash
# test-eso-remoteref-brand.sh — an ExternalSecret's Vault KV BASE SEGMENT must
# follow the SAME knob the seeder writes under: BRAND.
#
# THE DEFECT THIS PINS (issue #285; decision 38 = B on hugmesh-generator#347,
# operator 2026-09-17 — "template the brand into the remoteRef keys so the READER
# follows the WRITER"; measured 2026-09-17 on origin/main 88f70d99).
# ---------------------------------------------------------------------------
# An ExternalSecret addresses Vault as `remoteRef: { key: <base>/<doc> }`. ESO
# prepends the ClusterSecretStore's own mount (`provider.vault.path: "secret"`)
# and the KV-v2 `/data/` segment itself, so <base> is the Vault KV BASE PATH and
# nothing else supplies it. The WRITER, scripts/gen-cluster-secrets.sh, writes
# under BASE="${BRAND:-hugmesh}".
#
# specs/cluster is NOT what a cluster runs: build-*-stage4.sh copies it to
# ${SYSROOT}/var/lib/hugmesh/cluster and rebrand_sysroot() seds that tree. Its
# catch-all rule is `s|hugmesh|${ORG}|g`, which ALREADY rewrote all 143 remoteRef
# keys — to ORG. So:
#
#   * "the reader is pinned at the literal hugmesh/<service>" (what #285 and the
#     gen-cluster-secrets.sh header used to say) was true of the GIT tree and
#     FALSE of what a device serves to ArgoCD;
#   * reader and writer agreed only when ORG == BRAND. Three of the four corners
#     were broken — (acme,widgetco) and (hugmesh,widgetco) read `widgetco/...`,
#     and (acme,hugmesh), i.e. `--brand acme` with no `--org`, read `hugmesh/...`.
#     In each, ESO resolves a path gen-cluster-secrets.sh never wrote: no error
#     that names the brand, just Secrets that never materialize.
#
# The fix is one sentinel pair in the sed chain of all ten builders, in the same
# idiom the frozen `hugmesh.net/` label-key namespace already uses: capture
# `key: hugmesh/` FIRST, restore it to `${BRAND}/` LAST.
#
# WHAT IS ASSERTED (the invariant, not a literal)
# -----------------------------------------------
#  (1) CENSUS. Every build-*-stage4.sh that defines rebrand_sysroot is covered
#      here, and carries BOTH halves of the sentinel pair — a builder that grew a
#      capture without a restore would emit the sentinel into a live manifest.
#  (2) NON-VACUITY + SPELLING CLOSURE. The REAL specs/cluster tree carries at
#      least one `hugmesh/`-based remoteRef, and the number a YAML parse finds
#      (walking spec.data[].remoteRef.key and spec.dataFrom[].extract.key of
#      every ExternalSecret) EQUALS the number the builders' sed rule can see.
#      THIS is the "a new hard-coded hugmesh/ remoteRef appears" guard: a key
#      written in a spelling the rule does not cover makes the two disagree and
#      this suite goes RED, instead of a non-default brand silently reading a
#      path nothing ever wrote.
#  (3) WRITER AGREEMENT. gen-cluster-secrets.sh's BASE= is BRAND-derived. Point
#      the writer somewhere else and this goes RED — the two halves of the
#      contract cannot drift apart silently.
#  (4) DEFAULT IS BYTE-IDENTICAL, twice: with BRAND unset and every knob default
#      the baked tree equals specs/cluster exactly; with BRAND and ORG unset but
#      a NON-default domain/title (so the chain really runs) every remoteRef key
#      is still `hugmesh/` while the domain rebrand demonstrably happened.
#  (5) THE FOUR CORNERS. For every builder that walks the cluster tree, and for
#      (BRAND,ORG) in {(acme,widgetco),(acme,hugmesh),(hugmesh,widgetco),
#      (acme,acme)}: every remoteRef base is exactly BRAND, none is ORG unless
#      ORG == BRAND, and the count is preserved.
#  (6) COLLATERAL. `key:` fields that are NOT Vault remoteRefs — `key: tls.crt`,
#      `key: token`, the frozen label key `key: hugmesh.net/egress-vpn`, a
#      `key: app.kubernetes.io/part-of` selector — are byte-identical afterwards,
#      and the quoted remoteRef spellings ARE carried.
#  (7) NO SENTINEL LEAK: @@SDSYSVAULTBASE@@ never survives.
#
# Runs ANYWHERE with bash + sed + awk + python3 (PyYAML) — NO cross-build, NO
# root, NO cluster, NO network. Secret VALUES are never read or printed; this
# suite only looks at PATHS.
#
# Mutation-tested (see the commit that added it): dropping the capture, dropping
# the restore, restoring to ORG instead of BRAND, moving the capture below the
# catch-all, dropping one builder from the list, and hollowing the fixture are
# each caught. See the battery in the PR body.
# NOTE on `grep` inside pipelines here: never `| grep -q`. Under pipefail a -q
# grep exits the moment it matches, SIGPIPEs the writer, and the pipeline then
# reports FAILURE for a match it actually found. Every pipeline below drains with
# `>/dev/null` instead (tests/scripts/test-guard-integrity.sh check 8 enforces it).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Extract a shell function body verbatim from a builder (the idp/frozen-keys idiom).
extract_fn() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }

# Harmless stubs for the builder helpers rebrand_sysroot calls.
info() { :; }
warn() { :; }
err()  { echo "ERR: $*" >&2; }
banner() { :; }

CLUSTER="${REPO}/specs/cluster"
SEEDER="${REPO}/scripts/gen-cluster-secrets.sh"

# EXPLICIT list, never a glob — the census right below makes the list and the tree
# agree, so a NEW builder is an error rather than a silent gap.
BUILDERS=(
  build-frite-stage4.sh
  build-jetson-stage4.sh
  build-orangepi-zero2-stage4.sh
  build-orangepi-zero2w-stage4.sh
  build-orangepi-zero3-stage4.sh
  build-orangepi3-lts-stage4.sh
  build-orangepi4-lts-stage4.sh
  build-orangepi5-stage4.sh
  build-rpi5-stage4.sh
  build-x86-host-stage4.sh
)

# ── (1) census + both halves of the sentinel pair ────────────────────────────
echo "== (1) census: every rebrand_sysroot builder is covered and carries the pair =="
for b in "${REPO}"/build-*-stage4.sh; do
  bn="$(basename "${b}")"
  grep -q '^rebrand_sysroot() {' "${b}" || continue
  listed=0
  for x in "${BUILDERS[@]}"; do [ "${x}" = "${bn}" ] && listed=1; done
  if [ "${listed}" -eq 1 ]; then
    ok "census: ${bn} is in the covered list"
  else
    bad "census: ${bn} defines rebrand_sysroot but is NOT covered by this suite"
  fi
done
for bn in "${BUILDERS[@]}"; do
  b="${REPO}/${bn}"
  if [ ! -f "${b}" ]; then bad "census: ${bn} is listed here but missing from the tree"; continue; fi
  fn="$(extract_fn rebrand_sysroot "${b}")"
  # Read the two halves out of the REAL function body, so a copy of the rule that
  # sits somewhere else in the file cannot satisfy this.
  ncap="$(printf '%s\n' "${fn}" | grep -c 'hugmesh/|.1@@SDSYSVAULTBASE@@/')"
  nres="$(printf '%s\n' "${fn}" | grep -c '@@SDSYSVAULTBASE@@/|\${_brand}/')"
  [ "${ncap}" -ge 1 ] && ok "${bn}: rebrand_sysroot captures the remoteRef base" \
                       || bad "${bn}: rebrand_sysroot has NO @@SDSYSVAULTBASE@@ capture"
  [ "${nres}" -ge 1 ] && ok "${bn}: rebrand_sysroot restores it to \${_brand}" \
                       || bad "${bn}: rebrand_sysroot never restores @@SDSYSVAULTBASE@@ to \${_brand} (sentinel would LEAK)"
done

# ── (2) non-vacuity + spelling closure ───────────────────────────────────────
echo "== (2) the YAML-level remoteRef census equals what the sed rule can see =="
# TWO independent censuses of the same thing, per file:
#   yaml  — every ExternalSecret's spec.data[].remoteRef.key and
#           spec.dataFrom[].extract.key whose FIRST path segment is "hugmesh";
#   sed   — every NON-COMMENT line the builders' capture rule matches.
# Comment lines are excluded from the sed side on purpose: the rule rewrites them
# too (harmlessly), but a commented-out example remoteRef is not a live reference
# and counting it would make the two censuses differ for a reason that is not a
# defect. velero-externalsecrets.yaml carries two such examples today.
CENSUS="$(CLUSTER="${CLUSTER}" python3 - <<'PY'
import os, pathlib, re, sys, collections
try:
    import yaml
except ImportError:
    print("SKIP no-pyyaml"); sys.exit(0)
root = pathlib.Path(os.environ["CLUSTER"])
pat = re.compile(r"""key: *['"]?hugmesh/""")
sedc, yamlc = collections.Counter(), collections.Counter()
parse_fail_with_es = []
for p in sorted(root.rglob("*")):
    if not p.is_file():
        continue
    try:
        txt = p.read_text()
    except Exception:
        continue
    n = sum(1 for ln in txt.splitlines()
            if not ln.lstrip().startswith("#") and pat.search(ln))
    if n:
        sedc[str(p)] = n
    if p.suffix not in (".yaml", ".yml"):
        continue
    try:
        docs = list(yaml.safe_load_all(txt))
    except Exception:
        if "kind: ExternalSecret" in txt:
            parse_fail_with_es.append(str(p))
        continue
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "ExternalSecret":
            continue
        spec = doc.get("spec") or {}
        ks = []
        for d in (spec.get("data") or []):
            rr = (d or {}).get("remoteRef") or {}
            if "key" in rr:
                ks.append(rr["key"])
        for d in (spec.get("dataFrom") or []):
            ex = (d or {}).get("extract") or {}
            if "key" in ex:
                ks.append(ex["key"])
        for k in ks:
            if isinstance(k, str) and k.split("/", 1)[0] == "hugmesh":
                yamlc[str(p)] += 1
print("SED %d" % sum(sedc.values()))
print("YAML %d" % sum(yamlc.values()))
for f in sorted(set(sedc) | set(yamlc)):
    if sedc[f] != yamlc[f]:
        print("MISMATCH %s sed=%d yaml=%d" % (f, sedc[f], yamlc[f]))
for f in parse_fail_with_es:
    print("UNPARSEABLE %s" % f)
PY
)"
if printf '%s' "${CENSUS}" | grep -a '^SKIP no-pyyaml' >/dev/null; then
  bad "(2) PyYAML is missing — the spelling-closure half of this guard CANNOT run; install python3-yaml"
  SED_SEEN=0
else
  SED_SEEN="$(printf '%s\n' "${CENSUS}" | awk '/^SED /{print $2}')"
  YAML_SEEN="$(printf '%s\n' "${CENSUS}" | awk '/^YAML /{print $2}')"
  [ "${SED_SEEN:-0}" -gt 0 ] \
    && ok "(2) non-vacuity: ${SED_SEEN} live hugmesh/-based remoteRef keys under specs/cluster" \
    || bad "(2) VACUOUS: no hugmesh/-based remoteRef key found under specs/cluster"
  if [ "${YAML_SEEN}" = "${SED_SEEN}" ]; then
    ok "(2) spelling closure: YAML census ${YAML_SEEN} == sed-visible ${SED_SEEN}"
  else
    bad "(2) spelling closure: YAML census ${YAML_SEEN} != sed-visible ${SED_SEEN} — a remoteRef is written in a spelling rebrand_sysroot cannot see, or a non-ExternalSecret field now matches the rule"
    printf '%s\n' "${CENSUS}" | grep -a '^MISMATCH' | sed 's/^/       /'
  fi
  if printf '%s' "${CENSUS}" | grep -a '^UNPARSEABLE' >/dev/null; then
    bad "(2) a file declaring kind: ExternalSecret does not parse as YAML — the census cannot see it"
    printf '%s\n' "${CENSUS}" | grep -a '^UNPARSEABLE' | sed 's/^/       /'
  else
    ok "(2) every kind: ExternalSecret file parses, so the YAML census is complete"
  fi
fi

# ── (3) writer agreement ─────────────────────────────────────────────────────
echo "== (3) the WRITER's base is BRAND-derived =="
if [ -f "${SEEDER}" ]; then
  base_line="$(grep -aE '^BASE=' "${SEEDER}" | head -1)"
  case "${base_line}" in
    'BASE="${BRAND:-hugmesh}"'|'BASE=${BRAND:-hugmesh}')
      ok "(3) gen-cluster-secrets.sh: ${base_line}" ;;
    "")
      bad "(3) gen-cluster-secrets.sh has no BASE= assignment — the writer half of the contract moved" ;;
    *)
      bad "(3) gen-cluster-secrets.sh BASE is not BRAND-derived: ${base_line}" ;;
  esac
else
  bad "(3) missing ${SEEDER}"
fi

# ── the render harness ───────────────────────────────────────────────────────
# Drive the REAL rebrand_sysroot from a builder over a fixture sysroot holding a
# copy of the REAL specs/cluster tree. Every knob is passed explicitly so an
# ambient value cannot make a pass vacuous.
render() { # <outdir> <builder-basename> <BRAND-or-UNSET> <ORG-or-UNSET> <domain> <title> <games>
  local out="$1" bn="$2" b="$3" o="$4" dom="$5" title="$6" games="$7"
  rm -rf "${out}"; mkdir -p "${out}/var/lib/hugmesh" "${out}/etc/hugmesh"
  cp -a "${CLUSTER}" "${out}/var/lib/hugmesh/cluster"
  local envargs=()
  if [ "${b}" = "UNSET" ]; then envargs+=(-u BRAND); else envargs+=("BRAND=${b}"); fi
  if [ "${o}" = "UNSET" ]; then envargs+=(-u ORG);   else envargs+=("ORG=${o}");   fi
  env "${envargs[@]}" "CLUSTER_DOMAIN=${dom}" "BRAND_TITLE=${title}" "GAMES_DOMAIN=${games}" \
      REPO="${REPO}" BN="${bn}" SYSROOT="${out}" bash -c '
        set -uo pipefail
        # the builders default these the same way their argument parsers do
        export BRAND="${BRAND:-hugmesh}" ORG="${ORG:-hugmesh}"
        info() { :; }; warn() { :; }; err() { echo "ERR: $*" >&2; }; banner() { :; }
        ex() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }
        eval "$(ex _sed_rep_escape "${REPO}/${BN}")"
        eval "$(ex rebrand_sysroot  "${REPO}/${BN}")"
        rebrand_sysroot
      '
}
# Which builders actually walk the cluster tree (read from the real function).
# Read it off the WALK (the `find ...` / `roots=(...)` line), never off the prose —
# a comment that merely NAMES the path must not make a builder look like a walker.
CLUSTER_BUILDERS=()
for bn in "${BUILDERS[@]}"; do
  if extract_fn rebrand_sysroot "${REPO}/${bn}" \
       | grep -av '^[[:space:]]*#' | grep -a 'var/lib/hugmesh/cluster' >/dev/null; then
    CLUSTER_BUILDERS+=("${bn}")
  fi
done
[ "${#CLUSTER_BUILDERS[@]}" -gt 0 ] \
  && ok "harness: ${#CLUSTER_BUILDERS[@]} builder(s) walk /var/lib/hugmesh/cluster: ${CLUSTER_BUILDERS[*]}" \
  || bad "harness: NO builder walks /var/lib/hugmesh/cluster — the rest of this suite would be vacuous"

# Count remoteRef bases the SAME way census (2) counts them: NON-COMMENT lines
# only, so the two commented-out example refs in velero-externalsecrets.yaml cannot
# make a correct render look off-by-two.
base_count() { # <base> <tree>
  grep -rha "key: $1/" "$2" | grep -avc '^[[:space:]]*#' | tr -d ' '
}

# ── (4) the default brand does not move ──────────────────────────────────────
echo "== (4) default brand: byte-identical =="
for bn in "${CLUSTER_BUILDERS[@]}"; do
  render "${WORK}/defA" "${bn}" UNSET UNSET "hugmesh.net" "HugMesh Systems" "hugmesh.games"
  if diff -r "${CLUSTER}" "${WORK}/defA/var/lib/hugmesh/cluster" >"${WORK}/defA.diff" 2>&1; then
    ok "(4a) ${bn}: BRAND unset + all knobs default -> baked tree == specs/cluster byte-for-byte"
  else
    bad "(4a) ${bn}: the DEFAULT brand's baked tree differs from specs/cluster"
    head -20 "${WORK}/defA.diff" | sed 's/^/       /'
  fi
  # BRAND unset, ORG unset, but a NON-default domain/title so the chain really runs.
  render "${WORK}/defB" "${bn}" UNSET UNSET "example.org" "Acme Mesh" "acme.games"
  n_h="$(base_count hugmesh "${WORK}/defB/var/lib/hugmesh/cluster")"
  if [ "${n_h}" = "${SED_SEEN}" ]; then
    ok "(4b) ${bn}: BRAND unset + non-default domain -> all ${n_h} remoteRef bases still hugmesh/"
  else
    bad "(4b) ${bn}: BRAND unset + non-default domain -> ${n_h} hugmesh/ bases, expected ${SED_SEEN}"
  fi
  # ...and the pass was NOT a no-op (otherwise 4b proves nothing).
  if grep -rqa 'example\.org' "${WORK}/defB/var/lib/hugmesh/cluster"; then
    ok "(4b) ${bn}: that pass really ran (example.org present in the baked tree)"
  else
    bad "(4b) ${bn}: VACUOUS — the rebrand pass did not rewrite the domain, so 4b proves nothing"
  fi
done

# ── (5) the four corners ─────────────────────────────────────────────────────
echo "== (5) reader base == BRAND in every BRAND/ORG corner =="
CORNERS=("acme:widgetco" "acme:hugmesh" "hugmesh:widgetco" "acme:acme")
for bn in "${CLUSTER_BUILDERS[@]}"; do
  for c in "${CORNERS[@]}"; do
    b="${c%%:*}"; o="${c##*:}"
    render "${WORK}/c" "${bn}" "${b}" "${o}" "example.org" "Acme Mesh" "acme.games"
    tree="${WORK}/c/var/lib/hugmesh/cluster"
    n_b="$(base_count "${b}" "${tree}")"
    n_o="$(base_count "${o}" "${tree}")"
    [ "${n_b}" = "${SED_SEEN}" ] \
      && ok "(5) ${bn} BRAND=${b} ORG=${o}: all ${SED_SEEN} remoteRef bases are ${b}/ (== the seeder's BASE)" \
      || bad "(5) ${bn} BRAND=${b} ORG=${o}: ${n_b}/${SED_SEEN} remoteRef bases are ${b}/ — the reader does NOT follow the writer"
    if [ "${o}" != "${b}" ]; then
      [ "${n_o}" = "0" ] \
        && ok "(5) ${bn} BRAND=${b} ORG=${o}: no remoteRef base tracks ORG" \
        || bad "(5) ${bn} BRAND=${b} ORG=${o}: ${n_o} remoteRef base(s) still track ORG (${o}/) — ESO would read a path nothing writes"
    fi
    if grep -rqa '@@SDSYS' "${tree}"; then
      bad "(5) ${bn} BRAND=${b} ORG=${o}: a @@SDSYS…@@ sentinel LEAKED into the baked tree"
    else
      ok "(5) ${bn} BRAND=${b} ORG=${o}: no sentinel leak"
    fi
  done
done

# ── (6) collateral: non-Vault `key:` fields, and the quoted spellings ────────
echo "== (6) collateral safety on other key: fields, and quoted remoteRef spellings =="
KEEP=(
  'key: tls.crt'
  '          key: token'
  '  - key: hugmesh.net/egress-vpn'
  'key: app.kubernetes.io/part-of'
  '  key: node-role.kubernetes.io/control-plane'
  'key: kubernetes.io/os'
)
MOVE_IN=(
  '        key: hugmesh/casdoor'
  '      remoteRef: { key: hugmesh/route-access-db, property: app_password }'
  '        key: "hugmesh/bff-internal-token"'
  "        key: 'hugmesh/user-bff-custody-key'"
  '        key: hugmesh/device/dev-01/ssh'
)
MOVE_OUT=(
  '        key: acme/casdoor'
  '      remoteRef: { key: acme/route-access-db, property: app_password }'
  '        key: "acme/bff-internal-token"'
  "        key: 'acme/user-bff-custody-key'"
  '        key: acme/device/dev-01/ssh'
)
# The fixture lives under /etc/hugmesh, which ALL TEN builders walk, so the rule is
# exercised in every copy of the chain and not only in the three that also walk the
# cluster tree.
for bn in "${BUILDERS[@]}"; do
  fx="${WORK}/fx"
  rm -rf "${fx}"; mkdir -p "${fx}/var/lib/hugmesh/cluster" "${fx}/etc/hugmesh"
  : > "${fx}/etc/hugmesh/collateral.yaml"
  for l in "${KEEP[@]}";    do printf '%s\n' "${l}" >> "${fx}/etc/hugmesh/collateral.yaml"; done
  for l in "${MOVE_IN[@]}"; do printf '%s\n' "${l}" >> "${fx}/etc/hugmesh/collateral.yaml"; done
  env BRAND=acme ORG=widgetco CLUSTER_DOMAIN=example.org BRAND_TITLE="Acme Mesh" GAMES_DOMAIN=acme.games \
      REPO="${REPO}" BN="${bn}" SYSROOT="${fx}" bash -c '
        set -uo pipefail
        info() { :; }; warn() { :; }; err() { echo "ERR: $*" >&2; }; banner() { :; }
        ex() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }
        eval "$(ex _sed_rep_escape "${REPO}/${BN}")"
        eval "$(ex rebrand_sysroot  "${REPO}/${BN}")"
        rebrand_sysroot
      '
  got="${fx}/etc/hugmesh/collateral.yaml"
  for l in "${KEEP[@]}"; do
    if grep -Fxqa -- "${l}" "${got}"; then ok "(6) ${bn}: keeps   '${l}'"
    else bad "(6) ${bn}: EATS    '${l}'"; fi
  done
  i=0
  for l in "${MOVE_IN[@]}"; do
    want="${MOVE_OUT[$i]}"; i=$((i+1))
    if grep -Fxqa -- "${want}" "${got}"; then ok "(6) ${bn}: rebrands '${l}' -> '${want}'"
    else bad "(6) ${bn}: '${l}' did NOT become '${want}' (got: $(grep -a -m1 -F "${l%%:*}" "${got}" || true))"; fi
  done
  if grep -qa '@@SDSYS' "${got}"; then bad "(6) ${bn}: sentinel leak in the collateral fixture"
  else ok "(6) ${bn}: no sentinel leak"; fi
done

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
