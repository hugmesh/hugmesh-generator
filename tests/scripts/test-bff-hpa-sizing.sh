#!/usr/bin/env bash
# =============================================================================
# test-bff-hpa-sizing.sh — a JVM service must not autoscale on MEMORY, and must
# REQUEST at least what its JVM uses at idle.
#
# WHAT HAPPENED (hugmesh-generator#685; measured on the kind cluster hugmesh-local,
# 2026-11-18). Every BFF Deployment requested 256Mi and carried an HPA with a
# memory Utilization target of 80 %. The JVMs sit at about 415-425 Mi at idle
# (163 % and 113 % of the request), so the memory target was exceeded from the
# first scrape and both autoscalers went 2 -> 6 with no load at all: twelve JVM pods
# holding about 5 GiB. A JVM's heap grows to what it is allowed and is not handed
# back, so memory utilisation is not a load signal for it. Raising the request alone
# does not help: at 80 % of 512 Mi the threshold is about 410 Mi, below idle use.
#
# WHAT THIS PINS, offline, over specs/cluster/manifests (no cluster, no network).
# For every Deployment whose container carries SPRING_R2DBC_URL (the Spring Boot
# BFFs; the same candidate census test-db-connection-budget.sh uses) AND is scaled
# by a HorizontalPodAutoscaler (one without an HPA cannot mis-scale):
#   (1) the container requests at least MIN_REQUEST_MI (512) of memory;
#   (2) the HorizontalPodAutoscaler that scales it carries NO memory metric.
# Every HorizontalPodAutoscaler must name a Deployment that exists, so a typo in a
# scaleTargetRef cannot silently drop a service out of the census. Zero candidates
# is FAIL: a census that finds nothing has lost the tree, not proved it clean.
#
# NEGATIVE CONTROL: BFF_ROOT=<tree> runs the analyser over another checkout. On
# origin/main 9ca8ea20 (before this change) it is RED on all seven BFFs.
#
# Needs bash + python3 + PyYAML (the debian shell-suites job installs PyYAML; the
# alpine job has py3-yaml).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BFF_ROOT:-$(cd "${HERE}/../.." && pwd)}"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML is required (pip install pyyaml / apk add py3-yaml)"; exit 2; }
[ -d "${REPO}/specs/cluster/manifests" ] || { echo "  FAIL ${REPO}/specs/cluster/manifests is not a directory"; exit 2; }

REPO="${REPO}" python3 - <<'PY'
import glob, os, re, sys
import yaml

REPO = os.environ["REPO"]
MAN = os.path.join(REPO, "specs", "cluster", "manifests")
MIN_REQUEST_MI = 512

P = F = 0
def ok(m):
    global P; P += 1; print("  PASS " + m)
def bad(m):
    global F; F += 1; print("  FAIL " + m)

UNITS = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024, "": 1 / (1024 * 1024)}
def to_mi(q):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti)?", str(q).strip())
    return None if not m else float(m.group(1)) * UNITS[m.group(2) or ""]

def load_all(path):
    with open(path) as fh:
        try:
            return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]
        except yaml.YAMLError as e:
            bad("%s: not parseable YAML: %s" % (os.path.relpath(path, REPO), e)); return []

deployments, hpas = [], []
for path in sorted(glob.glob(os.path.join(MAN, "*", "*.yaml"))):
    for doc in load_all(path):
        if doc.get("kind") == "Deployment":
            deployments.append((path, doc))
        elif doc.get("kind") == "HorizontalPodAutoscaler":
            hpas.append((path, doc))

names = {d.get("metadata", {}).get("name") for _, d in deployments}
by_target = {}
for path, h in hpas:
    t = (h.get("spec", {}).get("scaleTargetRef") or {})
    if t.get("kind") == "Deployment" and t.get("name") not in names:
        bad("%s: HPA scaleTargetRef %r names no Deployment under manifests" % (os.path.relpath(path, REPO), t.get("name")))
    by_target[t.get("name")] = (path, h)

candidates = 0
for path, d in deployments:
    rel = os.path.relpath(path, REPO)
    name = d.get("metadata", {}).get("name")
    for c in d.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []) or []:
        envnames = {e.get("name") for e in (c.get("env") or []) if isinstance(e, dict)}
        if "SPRING_R2DBC_URL" not in envnames:
            continue
        candidates += 1
        label = "%s (%s)" % (name, rel)
        h = by_target.get(name)
        if h is None:
            ok("%s: no HPA scales it, so there is nothing to mis-scale" % label)
            continue
        req = ((c.get("resources") or {}).get("requests") or {}).get("memory")
        mi = to_mi(req) if req is not None else None
        if mi is None:
            bad("%s: no readable memory request (%r)" % (label, req))
        elif mi < MIN_REQUEST_MI:
            bad("%s: memory request %s is below %d Mi, under idle JVM use" % (label, req, MIN_REQUEST_MI))
        else:
            ok("%s: memory request %s >= %d Mi" % (label, req, MIN_REQUEST_MI))
        metrics = h[1].get("spec", {}).get("metrics") or []
        mem = [m for m in metrics if (m.get("resource") or {}).get("name") == "memory"]
        if mem:
            bad("%s: HPA %s scales on MEMORY; a JVM heap is not a load signal" % (label, os.path.relpath(h[0], REPO)))
        else:
            ok("%s: HPA carries no memory metric" % label)

if candidates == 0:
    bad("no Deployment carries SPRING_R2DBC_URL: the census found nothing, so it proves nothing")

print("\n%d passed, %d failed" % (P, F))
sys.exit(1 if F else 0)
PY
