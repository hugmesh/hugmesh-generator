#!/usr/bin/env bash
# =============================================================================
# validate-federation-module-slugs.sh — federation_modules registration drift guard.
# =============================================================================
# THE DEFECT THIS EXISTS FOR (observed 2026-08-26, confirmed by hand):
#
#   specs/cluster/optional-services.yaml declared
#       akkoma  -> federationModule: { slug: akkoma,  changeset: 023-register-akkoma-module.xml }
#       tuwunel -> federationModule: { slug: tuwunel, changeset: 024-register-tuwunel-module.xml }
#   but those changesets actually seed
#       023 -> <column name="slug" value="mastodon"/>
#       024 -> <column name="slug" value="matrix"/>
#   and NO changeset in hugmesh-federation-api ever seeds an `akkoma` or `tuwunel`
#   row. So anything resolving the module by the registry's slug looked it up under
#   a name no row carries. The failure is SILENT at both ends: the host shell just
#   never finds the remote, and tests/stack/seed-e2e.sh leg 4 logs
#   `no federation_modules row for slug '…' — skipped` and carries on green.
#
# WHICH SIDE IS AUTHORITATIVE: the DB slug.
#   * the host shell resolves remotes from federation_modules.slug at RUNTIME
#     (docs/FEDERATION-EXAMPLES.md §5), and the seeder UPDATEs that column;
#   * `mastodon` and `matrix` are FROZEN feature slugs — specs/cluster/
#     reserved-prefixes.yaml reserves them (and reserves neither `akkoma` nor
#     `tuwunel`), and 041-rebrand-module-remote-entries.xml's header names them in
#     its explicit NOT-RENAMED list;
#   * the changesets are MERGED Liquibase history. Editing a seed value in place
#     breaks its checksum on every live DB (ValidationFailedException at startup)
#     AND does not migrate already-RAN databases. They CANNOT be the side that moves.
#   Therefore the registry metadata is the side that was wrong, and this gate pins
#   it to the changeset rather than the other way round.
#
# WHAT IS ASSERTED — both sides are RE-DERIVED every run, never tabulated here.
# For every declaration that names a federation module (optional-services.yaml
# `federationModule:` blocks AND every `kind: FederationModuleRegistration`
# descriptor under specs/cluster/manifests/**):
#
#   LANDED (the named changeset file exists in the federation-api changelog):
#     1) the declared slug        == the changeset's <column name="slug">;
#     2) the declared mountAt     == metadata.mountAt in that same <insert>;
#     3) declared requiresRole    == metadata.requiresRole   (when declared);
#     4) declared exposed(Module) == <column name="exposed_module"> (when declared);
#     5) the changeset is <include>d by db.changelog-master.xml — an unincluded
#        changeset never runs, so the row would be absent however right it reads.
#   PENDING (the named changeset does not exist yet — a forward reference):
#     6) its NNN- number prefix must be FREE in the changelog. A forward reference
#        to an already-taken number is a registration that can never land under the
#        name it claims. (This is how the superadmin-service-catalog descriptor's
#        "040-…" was caught: 040 had since been taken by character-studio.)
#
#   7) VACUITY GUARD: at least one declaration must have been derived, and at least
#      one must be LANDED. An empty derivation compares nothing and passes — which
#      is exactly how this class of check dies unnoticed.
#
# EXIT CODES (mirroring scripts/validate-reserved-prefixes.sh, deliberately)
#   0  PASS        — every declaration derived and agreed.
#   1  FAIL        — drift: a slug/mountAt/role/exposed mismatch, a missing
#                    <include>, a colliding forward reference, or a vacuous run.
#   2  FATAL       — environment problem (missing input, no python3/PyYAML).
#   3  INCOMPLETE  — the federation-api changelog could not be located, so the
#                    comparison did not run. Non-zero on purpose: an unrun
#                    assertion is not a pass. Point FEDERATION_CHANGELOG_DIR (or
#                    FEDERATION_SIBLING_ROOT) at a checkout, or set
#                    FEDERATION_ALLOW_MISSING_CHANGELOG=1 to opt out DELIBERATELY
#                    (exit 0, but the verdict line still says INCOMPLETE).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY="${REPO_ROOT}/specs/cluster/optional-services.yaml"
MANIFESTS="${REPO_ROOT}/specs/cluster/manifests"

# Where the federation-api Liquibase changelog lives. It is a SEPARATE repo, so it
# is located, never vendored. First explicit win, then the usual checkouts.
CHANGELOG_DIR="${FEDERATION_CHANGELOG_DIR:-}"
if [ -z "${CHANGELOG_DIR}" ]; then
  REL="hugmesh-federation-api/src/main/resources/db/changelog"
  for root in "${FEDERATION_SIBLING_ROOT:-}" "${REPO_ROOT}/.stack-src" "$(cd "${REPO_ROOT}/.." && pwd)"; do
    [ -n "${root}" ] || continue
    if [ -d "${root}/${REL}" ]; then CHANGELOG_DIR="${root}/${REL}"; break; fi
  done
fi

ALLOW_MISSING="${FEDERATION_ALLOW_MISSING_CHANGELOG:-0}"

[ -f "${REGISTRY}" ] || { echo "FATAL: missing required file: ${REGISTRY}" >&2; exit 2; }
# The descriptor sweep globs under this dir; if it is absent the sweep would come
# back empty and half the declarations would vanish without a word.
[ -d "${MANIFESTS}" ] || { echo "FATAL: missing manifests dir: ${MANIFESTS}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required." >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML is required (pip install pyyaml)." >&2; exit 2; }

python3 - "${REGISTRY}" "${MANIFESTS}" "${CHANGELOG_DIR}" "${ALLOW_MISSING}" <<'PY'
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

import yaml

registry_path, manifests_dir, changelog_dir, allow_missing_raw = sys.argv[1:5]
allow_missing = allow_missing_raw.strip().lower() in {"1", "true", "yes", "on"}

fails = []
notes = []


def local(tag):
    return tag.rsplit("}", 1)[-1]


# ── side A: every declaration in THIS repo that names a federation module ───────
# Shape-normalised to one record so the registry's inline `federationModule` block
# and a standalone FederationModuleRegistration descriptor are compared identically.
def declarations():
    out = []

    doc = yaml.safe_load(open(registry_path, encoding="utf-8"))
    for svc in doc["spec"]["services"]:
        fm = svc.get("federationModule")
        if not fm:
            continue
        out.append({
            "where": "%s (optional-services.yaml: %s)" % (fm.get("slug"), svc["slug"]),
            "slug": fm.get("slug"),
            "mountAt": fm.get("mountAt"),
            "requiresRole": fm.get("requiresRole"),
            "exposed": fm.get("exposed") or fm.get("exposedModule"),
            "changeset": fm.get("changeset"),
        })

    for path in sorted(glob.glob(os.path.join(manifests_dir, "**", "*.descriptor.yaml"),
                                 recursive=True)):
        try:
            d = yaml.safe_load(open(path, encoding="utf-8"))
        except Exception as exc:                        # malformed descriptor is a FAIL
            fails.append("%s: unparseable descriptor (%s)" % (path, exc))
            continue
        if not isinstance(d, dict) or d.get("kind") != "FederationModuleRegistration":
            continue
        spec = d.get("spec") or {}
        out.append({
            "where": "%s (%s)" % (spec.get("slug"),
                                  os.path.relpath(path, os.path.dirname(manifests_dir))),
            "slug": spec.get("slug"),
            "mountAt": spec.get("mountAt"),
            "requiresRole": spec.get("requiresRole"),
            "exposed": spec.get("exposedModule") or spec.get("exposed"),
            "changeset": (d.get("metadata") or {}).get("changeset"),
        })
    return out


# ── side B: what the named Liquibase changeset actually SEEDS ──────────────────
def seeded(changeset_path):
    """The federation_modules row a register-changeset inserts, or None."""
    root = ET.parse(changeset_path).getroot()
    for ins in root.iter():
        if local(ins.tag) != "insert":
            continue
        if ins.get("tableName") != "federation_modules":
            continue
        cols = {c.get("name"): c.get("value") for c in ins
                if local(c.tag) == "column"}
        meta = {}
        if cols.get("metadata"):
            try:
                meta = json.loads(cols["metadata"])
            except ValueError:
                meta = {}
        return {
            "slug": cols.get("slug"),
            "mountAt": meta.get("mountAt"),
            "requiresRole": meta.get("requiresRole"),
            "exposed": cols.get("exposed_module"),
        }
    return None


decls = declarations()
if not decls:
    fails.append("VACUOUS: no federation-module declaration was derived at all "
                 "(nothing was compared).")

if not changelog_dir or not os.path.isdir(changelog_dir):
    print("federation module slug gate")
    print("  changelog dir: NOT FOUND — %d declaration(s) derived, 0 compared."
          % len(decls))
    for d in decls:
        print("    declared: %s -> %s" % (d["where"], d["changeset"]))
    if fails:
        for f in fails:
            print("  [FAIL] %s" % f)
        print("RESULT: FAIL")
        sys.exit(1)
    if allow_missing:
        print("RESULT: PASS (INCOMPLETE — changelog not checked out, opted out via "
              "FEDERATION_ALLOW_MISSING_CHANGELOG=1)")
        sys.exit(0)
    print("RESULT: INCOMPLETE — set FEDERATION_CHANGELOG_DIR/FEDERATION_SIBLING_ROOT")
    sys.exit(3)

present = sorted(os.path.basename(p) for p in
                 glob.glob(os.path.join(changelog_dir, "*.xml"))
                 if os.path.basename(p) != "db.changelog-master.xml")
numbers = {}
for name in present:
    m = re.match(r"^(\d+)-", name)
    if m:
        numbers.setdefault(m.group(1), []).append(name)

master = os.path.join(changelog_dir, "db.changelog-master.xml")
included = set()
if os.path.isfile(master):
    mtext = open(master, encoding="utf-8").read()
    included = set(re.findall(r'file="[^"]*/([^"/]+\.xml)"', mtext))
else:
    fails.append("db.changelog-master.xml missing from %s" % changelog_dir)

print("federation module slug gate")
print("  registry:  %s" % registry_path)
print("  changelog: %s (%d changesets)" % (changelog_dir, len(present)))

landed = 0
for d in sorted(decls, key=lambda x: str(x["where"])):
    where, cs = d["where"], d["changeset"]
    if not cs:
        fails.append("%s: declares a federation module but names no changeset" % where)
        continue
    path = os.path.join(changelog_dir, cs)

    if not os.path.isfile(path):
        # PENDING forward reference — legal, but its number must still be free.
        m = re.match(r"^(\d+)-", cs)
        taken = numbers.get(m.group(1), []) if m else []
        if taken:
            fails.append("%s: forward-references %s, but number %s is ALREADY TAKEN "
                         "by %s — this registration can never land under that name"
                         % (where, cs, m.group(1), ", ".join(taken)))
        else:
            notes.append("%s: PENDING %s (number free)" % (where, cs))
        continue

    row = seeded(path)
    if row is None:
        fails.append("%s: %s exists but inserts no federation_modules row"
                     % (where, cs))
        continue

    landed += 1
    if cs not in included:
        fails.append("%s: %s is not <include>d by db.changelog-master.xml — it would "
                     "never run" % (where, cs))

    for field, label in (("slug", "slug"), ("mountAt", "mountAt"),
                         ("requiresRole", "requiresRole"), ("exposed", "exposed_module")):
        want, got = d.get(field), row.get(field)
        if want is None:
            continue                     # not declared here: nothing to disagree about
        if want != got:
            fails.append("%s: declared %s=%r but %s seeds %r"
                         % (where, label, want, cs, got))
    if not [f for f in fails if f.startswith(where)]:
        notes.append("%s: OK -> %s seeds slug=%r mountAt=%r"
                     % (where, cs, row["slug"], row["mountAt"]))

if decls and landed == 0:
    fails.append("VACUOUS: %d declaration(s) derived but NONE resolved to an existing "
                 "changeset — nothing was actually compared." % len(decls))

for n in notes:
    print("  [ok]   %s" % n)
for f in fails:
    print("  [FAIL] %s" % f)

print("  compared %d landed / %d declared" % (landed, len(decls)))
if fails:
    print("RESULT: FAIL")
    sys.exit(1)
print("RESULT: PASS")
sys.exit(0)
PY
