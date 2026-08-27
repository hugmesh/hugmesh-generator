#!/usr/bin/env bash
# test-argocd-route-honesty.sh — guards the DELIBERATE ABSENCE of a dedicated
# /bff/admin/argocd/** route-access row, and the reasoning that absence rests on.
#
# WHY THIS EXISTS. hugmesh-admin-ui's ArgoCD dashboard (/admin/argocd) calls
# /bff/admin/argocd/applications, /{name} and /{name}/sync. NO controller serves any of
# those paths in any repo in the org (verified by a comment-stripped scan of every
# @RestController/@RequestMapping class; the only ArgoCD code in hugmesh-admin-bff-api
# is the App-Store effector's ArgoCdClient, which has no HTTP surface). The obvious
# "fix" — seed a /bff/admin/argocd/** route-access row — is WRONG twice over, and this
# test pins both halves of why so a future change cannot quietly reintroduce it:
#
#   1. It would be a NO-OP. The seeded ('hugmesh-fe-gateway', '/bff/admin/**',
#      'ROLE_ADMIN') floor ALREADY covers the prefix. The gateway is not what is
#      broken; the request is authorized, forwarded, and 404s at the admin BFF.
#   2. It would be ACTIVELY HARMFUL. Matching is most-specific-wins, so a narrower
#      /bff/admin/argocd/** row SHADOWS the floor. A row that authorizes a 404 is a
#      green surface that proves nothing — and if its role were ever mistyped it would
#      silently narrow admin access to a real path later served there.
#
# WHAT IS ASSERTED (post-conditions on the seeded rows, via a real longest-pattern
# resolver run over the parsed SQL — not a substring grep):
#   1. The SQL comment stripper is STRING-LITERAL AWARE, proved on a fixture, before
#      it is trusted on the real file. See COMMENT-TOKEN INVERSION below.
#   2. /bff/admin/argocd/applications RESOLVES to a row at all (it is not unreachable).
#   3. The row it resolves to is the '/bff/admin/**' ROLE_ADMIN floor — i.e. nothing
#      narrower shadows it today.
#   4. No seeded url_pattern mentions 'argocd' anywhere, on any gateway.
#   5. docs/ADMIN-CONSOLES.md §2 still carries the WHOLE decision, not one table cell:
#      the evidence, the fail-open mechanism, the option-(b) decision, the two-repo
#      file-and-line removal spec and the 503 restore contract — each anchored inside
#      the subsection itself and each with its own PASS/FAIL line. That spec IS the
#      deliverable while the cross-repo edit is unlanded, so it is what must be pinned.
#
# COMMENT-TOKEN INVERSION — the defect that has bitten this repo four times. Assertion
# 4 must see the rows the database will really hold, so SQL comments have to go. But a
# naive `s/--.*//` also eats a `--` that appears INSIDE a quoted literal, and with it
# everything after it on that line — including further rows on the same statement. That
# is not hypothetical prose: it turns "a row naming argocd was added" into "no row
# names argocd", the exact inversion, and nothing about the green result would say so.
# The stripper below is a small tokenizer that skips over '…' and "…" literals, and
# assertion 1 proves it on a fixture where the naive form loses a real row. The
# fixture and the real schema go through the SAME rows_from_sql() function — a
# self-test wired to its own private copy of the stripper would keep passing while
# the real call site had been quietly downgraded, which is just this repo's
# "a guard nothing runs" in miniature.
#
# WHAT THIS DOES NOT PROVE: it does not contact a gateway, so it does not prove the
# gateway implements most-specific-wins the way the resolver here models it (that
# semantic is documented in 20-schema.sql and is assumed, not tested). It cannot see
# the admin-ui or host-shell trees, so it CANNOT prove the dashboard page was actually
# removed — that edit is cross-repo and is specified in docs/ADMIN-CONSOLES.md §2.
# It proves only that THIS repo has not seeded a row that would dress the dead page up
# as wired, and that the cross-repo spec is still on record in full.
#
# NON-VACUITY. The deriver below is a python program whose stdout this script parses.
# An exception in it used to leave the report EMPTY and this suite exited 0 printing
# "0 passed, 0 failed" — reproduced under review by appending one invalid UTF-8 byte to
# 20-schema.sql. Three things now close it: the deriver's rc is checked, its stderr is
# captured and any byte of it is a FAILURE, and the number of PASS/FAIL rows it emitted
# is asserted to be non-zero.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
DOC="${REPO}/docs/ADMIN-CONSOLES.md"

P=0; F=0; ASSERTS=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== ArgoCD route-access honesty (deliberate absence) =="
[ -f "${SCHEMA}" ] || { echo "  FAIL schema missing: ${SCHEMA}"; exit 1; }
[ -f "${DOC}" ]    || { echo "  FAIL doc missing: ${DOC}"; exit 1; }
command -v python3 >/dev/null || { echo "  FAIL python3 unavailable; NOT skipping"; exit 1; }

ERRF="$(mktemp)" || { echo "  FAIL cannot create a temp file for the deriver's stderr"; exit 1; }
REPORT="$(python3 - "${SCHEMA}" "${DOC}" 2>"${ERRF}" <<'PY'
import re, sys
schema_p, doc_p = sys.argv[1], sys.argv[2]
out=[]
def emit(s,m): out.append(f"{s}\t{m}")
def flush(): print("\n".join(out))

def read_text(path, label):
    """Read a file, turning ANY failure into a FAIL ROW rather than a traceback.

    A traceback goes to stderr, leaves stdout empty, and used to read as
    '0 passed, 0 failed'."""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception as exc:                                  # noqa: BLE001 - deliberate
        emit("FAIL", f"{label} could not be read ({type(exc).__name__}: "
                     f"{str(exc).splitlines()[0][:160]}) — every assertion that reads it "
                     f"would otherwise pass vacuously")
        return None

# ── SQL comment stripping that respects string literals ────────────────────────
def strip_sql_comments(s):
    """Remove -- and /* */ comments, but NEVER inside a '…' or "…" literal."""
    o, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":
            j = i + 1
            while j < n:
                if s[j] == "'":
                    if j + 1 < n and s[j + 1] == "'":   # SQL escaped quote ''
                        j += 2; continue
                    j += 1; break
                j += 1
            o.append(s[i:j]); i = j; continue
        if c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 1
            j = min(j + 1, n)
            o.append(s[i:j]); i = j; continue
        if c == "-" and i + 1 < n and s[i + 1] == "-":
            nl = s.find("\n", i)
            i = n if nl == -1 else nl                   # keep the newline itself
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "*":
            e = s.find("*/", i + 2)
            i = n if e == -1 else e + 2
            o.append(" "); continue
        o.append(c); i += 1
    return "".join(o)

def naive_strip(s):
    return re.sub(r"--[^\n]*", "", s)

ROW = re.compile(r"\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*(true|false)\s*\)",
                 re.IGNORECASE)
def parse_rows(code):
    return [(g, p, r, a.lower() == "true") for g, p, r, a in ROW.findall(code)]

def rows_from_sql(text):
    """THE ONE PATH from SQL text to rows.

    The self-test below and the real schema BOTH go through this function, on
    purpose: if a future edit swaps the stripper here for the naive one, the
    self-test fails too. A self-test that called strip_sql_comments() directly
    would keep passing while the real call site had been downgraded — a guard
    guarding a function nothing uses."""
    return parse_rows(strip_sql_comments(text))

# ── 1) SELF-TEST: prove the stripper before trusting it ────────────────────────
# Both real rows sit on ONE line, the second AFTER a '--' that lives inside the
# first one's quoted pattern. That is the inversion in miniature: the naive
# s/--.*// deletes the rest of the line and reports "no row names ARGO_MARKER".
FIXTURE = (
    "INSERT INTO route_access (gateway, url_pattern, required_role, active) VALUES\n"
    "  ('g', '/bff/x--y/**', 'ROLE_A', true), "
    "('g', '/bff/admin/ARGO_MARKER/**', 'ROLE_ADMIN', true);\n"
    "-- ('g', '/bff/commented/**', 'ROLE_X', true)\n"
)
fx_aware = rows_from_sql(FIXTURE)
fx_naive = parse_rows(naive_strip(FIXTURE))
aware_pats = [p for _g, p, _r, _a in fx_aware]
naive_pats = [p for _g, p, _r, _a in fx_naive]
if aware_pats == ["/bff/x--y/**", "/bff/admin/ARGO_MARKER/**"] \
   and "/bff/commented/**" not in aware_pats:
    if "/bff/admin/ARGO_MARKER/**" in naive_pats:
        emit("FAIL", "the stripper self-test fixture no longer distinguishes the two "
                     "strippers — it can no longer prove comment-token inversion is "
                     "closed; rewrite the fixture, do not delete the assertion")
    else:
        emit("PASS", "SQL comment stripper is string-literal aware: on a fixture whose "
                     "first pattern contains '--', it keeps BOTH real rows and drops the "
                     "commented one, where the naive s/--.*// loses "
                     f"{len(aware_pats) - len(naive_pats)} real row(s)")
else:
    emit("FAIL", f"SQL comment stripper FAILED its own fixture (kept {aware_pats}); a "
                 f"'--' inside a quoted url_pattern would swallow the rest of the "
                 f"statement and invert assertion 4")

src = read_text(schema_p, "the route-access schema")
if src is None:
    flush(); sys.exit(1)
rows = rows_from_sql(src)
naive_rows = parse_rows(naive_strip(src))
if not rows:
    emit("FAIL", "parsed ZERO route-access rows — the parser broke; every assertion "
                 "below would pass vacuously")
    flush(); sys.exit(1)
emit("INFO", f"parsed {len(rows)} route-access rows from the comment-stripped schema "
             f"(a naive s/--.*// sees {len(naive_rows)})")

def matches(pattern, path):
    """Ant-style: ** spans segments, * within a segment."""
    rx = re.escape(pattern).replace(r"/\*\*", "(?:/.*)?").replace(r"\*\*", ".*")
    rx = rx.replace(r"\*", "[^/]*")
    return re.fullmatch(rx, path) is not None

TARGET = "/bff/admin/argocd/applications"
GATEWAY = "hugmesh-fe-gateway"   # the gateway that serves /bff/admin/** to the browser

cands = [r for r in rows if r[0] == GATEWAY and matches(r[1], TARGET)]
if not cands:
    emit("FAIL", f"{TARGET} matches NO row on {GATEWAY} — the dashboard's calls would "
                 f"be denied by default; the doc's reasoning would be wrong")
else:
    # most-specific wins == longest pattern
    best = max(len(p) for _g, p, _r, _a in cands)
    winners = sorted({(p, r) for _g, p, r, _a in cands if len(p) == best})
    emit("PASS", f"{TARGET} resolves on {GATEWAY} ({len(cands)} matching rows)")
    if [w[0] for w in winners] != ["/bff/admin/**"]:
        emit("FAIL", f"{TARGET} no longer resolves to the '/bff/admin/**' floor — "
                     f"a narrower row now SHADOWS it: {winners}. If this is deliberate, "
                     f"a controller must exist; see docs/ADMIN-CONSOLES.md §2.")
    else:
        roles = sorted(r for _p, r in winners)
        emit("PASS", f"winning row is the '/bff/admin/**' floor {roles} — unshadowed")

argo = [(g, p, r) for g, p, r, _a in rows if "argocd" in p.lower()]
if argo:
    emit("FAIL", "a route-access row now names 'argocd': "
                 + "; ".join(f"{g} {p} {r}" for g, p, r in argo)
                 + " — the floor already covers the prefix and no controller serves it")
else:
    emit("PASS", "no seeded url_pattern names 'argocd' (deliberate absence intact)")

# ── 5) THE DOC: anchor INSIDE §2's subsection, not on one table cell ───────────
# The previous version of this test asserted two substrings against the WHOLE
# document. One of them ('no backend controller exists') occurs exactly once — in the
# one-line console-table row — so deleting the ENTIRE subsection (the evidence, the
# fail-open mechanism, the decision, the two-repo removal spec, the restore contract)
# left it printing PASS. The subsection is the deliverable while the cross-repo edit is
# unlanded, so it is what gets pinned: the subsection is EXTRACTED by its heading, and
# every claim is anchored inside it, each with its own PASS/FAIL line.
doc = read_text(doc_p, "docs/ADMIN-CONSOLES.md")
if doc is None:
    flush(); sys.exit(1)

def norm(t):
    return re.sub(r"\s+", " ", t)

ndoc = norm(doc)
row_bits = ["/admin/argocd", "no backend controller exists"]
missing = [b for b in row_bits if b not in ndoc]
if missing:
    emit("FAIL", f"the console table no longer lists /admin/argocd as dark "
                 f"(missing: {missing})")
else:
    emit("PASS", "the console table still lists /admin/argocd as dark "
                 "(\"no backend controller exists\")")

HEADING = "The ArgoCD dashboard is worse than dark"
start = doc.find(HEADING)
if start == -1:
    emit("FAIL", f"docs/ADMIN-CONSOLES.md no longer contains the §2 subsection "
                 f"'{HEADING}' — the whole ArgoCD decision, including the two-repo "
                 f"removal spec, has been deleted")
    flush(); sys.exit(1)
nxt = [i for i in (doc.find("\n## ", start), doc.find("\n### ", start)) if i != -1]
section = norm(doc[start:min(nxt) if nxt else len(doc)])
emit("INFO", f"§2 ArgoCD subsection extracted: {len(section)} chars")

CLAIMS = [
    ("the evidence that no controller exists",
     ["No controller serves any of those paths in any repo",
      "ArgoCdClient",
      "feat/argocd-admin-module"]),
    ("the fail-open mechanism (why a 404 reads as success)",
     ["only treats **503** as",
      "unavailable",
      "argocdPresent"]),
    ("the option-(b) decision: remove the page, do not add the row",
     ["Decision: remove the page rather than add the row",
      "no-op",
      "shadow the floor"]),
    ("the cross-repo removal spec — hugmesh-admin-ui, file and line",
     ["CROSS-REPO",
      "hugmesh-admin-ui",
      "src/app/admin.routes.ts",
      "src/app/argocd-dashboard.component.ts",
      "src/app/bff.service.ts",
      "e2e/features/admin/route-matrix.feature"]),
    ("the cross-repo removal spec — hugmesh-host-shell menu entry",
     ["hugmesh-host-shell",
      "menu.component.ts",
      "subnav-admin-argocd"]),
    ("the restore contract (503 is the only honest failure signal)",
     ["503 when ArgoCD is not reachable",
      "/bff/admin/argocd/applications/{name}/sync",
      "`devops`"]),
]
for label, needles in CLAIMS:
    gone = [n for n in needles if n not in section]
    if gone:
        emit("FAIL", f"§2 no longer records {label} — missing from the subsection: "
                     f"{gone}. This spec IS the deliverable until the cross-repo edit "
                     f"lands; do not delete it, land it.")
    else:
        emit("PASS", f"§2 still records {label}")

flush()
PY
)"
RC=$?

if [ "${RC}" -ne 0 ]; then
  bad "the deriver exited ${RC} — it crashed rather than reporting; NOT skipping"
fi
if [ -s "${ERRF}" ]; then
  bad "the deriver wrote to stderr — a traceback or warning was about to be discarded:"
  sed 's/^/         | /' "${ERRF}"
fi
rm -f "${ERRF}"

while IFS=$'\t' read -r status msg; do
  case "${status}" in
    PASS) ok  "${msg}"; ASSERTS=$((ASSERTS+1)) ;;
    FAIL) bad "${msg}"; ASSERTS=$((ASSERTS+1)) ;;
    INFO) echo "  ---- ${msg}" ;;
    *)    [ -n "${status}" ] && bad "unparsed output: ${status} ${msg}" ;;
  esac
done <<< "${REPORT}"

# NON-VACUITY GATE. Without this an exception in the deriver printed
# "== 0 passed, 0 failed ==" and exited 0.
if [ "${ASSERTS}" -eq 0 ]; then
  bad "the deriver emitted NO PASS/FAIL rows — it produced no verdict at all; NOT skipping"
fi

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
