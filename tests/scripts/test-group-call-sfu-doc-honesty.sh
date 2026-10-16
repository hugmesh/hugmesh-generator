#!/usr/bin/env bash
# test-group-call-sfu-doc-honesty.sh — offline lint that keeps docs/GROUP-CALL-SFU.md
# and the four pages that point at it honest about what THIS repo contains.
#
# THE DEFECT THIS EXISTS TO STOP. README, ARCHITECTURE, COTURN and XR-CHAT said the
# group-call SFU "does not exist in any form" for weeks after the client half had
# merged in hugmesh-matrix-ui. The opposite drift is just as likely: someone lands
# LiveKit manifests (stage 1 of the plan) and the design page keeps saying
# "DESIGN ONLY, nothing in this repo deploys an SFU". Prose has no test, so both
# directions went unnoticed. This lint pins only what can be measured from this
# checkout; everything about tuwunel, LiveKit and lk-jwt-service upstream is NOT
# checked here (the page lists it under "Not verified").
#
# Properties:
#   1) the page's "server half is absent" claim is true: no livekit / lk-jwt /
#      rtc_foci / livekit_url / MatrixRTC in specs/ or scripts/ or tests/ (outside
#      the vendored UI bundle and this file). When it stops being true this FAILS,
#      and the page, its status banner and this lint are to be updated together;
#   2) every tuwunel image pin in specs/ and tests/stack is the tag the page says
#      the mesh pins, so a bump forces a re-measure of section 4.1;
#   3) [global.well_known] is still the last TOML table of tuwunel.toml (section 5
#      tells stage 2 to append one key there);
#   4) the coturn facts section 4.3 reasons from (ports, relay window, denied
#      ranges) are still what the manifests say;
#   5) the adjacent-defect sentence about reserved-prefixes.yaml stays consistent
#      with the file (it may be fixed; the page then has to stop saying it);
#   6) no page says the SFU "does not exist in any form" / is "NOT scheduled", and
#      each of the five pages links the design;
#   7) every repo path and test script the page cites exists.
#
# Pure static analysis. No network, no root, no docker, no cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
DOC="${REPO}/docs/GROUP-CALL-SFU.md"
SELF="tests/scripts/test-group-call-sfu-doc-honesty.sh"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

echo "== group-call SFU doc honesty: the page matches this checkout =="

REPO="${REPO}" SELF="${SELF}" python3 - <<'PY'
import os, re, sys

repo = os.environ["REPO"]
self_rel = os.environ["SELF"]
P = [0]; F = [0]
def ok(m):  print("  PASS " + m); P[0] += 1
def bad(m): print("  FAIL " + m); F[0] += 1

def read(rel):
    # bytes + replace: a stray NUL must not make this lint blind (GNU grep skips a
    # whole file on one 0x00 and reports "no match").
    with open(os.path.join(repo, rel), "rb") as f:
        return f.read().decode("utf-8", "replace")

doc_rel = "docs/GROUP-CALL-SFU.md"
if not os.path.isfile(os.path.join(repo, doc_rel)):
    bad("docs/GROUP-CALL-SFU.md is missing"); print("== RESULT: 0 passed, 1 failed =="); sys.exit(1)
doc = read(doc_rel)

# ---- 1) the server half is absent -------------------------------------------
NEEDLE = re.compile(r"livekit|lk-jwt|rtc_foci|matrixrtc|matrix_rtc", re.I)
hits = []
walked = 0
for top in ("specs", "scripts", "tests"):
    for root, dirs, files in os.walk(os.path.join(repo, top)):
        rel_root = os.path.relpath(root, repo)
        if rel_root.startswith("tests/stack/.uidist") or "/node_modules" in rel_root:
            dirs[:] = []
            continue
        for fn in files:
            rel = os.path.join(rel_root, fn)
            if rel == self_rel:
                continue
            walked += 1
            try:
                with open(os.path.join(repo, rel), "rb") as f:
                    txt = f.read().decode("utf-8", "replace")
            except OSError:
                continue
            if NEEDLE.search(txt):
                hits.append(rel)
if walked < 200:
    bad("absence scan walked only %d files (expected the whole specs/scripts/tests tree)" % walked)
elif doc.count("DESIGN ONLY") == 0:
    bad("the page lost its 'DESIGN ONLY' status banner")
elif hits:
    bad("the page says the server half is absent, but these files mention it: %s. "
        "Update the status banner, sections 2 and 10 and this lint together." % ", ".join(sorted(hits)[:8]))
else:
    ok("server half absent from specs/, scripts/ and tests/ (%d files scanned), as the banner says" % walked)

# ---- 2) tuwunel pin ----------------------------------------------------------
pins = {}
for top in ("specs", "tests/stack"):
    for root, dirs, files in os.walk(os.path.join(repo, top)):
        rel_root = os.path.relpath(root, repo)
        if ".uidist" in rel_root or "node_modules" in rel_root:
            dirs[:] = []
            continue
        for fn in files:
            rel = os.path.join(rel_root, fn)
            try:
                with open(os.path.join(repo, rel), "rb") as f:
                    txt = f.read().decode("utf-8", "replace")
            except OSError:
                continue
            for m in re.finditer(r"matrix-construct/tuwunel:([A-Za-z0-9._-]+)", txt):
                pins.setdefault(m.group(1), set()).add(rel)
doc_tag = "v1.7.0"
if not pins:
    bad("no tuwunel image pin found anywhere (the scan is blind)")
elif set(pins) != {doc_tag}:
    bad("tuwunel pins are %s but the page's section 4.1 was measured at %s: re-measure it"
        % (sorted(pins), doc_tag))
elif "`" + doc_tag + "`" not in doc:
    bad("the page no longer names the pinned tag %s" % doc_tag)
else:
    ok("every tuwunel pin (%d files) is %s, the tag the page measured" % (sum(len(v) for v in pins.values()), doc_tag))

# ---- 3) [global.well_known] is the last table -------------------------------
tw = read("specs/cluster/manifests/tuwunel/tuwunel.yaml").split("\n")
idx = [i for i, l in enumerate(tw) if l.strip() == "[global.well_known]"]
if len(idx) != 1:
    bad("expected exactly one [global.well_known] line in tuwunel.yaml, found %d" % len(idx))
else:
    i = idx[0]
    indent = len(tw[i]) - len(tw[i].lstrip())
    later = []
    for l in tw[i + 1:]:
        if l.strip() and (len(l) - len(l.lstrip())) < indent:
            break  # left the tuwunel.toml block scalar
        if re.match(r"\s*\[[A-Za-z0-9_.\"-]+\]\s*$", l):
            later.append(l.strip())
    if later:
        bad("section 5 says [global.well_known] must stay the LAST table, but %s follows it" % later)
    else:
        ok("[global.well_known] is still the last table of tuwunel.toml")

# ---- 4) coturn facts --------------------------------------------------------
np = read("specs/cluster/manifests/coturn/network-policy.yaml")
dep = read("specs/cluster/manifests/coturn/deployment.yaml")
missing = []
for port in ("3478", "5349"):
    for proto in ("UDP", "TCP"):
        if not re.search(r"protocol:\s*%s,\s*port:\s*%s\b" % (proto, port), np):
            missing.append("%s/%s" % (port, proto))
if not re.search(r"port:\s*49152,\s*endPort:\s*49200", np):
    missing.append("relay window 49152-49200")
for needle in ("denied-peer-ip=10.0.0.0-10.255.255.255", "denied-peer-ip=100.64.0.0-100.127.255.255",
               "denied-peer-ip=127.0.0.0-127.255.255.255", "denied-peer-ip=169.254.0.0-169.254.255.255",
               "denied-peer-ip=172.16.0.0-172.31.255.255", "denied-peer-ip=192.168.0.0-192.168.255.255"):
    if needle not in dep:
        missing.append(needle)
claim = all(s in doc for s in ("3478 and 5349", "49152-49200", "100.64.0.0/10"))
if missing:
    bad("section 4.3 reasons from coturn facts that changed: %s" % missing)
elif not claim:
    bad("section 4.3 no longer states the coturn ports, relay window and tailnet range this lint pins")
else:
    ok("coturn ports 3478/5349, relay window 49152-49200 and the denied ranges are as section 4.3 states")

# ---- 5) reserved-prefixes consistency ---------------------------------------
rp = read("specs/cluster/reserved-prefixes.yaml")
labels = set(re.findall(r"^\s*-\s*([A-Za-z0-9-]+)\s*(?:#.*)?$", rp, re.M))
says_no_turn = "has no `turn` label" in re.sub(r"\s+", " ", doc)
if "turn" in labels and says_no_turn:
    bad("reserved-prefixes.yaml now has a `turn` label but the page still says it has none")
elif "turn" not in labels and not says_no_turn:
    bad("reserved-prefixes.yaml has no `turn` label and the page no longer says so")
elif len(labels) < 10:
    bad("parsed only %d reserved labels (the parse is blind)" % len(labels))
else:
    ok("the page's statement about the `turn` label matches reserved-prefixes.yaml (turn %s)"
       % ("present" if "turn" in labels else "absent"))

# ---- 6) stale wording gone, every page links the design ---------------------
pages = ["README.md", "docs/ARCHITECTURE.md", "docs/COTURN.md", "docs/XR-CHAT.md", "docs/README.md"]
STALE = re.compile(r"does not exist in any form|NOT scheduled|Group-call SFU\W+does not exist", re.I)
bad_pages = []
unlinked = []
for p in pages:
    t = read(p)
    if STALE.search(t):
        bad_pages.append(p)
    if "GROUP-CALL-SFU.md" not in t:
        unlinked.append(p)
if bad_pages:
    bad("stale 'does not exist' wording in %s" % bad_pages)
elif unlinked:
    bad("these pages do not link GROUP-CALL-SFU.md: %s" % unlinked)
else:
    ok("no page claims the SFU does not exist in any form; all %d pages link the design" % len(pages))

# ---- 7) cited paths and scripts exist ---------------------------------------
tokens = set(re.findall(r"`([^`\n]+)`", doc))
# Paths inside the UPSTREAM tuwunel repository, cited as such; they are not ours.
UPSTREAM = {"docs/calls/matrix_rtc.md", "docs/development/compliance/msc.md"}
tokens -= UPSTREAM
missing = []
checked = 0
for t in sorted(tokens):
    t = t.strip()
    if re.search(r"[<>*{}$ ]", t):
        continue
    cand = None
    if re.match(r"^(specs|scripts|tests|docs)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+$", t):
        cand = [t]
    elif re.match(r"^manifests/[A-Za-z0-9_./-]+$", t):
        cand = ["specs/cluster/" + t]
    elif re.match(r"^test-[A-Za-z0-9_-]+\.sh$", t):
        cand = ["tests/scripts/" + t]
    elif re.match(r"^[A-Z][A-Z0-9-]+\.md$", t):
        cand = ["docs/" + t]
    elif re.match(r"^external-secrets/[A-Za-z0-9_.-]+\.yaml$", t):
        cand = ["specs/cluster/manifests/" + t]
    if cand is None:
        continue
    checked += 1
    if not any(os.path.exists(os.path.join(repo, c)) for c in cand):
        missing.append(t)
if checked < 10:
    bad("only %d cited paths were recognised (the extractor is blind)" % checked)
elif missing:
    bad("the page cites files that do not exist: %s" % missing)
else:
    ok("all %d repo paths and scripts the page cites exist" % checked)

print("== RESULT: %d passed, %d failed ==" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
rc=$?
exit $rc
