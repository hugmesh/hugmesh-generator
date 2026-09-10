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
# ENGINE CAVEAT, stated up front: the net-effect SIMULATION runs on **sqlite3**
# (it replays the file dozens of times, once per mutation control — cheap and
# always available). sqlite is used only for the constructs this file needs
# (`LIKE` prefix matching, `IS DISTINCT FROM`, `true/false` literals,
# `ON CONFLICT (…expression index…) DO NOTHING`) — all four verified present.
# sqlite's `LIKE` is ASCII-case-INSENSITIVE while Postgres's is case-SENSITIVE;
# every pattern in this seed is lowercase, so the two agree here, but a
# mixed-case pattern added later could diverge. The Postgres-only de-dup DELETE
# (ctid + DELETE…USING) is skipped and REPORTED, and any OTHER statement the
# engine cannot run is a hard failure, never a silent skip.
#
# THE REAL ENGINE (leg 1c): those caveats are why, when POSTGRES_HOST is set,
# the file is ALSO replayed VERBATIM — twice, via psql, under ON_ERROR_STOP,
# nothing translated and nothing skipped — against a real Postgres, and the
# resulting mfa_required set must agree ROW FOR ROW with the sqlite replay. CI
# always runs that leg (lint:mfa-required-rules attaches a postgres:16-alpine
# service container — the exact image the route-access initdb runs in
# production), so the dialect-sensitive semantics are proven on the engine that
# executes them, on every pipeline. A plain local run without POSTGRES_HOST
# keeps the sqlite-only posture and SAYS SO. The leg is FAIL-CLOSED: with
# POSTGRES_HOST set, an unreachable server, a missing psql or any erroring
# statement is a FAILURE, never a skip.
#
# No cluster, no docker, no network beyond the one Postgres host the CALLER
# names (unset => none at all). Checks are re-run against
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
    # FIRST per-service *superadmin* seam (#329). Same reason as its
    # /bff/wiki/admin/** sibling directly above: it lives behind the wiki-bff's
    # own service prefix, not under the two authorised blanket prefixes, so the
    # UPDATE cannot reach it without a new predicate SHAPE. Listed -- not
    # flipped -- deliberately: flipping the per-service seams is the open
    # operator decision, and this gate must keep saying so out loud.
    ("hugmesh-fe-gateway", "/bff/wiki/superadmin/**",           "ROLE_SUPERADMIN"),
}

# PER-DOMAIN MFA SCOPE (issue #47 × casdoor-choice). url_patterns an operator has
# listed in the UPDATE's per-domain arm — the seed-side convergence list for
# per-domain TIGHTENING rows (a domain-scoped sibling row outside the two blanket
# prefixes with mfa_required=true). EMPTY today: the reference mesh defines no
# per-domain tightening. Cross-checked against the arm's own IN (...) list in
# BOTH directions, exactly like DOCUMENTED_EXCLUSIONS: a surface listed in the
# SQL arm but not here (or here but not in the arm) fails the gate, so widening
# the per-domain scope is always a conscious two-place edit (plus §1.2a prose).
PER_DOMAIN_SCOPE = set()

# The gateway's own domain-scope equivalence, as the seed must spell it in the
# uq index, the INSERT's ON CONFLICT target, the de-dup DELETE and the UPDATE's
# per-domain arm (GatewayRouteAccessService.domainApplies(): NULL/blank/default
# — case-insensitive, trimmed — is ONE unscoped class; scoped compare is
# trimmed + case-insensitive).
DOMAIN_EXPR = "COALESCE(NULLIF(lower(trim(domain)), 'default'), '')"

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

# ── per-domain scope: the domain leg of the key must be the gateway's OWN scope
# equivalence, spelled identically in the index, the ON CONFLICT target and the
# de-dup DELETE — and the in-place upgrade must DROP the old lexical index first
# (IF NOT EXISTS keeps it, and then the re-applied INSERT's ON CONFLICT target
# matches no index and aborts the whole initdb), with the de-dup DELETE running
# before both so alias-duplicates are collapsed before the stricter key lands.
emit("UQ_DOMAIN_NORMALIZED", "yes" if (uq and DOMAIN_EXPR in uq) else "no")
onconf_stmt = next((s for s in STMTS if re.search(
    r"ON\s+CONFLICT\s*\(", s, re.I) and re.match(r"^\s*INSERT\b", s, re.I)), None)
onconf_m = re.search(r"ON\s+CONFLICT\s*\((.*)\)\s*DO\s+NOTHING", onconf_stmt or "", re.I | re.S)
emit("ONCONFLICT_DOMAIN_NORMALIZED",
     "yes" if (onconf_m and DOMAIN_EXPR in onconf_m.group(1)) else "no")
dedup_stmt = next((s for s in STMTS if re.search(r"\bctid\b", s, re.I)
                   and re.search(r"\bUSING\b", s, re.I)), None)
emit("DEDUP_DOMAIN_NORMALIZED",
     "yes" if (dedup_stmt
               and "COALESCE(NULLIF(lower(trim(a.domain)), 'default'), '')" in dedup_stmt
               and "COALESCE(NULLIF(lower(trim(b.domain)), 'default'), '')" in dedup_stmt)
     else "no")
drop_stmt = next((s for s in STMTS if re.match(
    r"^\s*DROP\s+INDEX\s+IF\s+EXISTS\s+uq_route_access_row\s*$", s.strip(), re.I)), None)
stmt_pos = {id(s): i for i, s in enumerate(STMTS)}
if uq and drop_stmt and dedup_stmt:
    order_ok = stmt_pos[id(dedup_stmt)] < stmt_pos[id(drop_stmt)] < stmt_pos[id(uq)]
    emit("UQ_UPGRADE_ORDER", "yes" if order_ok else "no")
else:
    emit("UQ_UPGRADE_ORDER", "no")

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

# ORDERING OF THE NULL REPAIR ITSELF, over ALL statements (not just DML — SET NOT NULL
# is DDL, so the dml-only positions above cannot see it). Postgres rejects SET NOT NULL
# outright while any row is NULL, so backfill-then-constrain is not a style preference:
# on the ONE cluster state this repair exists for (post-#136, column already nullable,
# NULLs present) the reversed order aborts initdb with
#   ERROR: column "mfa_required" of relation "gateway_route_access" contains null values
# and every later statement in the file never runs. Verified against a real Postgres 16.
SET_NOT_NULL_RE = re.compile(
    r'^ALTER\s+TABLE\s+' + TBL + r'\s+ALTER\s+COLUMN\s+mfa_required\s+SET\s+NOT\s+NULL$', re.I)
all_pos = {id(s): i for i, s in enumerate(STMTS)}
set_nn = [s for s in STMTS if SET_NOT_NULL_RE.match(flat(s))]
emit("MFA_SET_NOT_NULL_STMTS", len(set_nn))
if set_nn and backfills:
    emit("MFA_BACKFILL_BEFORE_SET_NOT_NULL",
         "yes" if max(all_pos[id(b)] for b in backfills) < min(all_pos[id(s)] for s in set_nn)
         else "no")
else:
    emit("MFA_BACKFILL_BEFORE_SET_NOT_NULL", "n/a")

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
    # The statement itself, flattened to one line: the real-engine leg (1c)
    # re-runs it after the second full replay and reads the UPDATE tag (must be 0).
    emit("RAW_FLIP", flat(up))
    # PER-DOMAIN ARM: the final OR of the predicate — domain-scoped rows on the
    # url_patterns listed in its IN (...) get the same seed convergence the two
    # blanket prefixes get. The list is cross-checked against PER_DOMAIN_SCOPE
    # in both directions so it can neither grow nor rot unnoticed.
    arm_m = re.search(
        r"OR \(" + re.escape(DOMAIN_EXPR) + r" <> '' AND url_pattern IN \(([^)]*)\)\)",
        flat(up))
    emit("UPDATE_DOMAIN_ARM", "yes" if arm_m else "no")
    arm_surfaces = set()
    if arm_m:
        arm_surfaces = {x.strip().strip("'") for x in arm_m.group(1).split(",")} - {""}
    emit("DOMAIN_ARM_SURFACES", ",".join(sorted(arm_surfaces)) if arm_surfaces else "-")
    arm_undoc = sorted(arm_surfaces - PER_DOMAIN_SCOPE)
    emit("DOMAIN_ARM_UNDOCUMENTED", len(arm_undoc))
    for a in arm_undoc:
        emit("DOMAIN_ARM_UNDOCUMENTED_ROW", a)
    arm_stale = sorted(PER_DOMAIN_SCOPE - arm_surfaces)
    emit("DOMAIN_ARM_STALE", len(arm_stale))
    for a in arm_stale:
        emit("DOMAIN_ARM_STALE_ROW", a)

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

# ─────────────────────────────────────────────────────────────────────────────
# PER-DOMAIN MFA SCOPE, proven BEHAVIOURALLY on the replayed database (issue #47
# × casdoor-choice). Staged per-domain rows are inserted through the file's OWN
# ON CONFLICT idiom, the file's DML is re-applied over them, and the verdicts
# are read back from the resulting rows — then everything is rolled back so no
# later check sees the probes. What is proven:
#   * the uniqueness key collapses exactly the gateway's unscoped equivalence
#     class ('Default' == NULL) and its scoped equivalence (case/whitespace),
#     while a genuinely scoped sibling row is ACCEPTED beside the canonical one;
#   * the blanket is DOMAIN-BLIND: a domain-scoped allow row under the two
#     prefixes ends up flipped by a re-apply exactly like its unscoped siblings
#     (a scoped false row there is a phantom exemption — decide() ORs
#     mfa_required across every granting row that domain-applies, and unscoped
#     rows apply to every domain — so converging it to true is the honest state);
#   * a per-domain TIGHTENING row outside the prefixes keeps mfa_required=true
#     across a re-apply, and its UNSCOPED twin stays false (the tightening
#     touches its own domain only).
# ─────────────────────────────────────────────────────────────────────────────
onconf_clause = onconf_m.group(0) if onconf_m else ""
pd = {"alias_default": False, "sibling_ok": False, "alias_scoped": False,
      "blanket_scoped": False, "tighten_kept": False, "tighten_scoped_only": False}
pd_err = []
con.execute("SAVEPOINT perdomain")
try:
    try:
        if not onconf_clause:
            raise RuntimeError("no ON CONFLICT clause found in the canonical INSERT")
        n0 = con.execute("SELECT count(*) FROM gateway_route_access").fetchone()[0]
        # (i) an alias-spelled "scoped" duplicate of a canonical row must collapse
        con.execute("INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain) VALUES "
                    "('hugmesh-fe-gateway', '/bff/admin/**', 'ROLE_ADMIN', true, 'Default')\n" + onconf_clause)
        pd["alias_default"] = con.execute(
            "SELECT count(*) FROM gateway_route_access").fetchone()[0] == n0
        # (ii) a genuinely scoped sibling row is accepted beside the canonical row
        con.execute("INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain) VALUES "
                    "('hugmesh-fe-gateway', '/bff/admin/phone-fleet/**', 'ROLE_FLEET_ADMIN', true, 'brand-x.example')\n" + onconf_clause)
        pd["sibling_ok"] = con.execute(
            "SELECT count(*) FROM gateway_route_access").fetchone()[0] == n0 + 1
        # (iii) a case/whitespace alias of that scoped row collides
        con.execute("INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain) VALUES "
                    "('hugmesh-fe-gateway', '/bff/admin/phone-fleet/**', 'ROLE_FLEET_ADMIN', true, ' Brand-X.Example ')\n" + onconf_clause)
        pd["alias_scoped"] = con.execute(
            "SELECT count(*) FROM gateway_route_access").fetchone()[0] == n0 + 1
        # (iv) a per-domain TIGHTENING row outside the blanket prefixes
        con.execute("INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain, mfa_required) VALUES "
                    "('hugmesh-fe-gateway', '/bff/wiki/admin/**', 'ROLE_ADMIN', true, 'brand-x.example', true)\n" + onconf_clause)
        # now RE-APPLY the whole file's DML with the per-domain rows in place
        for s in dml:
            try:
                con.execute(normalize(s))
            except Exception as e:                              # noqa: BLE001
                if not (re.search(r"\bctid\b", s, re.I) and re.search(r"\bUSING\b", s, re.I)):
                    pd_err.append("re-apply over per-domain rows: %s" % e)
        got = con.execute("SELECT mfa_required FROM gateway_route_access "
                          "WHERE domain = 'brand-x.example' AND url_pattern = '/bff/admin/phone-fleet/**'").fetchall()
        pd["blanket_scoped"] = len(got) == 1 and bool(got[0][0])
        got = con.execute("SELECT mfa_required FROM gateway_route_access "
                          "WHERE domain = 'brand-x.example' AND url_pattern = '/bff/wiki/admin/**'").fetchall()
        pd["tighten_kept"] = len(got) == 1 and bool(got[0][0])
        got = con.execute("SELECT mfa_required FROM gateway_route_access "
                          "WHERE domain IS NULL AND url_pattern = '/bff/wiki/admin/**'").fetchall()
        pd["tighten_scoped_only"] = len(got) == 1 and not got[0][0]
    except Exception as e:                                      # noqa: BLE001
        pd_err.append(str(e))
finally:
    con.execute("ROLLBACK TO perdomain")
    con.execute("RELEASE perdomain")
emit("PD_ERRORS", len(pd_err))
for e in pd_err:
    emit("PD_ERROR", e)
emit("DOMAIN_ALIAS_COLLAPSED", "yes" if pd["alias_default"] else "no")
emit("DOMAIN_SCOPED_SIBLING_OK", "yes" if pd["sibling_ok"] else "no")
emit("DOMAIN_SCOPED_ALIAS_COLLAPSED", "yes" if pd["alias_scoped"] else "no")
emit("DOMAIN_BLANKET_COVERS_SCOPED", "yes" if pd["blanket_scoped"] else "no")
emit("DOMAIN_TIGHTENING_KEPT", "yes" if pd["tighten_kept"] else "no")
emit("DOMAIN_TIGHTENING_SCOPED_ONLY", "yes" if pd["tighten_scoped_only"] else "no")

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
            elif expect == "per-domain-tightening":
                # The runbook's per-domain tightening EXAMPLE, executed for real:
                # its INSERT must land beside the unscoped canonical row, survive
                # a full seed re-apply with mfa_required=true, and leave the
                # unscoped twin false (the tightening touches its own domain only).
                con.execute("SAVEPOINT docsql")
                try:
                    for st in split_statements(body):
                        con.execute(normalize(st))
                    for st in dml:
                        try:
                            con.execute(normalize(st))
                        except Exception:                       # noqa: BLE001
                            if not (re.search(r"\bctid\b", st, re.I)
                                    and re.search(r"\bUSING\b", st, re.I)):
                                raise
                    scoped = con.execute(
                        "SELECT mfa_required FROM gateway_route_access "
                        "WHERE domain = 'brand-x.example' AND url_pattern = '/bff/wiki/admin/**'").fetchall()
                    unscoped = con.execute(
                        "SELECT mfa_required FROM gateway_route_access "
                        "WHERE domain IS NULL AND url_pattern = '/bff/wiki/admin/**'").fetchall()
                finally:
                    con.execute("ROLLBACK TO docsql")
                    con.execute("RELEASE docsql")
                if not (len(scoped) == 1 and bool(scoped[0][0])):
                    doc_bad.append("%s: the documented tightening row did not survive a "
                                   "seed re-apply as ONE mfa_required=true row (got %r)"
                                   % (name, scoped))
                elif not (len(unscoped) == 1 and not unscoped[0][0]):
                    doc_bad.append("%s: the UNSCOPED twin of the documented tightening "
                                   "surface did not stay mfa_required=false (got %r) — "
                                   "the example leaks onto other domains" % (name, unscoped))
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

case "$(g MFA_BACKFILL_BEFORE_SET_NOT_NULL)" in
  yes|n/a)
    ok "the NULL backfill runs BEFORE 'ALTER COLUMN mfa_required SET NOT NULL' ($(g MFA_SET_NOT_NULL_STMTS) such statement(s)) — Postgres rejects SET NOT NULL while any row is NULL, so the reverse order aborts initdb on the ONE cluster state this repair exists for (post-#136: column already nullable, NULLs present) and nothing after it in the file runs" ;;
  *)
    bad "'ALTER COLUMN mfa_required SET NOT NULL' runs BEFORE the NULL backfill — on a cluster whose mfa_required is already nullable with NULLs present, Postgres aborts with 'column \"mfa_required\" … contains null values' and the whole initdb fails. Move the backfill above it" ;;
esac

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
if [ -z "${POSTGRES_HOST:-}" ]; then
  echo "     (POSTGRES_HOST unset: THIS run does not execute the seed on Postgres."
  echo "      Leg 1c below is the real-engine proof; CI always runs it against a"
  echo "      postgres:16-alpine service — see the header's ENGINE CAVEAT.)"
fi

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

# ─────────────────────────────────────────────────────────────────────────────
# 1c) the REAL engine. Everything above replayed the file on a TRANSLATED sqlite
# schema; `IS DISTINCT FROM`, `ALTER COLUMN … SET NOT NULL`, the expression-index
# `ON CONFLICT … DO NOTHING` and the ctid de-dup DELETE are Postgres-dialect, and
# the engine that runs this file in production is postgres:16-alpine (the
# route-access initdb). With POSTGRES_HOST set (CI: a postgres:16-alpine service
# container; locally: any scratch server whose POSTGRES_USER may CREATE DATABASE)
# the file runs VERBATIM via psql — ON_ERROR_STOP, no translation, no skip —
# twice, and the flip set must agree ROW FOR ROW with the sqlite replay above.
# FAIL-CLOSED: an unreachable host, a missing psql or any erroring statement is a
# FAILURE, never a skip. Sort order is pinned with LC_ALL=C on BOTH sides so the
# comparison never depends on the server's collation.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
if [ -z "${POSTGRES_HOST:-}" ]; then
  echo "── 1c) REAL-ENGINE replay: NOT RUN (POSTGRES_HOST unset; CI runs this leg on postgres:16-alpine) ──"
else
  echo "── 1c) REAL-ENGINE replay (Postgres at ${POSTGRES_HOST}) ──"
  PGDB_ADMIN="${POSTGRES_DB:-postgres}"
  [ -n "${POSTGRES_PASSWORD:-}" ] && export PGPASSWORD="${POSTGRES_PASSWORD}"
  export PGCONNECT_TIMEOUT=5
  pgq() {   # pgq <db> [psql-args…] — quiet, fail-on-first-error psql
    local db="$1"; shift
    psql -X -q -v ON_ERROR_STOP=1 -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" \
         -U "${POSTGRES_USER:-postgres}" -d "${db}" "$@"
  }
  pg_fresh_replay() {   # pg_fresh_replay <db> <sql-file> — drop/create, then the file VERBATIM
    pgq "${PGDB_ADMIN}" -c "DROP DATABASE IF EXISTS $1" \
      && pgq "${PGDB_ADMIN}" -c "CREATE DATABASE $1" \
      && pgq "$1" -f "$2"
  }
  PG_FLIP_SEL="SELECT gateway || ' ' || url_pattern || ' ' || role FROM gateway_route_access WHERE mfa_required"
  PG_ALL_SEL="SELECT gateway || '|' || url_pattern || '|' || role || '|' || allow || '|' || mfa_required FROM gateway_route_access"

  if ! command -v psql >/dev/null 2>&1; then
    bad "POSTGRES_HOST=${POSTGRES_HOST} is set but psql is not installed — an engine this gate cannot reach must NOT read as a pass (install postgresql-client, or unset POSTGRES_HOST for the sqlite-only posture)"
  else
    pg_up=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      pgq "${PGDB_ADMIN}" -c 'SELECT 1' >/dev/null 2>&1 && { pg_up=1; break; }
      sleep 2
    done
    if [ -z "${pg_up}" ]; then
      bad "POSTGRES_HOST=${POSTGRES_HOST}:${POSTGRES_PORT:-5432} not reachable as ${POSTGRES_USER:-postgres} within 30s — fail-closed, never a skip"
    else
      ok "postgres reachable: server $(pgq "${PGDB_ADMIN}" -tA -c 'SHOW server_version' 2>/dev/null)"
      if ! pg_fresh_replay mfa_required_gate "${SQL}" >"${W}/pg1.log" 2>&1; then
        bad "the seed FAILED to replay verbatim on Postgres (first apply): $(tail -n 3 "${W}/pg1.log" | tr '\n' ';')"
      else
        ok "first apply: the WHOLE file ran VERBATIM under ON_ERROR_STOP — including every construct the sqlite leg translates or skips (IS DISTINCT FROM, ALTER COLUMN … SET NOT NULL, the expression-index ON CONFLICT, the ctid de-dup DELETE)"

        PG_ROWS="$(pgq mfa_required_gate -tA -c 'SELECT count(*) FROM gateway_route_access')"
        [ "${PG_ROWS}" = "$(g ROWS)" ] \
          && ok "row count on the real engine (${PG_ROWS}) equals the parsed seed — nothing dropped by the REAL expression-index ON CONFLICT, nothing deleted by the REAL ctid de-dup" \
          || bad "row count on the real engine is '${PG_ROWS}' but the file declares $(g ROWS) rows — the two engines disagree about the file's net effect"

        pgq mfa_required_gate -tA -c "${PG_FLIP_SEL}" | LC_ALL=C sort > "${W}/pg-flip"
        sed -n 's/^FLIP //p' "${W}/real.out" | LC_ALL=C sort > "${W}/sq-flip"
        PG_FLIPPED="$(grep -c . "${W}/pg-flip" || true)"
        if cmp -s "${W}/pg-flip" "${W}/sq-flip"; then
          ok "the mfa_required=true result set on the REAL engine (${PG_FLIPPED} rows) matches the sqlite replay ROW FOR ROW — the flipped set is now proven on the engine that executes the seed"
        else
          bad "the real engine's flip set DIFFERS from the sqlite replay: $(diff "${W}/sq-flip" "${W}/pg-flip" | head -n 6 | tr '\n' ';') — the dialect divergence this leg exists to catch"
        fi
        [ "${PG_FLIPPED}" -ge 9 ] \
          && ok "…and carries at least the 9 rows under /bff/admin/** + /bff/superadmin/**" \
          || bad "only ${PG_FLIPPED} row(s) are mfa_required=true on the real engine — expected at least the 9 under the two prefixes"

        pgq mfa_required_gate -tA -c "${PG_ALL_SEL}" | LC_ALL=C sort > "${W}/pg-state1"
        if ! pgq mfa_required_gate -f "${SQL}" >"${W}/pg2.log" 2>&1; then
          bad "the file FAILED on an in-place re-apply on the real engine (the path every initdb re-run takes): $(tail -n 3 "${W}/pg2.log" | tr '\n' ';')"
        else
          pgq mfa_required_gate -tA -c "${PG_ALL_SEL}" | LC_ALL=C sort > "${W}/pg-state2"
          cmp -s "${W}/pg-state1" "${W}/pg-state2" \
            && ok "re-applying the WHOLE file on the real engine converges (final state byte-identical)" \
            || bad "re-apply is NOT a no-op on the real engine: $(diff "${W}/pg-state1" "${W}/pg-state2" | head -n 4 | tr '\n' ';')"
          if [ "${HAVE_UPDATE}" = "1" ]; then
            # -q suppresses command tags, so this one call drops it and reads the tag.
            PG_TAG="$(psql -X -v ON_ERROR_STOP=1 -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" \
                       -U "${POSTGRES_USER:-postgres}" -d mfa_required_gate -c "$(g RAW_FLIP)" 2>&1 | tail -n 1)"
            [ "${PG_TAG}" = "UPDATE 0" ] \
              && ok "the seed's own flip UPDATE, run once more, tags UPDATE 0 — 'IS DISTINCT FROM true' is idempotent under the REAL engine's semantics" \
              || bad "the flip UPDATE re-run tagged '${PG_TAG}' (expected UPDATE 0) — a re-apply rewrites rows on the real engine"
          fi
        fi

        # The leg itself, proven to bite: an appended un-flip replayed on the
        # real engine must break the flip-set agreement (same mutation class as
        # the sqlite nc controls, exercised HERE so this comparison can never
        # rot into a vacuous cmp of two empty files).
        { cat "${SQL}"; echo; \
          echo "UPDATE gateway_route_access SET mfa_required = false WHERE url_pattern LIKE '/bff/superadmin%';"; } > "${W}/pg-nc.sql"
        if ! pg_fresh_replay mfa_required_gate_nc "${W}/pg-nc.sql" >"${W}/pg-nc.log" 2>&1; then
          bad "negative control: the mutated seed did not replay on Postgres, so the control proves NOTHING: $(tail -n 2 "${W}/pg-nc.log" | tr '\n' ';')"
        else
          pgq mfa_required_gate_nc -tA -c "${PG_FLIP_SEL}" | LC_ALL=C sort > "${W}/pg-nc-flip"
          if cmp -s "${W}/pg-nc-flip" "${W}/sq-flip"; then
            bad "negative control: an appended superadmin un-flip left the real-engine flip set UNCHANGED — the cross-engine comparison is vacuous"
          else
            ok "negative control: an appended superadmin un-flip breaks the real-engine flip-set agreement ($(grep -c . "${W}/pg-nc-flip" || true) rows vs $(grep -c . "${W}/sq-flip" || true)) — the comparison bites"
          fi
        fi
        pgq "${PGDB_ADMIN}" -c "DROP DATABASE IF EXISTS mfa_required_gate" >/dev/null 2>&1
        pgq "${PGDB_ADMIN}" -c "DROP DATABASE IF EXISTS mfa_required_gate_nc" >/dev/null 2>&1
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1d) PER-DOMAIN MFA SCOPE (issue #47 × casdoor-choice) — the domain key, the
#     per-domain arm of the UPDATE, and the behavioural proofs on staged rows
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── 1d) per-domain MFA scope (domain key + per-domain arm) ──"

[ "$(g UQ_DOMAIN_NORMALIZED)" = "yes" ] && [ "$(g ONCONFLICT_DOMAIN_NORMALIZED)" = "yes" ] \
  && ok "uq_route_access_row keys the domain leg on the gateway's OWN scope equivalence (COALESCE(NULLIF(lower(trim(domain)), 'default'), '')) and the INSERT's ON CONFLICT target spells it identically — domainApplies() treats NULL/blank/'default' (case-insensitive, trimmed) as ONE unscoped class, so the lexical COALESCE(domain,'') key could hold two rows the gateway cannot tell apart" \
  || bad "the domain leg of the uniqueness key is not the gateway's scope equivalence (uq=$(g UQ_DOMAIN_NORMALIZED), on_conflict=$(g ONCONFLICT_DOMAIN_NORMALIZED)) — alias-spelled duplicate rows ('Default' beside NULL) become possible, or the two spellings diverge and the re-applied INSERT aborts initdb"

[ "$(g DEDUP_DOMAIN_NORMALIZED)" = "yes" ] \
  && ok "the ctid de-dup DELETE compares the domain leg with the SAME normalization, so an in-place upgrade collapses alias-duplicates BEFORE the stricter unique index is created" \
  || bad "the ctid de-dup DELETE still compares the domain leg lexically — an upgraded cluster holding a NULL row beside a 'Default' row aborts at CREATE UNIQUE INDEX and nothing after it in the file runs"

[ "$(g UQ_UPGRADE_ORDER)" = "yes" ] \
  && ok "in-place-upgrade order is de-dup DELETE → DROP INDEX IF EXISTS uq_route_access_row → CREATE UNIQUE INDEX: the old lexical index cannot survive under the new ON CONFLICT target (which must match the index expression exactly), and the stricter key never lands on a still-duplicated table" \
  || bad "the de-dup DELETE / DROP INDEX / CREATE UNIQUE INDEX upgrade dance is missing or mis-ordered (UQ_UPGRADE_ORDER=$(g UQ_UPGRADE_ORDER)) — CREATE UNIQUE INDEX IF NOT EXISTS is a NO-OP while the old index holds the name, and then the re-applied INSERT's ON CONFLICT matches no index and aborts the whole initdb"

if [ "${HAVE_UPDATE}" = "1" ]; then
[ "$(g UPDATE_DOMAIN_ARM)" = "yes" ] \
  && ok "the flip UPDATE carries the per-domain arm (domain-scoped rows on the url_patterns it lists get the same seed convergence the two blanket prefixes get); listed surfaces today: $(g DOMAIN_ARM_SURFACES)" \
  || bad "the flip UPDATE's per-domain arm is gone — per-domain tightening rows lose their seed-side convergence (a CRUD un-flip of one silently survives every re-apply), and §1.2a's documented mechanism no longer exists in the SQL"

[ "$(g DOMAIN_ARM_UNDOCUMENTED)" = "0" ] && [ "$(g DOMAIN_ARM_STALE)" = "0" ] \
  && ok "the per-domain arm's surface list and the gate's PER_DOMAIN_SCOPE set agree in both directions (widening per-domain MFA scope is a conscious two-place edit, plus runbook §1.2a)" \
  || bad "per-domain arm vs PER_DOMAIN_SCOPE drift: $(g DOMAIN_ARM_UNDOCUMENTED) surface(s) in the SQL arm but undocumented ($(sed -n 's/^DOMAIN_ARM_UNDOCUMENTED_ROW //p' "${W}/real.out" | tr '\n' ';')), $(g DOMAIN_ARM_STALE) documented but missing from the arm ($(sed -n 's/^DOMAIN_ARM_STALE_ROW //p' "${W}/real.out" | tr '\n' ';'))"
fi

[ "$(g PD_ERRORS)" = "0" ] \
  && ok "the staged per-domain probe rows inserted through the file's OWN ON CONFLICT idiom and replayed cleanly" \
  || bad "$(g PD_ERRORS) error(s) staging the per-domain probes — the behavioural verdicts below are unreliable: $(sed -n 's/^PD_ERROR //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g DOMAIN_ALIAS_COLLAPSED)" = "yes" ] && [ "$(g DOMAIN_SCOPED_ALIAS_COLLAPSED)" = "yes" ] \
  && ok "alias spellings COLLAPSE instead of duplicating: a 'Default'-spelled twin of a canonical row is dropped by ON CONFLICT (it is unscoped to the gateway), and a case/whitespace alias of a scoped row collides with it" \
  || bad "alias spellings do NOT collapse (default-alias=$(g DOMAIN_ALIAS_COLLAPSED), scoped-alias=$(g DOMAIN_SCOPED_ALIAS_COLLAPSED)) — the table can hold rows the gateway cannot tell apart, with contradictory allow/mfa_required"

[ "$(g DOMAIN_SCOPED_SIBLING_OK)" = "yes" ] \
  && ok "a GENUINELY domain-scoped sibling row is accepted beside its unscoped canonical twin — the row shape per-domain MFA tightening needs" \
  || bad "a domain-scoped sibling row was NOT accepted beside the canonical row — the uniqueness key is over-collapsed and per-domain rows are impossible"

[ "$(g DOMAIN_BLANKET_COVERS_SCOPED)" = "yes" ] \
  && ok "the blanket is DOMAIN-BLIND: a domain-scoped allow row under the two prefixes ends up mfa_required=true after a re-apply, exactly like its unscoped siblings — a scoped false row there is a PHANTOM EXEMPTION (decide() ORs mfa_required across every granting row that domain-applies, and unscoped rows apply to every domain), so converging it true is the honest state" \
  || bad "a domain-scoped allow row under the blanket prefixes ends up mfa_required=false — the seed now manufactures phantom per-domain exemptions: the table LOOKS exempted while the gateway still enforces (or, for a scoped-only surface, an un-MFA'd per-domain admin surface ships inside the blanket)"

[ "$(g DOMAIN_TIGHTENING_KEPT)" = "yes" ] && [ "$(g DOMAIN_TIGHTENING_SCOPED_ONLY)" = "yes" ] \
  && ok "a per-domain TIGHTENING row outside the prefixes keeps mfa_required=true across a full re-apply while its UNSCOPED twin stays false — per-domain MFA scope tightens ONLY its own domain" \
  || bad "per-domain tightening broke (kept=$(g DOMAIN_TIGHTENING_KEPT), scoped_only=$(g DOMAIN_TIGHTENING_SCOPED_ONLY)) — either the seed reverts a provisioned tightening row, or the tightening leaks onto every domain via the unscoped twin"

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
  local got rc
  got="$(python3 "${W}/check.py" "${d}/s.sql" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"; rc=$?
  # An EMPTY reading is not evidence the control bit: if the checker crashed or
  # bailed early the key is simply absent, and "" != "${good}" would score a PASS.
  if [ -z "${got}" ]; then
    bad "negative control: ${name} — nc read NO ${key} row (rc=${rc}); an empty reading is not evidence the control bit"
    return
  fi
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
   'tail = "role, COALESCE(casdoor_user, %s), COALESCE(NULLIF(lower(trim(domain)), %s), %s));" % (repr(""), repr("default"), repr(""))
anchor(tail)
s = s.replace(tail, tail.replace("role, ", "role, mfa_required, ", 1), 1)'

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

# The healthy SIM_ROWS, read from the REAL run above rather than hardcoded. It was
# literally `129` here while the true count was 158, so the "(was N)" these controls
# print had been wrong for many row-additions -- still non-vacuous by luck (the
# mutated readings never happened to land on 129), but one unlucky DELETE size away
# from scoring a silent PASS on a control that never bit. Deriving it means adding a
# route row can no longer rot these two, which is exactly what #329 did to them.
HEALTHY_ROWS="$(g SIM_ROWS)"
[ -n "${HEALTHY_ROWS}" ] && [ "${HEALTHY_ROWS}" != "0" ] \
  || bad "cannot read a healthy SIM_ROWS from the real run, so the two row-count negative controls below would compare against nothing and score a vacuous PASS"

nc "an appended DELETE of flipped rows" SIM_ROWS "${HEALTHY_ROWS}" \
   's += "\nDELETE FROM gateway_route_access WHERE url_pattern LIKE %s;\n" % repr("/bff/admin/phone-fleet/%")'

nc "an appended SCHEMA-QUALIFIED DELETE that wipes every superadmin row" SIM_ROWS "${HEALTHY_ROWS}" \
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

# ── per-domain MFA scope (issue #47), proven to bite ──────────────────────────
nc "the domain key devolves to the lexical COALESCE(domain, ...) — alias rows duplicate again" DOMAIN_ALIAS_COLLAPSED yes \
   'norm = "COALESCE(NULLIF(lower(trim(domain)), %s), %s)" % (repr("default"), repr(""))
idx_tail = "COALESCE(casdoor_user, %s), %s);" % (repr(""), norm)
oc_tail  = "COALESCE(casdoor_user, %s), %s) DO NOTHING;" % (repr(""), norm)
anchor(idx_tail)
anchor(oc_tail)
lex = "COALESCE(domain, %s)" % repr("")
s = s.replace(idx_tail, idx_tail.replace(norm, lex), 1)
s = s.replace(oc_tail, oc_tail.replace(norm, lex), 1)'

nc "the blanket narrowed to unscoped rows only (a scoped row under the prefixes stays false — a phantom exemption ships)" DOMAIN_BLANKET_COVERS_SCOPED yes \
   'a = " WHERE allow = true\n   AND (url_pattern = %s" % repr("/bff/admin")
anchor(a)
s = s.replace(a, " WHERE allow = true\n   AND domain IS NULL\n   AND (url_pattern = %s" % repr("/bff/admin"), 1)'

nc "the per-domain arm removed from the UPDATE (tightening rows lose seed convergence)" UPDATE_DOMAIN_ARM yes \
   'arm = "\n     OR (COALESCE(NULLIF(lower(trim(domain)), %s), %s) <> %s\n         AND url_pattern IN (%s)))" % (repr("default"), repr(""), repr(""), repr(""))
anchor(arm)
s = s.replace(arm, ")", 1)'

nc "a surface listed in the per-domain arm without documenting it (scope widened on the sly)" DOMAIN_ARM_UNDOCUMENTED 0 \
   'a = "AND url_pattern IN (%s)))" % repr("")
anchor(a)
s = s.replace(a, "AND url_pattern IN (%s, %s)))" % (repr(""), repr("/bff/wiki/admin/**")), 1)'

nc "the DROP INDEX upgrade step removed (an upgraded cluster keeps the OLD lexical key and the re-applied INSERT aborts)" UQ_UPGRADE_ORDER yes \
   'a = "DROP INDEX IF EXISTS uq_route_access_row;\n"
anchor(a)
s = s.replace(a, "", 1)'

nc "the de-dup DELETE keeps the lexical domain compare while the index normalizes (upgrade aborts at CREATE UNIQUE INDEX)" DEDUP_DOMAIN_NORMALIZED yes \
   'a = "    AND COALESCE(NULLIF(lower(trim(a.domain)), %s), %s)\n      = COALESCE(NULLIF(lower(trim(b.domain)), %s), %s);" % (repr("default"), repr(""), repr("default"), repr(""))
anchor(a)
s = s.replace(a, "    AND COALESCE(a.domain, %s) = COALESCE(b.domain, %s);" % (repr(""), repr("")), 1)'

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
  local got rc
  got="$(python3 "${W}/check.py" "${SQL}" "${d}/doc.md" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"; rc=$?
  # An EMPTY reading is not evidence the control bit: if the checker crashed or
  # bailed early the key is simply absent, and "" != "${good}" would score a PASS.
  if [ -z "${got}" ]; then
    bad "negative control: ${name} — nd read NO ${key} row (rc=${rc}); an empty reading is not evidence the control bit"
    return
  fi
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

nd "the runbook's quoted UPDATE drifts from the seed's real one (per-domain arm dropped from the doc)" DOC_SQL_BAD 0 \
   'a = "\n     OR (COALESCE(NULLIF(lower(trim(domain)), %s), %s) <> %s\n         AND url_pattern IN (%s)))\n   AND mfa_required IS DISTINCT FROM true;" % (repr("default"), repr(""), repr(""), repr(""))
anchor(a)
s = s.replace(a, ")\n   AND mfa_required IS DISTINCT FROM true;", 1)'

nd "the runbook's per-domain tightening example loses its mfa_required=true (an example that provisions nothing)" DOC_SQL_BAD 0 \
   'a = ", %s, true)\nON CONFLICT" % repr("brand-x.example")
anchor(a)
s = s.replace(a, ", %s, false)\nON CONFLICT" % repr("brand-x.example"), 1)'

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
  # PRECONDITION, same as nc()/nd(). np() had none: its mutators are string
  # replacements against a LIVE app manifest, so an unrelated rename there
  # (extraEnv -> extraEnvVars, say) left `s` untouched, the file was rewritten
  # byte-identical, and the control then reported the POSTURE GUARD as vacuous —
  # three false statements about a different part of the system, which is the exact
  # defect class this helper exists to detect.
  if ! python3 - "${d}/apps/20-gateway-fe.yaml" >"${d}/mut.log" 2>&1 <<PY
import re, sys
p = sys.argv[1]
orig = open(p, encoding="utf-8").read()
s = orig
${mut}
assert s != orig, "the mutator produced no change at all"
open(p, "w", encoding="utf-8").write(s)
PY
  then
    bad "negative control: ${name} — its OWN PRECONDITION failed, so the mutation never ran and this control proves NOTHING (fix the control, not the check): $(tr -s ' \n' ' ' < "${d}/mut.log" | tail -c 240)"
    return
  fi
  local got rc
  got="$(python3 "${W}/posture.py" "${d}/apps" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"; rc=$?
  if [ -z "${got}" ]; then
    bad "negative control: ${name} — posture.py emitted NO ${key} row (rc=${rc}); an empty reading is not evidence the control bit"
    return
  fi
  [ "${got}" != "${good}" ] \
    && ok "negative control: ${name} -> ${key}=${got} (was ${good})" \
    || bad "negative control: ${name} was applied to the file and ${key} did NOT move (still ${good}) — the posture guard is vacuous for that shape"
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
  local got rc
  got="$(python3 "${W}/envscan.py" "${d}" "${d}/tree" 2>/dev/null | sed -n "s/^${key} //p" | head -1)"; rc=$?
  # An EMPTY reading is not evidence the control bit: if the checker crashed or
  # bailed early the key is simply absent, and "" != "${good}" would score a PASS.
  if [ -z "${got}" ]; then
    bad "negative control: ${name} — ne read NO ${key} row (rc=${rc}); an empty reading is not evidence the control bit"
    return
  fi
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
