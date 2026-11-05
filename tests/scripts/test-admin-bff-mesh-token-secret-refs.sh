#!/usr/bin/env bash
# test-admin-bff-mesh-token-secret-refs.sh — admin-bff's mesh-token issuer must be
# pointed at files that the cluster can actually deliver.
#
# WHAT IS WIRED. admin-bff issues v1 mesh tokens (docs/HUGMESH-TOKEN.md) from two
# credentials it reads as FILES:
#
#   APP_MESH_TOKEN_ISSUER_KEY_PATH         -> the Ed25519 issuer private key
#   APP_MESH_TOKEN_HEADSCALE_API_KEY_PATH  -> the headscale API key (Bearer)
#
# Both live in Secret admin-bff-mesh-token, which ExternalSecret
# admin-bff-mesh-token (external-secrets/secretstore.yaml) builds from Vault, and
# which the Deployment mounts as a volume at /run/secrets/mesh-token/.
#
# WHY A GUARD. Every link in that chain is a bare string, and every break is
# silent. The feature ships dark (APP_MESH_TOKEN_ENABLED="false") and the volume
# is `optional: true`, so a wrong Secret name, a renamed key, a moved mount or an
# unlisted ExternalSecret all produce the same pod: it starts, it is healthy, and
# the file the issuer will open does not exist. Nobody sees it until the day the
# flag flips, which is the worst possible day to find it. This repo has shipped
# that class repeatedly (see the APPSTORE_* and headscale base-url notes in the
# Deployment).
#
# THE INVARIANTS, each checked against the manifests rather than a copy of them:
#   1. each *_PATH env is a literal (never a secretKeyRef: the issuer key must not
#      sit in the pod spec or the process environment) whose dirname is a
#      readOnly volumeMount in the same container;
#   2. that mount's volume is a SECRET volume, optional: true, defaultMode 0400;
#   3. 0400 is readable by the non-root app only with an fsGroup (secret files are
#      root-owned otherwise), so runAsUser != 0 requires fsGroup;
#   4. the secretName is created by an ExternalSecret under external-secrets/, in
#      the Deployment's namespace, from a file that kustomization.yaml lists, and
#      that ExternalSecret produces a key equal to each path's basename;
#   5. that ExternalSecret reads exactly the agreed Vault paths/properties, from
#      ClusterSecretStore hugmesh-vault, refreshInterval 1h;
#   6. APP_MESH_TOKEN_ENABLED is the literal "true" or "false" (a bare
#      @ConditionalOnProperty arms on any value other than "false", so "False" or
#      "no" does not ship dark), and no APP_MESH_TOKEN_* name appears twice;
#   7. APP_MESH_TOKEN_HEADSCALE_BASE_URL names the headscale Service that
#      manifests/headscale/service.yaml really declares (name, namespace, port).
#
# NOT IN SCOPE, on purpose: whether the Vault paths are SEEDED. Both are
# operator-seeded and classified in tests/scripts/eso_seed_contract.py; that gate
# owns the question. Nor whether egress reaches headscale: see the PR that added
# this file.
#
# Needs bash + python3 + PyYAML. Refuses to skip when either is missing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# Control runs re-enter this script against synthetic trees. POSITIONAL flag,
# never an env var: an inherited env var would silently turn a CI run into a
# control run that skips every control and the vacuity floor.
CHILD=no
[ "${1:-}" = "--scan-only" ] && CHILD=yes

# The directory override is honoured ONLY in a child run.
if [ "${CHILD}" = yes ]; then
  DIR="${MESHTOKEN_MANIFEST_DIR:-${REPO}/specs/cluster/manifests}"
else
  DIR="${REPO}/specs/cluster/manifests"
fi

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo "FATAL: PyYAML required (refusing to skip)" >&2; exit 1; }
[ -d "${DIR}" ] || { echo "FATAL: manifest dir not found: ${DIR}" >&2; exit 1; }

# ── the scan ───────────────────────────────────────────────────────────────────
# Prints PASS/FAIL lines and, last, `CHECKS <n>` (how many assertions it made).
scan() { # <manifest dir>
  python3 - "$1" <<'PY'
import os, sys, glob, posixpath
import yaml

d = sys.argv[1]
checks = 0
fails = 0

def ok(msg):
    global checks
    checks += 1
    print(f"  PASS {msg}")

def bad(msg):
    global checks, fails
    checks += 1
    fails += 1
    print(f"  FAIL {msg}")

def load_all(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return [x for x in yaml.safe_load_all(fh) if isinstance(x, dict)]
    except (OSError, yaml.YAMLError) as e:
        bad(f"cannot parse {os.path.relpath(path, d)}: {e}")
        return []

SECRET = "admin-bff-mesh-token"
PATH_ENVS = ["APP_MESH_TOKEN_ISSUER_KEY_PATH", "APP_MESH_TOKEN_HEADSCALE_API_KEY_PATH"]
WANT_REMOTE = {
    "issuerKey": ("hugmesh/mesh-token-issuer", "private-key"),
    "headscaleApiKey": ("hugmesh/headscale-admin", "api-key"),
}
WANT_PATH_KEY = {
    "APP_MESH_TOKEN_ISSUER_KEY_PATH": "issuerKey",
    "APP_MESH_TOKEN_HEADSCALE_API_KEY_PATH": "headscaleApiKey",
}

dep_file = os.path.join(d, "admin-bff-api", "deployment.yaml")
deps = [o for o in load_all(dep_file) if o.get("kind") == "Deployment"]
if len(deps) != 1:
    bad(f"admin-bff-api/deployment.yaml holds {len(deps)} Deployment(s), expected 1")
    print(f"CHECKS {checks}")
    sys.exit(1)
dep = deps[0]
dns = (dep.get("metadata") or {}).get("namespace", "")
pod = ((dep.get("spec") or {}).get("template") or {}).get("spec") or {}
ctrs = [c for c in (pod.get("containers") or []) if c.get("name") == "hugmesh-admin-bff-api"]
if len(ctrs) != 1:
    bad("no container named hugmesh-admin-bff-api in the admin-bff Deployment")
    print(f"CHECKS {checks}")
    sys.exit(1)
ctr = ctrs[0]
env = ctr.get("env") or []

# 6b. no duplicate APP_MESH_TOKEN_* name
names = [e.get("name", "") for e in env]
dups = sorted({n for n in names if n.startswith("APP_MESH_TOKEN_") and names.count(n) > 1})
if dups:
    bad(f"APP_MESH_TOKEN_* env declared more than once: {', '.join(dups)} — a strategic-merge overlay keeps only one, and which one is not this file's choice")
else:
    ok("no APP_MESH_TOKEN_* env name is declared twice")
envmap = {e.get("name"): e for e in env}

# 6. the flag
flag = envmap.get("APP_MESH_TOKEN_ENABLED")
if flag is None:
    bad("APP_MESH_TOKEN_ENABLED is not declared — the lever must be visible in the manifest, not left to the image default")
elif "valueFrom" in flag or flag.get("value") not in ("true", "false"):
    bad(f"APP_MESH_TOKEN_ENABLED is {flag.get('value', flag.get('valueFrom'))!r}, not the literal string \"true\" or \"false\" — any other value ARMS a bare @ConditionalOnProperty")
else:
    ok(f"APP_MESH_TOKEN_ENABLED is the literal \"{flag['value']}\"")

# credential never as env
leaks = []
for e in env:
    ref = ((e.get("valueFrom") or {}).get("secretKeyRef") or {})
    if ref.get("name") == SECRET:
        leaks.append(e.get("name", "?"))
if leaks:
    bad(f"{', '.join(leaks)} read Secret {SECRET} into the ENVIRONMENT — the issuer key and API key are files only (pod spec, describe, /proc/<pid>/environ)")
else:
    ok(f"no env var reads Secret {SECRET} (credentials stay files)")

# 1. the path envs and their mount
mounts = ctr.get("volumeMounts") or []
vols = {v.get("name"): v for v in (pod.get("volumes") or [])}
used = {}
for pe in PATH_ENVS:
    e = envmap.get(pe)
    if e is None:
        bad(f"{pe} is not declared")
        continue
    if "valueFrom" in e or not isinstance(e.get("value"), str) or not e["value"].startswith("/"):
        bad(f"{pe} must be a literal absolute path, got {e.get('value', e.get('valueFrom'))!r}")
        continue
    p = e["value"]
    parent, base = posixpath.split(p)
    m = [x for x in mounts if posixpath.normpath(x.get("mountPath", "")) == posixpath.normpath(parent)]
    if len(m) != 1:
        bad(f"{pe}={p}: no volumeMount at {parent} in hugmesh-admin-bff-api — the file can never exist")
        continue
    m = m[0]
    if m.get("readOnly") is not True:
        bad(f"{pe}: mount {parent} is not readOnly")
    else:
        ok(f"{pe}={p} sits in readOnly mount {parent} (volume {m.get('name')})")
    used[pe] = (m.get("name"), base)

# 2. the volume(s)
secret_names = set()
seen_vols = set()
for pe, (vname, base) in used.items():
    if vname in seen_vols:
        continue
    seen_vols.add(vname)
    v = vols.get(vname)
    if v is None or "secret" not in v:
        bad(f"{pe}: volume {vname!r} is not a secret volume")
        continue
    s = v["secret"] or {}
    sn = s.get("secretName", "")
    secret_names.add(sn)
    if s.get("optional") is not True:
        bad(f"volume {vname}: optional: true is missing — the Vault paths are operator-seeded, so a required secret volume holds the always-present admin plane in ContainerCreating")
    else:
        ok(f"volume {vname} (Secret {sn}) is optional: true")
    if s.get("defaultMode") != 0o400:
        bad(f"volume {vname}: defaultMode is {s.get('defaultMode')!r}, not 0400")
    else:
        ok(f"volume {vname} has defaultMode 0400")

# 3. readability for a non-root user
sc = pod.get("securityContext") or {}
uid = sc.get("runAsUser")
if uid not in (None, 0) and sc.get("fsGroup") is None:
    bad(f"runAsUser {uid} with no pod fsGroup — a 0400 secret file is root:root and unreadable to the app")
elif uid not in (None, 0):
    ok(f"runAsUser {uid} reads the 0400 files through fsGroup {sc.get('fsGroup')}")

if secret_names != {SECRET}:
    bad(f"the mesh-token paths resolve to Secret(s) {sorted(secret_names)}, expected exactly {SECRET}")
else:
    ok(f"both paths resolve to Secret {SECRET}")

# 4./5. the ExternalSecret
esdir = os.path.join(d, "external-secrets")
kust = {}
kf = os.path.join(esdir, "kustomization.yaml")
for o in load_all(kf):
    kust = o
listed = set(kust.get("resources") or [])
found = []
for f in sorted(glob.glob(os.path.join(esdir, "*.yaml"))):
    for o in load_all(f):
        if o.get("kind") != "ExternalSecret":
            continue
        md = o.get("metadata") or {}
        sp = o.get("spec") or {}
        tname = (sp.get("target") or {}).get("name") or md.get("name")
        if tname in secret_names and md.get("namespace") == dns:
            found.append((os.path.basename(f), o))
if len(found) != 1:
    bad(f"{len(found)} ExternalSecret(s) under external-secrets/ create Secret {SECRET} in {dns}, expected exactly 1")
else:
    fname, es = found[0]
    sp = es.get("spec") or {}
    if fname not in listed:
        bad(f"ExternalSecret {SECRET} lives in {fname}, which external-secrets/kustomization.yaml does not list — never rendered, Secret never exists")
    else:
        ok(f"ExternalSecret {SECRET} ({fname}) is listed in external-secrets/kustomization.yaml")
    store = sp.get("secretStoreRef") or {}
    if store.get("name") != "hugmesh-vault" or store.get("kind") != "ClusterSecretStore":
        bad(f"ExternalSecret {SECRET} reads store {store!r}, not ClusterSecretStore hugmesh-vault")
    else:
        ok(f"ExternalSecret {SECRET} reads ClusterSecretStore hugmesh-vault")
    if sp.get("refreshInterval") != "1h":
        bad(f"ExternalSecret {SECRET} refreshInterval is {sp.get('refreshInterval')!r}, not 1h")
    else:
        ok(f"ExternalSecret {SECRET} refreshInterval 1h")
    produced = {}
    for item in sp.get("data") or []:
        rr = item.get("remoteRef") or {}
        produced[item.get("secretKey")] = (rr.get("key"), rr.get("property"))
    tmpl = ((sp.get("target") or {}).get("template") or {}).get("data")
    keys = set(tmpl) if isinstance(tmpl, dict) else set(produced)
    for pe, (vname, base) in used.items():
        if base not in keys:
            bad(f"{pe} opens key {base!r}, but ExternalSecret {SECRET} produces only {sorted(keys)} — the file is never written")
        else:
            ok(f"{pe} basename {base!r} is a key ExternalSecret {SECRET} produces")
        want = WANT_PATH_KEY[pe]
        if base != want:
            bad(f"{pe} opens {base!r}, but that credential is {want!r} — the two files would be swapped")
    if produced != WANT_REMOTE:
        bad(f"ExternalSecret {SECRET} reads {produced!r}, expected exactly {WANT_REMOTE!r}")
    else:
        ok(f"ExternalSecret {SECRET} reads exactly mesh-token-issuer/private-key and headscale-admin/api-key")

# 7. the headscale address names a real Service
hb = envmap.get("APP_MESH_TOKEN_HEADSCALE_BASE_URL")
svcs = [o for o in load_all(os.path.join(d, "headscale", "service.yaml")) if o.get("kind") == "Service"]
if hb is None or not isinstance(hb.get("value"), str):
    bad("APP_MESH_TOKEN_HEADSCALE_BASE_URL is not a literal")
elif len(svcs) != 1:
    bad(f"manifests/headscale/service.yaml holds {len(svcs)} Service(s), expected 1 — cannot derive the address")
else:
    s = svcs[0]
    sm = s.get("metadata") or {}
    ports = [p.get("port") for p in ((s.get("spec") or {}).get("ports") or [])]
    want = [f"http://{sm.get('name')}.{sm.get('namespace')}.svc.cluster.local:{p}" for p in ports]
    if hb["value"] not in want:
        bad(f"APP_MESH_TOKEN_HEADSCALE_BASE_URL={hb['value']} names no port of the headscale Service ({want})")
    else:
        ok(f"APP_MESH_TOKEN_HEADSCALE_BASE_URL matches the headscale Service ({hb['value']})")
hu = envmap.get("APP_MESH_TOKEN_HEADSCALE_USER")
if hu is None or hu.get("value") != "hugmesh":
    bad(f"APP_MESH_TOKEN_HEADSCALE_USER is {None if hu is None else hu.get('value')!r}, not \"hugmesh\"")
else:
    ok("APP_MESH_TOKEN_HEADSCALE_USER is \"hugmesh\"")

print(f"CHECKS {checks}")
sys.exit(1 if fails else 0)
PY
}

if [ "${CHILD}" = yes ]; then
  scan "${DIR}"
  exit $?
fi

echo "== admin-bff mesh-token secret refs (real tree) =="
out="$(scan "${DIR}")"; rc=$?
printf '%s\n' "${out}" | grep -v '^CHECKS ' || true
n="$(printf '%s\n' "${out}" | sed -n 's/^CHECKS \([0-9][0-9]*\)$/\1/p' | tail -1)"
n="${n:-0}"
pass=$((pass + $(printf '%s\n' "${out}" | grep -c '^  PASS ' || true)))
fail=$((fail + $(printf '%s\n' "${out}" | grep -c '^  FAIL ' || true)))
[ "${rc}" -eq 0 ] || bad "the real tree fails the mesh-token wiring (above)"

# Vacuity floor: a scan that stops early (missing container, unparsable file)
# makes fewer assertions. 17 is what the real tree makes today; fewer means the
# scan silently stopped looking at something.
FLOOR=17
if [ "${n}" -ge "${FLOOR}" ]; then
  ok "vacuity floor: the scan made ${n} assertions (>= ${FLOOR})"
else
  bad "vacuity floor: the scan made only ${n} assertions (< ${FLOOR}) — it stopped looking"
fi

# ── negative controls ──────────────────────────────────────────────────────────
# Each control copies the three directories the scan reads, plants ONE defect,
# proves the defect really changed the file, and requires the child scan to FAIL
# naming it. A control whose mutation did not apply is itself a failure: an
# unapplied mutation is a control that tests nothing.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/meshtoken-refs.XXXXXX")" || { echo "FATAL: mktemp" >&2; exit 1; }
trap 'rm -rf "${SCRATCH}"' EXIT

fixture() { # <name> -> prints the fixture manifest dir
  local t
  t="${SCRATCH}/$1/manifests"
  mkdir -p "${t}"
  cp -R "${DIR}/admin-bff-api" "${DIR}/external-secrets" "${DIR}/headscale" "${t}/"
  printf '%s\n' "${t}"
}

# <name> <file relative to manifests> <python expr over `s`> <expected FAIL substring>
control() {
  local name rel expr want t f before after cout crc
  name="$1"; rel="$2"; expr="$3"; want="$4"
  t="$(fixture "${name}")"
  f="${t}/${rel}"
  before="$(cksum < "${f}")"
  python3 - "${f}" "${expr}" <<'PY'
import sys
# eval() is deliberate and safe here: `expr` is one of the literal mutation
# expressions written in THIS script's control lines below, never input.
p, expr = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
s = eval(expr)
open(p, "w", encoding="utf-8").write(s)
PY
  after="$(cksum < "${f}")"
  if [ "${before}" = "${after}" ]; then
    bad "control '${name}': the mutation did not change ${rel} — this control tests nothing"
    return 0
  fi
  cout="$(MESHTOKEN_MANIFEST_DIR="${t}" bash "${BASH_SOURCE[0]}" --scan-only 2>&1)"; crc=$?
  if [ "${crc}" -ne 0 ] && printf '%s\n' "${cout}" | grep -F -- "${want}" >/dev/null; then
    ok "control '${name}': caught (${want})"
  else
    bad "control '${name}': NOT caught (rc=${crc}, wanted a FAIL containing '${want}')"
    printf '%s\n' "${cout}" | sed 's/^/      | /' | head -30
  fi
}

echo "== negative controls =="
# positive control first: an unmodified copy must pass, or every caught control
# below could be catching the copy rather than the defect.
t0="$(fixture clean)"
cout="$(MESHTOKEN_MANIFEST_DIR="${t0}" bash "${BASH_SOURCE[0]}" --scan-only 2>&1)"; crc=$?
if [ "${crc}" -eq 0 ]; then ok "control 'clean': an unmodified copy passes"; else bad "control 'clean': an unmodified copy FAILS (rc=${crc})"; printf '%s\n' "${cout}" | head -20; fi

D=admin-bff-api/deployment.yaml
E=external-secrets/secretstore.yaml
K=external-secrets/kustomization.yaml
control secret-name-typo   "${D}" 's.replace("secretName: admin-bff-mesh-token", "secretName: admin-bff-meshtoken", 1)' "ExternalSecret(s) under external-secrets/ create Secret"
control es-key-renamed     "${E}" 's.replace("secretKey: issuerKey", "secretKey: issuer_key", 1)' "opens key 'issuerKey'"
control optional-dropped   "${D}" 's.replace("secretName: admin-bff-mesh-token\n            optional: true\n", "secretName: admin-bff-mesh-token\n", 1)' "optional: true is missing"
control mount-moved        "${D}" 's.replace("mountPath: /run/secrets/mesh-token,", "mountPath: /run/secrets/meshtoken,", 1)' "no volumeMount at /run/secrets/mesh-token"
control flag-typo          "${D}" 's.replace("APP_MESH_TOKEN_ENABLED,                value: \"false\"", "APP_MESH_TOKEN_ENABLED,                value: \"False\"", 1)' "not the literal string"
control fsgroup-dropped    "${D}" 's.replace("        fsGroup: 1000\n", "", 1)' "with no pod fsGroup"
control mode-widened       "${D}" 's.replace("defaultMode: 0400", "defaultMode: 0444", 1)' "not 0400"
control property-changed   "${E}" 's.replace("key: hugmesh/headscale-admin\n        property: api-key", "key: hugmesh/headscale-admin\n        property: apikey", 1)' "expected exactly"
control es-unlisted        "${K}" 's.replace("  - secretstore.yaml\n", "", 1)' "does not list"
control es-other-namespace "${E}" 's.replace("name: admin-bff-mesh-token\n  namespace: hugmesh-backend", "name: admin-bff-mesh-token\n  namespace: hugmesh-pki", 1)' "ExternalSecret(s) under external-secrets/ create Secret"
control paths-swapped      "${D}" 's.replace("/run/secrets/mesh-token/issuerKey", "/run/secrets/mesh-token/XX", 1).replace("/run/secrets/mesh-token/headscaleApiKey", "/run/secrets/mesh-token/issuerKey", 1).replace("/run/secrets/mesh-token/XX", "/run/secrets/mesh-token/headscaleApiKey", 1)' "the two files would be swapped"
control key-as-env         "${D}" 's.replace("            - { name: APP_MESH_TOKEN_HEADSCALE_USER,", "            - name: APP_MESH_TOKEN_ISSUER_KEY\n              valueFrom:\n                secretKeyRef: { name: admin-bff-mesh-token, key: issuerKey, optional: true }\n            - { name: APP_MESH_TOKEN_HEADSCALE_USER,", 1)' "into the ENVIRONMENT"
control env-duplicated     "${D}" 's.replace("            - { name: APP_MESH_TOKEN_HEADSCALE_USER,", "            - { name: APP_MESH_TOKEN_ENABLED, value: \"true\" }\n            - { name: APP_MESH_TOKEN_HEADSCALE_USER,", 1)' "declared more than once"
control hs-url-wrong-ns    "${D}" 's.replace("APP_MESH_TOKEN_HEADSCALE_BASE_URL,     value: \"http://headscale.hugmesh-pki.", "APP_MESH_TOKEN_HEADSCALE_BASE_URL,     value: \"http://headscale.headscale.", 1)' "names no port of the headscale Service"
control store-changed      "${E}" 's.replace("  name: admin-bff-mesh-token\n  namespace: hugmesh-backend\nspec:\n  refreshInterval: 1h\n  secretStoreRef:\n    name: hugmesh-vault", "  name: admin-bff-mesh-token\n  namespace: hugmesh-backend\nspec:\n  refreshInterval: 1h\n  secretStoreRef:\n    name: other-vault", 1)' "not ClusterSecretStore hugmesh-vault"

echo "== admin-bff mesh-token secret refs: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
