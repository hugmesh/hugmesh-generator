#!/usr/bin/env bash
# test-mfa-required-rules.sh — pins the D6/D8 `mfa_required` route-access rules in
# specs/cluster/manifests/route-access/initdb/20-schema.sql.
#
# WHY THIS EXISTS. Until this seed carried an mfa_required write, NOTHING in the
# platform ever set the column true, so `APP_MFA_ENABLED=true` on a gateway was a
# pure NO-OP: GatewayRouteAccessService.decide() only demands the MFA_SATISFIED
# marker when the DECIDING row has mfa_required=true, and every row in the table
# was false. The rules are the data half of the feature; the flag is the other half
# and lands with the COMPANION change (see docs/MFA-ROLLOUT.md §0).
#
# Four ways this can silently go wrong, each with a check + a negative control:
#
#   (a) PARALLEL ROWS INSTEAD OF AN UPDATE. `mfa_required` is NOT part of
#       uq_route_access_row (gateway, url_pattern, role, COALESCE(casdoor_user,''),
#       COALESCE(domain,'')). A row that differs ONLY in mfa_required collides on
#       that 5-tuple and the INSERT's `ON CONFLICT DO NOTHING` SILENTLY DROPS it —
#       the seed looks right and enforces nothing. And even a separate 5-column
#       INSERT is wrong on an IN-PLACE re-apply (rows exist => skipped => the
#       column stays false). Only an UPDATE converges in both cases.
#
#   (b) LONGEST-PATTERN BYPASS. decide() picks the LONGEST matching url_pattern and
#       evaluates ONLY the rows at that length. Flipping just the two `/**` floors
#       leaves every longer sub-path row (/bff/admin/phone-fleet/**,
#       /bff/admin/workloads/**, /bff/superadmin/games-services/**,
#       /bff/superadmin/workloads/**) as the deciding rule with mfa_required=false
#       — an MFA bypass on the highest-value surfaces. So the write must be
#       PREFIX-based, which also covers sub-path rows added later.
#
#   (c) GATEWAY-SCOPED WRITE. `/bff/superadmin/**` is governed on BOTH
#       hugmesh-superadmin-gateway (tailnet) and hugmesh-be-gateway; `/bff/admin/**`
#       on hugmesh-fe-gateway with hugmesh-be-gateway carrying the longer
#       /bff/admin/workloads/**. Scoping the write to one gateway name leaves the
#       other gateway as an un-MFA'd second door to the same paths.
#
#   (d) A LATER STATEMENT THAT UNDOES THE WRITE. An `UPDATE … SET mfa_required =
#       false WHERE …` appended anywhere after the real UPDATE leaves the file's
#       NET effect un-gated. §5 of the runbook tells operators to exempt a surface
#       by editing THIS FILE, so that is the likely edit path. A check that reads
#       the text of one statement cannot see it. Therefore every behavioural
#       verdict here is read back from a REAL SQL ENGINE after replaying the file's
#       own statements in file order — see "NET-EFFECT SIMULATION" below.
#       ⚠ Replaying is only sound if the file's statements are all FOUND. The first
#       version of this matched DML with a pattern that demanded a BARE, unqualified
#       table name right after the verb, so `public.gateway_route_access`, a
#       `"double-quoted"` identifier and a CTE-led `WITH … UPDATE` were never
#       replayed and never counted — an appended
#       `DELETE FROM public.gateway_route_access WHERE url_pattern LIKE
#       '/bff/superadmin%'` wiped every superadmin route row and this gate printed
#       a clean pass. Fixed twice over: the matcher takes all those spellings, AND
#       every statement is classified so an unforeseen KIND fails loudly.
#
#   (e) A FRESH INITDB AND AN IN-PLACE UPGRADE DIVERGING. `mfa_required` is created
#       `NOT NULL` by the CREATE TABLE but was added NULLABLE by the ALTER, so an
#       upgraded cluster could hold NULL where a fresh one cannot — and the gateway
#       reads that column back as a primitive boolean. Comparing the two by column
#       NAME said they were "the same columns". The comparison is now over
#       (TYPE, NOT NULL, DEFAULT).
#
#   (f) THE RUNBOOK GOING QUIETLY FALSE. docs/MFA-ROLLOUT.md hands operators SQL to
#       run. One of those queries was described as returning the six deliberately-
#       excluded rows; it returns three, because the other three are excluded by
#       ROLE, not by path. Prose cannot be trusted to stay true, so the four blocks
#       the runbook asks an operator to run are marked and EXECUTED here.
#
# Plus the operator's BINDING enablement posture, which an earlier change got
# backwards and had to be corrected by hand:
#   * no specs/cluster/apps/*.yaml may turn gateway MFA on — the CLUSTER default
#     stays OFF, because the privileged floor is NOT exempt for SUPERADMIN, so
#     enabling before operators enrol a second factor locks them out of the
#     privileged plane;
#   * APP_MFA_ENFORCE_PRIVILEGED_FLOOR stays OFF everywhere INCLUDING the compose
#     dev stack — GatewayRouteAccessFilter checks that sub-flag WITHOUT consulting
#     app.mfa.enabled and fails CLOSED with 503 while route-access is still
#     priming, so it is a bad dev default.
# Those two used to be grep pipelines, and a grep CANNOT answer them: an ArgoCD
# Application can carry the value through helm.values (a YAML *string*, block or
# flow style, with comments anywhere), helm.valuesObject, helm.parameters
# (including indexed names like extraEnv[0].name), or a helm.valueFiles reference
# — and the flag has two spellings (`mfa.enabled` / `mfa.enforcePrivilegedFloor`
# chart values, or the raw APP_MFA_* container env through `extraEnv`, which is the
# ONLY mechanism the chart supports until the companion change lands). The posture
# half is now a real YAML parse of ALL of those, and an input it cannot read
# (valueFiles / fileParameters / a valueFrom-sourced APP_MFA_*) FAILS LOUDLY
# instead of quietly reading as a pass.
#
# That parse only sees specs/cluster/apps/*.yaml. Everything else — the shared chart
# TEMPLATE that renders env into all four gateway pods, ConfigMaps, plain
# Deployments, the compose stack — is covered by a second, SHAPE-AWARE sweep
# (envscan.py below). The half it replaced was a two-stage grep: find the variable
# NAME on a line, then test THAT SAME LINE for a true value. The dominant carrier is
# the Kubernetes env LIST, where the name and the value are on DIFFERENT lines, so
# the second grep never matched: the chart template could hardcode the privileged
# floor ON for every gateway and this gate stayed green — while its PASS text
# claimed the flag was "not defaulted true anywhere in specs/". Its own negative
# control only used the compose `KEY: value` map shape, so the control passed while
# the check was vacuous for the shape that mattered.
#
# ENGINE CAVEAT, stated up front: the net-effect simulation runs on **sqlite3**.
# Postgres is not installed in CI or on the dev box, so the rules have never been
# executed on the engine that will actually run them. sqlite is used only for the
# constructs this file needs (`LIKE` prefix matching, `IS DISTINCT FROM`,
# `true/false` literals, `ON CONFLICT (…expression index…) DO NOTHING`) — all four
# verified present. sqlite's `LIKE` is ASCII-case-INSENSITIVE while Postgres's is
# case-SENSITIVE; every pattern in this seed is lowercase, so the two agree here,
# but a mixed-case pattern added later could diverge. The Postgres-only de-dup
# DELETE (ctid + DELETE…USING) is skipped and REPORTED, and any OTHER statement the
# engine cannot run is a hard failure, never a silent skip.
#
# No cluster, no Postgres, no docker, no network. Checks are re-run against
# deliberately-corrupted staged copies, so a green run cannot be vacuous.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SQL="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
APPS="${REPO}/specs/cluster/apps"
CHART_VALUES="${REPO}/specs/cluster/charts/hugmesh-gateway/values.yaml"
CHART_TPL="${REPO}/specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml"
COMPOSE="${REPO}/tests/stack/compose.local.yaml"
DOC="${REPO}/docs/MFA-ROLLOUT.md"

for f in "${SQL}" "${COMPOSE}"; do
  [ -r "${f}" ] || { echo "  FAIL missing target: ${f}"; exit 1; }
done
[ -d "${APPS}" ] || { echo "  FAIL missing dir: ${APPS}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }
python3 -c 'import sqlite3' 2>/dev/null || { echo "  FAIL python3 sqlite3 not available"; exit 1; }
# The net-effect replay executes the seed's own `IS DISTINCT FROM` (sqlite >= 3.39).
# Probe it here so an old engine says so plainly instead of surfacing as a mystery
# SIM_ERROR halfway down the run.
if ! python3 -c 'import sqlite3; sqlite3.connect(":memory:").execute("SELECT 1 WHERE 1 IS DISTINCT FROM 2").fetchall()' 2>/dev/null; then
  echo "  FAIL sqlite3 $(python3 -c 'import sqlite3;print(sqlite3.sqlite_version)') lacks 'IS DISTINCT FROM' (needs >= 3.39); the net-effect replay cannot run this seed"
  exit 1
fi

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
W="$(mktemp -d)"; trap 'rm -rf "${W}" 2>/dev/null' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# The SQL checker. Reads ONE SQL file and prints machine-readable verdict lines.
# Shape/intent checks are textual; every BEHAVIOURAL verdict is read back from a
# real SQL engine after replaying the file's own statements in file order.
# ─────────────────────────────────────────────────────────────────────────────
cat > "${W}/check.py" <<'PY'
import os, re, sqlite3, sys

# The two prefixes the operator authorised. Blanket WITHIN them, and nothing else:
# see 20-schema.sql's "NOT IN SCOPE" list and docs/MFA-ROLLOUT.md §1.2a.
PREFIXES = ("/bff/admin", "/bff/superadmin")

# Admin-ish /bff/ surfaces DELIBERATELY outside that scope. Every entry is named
# and justified in the SQL header + the runbook. This list exists so the coverage
# assertion below can enumerate admin-ish surfaces INDEPENDENTLY of the UPDATE's
# own prefixes: a NEW admin-ish surface that is neither flipped nor listed here
# FAILS the gate instead of being defined away, and a listed row that no longer
# exists (or is now flipped) fails too, so the list cannot rot into a rubber stamp.
DOCUMENTED_EXCLUSIONS = {
    ("hugmesh-be-gateway", "/bff/games-services/instances/**", "ROLE_GAMES_SERVICES_ADMIN"),
    ("hugmesh-be-gateway", "/bff/image-builds/arch/**",        "ROLE_SUPERADMIN"),
    ("hugmesh-fe-gateway", "/bff/forum/admin/**",              "ROLE_ADMIN"),
    ("hugmesh-fe-gateway", "/bff/mod/**",                      "ROLE_ADMIN"),
    ("hugmesh-fe-gateway", "/bff/owncast/admin/**",            "ROLE_ADMIN"),
    ("hugmesh-fe-gateway", "/bff/wiki/admin/**",               "ROLE_ADMIN"),
}

sql = open(sys.argv[1], encoding="utf-8").read()
out = []
def emit(k, v): out.append("%s %s" % (k, v))
def done(code=0):
    print("\n".join(out)); sys.exit(code)

# ── statement tokenizer: '' strings, -- , /* */ and $$dollar$$ aware ───────────
def split_statements(text):
    res, buf, i, n = [], [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2; continue
                    j += 1; break
                j += 1
            buf.append(text[i:j]); i = j; continue
        if text[i:i + 2] == "--":
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if text[i:i + 2] == "/*":
            j = text.find("*/", i); i = n if j < 0 else j + 2; continue
        if c == "$":
            m = re.match(r"\$[A-Za-z_0-9]*\$", text[i:])
            if m:
                tag = m.group(0)
                j = text.find(tag, i + len(tag))
                j = n if j < 0 else j + len(tag)
                buf.append(text[i:j]); i = j; continue
        if c == ";":
            res.append("".join(buf)); buf = []; i += 1; continue
        buf.append(c); i += 1
    if "".join(buf).strip():
        res.append("".join(buf))
    return [s.strip() for s in res if s.strip()]

STMTS = split_statements(sql)
emit("STATEMENTS", len(STMTS))

# ── row SHAPE checks (textual — they are about the file's form, not its effect) ─
ROW_RE = re.compile(
    r"^\s*\('([a-z0-9-]+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)", re.M)
emit("ROWS", len(ROW_RE.findall(sql)))

# A row carrying FIVE values is the ON CONFLICT trap (a parallel row that gets
# dropped) or a column-list widening that breaks cluster_manifest_integrity.py's
# 4-field ROW_FULL_RE.
FIVE_RE = re.compile(
    r"^\s*\('([a-z0-9-]+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(?:true|false)\s*,", re.M)
emit("FIVE_VALUE_ROWS", len(FIVE_RE.findall(sql)))

# ── the trap itself: is mfa_required part of the uniqueness key? ───────────────
uq = None
for s in STMTS:
    if re.match(r"^\s*CREATE\s+UNIQUE\s+INDEX", s, re.I) and "uq_route_access_row" in s:
        uq = s
emit("UQ_FOUND", "yes" if uq else "no")
emit("UQ_HAS_MFA", "yes" if (uq and "mfa_required" in uq) else "no")

# ── which statements touch the table, in EVERY spelling Postgres accepts ───────
# The first version of this demanded a BARE, unqualified, unquoted table name
# IMMEDIATELY after the verb. `public.gateway_route_access`, `"gateway_route_access"`
# and a CTE-led `WITH … UPDATE gateway_route_access` all missed it, so such a
# statement never entered `dml`, was never counted and was never offered to
# replay() — a SILENT SKIP. An appended
#   `DELETE FROM public.gateway_route_access WHERE url_pattern LIKE '/bff/superadmin%';`
# wiped every superadmin row and the whole gate still printed 60 passed / 0 failed.
# Two independent fixes, because widening a pattern only ever covers the spellings
# somebody thought of:
#   1. the pattern below accepts ONLY / a schema qualifier / double-quoted
#      identifiers / a leading CTE / MERGE / TRUNCATE;
#   2. EVERY statement in the file is now classified, and anything this gate does
#      not understand is reported LOUDLY (UNCLASSIFIED) instead of ignored — so the
#      next spelling nobody thought of fails the build rather than passing it.
TBL = (r'(?:ONLY\s+)?'
       r'(?:(?:"[A-Za-z_][^"]*"|[A-Za-z_]\w*)\s*\.\s*)?'
       r'(?:"gateway_route_access"|gateway_route_access\b)')
VERB = r'(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|MERGE\s+INTO|TRUNCATE(?:\s+TABLE)?)'
DML_RE = re.compile(r'^\s*(?:WITH\s+.*?\)\s*)?' + VERB + r'\s+' + TBL, re.I | re.S)
DDL_RE = re.compile(
    r'^\s*(?:CREATE|ALTER|DROP)\s+(?:UNIQUE\s+)?'
    r'(?:TABLE|INDEX|VIEW|SEQUENCE|TYPE|SCHEMA|EXTENSION)\b', re.I)
BENIGN_RE = re.compile(
    r'^\s*(?:GRANT|REVOKE|COMMENT|DO|SET|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|ANALYZE|VACUUM|SELECT)\b',
    re.I)
# A DML statement hiding inside a DO $$…$$ / GRANT body. (`GRANT SELECT, INSERT,
# UPDATE, DELETE ON gateway_route_access` does NOT match: those verbs are followed
# by a comma or by `ON`, never by the table name.)
EMBEDDED_DML_RE = re.compile(VERB + r'\s+' + TBL, re.I)

# sqlite has no schemas and no ONLY; strip both so a legitimately schema-qualified
# statement REPLAYS (and its net effect is judged) instead of erroring out. The
# count is reported, so the rewriting is never invisible.
QUAL_RE = re.compile(
    r'(?:(?:"[A-Za-z_][^"]*"|[A-Za-z_]\w*)\s*\.\s*)?(?:"gateway_route_access"|\bgateway_route_access\b)')
def normalize(s):
    s = QUAL_RE.sub("gateway_route_access", s)
    return re.sub(r'\bONLY\s+gateway_route_access\b', "gateway_route_access", s, flags=re.I)

dml = [s for s in STMTS if DML_RE.match(s)]
emit("DML_STATEMENTS", len(dml))
emit("SIM_NORMALIZED", sum(1 for s in dml if normalize(s) != s))

unclassified = [" ".join(s.split())[:110] for s in STMTS
                if not DML_RE.match(s) and not DDL_RE.match(s)
                and not (BENIGN_RE.match(s) and not EMBEDDED_DML_RE.search(s))]
emit("UNCLASSIFIED", len(unclassified))
for u in unclassified:
    emit("UNCLASSIFIED_STMT", u)

def flat(s):
    return " ".join(s.split()).strip().rstrip(";").strip()

mfa_writes = [s for s in dml if re.search(r"\bmfa_required\b", s, re.I)]
emit("MFA_WRITE_STATEMENTS", len(mfa_writes))
mfa_ups = [s for s in mfa_writes
           if re.match(r'^\s*(?:WITH\s+.*?\)\s*)?UPDATE\b', s, re.I | re.S)
           and re.search(r"mfa_required\s*=\s*true", s, re.I)]
emit("MFA_UPDATES", len(mfa_ups))

# The ONE other write this file is allowed to contain: the in-place-upgrade NULL
# repair (see the ALTER block near the top of 20-schema.sql). Matched as a WHOLE
# statement, so it cannot smuggle a second predicate — a
# `… WHERE mfa_required IS NULL OR url_pattern LIKE '/bff/admin/%'` is NOT this
# shape and lands in MFA_WRITE_UNEXPECTED, which fails the gate.
BACKFILL_RE = re.compile(
    r'^UPDATE\s+' + TBL + r'\s+SET\s+mfa_required\s*=\s*false\s+WHERE\s+mfa_required\s+IS\s+NULL$',
    re.I)
backfills = [s for s in mfa_writes if BACKFILL_RE.match(flat(s))]
emit("MFA_NULL_BACKFILLS", len(backfills))
known = {id(s) for s in mfa_ups} | {id(s) for s in backfills}
unexpected = [s for s in mfa_writes if id(s) not in known]
emit("MFA_WRITE_UNEXPECTED", len(unexpected))
for s in unexpected:
    emit("MFA_WRITE_UNEXPECTED_STMT", flat(s)[:110])

pos = {id(s): i for i, s in enumerate(dml)}
mfa_idx = pos[id(mfa_ups[0])] if len(mfa_ups) == 1 else -1
if backfills and mfa_idx >= 0:
    emit("MFA_BACKFILL_BEFORE_FLIP",
         "yes" if max(pos[id(b)] for b in backfills) < mfa_idx else "no")
else:
    emit("MFA_BACKFILL_BEFORE_FLIP", "n/a")

if len(mfa_ups) == 1:
    up = mfa_ups[0]
    # GATEWAY-BLIND: any gateway predicate in the WHERE clause is defect (c).
    emit("UPDATE_GATEWAY_SCOPED",
         "yes" if re.search(r"\bgateway\s*(=|<>|!=|\bIN\b|\bLIKE\b)", up, re.I) else "no")
    # Idempotent re-apply (also proven behaviourally by SIM_MFA_CHANGES_2 below).
    emit("UPDATE_IDEMPOTENT",
         "yes" if re.search(r"mfa_required\s+IS\s+DISTINCT\s+FROM\s+true", up, re.I) else "no")
    # Deny rows excluded (a deny row denies at the longest match regardless of MFA).
    emit("UPDATE_ALLOW_ONLY",
         "yes" if re.search(r"\ballow\s*=\s*true", up, re.I) else "no")

# ─────────────────────────────────────────────────────────────────────────────
# NET-EFFECT SIMULATION (defect (d)). Replay the file's OWN statements, in file
# order, against a real SQL engine and read the RESULTING ROWS back. No verdict
# below is derived from the text of any single statement.
# ─────────────────────────────────────────────────────────────────────────────
emit("SIM_ENGINE", "sqlite3 " + sqlite3.sqlite_version)

# The CREATE TABLE is TRANSLATED from the file (not hardcoded) so a future DDL
# change — mfa_required's DEFAULT flipping, a new column — is reflected here.
ct = None
for s in STMTS:
    if re.match(r"^\s*CREATE\s+TABLE", s, re.I) and "gateway_route_access" in s:
        ct = s
if not ct:
    emit("SIM_ERRORS", 1)
    emit("SIM_ERROR", "no CREATE TABLE gateway_route_access found")
    done()

body = ct[ct.index("(") + 1:ct.rindex(")")]
cols, depth, cur = [], 0, []
for ch in body:
    if ch == "(": depth += 1
    if ch == ")": depth -= 1
    if ch == "," and depth == 0:
        cols.append("".join(cur)); cur = []; continue
    cur.append(ch)
if "".join(cur).strip():
    cols.append("".join(cur))
XLATE = [(r"\buuid\b", "TEXT"), (r"\btimestamptz\b", "TEXT"), (r"\btext\b", "TEXT"),
         (r"\bboolean\b", "BOOLEAN"),
         # sqlite has neither; the values are never asserted on, only the defaults
         # must exist so the seed's omitted columns behave like Postgres'.
         (r"DEFAULT\s+gen_random_uuid\(\)", "DEFAULT (lower(hex(randomblob(16))))"),
         (r"DEFAULT\s+now\(\)", "DEFAULT CURRENT_TIMESTAMP")]
CONSTRAINT_LEAD = re.compile(
    r'^\s*(CONSTRAINT|PRIMARY\s+KEY|UNIQUE|CHECK|FOREIGN\s+KEY|EXCLUDE)\b', re.I)

def coldef(text):
    """(name, (type, not_null, default)) for one column definition."""
    t = " ".join(text.split()).strip().rstrip(",").strip()
    head = t.split()[0]
    rest = t[len(head):].strip()
    not_null = bool(re.search(r"\bNOT\s+NULL\b", rest, re.I))
    d = re.search(
        r"\bDEFAULT\s+(.+?)(?=\s+NOT\s+NULL\b|\s+NULL\b|\s+PRIMARY\s+KEY\b|\s+UNIQUE\b"
        r"|\s+REFERENCES\b|\s+CHECK\b|\s+COLLATE\b|$)", rest, re.I)
    default = " ".join(d.group(1).split()).lower() if d else "-"
    typ = re.split(
        r"\s+(?:NOT\s+NULL|NULL|DEFAULT|PRIMARY|UNIQUE|REFERENCES|CHECK|GENERATED|COLLATE)\b",
        rest, flags=re.I)[0].strip().lower() or "-"
    return head.strip('"'), (typ, not_null, default)

sqlite_cols, colnames, create_shape = [], [], {}
for c in cols:
    c = " ".join(c.split())
    if not c or CONSTRAINT_LEAD.match(c):
        continue
    colnames.append(c.split()[0])
    n, shape = coldef(c)
    create_shape[n] = shape
    for pat, rep in XLATE:
        c = re.sub(pat, rep, c, flags=re.I)
    sqlite_cols.append(c)
emit("SIM_COLUMNS", ",".join(colnames))

# ── `ALTER TABLE … ADD COLUMN IF NOT EXISTS` — the in-place-upgrade idiom ──────
# Every column it adds must ALSO be in the CREATE TABLE, or a FRESH initdb (and
# this simulation) would be missing it while an upgraded cluster had it.
#
# Comparing NAMES ONLY was not enough, and that was a real divergence, not a
# hypothetical: the CREATE TABLE declared `mfa_required boolean NOT NULL DEFAULT
# false` while the ALTER added it NULLABLE. A fresh initdb and an upgraded cluster
# then genuinely differed — on the upgraded one a writer could set the column NULL,
# which the gateway reads back as a boolean — yet the gate said they "get the same
# columns". So the comparison is now over (TYPE, NOT NULL, DEFAULT), and the
# post-ALTER shape is accumulated across `ADD COLUMN` **and** any later
# `ALTER COLUMN … SET/DROP NOT NULL|DEFAULT|TYPE`, which is what lets an upgrade
# path legitimately repair a column an EARLIER, already-shipped revision of this
# file added with the wrong shape.
ADD_RE = re.compile(
    r'^\s*ALTER\s+TABLE\s+' + TBL + r'\s+ADD\s+COLUMN(?:\s+IF\s+NOT\s+EXISTS)?\s+(.+)$', re.I | re.S)
ALTCOL_RE = re.compile(
    r'^\s*ALTER\s+TABLE\s+' + TBL + r'\s+ALTER\s+(?:COLUMN\s+)?("?\w+"?)\s+(.+)$', re.I | re.S)
alter_shape, alter_order, alter_unknown = {}, [], []
for s in STMTS:
    m = ADD_RE.match(s)
    if m:
        n, shape = coldef(m.group(1))
        alter_shape[n] = list(shape)
        if n not in alter_order:
            alter_order.append(n)
        continue
    m = ALTCOL_RE.match(s)
    if not m:
        continue
    n = m.group(1).strip('"')
    act = " ".join(m.group(2).split())
    cur = alter_shape.get(n) or list(create_shape.get(n, ("-", False, "-")))
    if re.match(r'SET\s+NOT\s+NULL$', act, re.I):
        cur[1] = True
    elif re.match(r'DROP\s+NOT\s+NULL$', act, re.I):
        cur[1] = False
    elif re.match(r'SET\s+DEFAULT\s+', act, re.I):
        cur[2] = " ".join(re.sub(r'^SET\s+DEFAULT\s+', "", act, flags=re.I).split()).lower()
    elif re.match(r'DROP\s+DEFAULT$', act, re.I):
        cur[2] = "-"
    elif re.match(r'(?:SET\s+DATA\s+)?TYPE\s+', act, re.I):
        cur[0] = re.sub(r'^(?:SET\s+DATA\s+)?TYPE\s+', "", act, flags=re.I).strip().lower()
    else:
        alter_unknown.append("%s :: %s" % (n, act[:70]))
    alter_shape[n] = cur
    if n not in alter_order:
        alter_order.append(n)

emit("ALTER_ADD_COLUMNS", ",".join(alter_order) if alter_order else "-")
emit("ALTER_COLUMNS_IN_CREATE", "yes" if all(a in create_shape for a in alter_order) else "no")
emit("ALTER_UNKNOWN_ACTIONS", len(alter_unknown))
for u in alter_unknown:
    emit("ALTER_UNKNOWN_ACTION", u)
shape_mismatch = []
for n in alter_order:
    want, got = create_shape.get(n), tuple(alter_shape[n])
    if want is None:
        shape_mismatch.append("%s: added by ALTER but absent from the CREATE TABLE" % n)
    elif want != got:
        shape_mismatch.append(
            "%s: CREATE=(type=%s not_null=%s default=%s) but the upgrade path leaves "
            "(type=%s not_null=%s default=%s)" % (n, want[0], want[1], want[2], got[0], got[1], got[2]))
emit("ALTER_SHAPE_MISMATCH", len(shape_mismatch))
for m2 in shape_mismatch:
    emit("ALTER_SHAPE_MISMATCH_ROW", m2)

con = sqlite3.connect(":memory:")
con.isolation_level = None          # explicit txn control, so SAVEPOINT works below
errs, skips = [], []
try:
    con.execute("CREATE TABLE gateway_route_access (\n  %s\n)" % ",\n  ".join(sqlite_cols))
except Exception as e:                                          # noqa: BLE001
    errs.append("CREATE TABLE: %s" % e)
for s in STMTS:                                 # the file's OWN index statements
    if re.match(r"^\s*CREATE\s+(UNIQUE\s+)?INDEX", s, re.I) and "gateway_route_access" in s:
        try:
            con.execute(normalize(s))
        except Exception as e:                                  # noqa: BLE001
            errs.append("index: %s" % e)

def replay():
    """Run every gateway_route_access DML statement in FILE ORDER."""
    counts = []
    for s in dml:
        try:
            counts.append(con.execute(normalize(s)).rowcount)
        except Exception as e:                                  # noqa: BLE001
            # The ONLY statement allowed to be un-runnable is the Postgres-only
            # de-dup DELETE (ctid + DELETE…USING), which is a no-op on a table the
            # unique index keeps duplicate-free. Anything else is reported LOUDLY:
            # a statement the simulator silently ignored is exactly the blind spot
            # this rewrite exists to remove.
            if re.search(r"\bctid\b", s, re.I) and re.search(r"\bUSING\b", s, re.I):
                skips.append("postgres-only de-dup DELETE (ctid/USING): %s" % e)
            else:
                errs.append("%s :: %s" % (" ".join(s.split())[:90], e))
            counts.append(None)
    return counts

first = replay()
emit("SIM_SKIPPED", len(skips))
for s in skips:
    emit("SIM_SKIP", s)
emit("SIM_ERRORS", len(errs))
for e in errs:
    emit("SIM_ERROR", e)

sel = "SELECT gateway, url_pattern, role, allow, mfa_required FROM gateway_route_access"
final = con.execute(sel).fetchall()
emit("SIM_ROWS", len(final))
emit("SIM_MFA_CHANGES_1", first[mfa_idx] if mfa_idx >= 0 and first[mfa_idx] is not None else -1)

# Re-apply the WHOLE file a second time: a fresh initdb and an in-place re-apply
# must converge to the identical state, and the mfa UPDATE must be a true no-op.
before = sorted(final)
second = replay()
after = sorted(con.execute(sel).fetchall())
emit("SIM_REAPPLY_STABLE", "yes" if before == after else "no")
emit("SIM_MFA_CHANGES_2", second[mfa_idx] if mfa_idx >= 0 and second[mfa_idx] is not None else -1)

rows = [(g, p, r, bool(a), bool(m)) for (g, p, r, a, m) in final]
flipped = sorted((g, p, r) for (g, p, r, a, m) in rows if m)
emit("FLIPPED", len(flipped))
for g, p, r in flipped:
    emit("FLIP", "%s %s %s" % (g, p, r))

def under(pat):
    return any(pat == pre or pat.startswith(pre + "/") for pre in PREFIXES)

over = [t for t in flipped if not under(t[1])]
emit("OVERREACH", len(over))
for g, p, r in over:
    emit("OVERREACH_ROW", "%s %s %s" % (g, p, r))

deny = sorted((g, p, r) for (g, p, r, a, m) in rows if m and not a)
emit("DENY_FLIPPED", len(deny))
for g, p, r in deny:
    emit("DENY_FLIPPED_ROW", "%s %s %s" % (g, p, r))

# (b) every allow row under either authorised prefix must END UP true, on EVERY
# gateway that governs it — otherwise longest-pattern-wins can decide on a false
# row. Read from the final state, so an appended un-flip is caught.
missed = sorted((g, p, r) for (g, p, r, a, m) in rows if a and under(p) and not m)
emit("PREFIX_UNFLIPPED", len(missed))
for g, p, r in missed:
    emit("PREFIX_UNFLIPPED_ROW", "%s %s %s" % (g, p, r))

# ── INDEPENDENT admin-ish enumeration — deliberately does NOT reuse PREFIXES ───
def segs(p):
    return [s for s in p.split("/") if s and s != "**"]
def adminish(p, r):
    if not p.startswith("/bff/"):
        return False
    if "admin" in segs(p) or "superadmin" in segs(p):
        return True
    return r == "ROLE_SUPERADMIN" or r.endswith("_ADMIN") or "SUPERADMIN" in r

adm = sorted((g, p, r, m) for (g, p, r, a, m) in rows if a and adminish(p, r))
emit("ADMINISH", len(adm))
uncovered = [(g, p, r) for (g, p, r, m) in adm
             if not m and (g, p, r) not in DOCUMENTED_EXCLUSIONS]
emit("ADMINISH_UNCOVERED", len(uncovered))
for g, p, r in uncovered:
    emit("ADMINISH_UNCOVERED_ROW", "%s %s %s" % (g, p, r))
stale = sorted(DOCUMENTED_EXCLUSIONS - {(g, p, r) for (g, p, r, m) in adm if not m})
emit("STALE_EXCLUSIONS", len(stale))
for g, p, r in stale:
    emit("STALE_EXCLUSION", "%s %s %s" % (g, p, r))
emit("EXCLUSIONS_DOCUMENTED", len(DOCUMENTED_EXCLUSIONS))

for pre in PREFIXES:
    gws = sorted({g for (g, p, r) in flipped if p == pre or p.startswith(pre + "/")})
    emit("PREFIX_GATEWAYS", "%s %s" % (pre, ",".join(gws) if gws else "-"))

# ─────────────────────────────────────────────────────────────────────────────
# docs/MFA-ROLLOUT.md — the runbook's SQL, EXECUTED against the replayed database
# rather than eyeballed. A previous review found the runbook telling the operator
# that `LIKE '/bff/%admin%'` "also returns the six §1.2a rows that are false by
# design"; run for real it returns THREE of the six, because the other three have
# no "admin" substring in url_pattern at all. An operator using it to "see the
# scope boundary" would conclude three privileged surfaces were inside the gate.
# Prose cannot be trusted to stay true, so each block the runbook asks an operator
# to run now carries a `<!-- gate:doc-sql name=… expect=… -->` marker and IS RUN.
# ─────────────────────────────────────────────────────────────────────────────
raw_flip = ""
for m in re.finditer(r'^UPDATE\s+gateway_route_access\b[\s\S]*?;', sql, re.M):
    if re.search(r"mfa_required\s*=\s*true", m.group(0), re.I):
        raw_flip = m.group(0)

def dedent(block):
    ls = block.split("\n")
    pad = min((len(l) - len(l.lstrip()) for l in ls if l.strip()), default=0)
    return "\n".join(l[pad:] if len(l) >= pad else l for l in ls)

DOC_RE = re.compile(
    r'<!--\s*gate:doc-sql\s+name=(\S+)\s+expect=(\S+)\s*-->\s*\n[ \t]*```sql\n(.*?)\n[ \t]*```',
    re.S)
doc_names, doc_bad = [], []
if len(sys.argv) > 2 and os.path.isfile(sys.argv[2]):
    doctext = open(sys.argv[2], encoding="utf-8").read()
    want_flipped = {(g, p, r) for (g, p, r) in flipped}
    want_adminish = {(g, p, r) for (g, p, r, m) in adm}
    for name, expect, block in DOC_RE.findall(doctext):
        doc_names.append(name)
        body = dedent(block).strip()
        try:
            if expect == "identical-to-seed":
                if body.strip() != raw_flip.strip():
                    doc_bad.append("%s: the quoted SQL has drifted from the seed's own "
                                   "UPDATE (doc %d chars vs seed %d)"
                                   % (name, len(body.strip()), len(raw_flip.strip())))
            elif expect == "none-flipped":
                con.execute("SAVEPOINT docsql")
                try:
                    for st in split_statements(body):
                        con.execute(normalize(st))
                    left = con.execute(
                        "SELECT count(*) FROM gateway_route_access WHERE mfa_required").fetchone()[0]
                finally:
                    con.execute("ROLLBACK TO docsql")
                    con.execute("RELEASE docsql")
                if left:
                    doc_bad.append("%s: after the documented rollback %d row(s) are STILL "
                                   "mfa_required=true" % (name, left))
            elif expect in ("flipped", "adminish"):
                got = {(r[0], r[1], r[2]) for r in
                       con.execute(normalize(body.rstrip().rstrip(";"))).fetchall()}
                want = want_flipped if expect == "flipped" else want_adminish
                if got != want:
                    doc_bad.append(
                        "%s: returns %d row(s) but the prose promises the %d '%s' row(s); "
                        "missing=%s unexpected=%s"
                        % (name, len(got), len(want), expect,
                           sorted(want - got)[:4], sorted(got - want)[:4]))
            else:
                doc_bad.append("%s: unknown expect=%s" % (name, expect))
        except Exception as e:                                  # noqa: BLE001
            doc_bad.append("%s: %s" % (name, e))
emit("DOC_SQL_BLOCKS", len(doc_names))
emit("DOC_SQL_NAMES", ",".join(doc_names) if doc_names else "-")
emit("DOC_SQL_BAD", len(doc_bad))
for b in doc_bad:
    emit("DOC_SQL_BAD_ROW", b)

done()
PY

# ─────────────────────────────────────────────────────────────────────────────
# The POSTURE checker. Parses every gateway ArgoCD Application in a directory and
# reports whether ANY of them turns gateway MFA on, through ANY of the five inputs
# ArgoCD supports and either of the two spellings. Un-auditable inputs are
# reported, never ignored.
#
# NOTE de-duplication follow-up: the companion branch `feat/gateway-mfa-env` grows
# an equivalent parser at tests/stack/gateway_mfa_env.py. It is deliberately NOT
# imported here — it is not on this branch, so an import would break this branch's
# CI. Once BOTH have landed, collapse the two into one shared helper.
# ─────────────────────────────────────────────────────────────────────────────
cat > "${W}/posture.py" <<'PY'
import glob, os, re, sys, yaml

ENV_ENABLED = "APP_MFA_ENABLED"
ENV_FLOOR = "APP_MFA_ENFORCE_PRIVILEGED_FLOOR"
CHART_REL = "charts/hugmesh-gateway"

out = []
def emit(k, v): out.append("%s %s" % (k, v))

def truthy(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, int):
        return v == 1
    if isinstance(v, str):
        return v.strip().strip("\"'").lower() in ("true", "yes", "on", "1")
    return False

def norm(k):
    return str(k).lower().replace("-", "").replace("_", "")

hits = []          # (kind, where); kind in enabled | floor | unauditable

def walk(node, path):
    """Recursive, so a value nested anywhere in the tree is still seen."""
    if isinstance(node, dict):
        for k, v in node.items():
            if norm(k) == "mfa" and isinstance(v, dict):
                for k2, v2 in v.items():
                    if norm(k2) == "enabled" and truthy(v2):
                        hits.append(("enabled", "%s.mfa.%s=%r" % (path, k2, v2)))
                    if norm(k2) == "enforceprivilegedfloor" and truthy(v2):
                        hits.append(("floor", "%s.mfa.%s=%r" % (path, k2, v2)))
        nm = node.get("name")
        if isinstance(nm, str) and nm in (ENV_ENABLED, ENV_FLOOR):
            kind = "enabled" if nm == ENV_ENABLED else "floor"
            if "value" in node:
                if truthy(node.get("value")):
                    hits.append((kind, "%s[env %s=%r]" % (path, nm, node.get("value"))))
            else:
                hits.append(("unauditable", "%s[env %s sourced from %s]" % (
                    path, nm, ",".join(sorted(set(node.keys()) - {"name"})) or "?")))
        for k, v in node.items():
            walk(v, "%s.%s" % (path, k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, "%s[%d]" % (path, i))

def params(plist, where):
    """helm.parameters is a FLAT name/value list; names may be dotted or indexed."""
    by = {}
    for p in plist or []:
        if isinstance(p, dict) and "name" in p:
            by[str(p["name"]).replace("\\.", ".")] = p.get("value")
    for n, v in by.items():
        low = norm(n)
        if re.search(r"(^|\.)mfa\.enabled$", low) and truthy(v):
            hits.append(("enabled", "%s[parameter %s=%r]" % (where, n, v)))
        if re.search(r"(^|\.)mfa\.enforceprivilegedfloor$", low) and truthy(v):
            hits.append(("floor", "%s[parameter %s=%r]" % (where, n, v)))
        if isinstance(v, str) and v in (ENV_ENABLED, ENV_FLOOR):
            # e.g. extraEnv[0].name=APP_MFA_ENABLED — pair it with its .value
            kind = "enabled" if v == ENV_ENABLED else "floor"
            sib = n[:-4] + "value" if n.endswith("name") else None
            if sib and sib in by:
                if truthy(by[sib]):
                    hits.append((kind, "%s[parameter %s=%r via %s]" % (where, sib, by[sib], n)))
            else:
                hits.append(("unauditable",
                             "%s[parameter %s sets env name %s, value not in this list]"
                             % (where, n, v)))

gw_apps = 0
parse_errors = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.yaml"))):
    rel = os.path.basename(path)
    try:
        docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
    except Exception as e:                                      # noqa: BLE001
        parse_errors.append("%s :: %s" % (rel, e))
        continue
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "Application":
            continue
        spec = doc.get("spec") or {}
        srcs = []
        if isinstance(spec.get("source"), dict):
            srcs.append(("source", spec["source"]))
        for i, s in enumerate(spec.get("sources") or []):
            if isinstance(s, dict):
                srcs.append(("sources[%d]" % i, s))
        for label, src in srcs:
            if not str(src.get("path") or "").rstrip("/").endswith(CHART_REL):
                continue
            gw_apps += 1
            helm = src.get("helm")
            if not isinstance(helm, dict):
                continue
            where = "%s:%s.helm" % (rel, label)
            v = helm.get("values")
            if isinstance(v, str):
                try:
                    walk(yaml.safe_load(v) or {}, where + ".values")
                except Exception as e:                          # noqa: BLE001
                    parse_errors.append("%s.values :: %s" % (where, e))
            elif v is not None:
                walk(v, where + ".values")
            if helm.get("valuesObject") is not None:
                walk(helm["valuesObject"], where + ".valuesObject")
            params(helm.get("parameters"), where)
            # An input this gate cannot read must never read as a pass.
            for key in ("valueFiles", "fileParameters"):
                for item in helm.get(key) or []:
                    hits.append(("unauditable", "%s.%s -> %s" % (where, key, item)))

emit("GATEWAY_APPS", gw_apps)
emit("PARSE_ERRORS", len(parse_errors))
for e in parse_errors:
    emit("PARSE_ERROR", e)
for kind, key in (("enabled", "MFA_ENABLED_ON"), ("floor", "FLOOR_ON"),
                  ("unauditable", "UNAUDITABLE")):
    seen = [w for (k, w) in hits if k == kind]
    emit(key, len(seen))
    at = "UNAUDITABLE_AT" if kind == "unauditable" else key.replace("_ON", "_AT")
    for w in seen:
        emit(at, w)

# The chart default is the OTHER lever the runbook names. ABSENT on this branch —
# it arrives with the companion env-wiring change — so this is reported, never
# assumed, and starts biting the moment the block appears.
if len(sys.argv) > 2 and os.path.isfile(sys.argv[2]):
    try:
        cv = yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or {}
    except Exception as e:                                      # noqa: BLE001
        emit("CHART_MFA_BLOCK", "unparseable")
        emit("CHART_PARSE_ERROR", str(e))
    else:
        blk = cv.get("mfa")
        if not isinstance(blk, dict):
            emit("CHART_MFA_BLOCK", "absent")
        else:
            emit("CHART_MFA_BLOCK", "present")
            emit("CHART_MFA_ENABLED", "true" if truthy(blk.get("enabled")) else "not-true")
            floor = None
            for k, v in blk.items():
                if norm(k) == "enforceprivilegedfloor":
                    floor = v
            emit("CHART_FLOOR", "true" if truthy(floor) else "not-true")
else:
    emit("CHART_MFA_BLOCK", "no-chart-values-file")

print("\n".join(out))
PY

# ─────────────────────────────────────────────────────────────────────────────
# The ENV-SHAPE scanner. The posture parser above reads ArgoCD Applications; this
# one reads EVERYTHING ELSE — chart templates, ConfigMaps, plain Deployments, the
# compose stack — looking for a HARDCODED APP_MFA_ENABLED / _ENFORCE_PRIVILEGED_
# FLOOR value.
#
# WHY A SHAPE-AWARE SCANNER AND NOT A YAML PARSE. The file that renders env into
# ALL FOUR gateway pods is specs/cluster/charts/hugmesh-gateway/templates/
# deployment.yaml — a Helm template, which is NOT valid YAML (`{{ .Values.x |
# quote }}` in a value position, `{{- if }}` control lines), so yaml.safe_load
# cannot read it. But the shapes a container env can arrive in are lexically
# regular, so this walks lines with indent/list-item awareness instead.
#
# WHAT IT REPLACES. A two-stage grep: find the variable NAME on a line, then test
# THAT SAME LINE for a true value. In the dominant Kubernetes shape
#     - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR
#       value: "true"
# the name and the value are on DIFFERENT lines, so the second grep never matched.
# The check was vacuous for that shape while its PASS text claimed the flag was
# "not defaulted true anywhere in specs/ or the compose stack", and its own
# negative control only exercised the compose `KEY: value` map shape, so the
# control passed too. A false PASS message is worse than no check.
#
# Shapes understood (each has a negative control below):
#   A  k8s env list       - name: X / value: "true"   (either key order)
#   B  mapping key        X: "true"      (compose environment, ConfigMap data, …)
#   C  shell assignment   [export ]X=true
#   D  flow mapping       - {name: X, value: "true"}
# Values it CANNOT decide are reported, never treated as a pass:
#   * `valueFrom:` (Secret/ConfigMap ref)
#   * a literal true sitting inside an open Helm `{{ if/with/range }}` block
# A `{{ … }}` expression with no literal true default is DEFERRED (it resolves to a
# chart value, and the chart values.yaml arm above audits those); deferred sites are
# named in the PASS text so the message stays true.
# ─────────────────────────────────────────────────────────────────────────────
cat > "${W}/envscan.py" <<'PY'
import os, re, sys

TARGETS = {"APP_MFA_ENABLED": "enabled", "APP_MFA_ENFORCE_PRIVILEGED_FLOOR": "floor"}
TRUE = ("true", "yes", "on", "1")

out, hits, deferred, candidates, unaudited_defer = [], [], [], [], []
scanned = 0
def emit(k, v): out.append("%s %s" % (k, v))
def truthy(v): return str(v).strip().strip('"').strip("'").strip().lower() in TRUE

KEY_RE = re.compile(
    r'^(?P<ind>[ \t]*)(?P<dash>(?:-[ \t]+)*)'
    r'(?P<key>"[^"]*"|\'[^\']*\'|[A-Za-z_][A-Za-z0-9_.\-]*)[ \t]*:(?P<val>[ \t].*|)$')
FLOW_RE = re.compile(r'\{[^{}]*\bname[ \t]*:[ \t]*["\']?(' + "|".join(TARGETS) + r')["\']?[^{}]*\}')
ASSIGN_RE = re.compile(r'(?:^|[\s;])(?:export[ \t]+)?(' + "|".join(TARGETS) + r')=(\S*)')
HELM_OPEN = re.compile(r'\{\{-?[ \t]*(?:if|with|range|define|block)\b')
HELM_END = re.compile(r'\{\{-?[ \t]*end[ \t]*-?\}\}')
HELM_TRUE_DEFAULT = re.compile(r'\bdefault[ \t]+"?(?:true|yes|on|1)"?', re.I)
SHELL_DEFAULT = re.compile(r'^"?\$\{[A-Za-z_][A-Za-z0-9_]*:-(?P<d>[^}]*)\}"?$')
# The chart-values arm reads cv.get("mfa") ONLY, i.e. exactly these two keys. A deferred
# site pointing anywhere else is covered by nothing, and must not be reported as audited.
VALUES_REF = re.compile(r'\.Values\.([A-Za-z0-9_.]+)')
def norm_values_path(p):
    return ".".join(seg.lower() for seg in p.split(".") if seg)
AUDITED_VALUES_PATHS = {"mfa.enabled", "mfa.enforceprivilegedfloor"}

def strip_comment(line, sql):
    res, q, i = [], None, 0
    while i < len(line):
        c = line[i]
        if q:
            res.append(c)
            if c == q:
                q = None
        elif c in "\"'":
            q = c; res.append(c)
        elif c == "#" and (not res or res[-1] in " \t"):
            break
        elif sql and line[i:i + 2] == "--" and (not res or res[-1] in " \t"):
            break
        else:
            res.append(c)
        i += 1
    return "".join(res)

def record(site, raw, kind, depth):
    v = str(raw).strip()
    if not v:
        return
    if "{{" in v:
        if HELM_TRUE_DEFAULT.search(v):
            hits.append((kind, "%s = %s  (Helm expression with a literal TRUE default)" % (site, v)))
        else:
            # A deferred site is only GENUINELY covered if it points at a chart key the
            # chart-values arm actually reads, and that arm reads the TOP-LEVEL `mfa:`
            # block ONLY (cv.get("mfa") -> .enabled / .enforcePrivilegedFloor). Any other
            # .Values path is audited by NOTHING, while the deferred PASS message says it
            # was — so `{{ .Values.security.mfaFloor | quote }}` plus `security: {mfaFloor:
            # true}` in the chart brought every gateway pod up with the fail-closed
            # privileged floor ON and left this gate green. Split that case out.
            ref = VALUES_REF.search(v)
            if ref and norm_values_path(ref.group(1)) not in AUDITED_VALUES_PATHS:
                unaudited_defer.append("%s = %s  (chart key '%s' is read by NO arm of this gate)"
                                       % (site, v, ref.group(1)))
            else:
                deferred.append("%s = %s" % (site, v))
        return
    m = SHELL_DEFAULT.match(v)
    if m:
        if truthy(m.group("d")):
            hits.append((kind, "%s = %s  (shell default is true)" % (site, v)))
        return
    if v.startswith("$"):
        deferred.append("%s = %s  (resolved outside this repo)" % (site, v))
        return
    if not truthy(v):
        return
    if depth > 0:
        hits.append(("unauditable",
                     "%s = %s  but it sits inside an open Helm {{ if/with/range }} block, so "
                     "this scan cannot tell whether it is reached — drive it from a chart "
                     "value instead of a conditional literal" % (site, v)))
    else:
        hits.append((kind, "%s = %s" % (site, v)))

def scan(rel, text):
    sql = rel.endswith(".sql")
    lines = text.split("\n")
    recs, depth = [], 0
    for i, raw in enumerate(lines):
        ln = strip_comment(raw, sql)
        here = depth
        depth += len(HELM_OPEN.findall(ln)) - len(HELM_END.findall(ln))
        for fm in FLOW_RE.finditer(ln):                                   # shape D
            blk, var = fm.group(0), fm.group(1)
            vm = re.search(r'\bvalue[ \t]*:[ \t]*("[^"]*"|\'[^\']*\'|[^,}\s]+)', blk)
            if vm:
                record("%s:%d [flow env %s]" % (rel, i + 1, var), vm.group(1), TARGETS[var], here)
            elif "valueFrom" in blk:
                hits.append(("unauditable",
                             "%s:%d [flow env %s sourced from valueFrom]" % (rel, i + 1, var)))
        for am in ASSIGN_RE.finditer(ln):                                 # shape C
            record("%s:%d [assignment %s]" % (rel, i + 1, am.group(1)),
                   am.group(2), TARGETS[am.group(1)], here)
        m = KEY_RE.match(ln)
        if not m:
            continue
        recs.append(dict(i=i, ki=len(m.group("ind")) + len(m.group("dash")),
                         item=bool(m.group("dash")), depth=here,
                         key=m.group("key").strip('"\''), val=m.group("val").strip()))
    for n, r in enumerate(recs):
        if r["key"] in TARGETS:                                           # shape B
            record("%s:%d [mapping %s]" % (rel, r["i"] + 1, r["key"]),
                   r["val"], TARGETS[r["key"]], r["depth"])
            continue
        if r["key"] != "name":                                            # shape A
            continue
        var = r["val"].strip().strip('"').strip("'")
        if var not in TARGETS:
            continue
        sibs = [r]
        for o in recs[n + 1:]:                       # forward to the end of this item
            if o["ki"] < r["ki"]:
                break
            if o["ki"] == r["ki"]:
                if o["item"]:
                    break
                sibs.append(o)
        if not r["item"]:                            # backward to this item's own start
            for o in reversed(recs[:n]):
                if o["ki"] < r["ki"]:
                    break
                if o["ki"] == r["ki"]:
                    sibs.append(o)
                    if o["item"]:
                        break
        val = next((s for s in sibs if s["key"] == "value"), None)
        vfrom = next((s for s in sibs if s["key"] == "valueFrom"), None)
        if val is not None:
            record("%s:%d [env-list %s]" % (rel, r["i"] + 1, var), val["val"], TARGETS[var],
                   val["depth"])
        elif vfrom is not None:
            hits.append(("unauditable",
                         "%s:%d [env-list %s sourced from valueFrom]" % (rel, r["i"] + 1, var)))

base = sys.argv[1]
for target in sys.argv[2:]:
    paths = []
    if os.path.isdir(target):
        for dirpath, dirnames, filenames in os.walk(target):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            paths += [os.path.join(dirpath, f) for f in sorted(filenames)]
    elif os.path.isfile(target):
        paths = [target]
    for p in sorted(paths):
        scanned += 1
        try:
            if os.path.getsize(p) > 4000000:
                continue
            text = open(p, encoding="utf-8").read()
        except Exception:                                           # noqa: BLE001
            continue                       # binary / unreadable: cannot carry YAML env
        if "APP_MFA_" not in text:
            continue
        rel = os.path.relpath(p, base)
        candidates.append(rel)
        scan(rel, text)

emit("SCANNED_FILES", scanned)
emit("CANDIDATE_FILES", len(candidates))
for c in candidates:
    emit("CANDIDATE", c)
for kind, key in (("enabled", "ENABLED_TRUE"), ("floor", "FLOOR_TRUE"),
                  ("unauditable", "UNDECIDABLE")):
    seen = [w for (k, w) in hits if k == kind]
    emit(key, len(seen))
    for w in seen:
        emit(key.split("_")[0] + "_AT", w)
emit("UNAUDITED_DEFER", len(unaudited_defer))
for u in unaudited_defer:
    emit("UNAUDITED_DEFER_AT", u)
emit("DEFERRED", len(deferred))
for d in deferred:
    emit("DEFERRED_AT", d)
print("\n".join(out))
PY

# ─────────────────────────────────────────────────────────────────────────────
# 1) the real tree — shape, intent, and NET EFFECT
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── 1) mfa_required rules in the canonical seed ──"
python3 "${W}/check.py" "${SQL}" "${DOC}" > "${W}/real.out" 2>"${W}/real.err" \
  || { echo "  FAIL checker crashed:"; cat "${W}/real.err"; exit 1; }
g() { sed -n "s/^$1 //p" "${W}/real.out" | head -1; }

[ "$(g ROWS)" -gt 100 ] \
  && ok "parsed $(g ROWS) canonical seed rows" \
  || bad "parsed only $(g ROWS) seed rows — the row regex no longer matches the file"

HAVE_UPDATE=0
if [ "$(g MFA_UPDATES)" = "1" ]; then
  HAVE_UPDATE=1
  ok "exactly one 'UPDATE gateway_route_access SET mfa_required = true' statement"
else
  bad "expected exactly 1 mfa_required UPDATE, found $(g MFA_UPDATES) — with 0 the seed writes mfa_required nowhere, so nothing in the platform ever sets mfa_required=true and APP_MFA_ENABLED=true is a NO-OP (every check below about that statement is SKIPPED)"
fi

[ "$(g MFA_WRITE_UNEXPECTED)" = "0" ] \
  && ok "the only statements that write mfa_required are the single flip UPDATE plus $(g MFA_NULL_BACKFILLS) recognised in-place-upgrade NULL repair(s) (whole-statement shape 'SET mfa_required = false WHERE mfa_required IS NULL'); anything else — an appended un-flip in ANY spelling, schema-qualified, quoted or CTE-led — lands here" \
  || bad "$(g MFA_WRITE_UNEXPECTED) statement(s) write mfa_required and are neither the flip nor the exact NULL-repair shape: $(sed -n 's/^MFA_WRITE_UNEXPECTED_STMT //p' "${W}/real.out" | tr '\n' ';') — the file's NET effect is what matters (see the SIM_* checks) and an extra write is almost certainly an un-flip"

[ "$(g MFA_NULL_BACKFILLS)" -le 1 ] \
  && case "$(g MFA_BACKFILL_BEFORE_FLIP)" in yes|n/a) true ;; *) false ;; esac \
  && ok "the NULL repair (if present) runs BEFORE the flip UPDATE, so it can never un-flip a row the flip has already set (backfills=$(g MFA_NULL_BACKFILLS), before_flip=$(g MFA_BACKFILL_BEFORE_FLIP))" \
  || bad "the mfa_required NULL repair is mis-placed or duplicated (backfills=$(g MFA_NULL_BACKFILLS), before_flip=$(g MFA_BACKFILL_BEFORE_FLIP)) — it must appear exactly once, before the flip"

[ "$(g UNCLASSIFIED)" = "0" ] \
  && ok "every statement in the file is classified (DML on gateway_route_access / DDL / GRANT-DO-COMMENT) — none was silently skipped. That was a real hole: DML matching used to demand a BARE table name, so a 'public.'-qualified, double-quoted or CTE-led UPDATE/DELETE was neither replayed nor counted and the gate stayed green while the file's net effect was broken" \
  || bad "$(g UNCLASSIFIED) statement(s) this gate does not understand: $(sed -n 's/^UNCLASSIFIED_STMT //p' "${W}/real.out" | tr '\n' ';') — a statement nobody classified is a statement nobody replayed; teach the checker, do not ignore it"

[ "$(g UQ_FOUND)" = "yes" ] && [ "$(g UQ_HAS_MFA)" = "no" ] \
  && ok "mfa_required is NOT part of uq_route_access_row — so the value must be UPDATEd, never added as a parallel row" \
  || bad "uq_route_access_row unexpected (found=$(g UQ_FOUND) has_mfa=$(g UQ_HAS_MFA)); re-derive whether a parallel row is now possible"

[ "$(g FIVE_VALUE_ROWS)" = "0" ] \
  && ok "no seed row carries a 5th value — no parallel row for ON CONFLICT DO NOTHING to silently drop, and cluster_manifest_integrity.py's 4-field ROW_FULL_RE still parses every row" \
  || bad "$(g FIVE_VALUE_ROWS) seed row(s) carry a 5th value: a parallel mfa row is dropped by ON CONFLICT DO NOTHING (and stays false on an in-place re-apply), and the integrity gate's ROW_FULL_RE stops matching"

if [ "${HAVE_UPDATE}" = "1" ]; then
[ "$(g UPDATE_GATEWAY_SCOPED)" = "no" ] \
  && ok "the UPDATE is GATEWAY-BLIND — it cannot leave one gateway as an un-MFA'd second door to the same path" \
  || bad "the UPDATE's WHERE clause constrains 'gateway': /bff/superadmin/** is governed on BOTH hugmesh-superadmin-gateway and hugmesh-be-gateway, so a gateway-scoped write is an MFA bypass"

[ "$(g UPDATE_ALLOW_ONLY)" = "yes" ] \
  && ok "the UPDATE touches allow=true rows only" \
  || bad "the UPDATE does not restrict to allow=true rows"
fi

# ── the net-effect simulation ──────────────────────────────────────────────────
echo ""
echo "── 1b) NET EFFECT, replayed on a real SQL engine ($(g SIM_ENGINE)) ──"
echo "     (Postgres is NOT installed here, so the rules have never run on the"
echo "      engine that will execute them — see the header's ENGINE CAVEAT.)"

[ "$(g SIM_ERRORS)" = "0" ] \
  && ok "every gateway_route_access statement in the file replayed successfully ($(g DML_STATEMENTS) DML statements, $(g SIM_NORMALIZED) of them rewritten for sqlite by stripping a schema qualifier / ONLY, $(g SIM_SKIPPED) postgres-only skip: $(sed -n 's/^SIM_SKIP //p' "${W}/real.out" | tr '\n' ';'))" \
  || bad "$(g SIM_ERRORS) statement(s) could not be replayed, so the file's net effect is UNKNOWN — extend the simulator, do not ignore them: $(sed -n 's/^SIM_ERROR //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g SIM_ROWS)" = "$(g ROWS)" ] \
  && ok "all $(g SIM_ROWS) parsed rows survived the replay (nothing dropped by ON CONFLICT, nothing deleted)" \
  || bad "the replay ended with $(g SIM_ROWS) rows but the file declares $(g ROWS) — rows are being dropped or duplicated"

[ "$(g ALTER_COLUMNS_IN_CREATE)" = "yes" ] \
  && ok "every ALTER TABLE ADD COLUMN ($(g ALTER_ADD_COLUMNS)) is also in the CREATE TABLE" \
  || bad "an ALTER TABLE adds a column ($(g ALTER_ADD_COLUMNS)) that the CREATE TABLE ($(g SIM_COLUMNS)) lacks — a fresh initdb would not have it"

[ "$(g ALTER_SHAPE_MISMATCH)" = "0" ] && [ "$(g ALTER_UNKNOWN_ACTIONS)" = "0" ] \
  && ok "…and with the SAME TYPE, NULLABILITY and DEFAULT, so a fresh initdb and an in-place upgrade really do converge. Comparing NAMES only was not enough: the CREATE TABLE said 'mfa_required boolean NOT NULL' while the ALTER added it NULLABLE, so on an upgraded cluster a writer could set mfa_required = NULL — which the gateway reads back as a boolean — while this check called the two 'the same columns'" \
  || bad "$(g ALTER_SHAPE_MISMATCH) column(s) end up shaped differently on a fresh initdb vs an in-place upgrade: $(sed -n 's/^ALTER_SHAPE_MISMATCH_ROW //p' "${W}/real.out" | tr '\n' ';') $(sed -n 's/^ALTER_UNKNOWN_ACTION //p' "${W}/real.out" | tr '\n' ';')"

if [ "${HAVE_UPDATE}" = "1" ]; then
[ "$(g FLIPPED)" -ge 9 ] \
  && ok "AFTER the whole file runs, $(g FLIPPED) rows carry mfa_required=true: $(sed -n 's/^FLIP //p' "${W}/real.out" | tr '\n' ';' )" \
  || bad "after the whole file runs only $(g FLIPPED) rows carry mfa_required=true — expected at least the 9 rows under /bff/admin/** + /bff/superadmin/**"

[ "$(g PREFIX_UNFLIPPED)" = "0" ] \
  && ok "EVERY allow row under /bff/admin/** and /bff/superadmin/** ends up true — no longer sub-path row is left as a false deciding rule (longest-pattern-wins bypass), and nothing later in the file un-flips one" \
  || bad "$(g PREFIX_UNFLIPPED) allow row(s) under the two prefixes end up mfa_required=false, so decide() can settle on a false rule: $(sed -n 's/^PREFIX_UNFLIPPED_ROW //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g OVERREACH)" = "0" ] \
  && ok "nothing outside the two prefixes ends up flipped" \
  || bad "$(g OVERREACH) row(s) outside /bff/admin + /bff/superadmin ended up flipped: $(sed -n 's/^OVERREACH_ROW //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g DENY_FLIPPED)" = "0" ] \
  && ok "no allow=false (DENY) row ends up flipped — a deny row denies at the longest match regardless of MFA, so marking one would be noise" \
  || bad "$(g DENY_FLIPPED) DENY row(s) ended up mfa_required=true: $(sed -n 's/^DENY_FLIPPED_ROW //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g SIM_MFA_CHANGES_1)" = "$(g FLIPPED)" ] \
  && ok "the mfa UPDATE itself changed $(g SIM_MFA_CHANGES_1) rows on the first apply — the same count that ends up true, so no other statement contributes" \
  || bad "the mfa UPDATE changed $(g SIM_MFA_CHANGES_1) rows but $(g FLIPPED) end up true — another statement is also writing the column"

[ "$(g SIM_MFA_CHANGES_2)" = "0" ] && [ "$(g SIM_REAPPLY_STABLE)" = "yes" ] \
  && ok "re-applying the WHOLE file is a genuine no-op: the mfa UPDATE changes 0 rows the second time and the final state is byte-identical" \
  || bad "re-applying the file is NOT a no-op (mfa UPDATE rewrote $(g SIM_MFA_CHANGES_2) rows on the 2nd apply, state_stable=$(g SIM_REAPPLY_STABLE)) — an in-place cluster upgrade would not converge"

[ "$(g UPDATE_IDEMPOTENT)" = "yes" ] \
  && ok "the UPDATE says so in its own text too (mfa_required IS DISTINCT FROM true)" \
  || bad "the UPDATE lacks 'mfa_required IS DISTINCT FROM true' — every in-place re-apply rewrites all matched rows"
fi

# ── (FIX 4) coverage of the admin surface, enumerated INDEPENDENTLY ────────────
[ "$(g ADMINISH_UNCOVERED)" = "0" ] \
  && ok "$(g ADMINISH) admin-ish /bff/ allow rows exist (enumerated independently: a path segment 'admin'/'superadmin', OR a ROLE_SUPERADMIN/*_ADMIN role); each is either flipped or one of the $(g EXCLUSIONS_DOCUMENTED) exclusions named in the SQL header + runbook §1.2a" \
  || bad "$(g ADMINISH_UNCOVERED) admin-ish /bff/ surface(s) are neither flipped nor a DOCUMENTED exclusion: $(sed -n 's/^ADMINISH_UNCOVERED_ROW //p' "${W}/real.out" | tr '\n' ';') — either widen the predicate or add them to DOCUMENTED_EXCLUSIONS *and* to the prose, so the docs never claim more coverage than exists"

[ "$(g STALE_EXCLUSIONS)" = "0" ] \
  && ok "no stale entry in the documented-exclusion list — every listed surface still exists and is still un-flipped" \
  || bad "$(g STALE_EXCLUSIONS) documented exclusion(s) no longer match a real un-flipped row: $(sed -n 's/^STALE_EXCLUSION //p' "${W}/real.out" | tr '\n' ';') — the list has rotted into a rubber stamp; re-derive it"

# Per-prefix, the specific gateways. Deployed gateway ids come from the charts'
# instance.name (== SPRING_APPLICATION_NAME), NOT from a guess: a row whose
# `gateway` differs from the consuming gateway's application name never matches.
DEPLOYED="$(python3 - "${APPS}" <<'PY'
import glob, os, sys, yaml
names = set()
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*gateway*.yaml"))):
    for doc in yaml.safe_load_all(open(p, encoding="utf-8")):
        if not isinstance(doc, dict):
            continue
        for src in (doc.get("spec", {}).get("sources") or []) + [doc.get("spec", {}).get("source") or {}]:
            helm = src.get("helm") or {}
            for vals in (helm.get("values"), helm.get("valuesObject")):
                if isinstance(vals, str):
                    vals = yaml.safe_load(vals) or {}
                if not isinstance(vals, dict):
                    continue
                n = ((vals.get("instance") or {}).get("name"))
                if n:
                    names.add(n)
print(" ".join(sorted(names)))
PY
)"
[ -n "${DEPLOYED}" ] \
  && ok "deployed gateway instance names (== SPRING_APPLICATION_NAME) read from apps/*gateway*.yaml: ${DEPLOYED}" \
  || bad "could not read any instance.name from ${APPS}/*gateway*.yaml — cannot verify the rows key on a real gateway"

for spec in "/bff/admin hugmesh-fe-gateway" "/bff/superadmin hugmesh-superadmin-gateway hugmesh-be-gateway"; do
  [ "${HAVE_UPDATE}" = "1" ] || break
  set -- ${spec}; pre="$1"; shift
  got="$(sed -n "s|^PREFIX_GATEWAYS ${pre} ||p" "${W}/real.out" | head -1)"
  for want in "$@"; do
    case ",${got}," in
      *",${want},"*)
        case " ${DEPLOYED} " in
          *" ${want} "*) ok "${pre}/** MFA-gated on ${want} (a deployed gateway id)" ;;
          *) bad "${pre}/** flipped for ${want}, which is NOT a deployed gateway instance name (${DEPLOYED}) — the row can never match" ;;
        esac ;;
      *) bad "${pre}/** is NOT MFA-gated on ${want} (flipped gateways: ${got:--}) — that gateway serves the prefix un-MFA'd" ;;
    esac
  done
done

# ─────────────────────────────────────────────────────────────────────────────
# 2) the operator's BINDING enablement posture (cluster OFF, privileged floor OFF)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── 2) enablement posture (rules stay INERT until an operator flips a flag) ──"
posture() {   # <apps-dir> [chart-values.yaml] -> writes verdict lines to stdout
  python3 "${W}/posture.py" "$1" ${2+"$2"}
}
posture "${APPS}" "${CHART_VALUES}" > "${W}/posture.out" 2>"${W}/posture.err" \
  || { echo "  FAIL posture checker crashed:"; cat "${W}/posture.err"; exit 1; }
q() { sed -n "s/^$1 //p" "${W}/posture.out" | head -1; }

[ "$(q GATEWAY_APPS)" -ge 4 ] \
  && ok "posture parsed $(q GATEWAY_APPS) gateway Applications (spec.source[s].path == specs/cluster/charts/hugmesh-gateway) — the guards below have something to bite on" \
  || bad "posture found only $(q GATEWAY_APPS) gateway Applications in ${APPS}; the guards below would be vacuous. Did the chart path change?"

[ "$(q PARSE_ERRORS)" = "0" ] \
  && ok "every app manifest (and every embedded helm.values string) parsed as YAML" \
  || bad "$(q PARSE_ERRORS) manifest(s)/values-string(s) failed to parse, so the posture is UNKNOWN there: $(sed -n 's/^PARSE_ERROR //p' "${W}/posture.out" | tr '\n' ';')"

[ "$(q UNAUDITABLE)" = "0" ] \
  && ok "no gateway Application feeds MFA config through an input this gate cannot read (helm.valueFiles / helm.fileParameters / a valueFrom-sourced APP_MFA_*)" \
  || bad "$(q UNAUDITABLE) un-auditable MFA input(s): $(sed -n 's/^UNAUDITABLE_AT //p' "${W}/posture.out" | tr '\n' ';') — an input this gate cannot read must NOT read as a pass. Inline the value or add a reader for it"

[ "$(q MFA_ENABLED_ON)" = "0" ] \
  && ok "no specs/cluster/apps/*.yaml turns gateway MFA on — the CLUSTER default stays OFF (checked structurally across helm.values / valuesObject / parameters, and for both spellings: chart mfa.enabled and a raw APP_MFA_ENABLED extraEnv). Flipping it is an explicit operator action; the privileged floor is NOT exempt for SUPERADMIN, so enabling it before operators enrol a second factor locks them out of the privileged plane" \
  || bad "$(q MFA_ENABLED_ON) app manifest site(s) turn gateway MFA on: $(sed -n 's/^MFA_ENABLED_AT //p' "${W}/posture.out" | tr '\n' ';') — that is the posture an earlier change got backwards; see docs/MFA-ROLLOUT.md"

[ "$(q FLOOR_ON)" = "0" ] \
  && ok "no app manifest turns the privileged floor on (mfa.enforcePrivilegedFloor or APP_MFA_ENFORCE_PRIVILEGED_FLOOR)" \
  || bad "$(q FLOOR_ON) app manifest site(s) turn the privileged floor on: $(sed -n 's/^FLOOR_AT //p' "${W}/posture.out" | tr '\n' ';') — it fails CLOSED with 503 for privileged principals while route-access primes and is NOT gated on app.mfa.enabled"

case "$(q CHART_MFA_BLOCK)" in
  absent)
    ok "the shared chart has no 'mfa:' values block on this branch — the flag wiring arrives with the companion change (docs/MFA-ROLLOUT.md §0); this check starts asserting the defaults the moment the block appears" ;;
  present)
    [ "$(q CHART_MFA_ENABLED)" = "not-true" ] && [ "$(q CHART_FLOOR)" = "not-true" ] \
      && ok "the shared chart's mfa: block defaults BOTH enabled and enforcePrivilegedFloor off" \
      || bad "the shared chart's mfa: block defaults enabled=$(q CHART_MFA_ENABLED) / enforcePrivilegedFloor=$(q CHART_FLOOR) — a chart default reaches all four gateway Applications at once" ;;
  *)
    bad "could not read the shared chart values (${CHART_VALUES}): $(q CHART_MFA_BLOCK)" ;;
esac

# ── the env-SHAPE sweep: everything the ArgoCD parse above cannot see ─────────
# (chart templates, ConfigMaps, plain Deployments, the compose stack)
python3 "${W}/envscan.py" "${REPO}" "${REPO}/specs" "${COMPOSE}" \
  > "${W}/env.out" 2>"${W}/env.err" \
  || { echo "  FAIL env-shape scanner crashed:"; cat "${W}/env.err"; exit 1; }
e() { sed -n "s/^$1 //p" "${W}/env.out" | head -1; }
ESHAPES="k8s env lists ('- name:' / 'value:' on separate lines, either order), mapping keys, [export] KEY=value assignments and flow mappings"

[ "$(e SCANNED_FILES)" -ge 200 ] \
  && ok "the env-shape sweep walked $(e SCANNED_FILES) files under specs/ + the compose stack and found $(e CANDIDATE_FILES) mentioning APP_MFA_ at all: $(sed -n 's/^CANDIDATE //p' "${W}/env.out" | tr '\n' ' ')" \
  || bad "the env-shape sweep walked only $(e SCANNED_FILES) files — the roots are wrong and every verdict below it would be vacuous"

[ "$(e FLOOR_TRUE)" = "0" ] \
  && ok "nothing under specs/ or in the compose stack sets APP_MFA_ENFORCE_PRIVILEGED_FLOOR to a true value, in any of the shapes this scan understands — ${ESHAPES} ($(e DEFERRED) site(s) defer it to a chart value, audited by the chart-values arm above: $(sed -n 's/^DEFERRED_AT //p' "${W}/env.out" | tr '\n' ';')). It fails CLOSED with 503 for privileged principals while route-access primes, and GatewayRouteAccessFilter checks it WITHOUT consulting app.mfa.enabled, so it must stay off until operators have enrolled" \
  || bad "$(e FLOOR_TRUE) site(s) default APP_MFA_ENFORCE_PRIVILEGED_FLOOR true: $(sed -n 's/^FLOOR_AT //p' "${W}/env.out" | tr '\n' ';')"

# APP_MFA_ENABLED is deliberately ASYMMETRIC (docs/MFA-ROLLOUT.md §0): the CLUSTER ships it
# OFF, the COMPOSE DEV STACK defaults it ON so the enforcement leg is exercisable locally.
# A flat "zero sites anywhere" verdict encodes only half of that and fails on the compose
# half BY DESIGN — so partition by root and assert each side's real requirement. The cluster
# side keeps the original strength; the compose side is not merely tolerated but pinned.
ENABLED_CLUSTER_AT="$(sed -n 's/^ENABLED_AT //p' "${W}/env.out" | grep -v '^tests/stack/' || true)"
ENABLED_COMPOSE_AT="$(sed -n 's/^ENABLED_AT //p' "${W}/env.out" | grep '^tests/stack/' || true)"
ENABLED_CLUSTER_N="$(printf '%s' "${ENABLED_CLUSTER_AT}" | grep -c . || true)"
ENABLED_COMPOSE_N="$(printf '%s' "${ENABLED_COMPOSE_AT}" | grep -c . || true)"

[ "${ENABLED_CLUSTER_N}" = "0" ] \
  && ok "…and nothing OUTSIDE the compose dev stack hardcodes APP_MFA_ENABLED true — including the shared chart template that renders env into ALL FOUR gateway pods, which the ArgoCD-Application parse above cannot reach and a per-line grep could not read (name and value are on different lines)" \
  || bad "${ENABLED_CLUSTER_N} CLUSTER-side site(s) default APP_MFA_ENABLED true: $(printf '%s' "${ENABLED_CLUSTER_AT}" | tr '\n' ';') — the cluster posture is OFF; flipping it is an explicit operator action"

# Every compose default-ON site must stay OPERATOR-OVERRIDABLE. `${APP_MFA_ENABLED:-true}`
# lets `APP_MFA_ENABLED=false make stack-up` turn it back off; a bare `true` would not, which
# is a different posture from the one that was chosen.
COMPOSE_HARDCODED="$(printf '%s' "${ENABLED_COMPOSE_AT}" | grep -v 'shell default is true' || true)"
[ -z "${COMPOSE_HARDCODED}" ] \
  && ok "the compose dev stack's ${ENABLED_COMPOSE_N} APP_MFA_ENABLED default(s) are all the OVERRIDABLE \${APP_MFA_ENABLED:-true} form, so APP_MFA_ENABLED=false still turns the dev stack's enforcement off" \
  || bad "compose site(s) hardcode APP_MFA_ENABLED true with no override: $(printf '%s' "${COMPOSE_HARDCODED}" | tr '\n' ';') — the dev stack defaults ON, but an operator must still be able to set it false"

[ "$(e UNAUDITED_DEFER)" = "0" ] \
  && ok "every APP_MFA_* site that defers to a chart value defers to a key the chart-values arm actually reads (top-level mfa.enabled / mfa.enforcePrivilegedFloor) — so 'deferred' above genuinely means audited, not unexamined" \
  || bad "$(e UNAUDITED_DEFER) APP_MFA_* site(s) defer to a chart key NOTHING audits: $(sed -n 's/^UNAUDITED_DEFER_AT //p' "${W}/env.out" | tr '\n' ';') — the chart-values arm reads the TOP-LEVEL mfa: block only, so this renders from an unexamined default. Move the key under mfa:, or teach the chart-values arm to read it"

[ "$(e UNDECIDABLE)" = "0" ] \
  && ok "no APP_MFA_* env value in that sweep is undecidable (a valueFrom Secret/ConfigMap reference, or a literal true inside an open Helm {{ if }} block)" \
  || bad "$(e UNDECIDABLE) APP_MFA_* env value(s) this scan cannot decide: $(sed -n 's/^UNDECIDABLE_AT //p' "${W}/env.out" | tr '\n' ';') — an input the gate cannot read must NOT read as a pass"

[ -r "${DOC}" ] \
  && ok "operator runbook present: docs/MFA-ROLLOUT.md" \
  || bad "docs/MFA-ROLLOUT.md missing — these rules are inert until an operator flips a flag, and the order of operations is not obvious"

# ── the runbook's own SQL, EXECUTED (see check.py's DOC section) ──────────────
[ "$(g DOC_SQL_BLOCKS)" -ge 4 ] \
  && ok "the runbook marks $(g DOC_SQL_BLOCKS) SQL blocks for execution ($(g DOC_SQL_NAMES)); each is RUN against the replayed database rather than eyeballed" \
  || bad "only $(g DOC_SQL_BLOCKS) '<!-- gate:doc-sql -->' block(s) found in ${DOC} — the runbook's operator queries are back to being unverified prose"

[ "$(g DOC_SQL_BAD)" = "0" ] \
  && ok "every marked runbook query returns exactly what the prose around it promises (a previous revision told operators that LIKE '/bff/%admin%' 'also returns the six rows that are false by design' — run for real it returns THREE of the six, because the other three have no 'admin' substring in url_pattern)" \
  || bad "$(g DOC_SQL_BAD) runbook SQL block(s) do not do what the prose says: $(sed -n 's/^DOC_SQL_BAD_ROW //p' "${W}/real.out" | tr '\n' ';')"

# ─────────────────────────────────────────────────────────────────────────────
# 3) negative controls — each check must BITE on a corrupted copy
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── 3) negative controls (SQL) ──"
# EVERY control below asserts its OWN PRECONDITION before it claims anything.
# These mutators work by string-replacing anchors taken from the LIVE files, so an
# unrelated future edit can silently turn one into a no-op — and then the control
# reports "the check is vacuous", which is a lie about a DIFFERENT part of the
# system. That is not hypothetical: adding the mfa_required NULL repair near the top
# of 20-schema.sql immediately gave `re.search(r"UPDATE\s+gateway_route_access[^;]*;")`
# a SECOND, earlier match, so two mutators silently stopped biting. Every mutator now
# gets `anchor()` / `absent()` helpers, and the harness distinguishes
#   "the mutation could not be applied"      (precondition failure — fix the control)
# from
#   "the mutation applied and nothing moved" (the check really is vacuous).
#
# nc <name> <key> <expected-not-value> <python-mutator>
nc() {
  local name="$1" key="$2" good="$3" mut="$4"
  local d="${W}/nc"; rm -rf "${d}"; mkdir -p "${d}"
  cp "${SQL}" "${d}/s.sql"
  if ! python3 - "${d}/s.sql" >"${d}/mut.log" 2>&1 <<PY
import re, sys
p = sys.argv[1]
orig = open(p, encoding="utf-8").read()
s = orig
def anchor(text, n=1):
    got = s.count(text)
    assert got == n, "anchor %r occurs %d time(s) in the live file, expected %d" % (text[:70], got, n)
def absent(pattern):
    m = re.search(pattern, s, re.M)
    assert not m, "conflicting pre-existing text %r at offset %d" % (m.group(0)[:70], m.start())
def one(pattern, flags=re.S | re.I):
    ms = re.findall("(" + pattern + ")", s, flags)
    assert len(ms) == 1, "pattern %r matches %d statement(s), expected exactly 1" % (pattern[:70], len(ms))
    return ms[0] if isinstance(ms[0], str) else ms[0][0]
${mut}
assert s != orig, "the mutator produced no change at all"
open(p, "w", encoding="utf-8").write(s)
PY
  then
    bad "negative control: ${name} — its OWN PRECONDITION failed, so the mutation never ran and this control proves NOTHING (fix the control, not the check): $(tr -s ' \n' ' ' < "${d}/mut.log" | tail -c 240)"
    return
  fi
  local got
  got="$(python3 "${W}/check.py" "${d}/s.sql" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"
  [ "${got}" != "${good}" ] \
    && ok "negative control: ${name} -> ${key}=${got:-<absent>} (was ${good})" \
    || bad "negative control: ${name} was applied to the file and ${key} did NOT move (still ${good}) — the check is vacuous"
}

# The flip UPDATE, addressed UNAMBIGUOUSLY. `UPDATE\s+gateway_route_access[^;]*;`
# is NOT unambiguous — the in-place-upgrade NULL repair near the top of the file is
# also an `UPDATE gateway_route_access … ;`, and two controls silently stopped
# biting the moment it was added. one() asserts the match count.
FLIP='UPDATE\s+gateway_route_access\s+SET\s+mfa_required\s*=\s*true[^;]*;'

nc "mfa_required UPDATE removed entirely" MFA_UPDATES 1 \
   "s = s.replace(one(r'${FLIP}'), '', 1)"

nc "UPDATE narrowed to one gateway" UPDATE_GATEWAY_SCOPED no \
   'anchor(" WHERE allow = true")
s = s.replace(" WHERE allow = true", " WHERE allow = true\n   AND gateway = %s" % repr("hugmesh-fe-gateway"), 1)'

nc "prefix LIKE arms replaced by the two /** floors only (longest-pattern bypass)" PREFIX_UNFLIPPED 0 \
   "up = one(r'${FLIP}')"'
new = up.replace("url_pattern LIKE %s" % repr("/bff/admin/%"), "url_pattern = %s" % repr("/bff/admin/**"))
new = new.replace("url_pattern LIKE %s" % repr("/bff/superadmin/%"), "url_pattern = %s" % repr("/bff/superadmin/**"))
assert new != up, "neither LIKE arm was found inside the flip UPDATE"
s = s.replace(up, new, 1)'

nc "UPDATE broadened to every /bff/ path" OVERREACH 0 \
   'anchor("url_pattern LIKE %s" % repr("/bff/admin/%"))
s = s.replace("url_pattern LIKE %s" % repr("/bff/admin/%"), "url_pattern LIKE %s" % repr("/bff/%"), 1)'

nc "UPDATE no longer restricted to allow = true (a DENY row gets flipped)" DENY_FLIPPED 0 \
   "up = one(r'${FLIP}')"'
new = up.replace("WHERE allow = true\n   AND (url_pattern", "WHERE (url_pattern", 1)
assert new != up, "the allow=true arm was not found inside the flip UPDATE"
s = s.replace(up, new, 1).replace("url_pattern LIKE %s" % repr("/bff/admin/%"), "url_pattern LIKE %s" % repr("/bff/%"), 1)'

nc "mfa_required folded into uq_route_access_row" UQ_HAS_MFA no \
   'anchor("role, COALESCE(casdoor_user, %s), COALESCE(domain, %s));" % (repr(""), repr("")))
s = s.replace("role, COALESCE(casdoor_user, %s), COALESCE(domain, %s));" % (repr(""), repr("")),
              "role, mfa_required, COALESCE(casdoor_user, %s), COALESCE(domain, %s));" % (repr(""), repr("")), 1)'

nc "UPDATE replaced by a parallel 5-value INSERT row (the ON CONFLICT DO NOTHING trap)" FIVE_VALUE_ROWS 0 \
   "s = s.replace(one(r'${FLIP}'),"'
            "INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, mfa_required) VALUES\n"
            "  (%s, %s, %s, true, true)\nON CONFLICT DO NOTHING;" % (
                repr("hugmesh-fe-gateway"), repr("/bff/admin/**"), repr("ROLE_ADMIN")), 1)'

# ── (d) THE APPENDED SECOND STATEMENT ─────────────────────────────────────────
# The defeat a per-statement text check cannot see, in every spelling an operator
# following runbook §5 might plausibly paste. The four SCHEMA-QUALIFIED / QUOTED /
# CTE-LED ones below all used to pass the whole gate green (`60 passed, 0 failed`)
# because the DML pattern demanded a bare table name, so the statement was never
# replayed and never counted — including a DELETE that wiped every superadmin row.
UNFLIP='s += "\nUPDATE gateway_route_access SET mfa_required = false\n WHERE url_pattern LIKE %s;\n" % repr("/bff/admin/phone-fleet/%")'
nc "a SECOND, LATER 'SET mfa_required = false' appended (phone-fleet un-flipped)" PREFIX_UNFLIPPED 0 "${UNFLIP}"
nc "…the same append, seen by the INDEPENDENT admin-ish enumeration" ADMINISH_UNCOVERED 0 "${UNFLIP}"
nc "…and by the single-writer guard" MFA_WRITE_UNEXPECTED 0 "${UNFLIP}"

nc "an appended un-flip of the whole superadmin prefix" PREFIX_UNFLIPPED 0 \
   's += "\nUPDATE gateway_route_access SET mfa_required = false\n WHERE url_pattern LIKE %s;\n" % repr("/bff/superadmin%")'

nc "an appended SCHEMA-QUALIFIED un-flip (public.gateway_route_access)" PREFIX_UNFLIPPED 0 \
   's += "\nUPDATE public.gateway_route_access SET mfa_required = false\n WHERE url_pattern LIKE %s;\n" % repr("/bff/admin/phone-fleet/%")'
nc "…the same schema-qualified un-flip, seen by the single-writer guard" MFA_WRITE_UNEXPECTED 0 \
   's += "\nUPDATE public.gateway_route_access SET mfa_required = false\n WHERE url_pattern LIKE %s;\n" % repr("/bff/admin/phone-fleet/%")'

nc "an appended DOUBLE-QUOTED-identifier un-flip" PREFIX_UNFLIPPED 0 \
   's += "\nUPDATE %s SET mfa_required = false\n WHERE url_pattern LIKE %s;\n" % (chr(34) + "gateway_route_access" + chr(34), repr("/bff/superadmin/%"))'

nc "an appended CTE-LED un-flip (WITH … UPDATE)" PREFIX_UNFLIPPED 0 \
   's += ("\nWITH exempt AS (SELECT id FROM gateway_route_access WHERE url_pattern LIKE %s)\n"
      "UPDATE gateway_route_access SET mfa_required = false WHERE id IN (SELECT id FROM exempt);\n"
      % repr("/bff/superadmin/%"))'

nc "an appended PARTIAL un-flip of ONE row" PREFIX_UNFLIPPED 0 \
   's += ("\nUPDATE gateway_route_access SET mfa_required = false\n"
      " WHERE url_pattern = %s AND role = %s;\n"
      % (repr("/bff/superadmin/workloads/**"), repr("ROLE_SUPERADMIN")))'

nc "an appended DELETE of flipped rows" SIM_ROWS 129 \
   's += "\nDELETE FROM gateway_route_access WHERE url_pattern LIKE %s;\n" % repr("/bff/admin/phone-fleet/%")'

nc "an appended SCHEMA-QUALIFIED DELETE that wipes every superadmin row" SIM_ROWS 129 \
   's += "\nDELETE FROM public.gateway_route_access WHERE url_pattern LIKE %s;\n" % repr("/bff/superadmin%")'

nc "'IS DISTINCT FROM true' dropped (re-apply stops being a no-op)" SIM_MFA_CHANGES_2 0 \
   'anchor("\n   AND mfa_required IS DISTINCT FROM true;")
s = s.replace("\n   AND mfa_required IS DISTINCT FROM true;", ";", 1)'

nc "a statement the simulator cannot run is NOT silently skipped" SIM_ERRORS 0 \
   's += "\nUPDATE gateway_route_access SET mfa_required = false\n WHERE url_pattern ~ %s;\n" % repr("^/bff/admin")'

nc "a statement of a KIND this gate does not classify is not silently skipped either" UNCLASSIFIED 0 \
   's += "\nCALL some_procedure_that_rewrites(%s);\n" % repr("gateway_route_access")'

# ── the in-place-upgrade column shape (fresh initdb vs ALTER path) ─────────────
nc "the mfa_required ALTER goes back to NULLABLE while the CREATE TABLE says NOT NULL" \
   ALTER_SHAPE_MISMATCH 0 \
   'anchor("ADD COLUMN IF NOT EXISTS mfa_required boolean NOT NULL DEFAULT false;")
anchor("ALTER COLUMN mfa_required SET NOT NULL;")
s = s.replace("ADD COLUMN IF NOT EXISTS mfa_required boolean NOT NULL DEFAULT false;",
              "ADD COLUMN IF NOT EXISTS mfa_required boolean DEFAULT false;", 1)
s = s.replace("ALTER TABLE gateway_route_access ALTER COLUMN mfa_required SET NOT NULL;\n", "", 1)'

nc "the ALTER path leaves a DIFFERENT DEFAULT from the CREATE TABLE" ALTER_SHAPE_MISMATCH 0 \
   'anchor("ALTER COLUMN mfa_required SET DEFAULT false;")
s = s.replace("ALTER COLUMN mfa_required SET DEFAULT false;",
              "ALTER COLUMN mfa_required SET DEFAULT true;", 1)'

nc "the NULL backfill is moved AFTER the flip, where it could un-flip rows" \
   MFA_BACKFILL_BEFORE_FLIP yes \
   'anchor("UPDATE gateway_route_access SET mfa_required = false WHERE mfa_required IS NULL;\n")
s = s.replace("UPDATE gateway_route_access SET mfa_required = false WHERE mfa_required IS NULL;\n", "", 1)
s += "\nUPDATE gateway_route_access SET mfa_required = false WHERE mfa_required IS NULL;\n"'

nc "a second predicate smuggled into the NULL backfill" MFA_WRITE_UNEXPECTED 0 \
   'anchor("UPDATE gateway_route_access SET mfa_required = false WHERE mfa_required IS NULL;")
s = s.replace("UPDATE gateway_route_access SET mfa_required = false WHERE mfa_required IS NULL;",
              "UPDATE gateway_route_access SET mfa_required = false WHERE mfa_required IS NULL"
              " OR url_pattern LIKE %s;" % repr("/bff/admin/%"), 1)'

nc "an admin-ish /bff/ surface added but neither flipped nor documented" ADMINISH_UNCOVERED 0 \
   'mod = "  (%s,  %s,           %s,       true)," % (
    repr("hugmesh-fe-gateway"), repr("/bff/mod/**"), repr("ROLE_MOD"))
anchor(mod)
s = s.replace(mod, mod + "\n  (%s, %s, %s, true)," % (
    repr("hugmesh-fe-gateway"), repr("/bff/tube/admin/**"), repr("ROLE_ADMIN")), 1)'

nc "a documented exclusion that no longer exists (the list rots)" STALE_EXCLUSIONS 0 \
   'anchor("'"'"'/bff/wiki/admin/**'"'"'")
s = re.sub(r"^.*%s.*$\n" % re.escape("'"'"'/bff/wiki/admin/**'"'"'"), "", s, flags=re.M)'

# ── the runbook SQL that this gate executes, proven to bite ──────────────────
# nd <name> <key> <expected-not-value> <python-mutator-on-a-COPY-of-the-doc>
nd() {
  local name="$1" key="$2" good="$3" mut="$4"
  local d="${W}/nd"; rm -rf "${d}"; mkdir -p "${d}"
  cp "${DOC}" "${d}/doc.md"
  if ! python3 - "${d}/doc.md" >"${d}/mut.log" 2>&1 <<PY
import re, sys
p = sys.argv[1]
orig = open(p, encoding="utf-8").read()
s = orig
def anchor(text, n=1):
    got = s.count(text)
    assert got == n, "anchor %r occurs %d time(s) in the live runbook, expected %d" % (text[:70], got, n)
${mut}
assert s != orig, "the mutator produced no change at all"
open(p, "w", encoding="utf-8").write(s)
PY
  then
    bad "negative control: ${name} — its OWN PRECONDITION failed, so the mutation never ran and this control proves NOTHING: $(tr -s ' \n' ' ' < "${d}/mut.log" | tail -c 240)"
    return
  fi
  local got
  got="$(python3 "${W}/check.py" "${SQL}" "${d}/doc.md" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"
  [ "${got}" != "${good}" ] \
    && ok "negative control: ${name} -> ${key}=${got:-<absent>} (was ${good})" \
    || bad "negative control: ${name} was applied to the runbook and ${key} did NOT move (still ${good}) — the runbook checks are vacuous"
}

nd "the runbook's scope-boundary query narrowed back to LIKE '/bff/%admin%' (returns 3 of the 6 exclusions, not 6)" \
   DOC_SQL_BAD 0 \
   'a = "      AND url_pattern LIKE %s\n      AND (url_pattern LIKE %s OR role LIKE %s)" % (
    repr("/bff/%"), repr("%admin%"), repr("%ADMIN%"))
anchor(a)
s = s.replace(a, "      AND url_pattern LIKE %s" % repr("/bff/%admin%"), 1)'

nd "the runbook's verification query silently widened to every row" DOC_SQL_BAD 0 \
   'a = "    WHERE url_pattern LIKE %s\n       OR url_pattern LIKE %s" % (
    repr("/bff/admin%"), repr("/bff/superadmin%"))
anchor(a)
s = s.replace(a, "    WHERE 1 = 1", 1)'

nd "the runbook's quoted UPDATE drifts from the seed's real one" DOC_SQL_BAD 0 \
   'anchor("     OR url_pattern LIKE %s)\n   AND mfa_required IS DISTINCT FROM true;" % repr("/bff/superadmin/%"))
s = s.replace("     OR url_pattern LIKE %s)\n   AND mfa_required IS DISTINCT FROM true;" % repr("/bff/superadmin/%"),
              "     OR url_pattern LIKE %s);" % repr("/bff/superadmin/%"), 1)'

nd "the runbook's rollback stops actually rolling everything back" DOC_SQL_BAD 0 \
   'anchor("    WHERE url_pattern LIKE %s OR url_pattern LIKE %s" % (
    repr("/bff/admin/%"), repr("/bff/superadmin/%")))
s = s.replace("    WHERE url_pattern LIKE %s OR url_pattern LIKE %s" % (
    repr("/bff/admin/%"), repr("/bff/superadmin/%")),
    "    WHERE url_pattern LIKE %s" % repr("/bff/admin/%"), 1)'

echo ""
echo "── 3b) negative controls (posture: every ArgoCD input shape) ──"
# np <name> <key> <expected-not-value> <python-mutator-on-20-gateway-fe.yaml>
np() {
  local name="$1" key="$2" good="$3" mut="$4"
  local d="${W}/np"; rm -rf "${d}"; mkdir -p "${d}/apps"
  cp "${APPS}/20-gateway-fe.yaml" "${d}/apps/"
  python3 - "${d}/apps/20-gateway-fe.yaml" <<PY
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
${mut}
open(p, "w", encoding="utf-8").write(s)
PY
  local got
  got="$(python3 "${W}/posture.py" "${d}/apps" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"
  [ "${got}" != "${good}" ] \
    && ok "negative control: ${name} -> ${key}=${got:-<absent>} (was ${good})" \
    || bad "negative control: ${name} was NOT caught (${key} still ${good}) — the posture guard is vacuous for that shape"
}

np "helm.values string, block style mfa.enabled: true" MFA_ENABLED_ON 0 \
   's = s.replace("        instance:\n", "        mfa:\n          enabled: true\n        instance:\n", 1)'
np "helm.values string, FLOW style mfa: {enabled: true}" MFA_ENABLED_ON 0 \
   's = s.replace("        instance:\n", "        mfa: {enabled: true}\n        instance:\n", 1)'
np "helm.values string, a comment block between mfa: and enabled: true" MFA_ENABLED_ON 0 \
   's = s.replace("        instance:\n", "        mfa:\n          # the repo commenting style\n          # spread over several lines\n          enabled: true\n        instance:\n", 1)'
np "helm.values extraEnv APP_MFA_ENABLED (the ONLY mechanism the chart supports today)" MFA_ENABLED_ON 0 \
   's = s.replace("        extraEnv:\n", "        extraEnv:\n          - name: APP_MFA_ENABLED\n            value: \"true\"\n", 1)'
np "helm.valuesObject (structured, not a string)" MFA_ENABLED_ON 0 \
   's = s.replace("      values: |\n", "      valuesObject:\n        mfa:\n          enabled: true\n      values: |\n", 1)'
np "helm.parameters name=mfa.enabled" MFA_ENABLED_ON 0 \
   's = s.replace("      values: |\n", "      parameters:\n        - name: mfa.enabled\n          value: \"true\"\n      values: |\n", 1)'
np "helm.parameters indexed extraEnv[0].name/.value" MFA_ENABLED_ON 0 \
   's = s.replace("      values: |\n", "      parameters:\n        - name: extraEnv[0].name\n          value: APP_MFA_ENABLED\n        - name: extraEnv[0].value\n          value: \"true\"\n      values: |\n", 1)'
np "helm.valueFiles — an input the gate cannot read must FAIL, not silently pass" UNAUDITABLE 0 \
   's = s.replace("      values: |\n", "      valueFiles:\n        - values-mfa-on.yaml\n      values: |\n", 1)'
np "an APP_MFA_ENABLED extraEnv sourced from a Secret (also un-auditable)" UNAUDITABLE 0 \
   's = s.replace("        extraEnv:\n", "        extraEnv:\n          - name: APP_MFA_ENABLED\n            valueFrom:\n              secretKeyRef:\n                name: x\n                key: y\n", 1)'
np "the privileged floor via helm.values mfa.enforcePrivilegedFloor" FLOOR_ON 0 \
   's = s.replace("        instance:\n", "        mfa:\n          enforcePrivilegedFloor: true\n        instance:\n", 1)'
np "the privileged floor via extraEnv APP_MFA_ENFORCE_PRIVILEGED_FLOOR" FLOOR_ON 0 \
   's = s.replace("        extraEnv:\n", "        extraEnv:\n          - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR\n            value: \"true\"\n", 1)'
np "a manifest whose helm.values string is not valid YAML (posture UNKNOWN there)" PARSE_ERRORS 0 \
   's = s.replace("        instance:\n", "        instance:\n         \tbad: [unclosed\n", 1)'

# The chart-values arm of the posture guard, proven to bite on a staged copy.
d="${W}/chart"; rm -rf "${d}"; mkdir -p "${d}/apps"
cp "${APPS}/20-gateway-fe.yaml" "${d}/apps/"
printf 'mfa:\n  enabled: true\n  enforcePrivilegedFloor: true\n' > "${d}/values.yaml"
cb="$(python3 "${W}/posture.py" "${d}/apps" "${d}/values.yaml" 2>/dev/null)"
if [ "$(printf '%s\n' "${cb}" | sed -n 's/^CHART_MFA_ENABLED //p')" = "true" ] \
   && [ "$(printf '%s\n' "${cb}" | sed -n 's/^CHART_FLOOR //p')" = "true" ]; then
  ok "negative control: a chart values.yaml with mfa.enabled/enforcePrivilegedFloor true -> both caught"
else
  bad "negative control: a chart values.yaml turning MFA on was NOT caught — the chart arm is vacuous"
fi

echo ""
echo "── 3c) negative controls (env shapes outside the ArgoCD Applications) ──"
# ne <name> <key> <expected-not-value> <file-basename> <heredoc-body-on-stdin>
# Each control writes ONE file into an otherwise-empty tree and scans it, so a
# control can never accidentally read a hit from a neighbouring fixture.
ne() {
  local name="$1" key="$2" good="$3" fn="$4"
  local d="${W}/ne"; rm -rf "${d}"; mkdir -p "${d}/tree"
  cat > "${d}/tree/${fn}"
  local got
  got="$(python3 "${W}/envscan.py" "${d}" "${d}/tree" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"
  [ "${got}" != "${good}" ] \
    && ok "negative control: ${name} -> ${key}=${got:-<absent>} (was ${good})" \
    || bad "negative control: ${name} was NOT caught (${key} still ${good}) — the env-shape sweep is vacuous for that shape"
}

# THE shape that defeated the previous grep: the REAL shared chart template, which
# renders env into ALL FOUR gateway pods and is not valid YAML (Helm actions in
# value positions), with the floor hardcoded on in k8s env-list form.
d="${W}/nechart"; rm -rf "${d}"; mkdir -p "${d}/tree"
python3 - "${CHART_TPL}" "${d}/tree/deployment.yaml" >"${d}/mut.log" 2>&1 <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
a = "            - name: SPRING_PROFILES_ACTIVE\n"
assert s.count(a) == 1, "anchor %r occurs %d time(s) in the live chart template" % (a, s.count(a))
s = s.replace(a, '            - name: APP_MFA_ENABLED\n              value: "true"\n'
                 '            - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR\n              value: "true"\n' + a, 1)
open(dst, "w", encoding="utf-8").write(s)
PY
if [ $? -ne 0 ]; then
  bad "negative control: the shared chart template control could not be applied, so it proves NOTHING: $(tr -s ' \n' ' ' < "${d}/mut.log" | tail -c 200)"
else
  cf="$(python3 "${W}/envscan.py" "${d}" "${d}/tree" 2>/dev/null | sed -n 's/^FLOOR_TRUE //p' | head -1)"
  ce="$(python3 "${W}/envscan.py" "${d}" "${d}/tree" 2>/dev/null | sed -n 's/^ENABLED_TRUE //p' | head -1)"
  [ "${cf:-0}" != "0" ] && [ "${ce:-0}" != "0" ] \
    && ok "negative control: the REAL shared chart template (Helm actions and all) with both APP_MFA_* hardcoded true in k8s env-list form -> FLOOR_TRUE=${cf} ENABLED_TRUE=${ce}. This is the exact shape the previous two-stage grep could not see: it looked for the variable NAME on a line and then tested THAT SAME LINE for a true value, and here the name and the value are on different lines" \
    || bad "negative control: the shared chart template hardcoding both APP_MFA_* true was NOT caught (FLOOR_TRUE=${cf:-?} ENABLED_TRUE=${ce:-?}) — the sweep is still blind to the k8s env-list shape"
fi

ne "a plain Deployment with the floor in k8s env-list form" FLOOR_TRUE 0 dep.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: hugmesh-be-gateway}
spec:
  template:
    spec:
      containers:
        - name: gateway
          env:
            - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR
              value: "true"
EOF

ne "…the same, with name and value in the OPPOSITE order" FLOOR_TRUE 0 dep.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: gateway
          env:
            - value: "true"
              name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR
EOF

ne "a ConfigMap whose data turns the floor on" FLOOR_TRUE 0 cm.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: gateway-env}
data:
  APP_MFA_ENFORCE_PRIVILEGED_FLOOR: "true"
EOF

ne "a compose service defaulting the floor true" FLOOR_TRUE 0 compose.yaml <<'EOF'
services:
  gw:
    environment:
      APP_MFA_ENFORCE_PRIVILEGED_FLOOR: ${APP_MFA_ENFORCE_PRIVILEGED_FLOOR:-true}
EOF

ne "a FLOW-mapping env entry" FLOOR_TRUE 0 dep.yaml <<'EOF'
spec:
  containers:
    - env:
        - {name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR, value: "true"}
EOF

ne "a shell/dotenv assignment" FLOOR_TRUE 0 gateway.env.sh <<'EOF'
export APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true
EOF

ne "APP_MFA_ENABLED hardcoded in a chart template's env list" ENABLED_TRUE 0 tpl.yaml <<'EOF'
        env:
          - name: APP_MFA_ENABLED
            value: {{ .Values.x | default "true" | quote }}
EOF

ne "the floor sourced from a Secret — undecidable, must NOT read as a pass" UNDECIDABLE 0 dep.yaml <<'EOF'
env:
  - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR
    valueFrom:
      secretKeyRef: {name: x, key: y}
EOF

ne "a literal true inside an open Helm {{ if }} block — also undecidable" UNDECIDABLE 0 tpl.yaml <<'EOF'
        env:
{{- if .Values.somethingElse }}
          - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR
            value: "true"
{{- end }}
EOF

# …and the other direction. A guard that cries wolf on a correctly-OFF value gets
# muted the first time someone wires the flag up properly, so these assert SILENCE.
# ne_off <name> <file-basename> <heredoc>  -> requires FLOOR_TRUE=ENABLED_TRUE=UNDECIDABLE=0
ne_off() {
  local name="$1" fn="$2"
  local d="${W}/ne"; rm -rf "${d}"; mkdir -p "${d}/tree"
  cat > "${d}/tree/${fn}"
  local o
  o="$(python3 "${W}/envscan.py" "${d}" "${d}/tree" 2>/dev/null)"
  local f n u
  f="$(printf '%s\n' "${o}" | sed -n 's/^FLOOR_TRUE //p')"
  n="$(printf '%s\n' "${o}" | sed -n 's/^ENABLED_TRUE //p')"
  u="$(printf '%s\n' "${o}" | sed -n 's/^UNDECIDABLE //p')"
  [ "${f}" = "0" ] && [ "${n}" = "0" ] && [ "${u}" = "0" ] \
    && ok "negative control (other direction): ${name} -> stays silent (floor=0 enabled=0 undecidable=0)" \
    || bad "negative control (other direction): ${name} FIRED (floor=${f} enabled=${n} undecidable=${u}) — a sweep that cries wolf on a correctly-OFF value gets muted the first time the flag is wired up properly"
}

ne_off "a correctly-OFF env-list value" dep.yaml <<'EOF'
env:
  - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR
    value: "false"
  - name: APP_MFA_ENABLED
    value: "false"
EOF

ne_off "a value deferred to a chart value (what the companion change will look like)" tpl.yaml <<'EOF'
env:
  - name: APP_MFA_ENFORCE_PRIVILEGED_FLOOR
    value: {{ .Values.mfa.enforcePrivilegedFloor | quote }}
  - name: APP_MFA_ENABLED
    value: {{ .Values.mfa.enabled | quote }}
EOF

ne_off "the variables merely NAMED in comments and prose (as 20-schema.sql names them)" notes.sql <<'EOF'
-- APP_MFA_ENABLED: true  <- a comment, not a setting
-- app.mfa.enforce-privileged-floor (APP_MFA_ENFORCE_PRIVILEGED_FLOOR) is dangerous
EOF

echo ""
echo "== mfa_required route-access rules: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
