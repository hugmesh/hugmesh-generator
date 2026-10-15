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
# ...plus the PER-SERVICE console shape added by operator decision 80b = B
# (hugmesh-generator#329): `LIKE '/bff/%/admin/%'` / `LIKE '/bff/%/superadmin/%'`.
# `%` spans ANY characters, `/` included, so these are `.*` and not `[^/]+` -- the
# model must accept exactly what the SQL accepts, no more and no less. The two
# shapes are disjoint from PREFIXES (they need a segment BETWEEN `/bff/` and
# `/admin/`), so a row can never be "under" both.
PER_SERVICE_SHAPES = (re.compile(r"^/bff/.*/admin/.*$", re.S),
                      re.compile(r"^/bff/.*/superadmin/.*$", re.S))

# Admin-ish /bff/ surfaces DELIBERATELY outside that scope. Every entry is named
# and justified in the SQL header + the runbook. This list exists so the coverage
# assertion below can enumerate admin-ish surfaces INDEPENDENTLY of the UPDATE's
# own prefixes: a NEW admin-ish surface that is neither flipped nor listed here
# FAILS the gate instead of being defined away, and a listed row that no longer
# exists (or is now flipped) fails too, so the list cannot rot into a rubber stamp.
#
# Decision 80b = B (hugmesh-generator#329, 2026-09-23) REMOVED four entries -- the
# forum, wiki-admin, wiki-superadmin and owncast console seams -- because the
# UPDATE now carries the per-service shape and flips them. They must stay OUT of
# this set: a row that is flipped AND listed here fails the STALE_EXCLUSIONS check,
# which is what makes the list impossible to leave behind. What remains is what the
# path predicate genuinely cannot (or must not) express.
DOCUMENTED_EXCLUSIONS = {
    ("hugmesh-be-gateway", "/bff/games-services/instances/**", "ROLE_GAMES_SERVICES_ADMIN"),
    ("hugmesh-be-gateway", "/bff/image-builds/arch/**",        "ROLE_SUPERADMIN"),
    ("hugmesh-fe-gateway", "/bff/mod/**",                      "ROLE_ADMIN"),
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

# ── the ROW-SCOPED mfa seed (#347 decision 28 = D) ────────────────────────────
# The seed now contains a SECOND `SET mfa_required = true` statement, and it is a
# different animal from the blanket flip: it names ONE full row identity
# (gateway + url_pattern + role + allow=false) and exists because the blanket flip
# is `WHERE allow = true` and the fe games-services row is a DENY row that must
# still carry the privileged step-up floor. Why a deny row can carry a floor at
# all: GatewayRouteAccessFilter's privileged floor calls
# GatewayRouteAccessService.isMfaRequiredSurface(), which is allow-BLIND and
# role-BLIND (it ORs mfaRequired across every rule at the longest matching
# pattern) — unlike decide(), whose D8 floor is scoped to the rows that GRANT the
# principal. Matched as a WHOLE statement, with the target captured, so it cannot
# widen into a second blanket: a `… AND allow = false OR true` or a dropped
# predicate stops matching this shape and lands in MFA_WRITE_UNEXPECTED.
ROW_SEED_TARGET = ("hugmesh-fe-gateway", "/bff/superadmin/games-services/**",
                   "ROLE_SUPERADMIN")
ROWSEED_RE = re.compile(
    r"^UPDATE\s+" + TBL + r"\s+SET\s+mfa_required\s*=\s*true\s+"
    r"WHERE\s+gateway\s*=\s*'([^']*)'\s+"
    r"AND\s+url_pattern\s*=\s*'([^']*)'\s+"
    r"AND\s+role\s*=\s*'([^']*)'\s+"
    r"AND\s+allow\s*=\s*false"
    r"(?P<idem>\s+AND\s+mfa_required\s+IS\s+DISTINCT\s+FROM\s+true)?$", re.I)
rowseeds = [s for s in mfa_writes if ROWSEED_RE.match(flat(s))]
emit("MFA_ROW_SEEDS", len(rowseeds))
rs_targets = sorted(ROWSEED_RE.match(flat(s)).group(1, 2, 3) for s in rowseeds)
emit("MFA_ROW_SEED_IDEMPOTENT",
     "yes" if rowseeds and all(ROWSEED_RE.match(flat(x)).group("idem") for x in rowseeds)
     else "no")
for t in rs_targets:
    emit("MFA_ROW_SEED_TARGET", "%s %s %s" % t)
emit("MFA_ROW_SEED_DECLARED",
     "yes" if rs_targets == [ROW_SEED_TARGET] else "no")

mfa_ups = [s for s in mfa_writes
           if re.match(r'^\s*(?:WITH\s+.*?\)\s*)?UPDATE\b', s, re.I | re.S)
           and re.search(r"mfa_required\s*=\s*true", s, re.I)
           and not ROWSEED_RE.match(flat(s))]
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
known = {id(s) for s in mfa_ups} | {id(s) for s in backfills} | {id(s) for s in rowseeds}
unexpected = [s for s in mfa_writes if id(s) not in known]
emit("MFA_WRITE_UNEXPECTED", len(unexpected))
for s in unexpected:
    emit("MFA_WRITE_UNEXPECTED_STMT", flat(s)[:110])

pos = {id(s): i for i, s in enumerate(dml)}
mfa_idx = pos[id(mfa_ups[0])] if len(mfa_ups) == 1 else -1
rowseed_idx = pos[id(rowseeds[0])] if len(rowseeds) == 1 else -1
# ORDER of the row-scoped seed relative to the blanket flip. The VALUE does not
# depend on it (the two statements touch disjoint rows: allow=false vs allow=true),
# but docs/MFA-ROLLOUT.md's `expect=identical-to-seed` block compares against the
# LAST `SET mfa_required = true` statement in the file, so the blanket flip has to
# stay last or the runbook silently starts quoting the wrong statement.
if rowseed_idx >= 0 and mfa_idx >= 0:
    emit("MFA_ROW_SEED_BEFORE_FLIP", "yes" if rowseed_idx < mfa_idx else "no")
else:
    emit("MFA_ROW_SEED_BEFORE_FLIP", "n/a")
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

def _deny_true_set():
    """(gateway, url_pattern, role) of every allow=false row currently true."""
    return {(g, p, r) for (g, p, r, a, m)
            in con.execute("SELECT gateway, url_pattern, role, allow, mfa_required "
                           "FROM gateway_route_access").fetchall()
            if m and not a}


# The BLANKET flip is `WHERE allow = true`, so it must never move a DENY row.
# Read as a BEFORE/AFTER around that one statement rather than off the final
# state: since #347 decision 28 the final state legitimately contains ONE deny row
# at true, seeded deliberately by the row-scoped UPDATE, and a final-state reading
# can no longer tell "the blanket flip reached a deny row" from "a deny row was
# seeded true on purpose". Those are different defects and only the first one is
# this check's business; DENY_TRUE_UNDECLARED below covers the second.
deny_across_flip = {"before": None, "after": None}


def replay(probe=False):
    """Run every gateway_route_access DML statement in FILE ORDER."""
    counts = []
    for _i, s in enumerate(dml):
        if probe and _i == mfa_idx:
            deny_across_flip["before"] = _deny_true_set()
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
        if probe and _i == mfa_idx:
            deny_across_flip["after"] = _deny_true_set()
    return counts

first = replay(probe=True)
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
emit("SIM_ROWSEED_CHANGES_1",
     first[rowseed_idx] if rowseed_idx >= 0 and first[rowseed_idx] is not None else -1)

# Re-apply the WHOLE file a second time: a fresh initdb and an in-place re-apply
# must converge to the identical state, and the mfa UPDATE must be a true no-op.
before = sorted(final)
second = replay()
after = sorted(con.execute(sel).fetchall())
emit("SIM_REAPPLY_STABLE", "yes" if before == after else "no")
emit("SIM_MFA_CHANGES_2", second[mfa_idx] if mfa_idx >= 0 and second[mfa_idx] is not None else -1)
emit("SIM_ROWSEED_CHANGES_2",
     second[rowseed_idx] if rowseed_idx >= 0 and second[rowseed_idx] is not None else -1)

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
                    "('hugmesh-fe-gateway', '/bff/mod/**', 'ROLE_ADMIN', true, 'brand-x.example', true)\n" + onconf_clause)
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
                          "WHERE domain = 'brand-x.example' AND url_pattern = '/bff/mod/**'").fetchall()
        pd["tighten_kept"] = len(got) == 1 and bool(got[0][0])
        got = con.execute("SELECT mfa_required FROM gateway_route_access "
                          "WHERE domain IS NULL AND url_pattern = '/bff/mod/**' AND role = 'ROLE_ADMIN'").fetchall()
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
# The two behavioural models below (_mfa_surface / _decide) are DOMAIN-BLIND: they
# rank on (gateway, url_pattern) and never transcribe
# GatewayRouteAccessService.domainApplies(). That is inert only while the seed's
# FINAL state carries no domain-scoped row — the per-domain rows this file inserts
# are inside a SAVEPOINT that is rolled back, so this must read 0. If it ever does
# not, the models silently start answering for a row the gateway would skip on
# another domain, so the gate fails instead of pretending (raised 2026-09-17 with
# the skeptic's note on the _mfa_surface transcription).
emit("DOMAIN_SCOPED_SEED_ROWS", con.execute(
    "SELECT count(*) FROM gateway_route_access "
    "WHERE COALESCE(NULLIF(lower(trim(COALESCE(domain, ''))), 'default'), '') <> ''"
).fetchone()[0])
flipped = sorted((g, p, r) for (g, p, r, a, m) in rows if m)
emit("FLIPPED", len(flipped))
for g, p, r in flipped:
    emit("FLIP", "%s %s %s" % (g, p, r))

def under(pat):
    return (any(pat == pre or pat.startswith(pre + "/") for pre in PREFIXES)
            or any(rx.match(pat) for rx in PER_SERVICE_SHAPES))

over = [t for t in flipped if not under(t[1])]
emit("OVERREACH", len(over))
for g, p, r in over:
    emit("OVERREACH_ROW", "%s %s %s" % (g, p, r))

# (a1) did the BLANKET flip itself reach a deny row? Measured across that one
# statement, so a deliberately seeded true cannot mask a broadened predicate.
_dbefore = deny_across_flip["before"]
_dafter = deny_across_flip["after"]
if _dbefore is None or _dafter is None:
    emit("DENY_FLIPPED", -1)
else:
    _by_flip = sorted(_dafter - _dbefore)
    emit("DENY_FLIPPED", len(_by_flip))
    for g, p, r in _by_flip:
        emit("DENY_FLIPPED_ROW", "%s %s %s" % (g, p, r))

# (a2) which deny rows carry the floor at the END, and are they the DECLARED ones?
# A deny row at the longest matching pattern DECIDES isMfaRequiredSurface() for its
# whole subtree (that function is allow-blind and role-blind), so a true here is a
# real posture statement in both directions: seeding one keeps the floor, and
# leaving one false removes it. Exactly one is authorised today.
DELIBERATE_DENY_MFA = {
    # #347 decision 28 = D — the games app-store control plane is DENIED at the
    # public browser door AND stays inside the privileged step-up floor.
    ("hugmesh-fe-gateway", "/bff/superadmin/games-services/**", "ROLE_SUPERADMIN"),
}
deny = sorted((g, p, r) for (g, p, r, a, m) in rows if m and not a)
emit("DENY_TRUE", len(deny))
for g, p, r in deny:
    emit("DENY_TRUE_ROW", "%s %s %s" % (g, p, r))
_undeclared = [t for t in deny if t not in DELIBERATE_DENY_MFA]
emit("DENY_TRUE_UNDECLARED", len(_undeclared))
for g, p, r in _undeclared:
    emit("DENY_TRUE_UNDECLARED_ROW", "%s %s %s" % (g, p, r))
_missing = sorted(DELIBERATE_DENY_MFA - set(deny))
emit("DENY_DECLARED_MISSING", len(_missing))
for g, p, r in _missing:
    emit("DENY_DECLARED_MISSING_ROW", "%s %s %s" % (g, p, r))

# (b) every allow row under either authorised prefix must END UP true, on EVERY
# gateway that governs it — otherwise longest-pattern-wins can decide on a false
# row. Read from the final state, so an appended un-flip is caught.
missed = sorted((g, p, r) for (g, p, r, a, m) in rows if a and under(p) and not m)
emit("PREFIX_UNFLIPPED", len(missed))
for g, p, r in missed:
    emit("PREFIX_UNFLIPPED_ROW", "%s %s %s" % (g, p, r))

# ── #244: the SUPERADMIN PLATFORM CONSOLE at the PUBLIC BROWSER DOOR ──────────
# A row with no test is a row that silently disappears. These three readings are
# BEHAVIOURAL — they replay decide() over the FINAL row state (after every
# statement in the file, including the flip UPDATE) rather than grepping the
# INSERT for a line — so deleting the row, lowering its floor, or re-porting
# 63c8952f's games-services DENY refinement each move a value here.
#
# Ranking mirrors GatewayRouteAccessService: longest MATCHING pattern wins (by
# pattern LENGTH, not specificity), deny-wins at that length, and no matching
# pattern at all is NO_RULE — which is FORWARD at the filter, not a refusal.
def _ant(pat, path):
    if pat == path:
        return True
    if pat == "/**":
        return True
    if pat.endswith("/**"):
        pre = pat[:-3]
        return path == pre or path.startswith(pre + "/")
    if "*" in pat:                      # single-segment glob, e.g. /*.js
        import fnmatch
        return fnmatch.fnmatch(path, pat) and path.count("/") == pat.count("/")
    return False

def _mfa_surface(gateway, path):
    """GatewayRouteAccessService.isMfaRequiredSurface(), transcribed.

    DELIBERATELY NOT _decide()'s mfa leg. The two functions differ and the
    difference is the whole of #347 decision 28:
      * decide() raises its D8 floor only from rows that GRANT the principal
        (`if (r.allow())` / isPublic()), so a DENY row can never raise it;
      * isMfaRequiredSurface() takes the longest matching url_pattern and returns
        true if ANY rule at that length carries mfaRequired — no allow test, no
        authority test. It is what GatewayRouteAccessFilter's PRIVILEGED floor
        calls, on both the JWT and the opaque-session branch.
    So a deny row that wins the longest match DECIDES the floor for its subtree.

    NOT transcribed: the real function's domainApplies(r, targetDomain) guard. This
    model is domain-blind, which is faithful only while the seed's final state has
    no domain-scoped row — asserted separately as DOMAIN_SCOPED_SEED_ROWS = 0, so
    the omission cannot go quiet. _decide() below has the same limitation.
    """
    best = -1
    for (g, p, r, a, m) in rows:
        if g != gateway or not _ant(p, path):
            continue
        best = max(best, len(p))
    if best < 0:
        return "no"                     # ungoverned path — no floor
    for (g, p, r, a, m) in rows:
        if g == gateway and _ant(p, path) and len(p) == best and m:
            return "yes"
    return "no"


def _decide(gateway, path, roles):
    """(verdict, mfa) as the gateway would answer, from the replayed final rows."""
    best, allow, deny, mfa = -1, False, False, False
    for (g, p, r, a, m) in rows:
        if g != gateway or not _ant(p, path):
            continue
        if len(p) > best:
            best, allow, deny, mfa = len(p), False, False, False
        if len(p) == best:
            held = (r in roles) or (r == "PUBLIC")
            if a and held:
                allow = True
            if (not a) and held:
                deny = True
            if a and m:
                mfa = True
    if best < 0:
        return "NO_RULE", "no"          # ungoverned: forwarded, and no MFA floor
    if deny or not allow:
        return "DENY", ("yes" if mfa else "no")
    return "ALLOW", ("yes" if mfa else "no")

_v, _m = _decide("hugmesh-fe-gateway", "/bff/superadmin/workloads/exec", ["ROLE_USER"])
emit("FE_SUPERADMIN_VERDICT", _v)       # DENY = governed at the door => X-Route-Denied
emit("FE_SUPERADMIN_MFA",               # yes  = the D6/D8 floor has a surface to hang on
     _mfa_surface("hugmesh-fe-gateway", "/bff/superadmin/workloads/exec"))
_v2, _m2 = _decide("hugmesh-fe-gateway", "/bff/superadmin/workloads/exec",
                   ["ROLE_SUPERADMIN"])
emit("FE_SUPERADMIN_TIER_VERDICT", _v2)  # ALLOW = the tier the row admits (rows only;
                                         # the filter's admin bypass is not modelled)
# The subtree 63c8952f's extra DENY row sits on — SEEDED since #347 decision 28=D.
# Read through isMfaRequiredSurface(), which is the function the privileged floor
# calls; decide()'s grant-scoped floor cannot see a deny row's mfa_required at all,
# and reading this through decide() is what made the row look like it had to strip
# the floor. The DENY verdict is asserted separately (and by §5b of
# test-superadmin-bff-reachability.sh); this reading is only about the floor.
_v3, _m3 = _decide("hugmesh-fe-gateway", "/bff/superadmin/games-services/catalog",
                   ["ROLE_SUPERADMIN"])
emit("FE_GAMES_SUBTREE_VERDICT", _v3)
emit("FE_GAMES_SUBTREE_MFA",
     _mfa_surface("hugmesh-fe-gateway", "/bff/superadmin/games-services/catalog"))

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
    # The runbook's `verify` block carries `WHERE allow = true` on purpose ("the
    # same predicate the flip UPDATE uses"), so it is scoped to the ALLOW rows the
    # blanket flip produces — not to every row that ends up carrying the floor.
    # Since #347 decision 28 those two sets differ by the deliberately seeded fe
    # games-services DENY row, so comparing the doc's result against ALL flipped
    # rows would fail on a doc that is correct for what it claims. The deny row is
    # not let off, THREE ways: DENY_TRUE_UNDECLARED above keeps it from hiding in
    # the seed; the runbook's own `floor` block (expect=every-floor-row, added
    # 2026-09-17) is scoped to the FLOOR rather than to the flip and must return
    # every row carrying it, deny rows included; and DOC_DENY_* below cross-checks
    # the runbook's `gate:deny-floor` table against DELIBERATE_DENY_MFA in both
    # directions. That closes what the 2026-09-17 lane left open and recorded on
    # hugmesh-generator#485: the prose said "the 10 rows ... and nothing else" while
    # ELEVEN rows carried the floor, and no gate could see the sentence.
    want_flipped = {(g, p, r) for (g, p, r, a, m) in rows if m and a}
    want_adminish = {(g, p, r) for (g, p, r, m) in adm}
    # every row that ends up carrying the privileged step-up floor, allow-blind —
    # the set isMfaRequiredSurface() actually reads (see the D8 note above).
    want_floor = {(g, p, r) for (g, p, r, a, m) in rows if m}
    for name, expect, block in DOC_RE.findall(doctext):
        doc_names.append(name)
        body = dedent(block).strip()
        # Optional 3rd argv: a directory to drop each block's body into, so the shell
        # side can compare scripts/mfa-runbook-sql.sh (what an operator actually runs)
        # against the very text this checker parsed and executed.
        if len(sys.argv) > 3 and os.path.isdir(sys.argv[3]):
            with open(os.path.join(sys.argv[3], name + ".sql"), "w", encoding="utf-8") as _bf:
                _bf.write(body + "\n")
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
            elif expect in ("flipped", "adminish", "every-floor-row"):
                got = {(r[0], r[1], r[2]) for r in
                       con.execute(normalize(body.rstrip().rstrip(";"))).fetchall()}
                want = {"flipped": want_flipped, "adminish": want_adminish,
                        "every-floor-row": want_floor}[expect]
                if got != want:
                    doc_bad.append(
                        "%s: returns %d row(s) but the prose promises the %d '%s' row(s); "
                        "missing=%s unexpected=%s"
                        % (name, len(got), len(want), expect,
                           sorted(want - got)[:4], sorted(got - want)[:4]))
            elif expect == "mfa-census":
                # The runbook's §9 privileged-operator census (admin-bff database,
                # NOT the route-access database every other block runs against), so
                # it gets its own throwaway engine with a fixture schema that mirrors
                # hugmesh-admin-bff-api changelogs 004-account.xml (account: id,
                # roles CSV) and 151-mfa-factors.xml (mfa_factor: owner_subject,
                # type TOTP|WEBAUTHN, enabled). Each fixture row is a way an operator
                # could be WRONGLY classified: a role that merely CONTAINS "admin"
                # (a substring match would pull it in), a CSV with spaces, a TOTP
                # still mid-enrol (enabled=false), a WEBAUTHN-only operator (the §2.2
                # hazard), a non-privileged user, and a factor owned by someone else.
                import sqlite3 as _sq
                ce = _sq.connect(":memory:")
                ce.executescript("""
                    CREATE TABLE account (id TEXT PRIMARY KEY, roles TEXT NOT NULL DEFAULT 'user');
                    CREATE TABLE mfa_factor (id TEXT PRIMARY KEY, owner_subject TEXT NOT NULL,
                                             type TEXT NOT NULL, enabled BOOLEAN NOT NULL DEFAULT 0);
                    INSERT INTO account VALUES
                      ('casdoor:root',        'user,superadmin'),
                      ('casdoor:adm-none',    'user,admin'),
                      ('casdoor:adm-webauthn','user,admin'),
                      ('casdoor:gm-midenrol', 'user,game-master'),
                      ('casdoor:gm-both',     'game-master'),
                      ('casdoor:sa-spaces',   'user, admin'),
                      ('casdoor:plain-mod',   'user,mod'),
                      ('casdoor:trap',        'user,administrator,superadministrator');
                    INSERT INTO mfa_factor VALUES
                      ('1','casdoor:root',        'TOTP',     1),
                      ('2','casdoor:adm-webauthn','WEBAUTHN', 1),
                      ('3','casdoor:gm-midenrol', 'TOTP',     0),
                      ('4','casdoor:gm-both',     'TOTP',     1),
                      ('5','casdoor:gm-both',     'WEBAUTHN', 1),
                      ('6','casdoor:plain-mod',   'TOTP',     1),
                      ('7','someone-else',        'TOTP',     1);
                """)
                got_c = [(r[0], r[1], bool(r[2]), bool(r[3])) for r in
                         ce.execute(body.rstrip().rstrip(";")).fetchall()]
                want_c = [
                    ("casdoor:adm-none",     "user,admin",       False, False),
                    ("casdoor:adm-webauthn", "user,admin",       False, True),
                    ("casdoor:gm-midenrol",  "user,game-master", False, False),
                    ("casdoor:sa-spaces",    "user, admin",      False, False),
                    ("casdoor:gm-both",      "game-master",      True,  True),
                    ("casdoor:root",         "user,superadmin",  True,  False),
                ]
                # ORDER matters: the runbook promises un-enrolled operators sort first.
                if got_c != want_c:
                    doc_bad.append("%s: census returned %r, expected %r (privileged accounts only, "
                                   "TOTP-less first, a mid-enrol or WebAuthn-only operator must NOT "
                                   "read as covered)" % (name, got_c, want_c))
            elif expect == "mfa-fleet-census":
                # §9 phase C5b: the PURE fleet owners (fleet_admin and none of the three
                # roles that short-circuit in the gateway), the one population that
                # mfa.enabled alone gates. Same admin-bff fixture shape as the census above
                # plus fleet_entitlement (changelog 306: subject PK, active, expires_at).
                # Each row is a way an owner could be WRONGLY classified: a fleet owner who
                # is ALSO admin / game-master / superadmin (short-circuits, not gated at
                # step 6), the LIKE wildcard '_' (fleet-admin / fleetXadmin must not match
                # fleet_admin), a SUBSTRING role (fleet_administrator), a spaced CSV, an
                # entitlement that is inactive, expired, absent, or open-ended, a TOTP still
                # mid-enrol, a WEBAUTHN-only owner, and a factor owned by someone else.
                import sqlite3 as _sq
                fe = _sq.connect(":memory:")
                fe.executescript("""
                    CREATE TABLE account (id TEXT PRIMARY KEY, roles TEXT NOT NULL DEFAULT 'user');
                    CREATE TABLE mfa_factor (id TEXT PRIMARY KEY, owner_subject TEXT NOT NULL,
                                             type TEXT NOT NULL, enabled BOOLEAN NOT NULL DEFAULT 0);
                    CREATE TABLE fleet_entitlement (subject TEXT PRIMARY KEY,
                                             active BOOLEAN NOT NULL DEFAULT 1, seats INT,
                                             expires_at TIMESTAMP, updated_at TIMESTAMP);
                    INSERT INTO account VALUES
                      ('casdoor:f-bare',      'user,fleet_admin'),
                      ('casdoor:f-totp',      'user,fleet_admin'),
                      ('casdoor:f-webauthn',  'fleet_admin'),
                      ('casdoor:f-midenrol',  'user, fleet_admin'),
                      ('casdoor:f-inactive',  'user,fleet_admin'),
                      ('casdoor:f-expired',   'user,fleet_admin'),
                      ('casdoor:f-noent',     'user,fleet_admin'),
                      ('casdoor:f-and-admin', 'user,fleet_admin,admin'),
                      ('casdoor:f-and-gm',    'user,fleet_admin,game-master'),
                      ('casdoor:f-and-super', 'fleet_admin,superadmin'),
                      ('casdoor:dash',        'user,fleet-admin'),
                      ('casdoor:wild',        'user,fleetXadmin'),
                      ('casdoor:substr',      'user,fleet_administrator'),
                      ('casdoor:plain',       'user,mod');
                    INSERT INTO mfa_factor VALUES
                      ('1','casdoor:f-totp',     'TOTP',     1),
                      ('2','casdoor:f-webauthn', 'WEBAUTHN', 1),
                      ('3','casdoor:f-midenrol', 'TOTP',     0),
                      ('4','casdoor:f-bare',     'WEBAUTHN', 0),
                      ('5','someone-else',       'TOTP',     1);
                    INSERT INTO fleet_entitlement VALUES
                      ('casdoor:f-bare',     1, 3,    NULL,                  '2026-01-01 00:00:00'),
                      ('casdoor:f-totp',     1, NULL, '2999-01-01 00:00:00', '2026-01-01 00:00:00'),
                      ('casdoor:f-webauthn', 1, NULL, '2999-01-01 00:00:00', '2026-01-01 00:00:00'),
                      ('casdoor:f-midenrol', 1, NULL, NULL,                  '2026-01-01 00:00:00'),
                      ('casdoor:f-inactive', 0, NULL, NULL,                  '2026-01-01 00:00:00'),
                      ('casdoor:f-expired',  1, NULL, '2000-01-01 00:00:00', '2026-01-01 00:00:00'),
                      ('casdoor:f-and-admin',1, NULL, NULL,                  '2026-01-01 00:00:00');
                """)
                got_f = [(r[0], bool(r[2]), bool(r[3]), bool(r[4])) for r in
                         fe.execute(body.rstrip().rstrip(";")).fetchall()]
                want_f = [
                    # un-enrolled first (totp False), entitled before un-entitled, then id
                    ("casdoor:f-bare",     False, False, True),
                    ("casdoor:f-midenrol", False, False, True),
                    ("casdoor:f-webauthn", False, True,  True),
                    ("casdoor:f-expired",  False, False, False),
                    ("casdoor:f-inactive", False, False, False),
                    ("casdoor:f-noent",    False, False, False),
                    ("casdoor:f-totp",     True,  False, True),
                ]
                if got_f != want_f:
                    doc_bad.append("%s: fleet census returned %r, expected %r (pure fleet_admin only: "
                                   "admin / game-master / superadmin co-holders, the '_' wildcard and a "
                                   "substring role must NOT match; inactive and expired entitlements "
                                   "must read entitled=false; a mid-enrol TOTP must not read as enrolled)"
                                   % (name, got_f, want_f))
            elif expect == "casdoor-token-census":
                # §9 phase C4 / §2.4: the Casdoor `token` table, shaped as casbin/casdoor
                # v3.80.0 (the tag the cluster pins) defines it. object/token_oauth.go
                # GetClientCredentialsToken stores User = application.Name (a placeholder
                # user, Type "application") and GrantType = "client_credentials"; rows
                # from before the grant_type column existed carry only the placeholder
                # user. The previous census keyed on an EMPTY user, which no
                # client_credentials row has, so it could never report a machine token.
                import sqlite3 as _sq
                te = _sq.connect(":memory:")
                te.executescript("""
                    CREATE TABLE token (owner TEXT, name TEXT, created_time TEXT,
                                        application TEXT, organization TEXT, "user" TEXT,
                                        grant_type TEXT);
                    INSERT INTO token VALUES
                      ('admin','t1','2026-08-01T10:00:00Z','app-user-bff',     'hugmesh','alice',            'password'),
                      ('admin','t2','2026-08-02T10:00:00Z','app-user-bff',     'hugmesh','bob',              ''),
                      ('admin','t3','2026-08-03T10:00:00Z','app-user-bff',     'hugmesh','app-user-bff',     'client_credentials'),
                      ('admin','t4','2026-08-04T10:00:00Z','app-user-bff',     'hugmesh','app-user-bff',     'client_credentials'),
                      ('admin','t5','2026-08-05T10:00:00Z','app-fragment-sync','hugmesh','app-fragment-sync',''),
                      ('admin','t6','2026-08-06T10:00:00Z','app-signup-gate',  'hugmesh','',                 'client_credentials'),
                      ('admin','t7','2026-08-07T10:00:00Z','app-built-in',     'built-in','admin',           'authorization_code'),
                      ('admin','t8','2026-08-08T10:00:00Z','app-built-in',     'built-in','admin',           'authorization_code');
                """)
                got_t = [tuple(r) for r in te.execute(body.rstrip().rstrip(";")).fetchall()]
                want_t = [
                    ("app-fragment-sync", "machine",    1, "2026-08-05T10:00:00Z"),  # user = app name, no grant_type (legacy row)
                    ("app-signup-gate",   "machine",    1, "2026-08-06T10:00:00Z"),  # grant_type only, empty user
                    ("app-user-bff",      "machine",    2, "2026-08-04T10:00:00Z"),  # both markers
                    ("app-built-in",      "user-bound", 2, "2026-08-08T10:00:00Z"),
                    ("app-user-bff",      "user-bound", 2, "2026-08-02T10:00:00Z"),  # same app also mints user tokens
                ]
                if got_t != want_t:
                    doc_bad.append("%s: casdoor token census returned %r, expected %r (a client_credentials "
                                   "token has user = its application name and grant_type = client_credentials; "
                                   "an EMPTY user is not how a machine token looks)" % (name, got_t, want_t))
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
                        "WHERE domain = 'brand-x.example' AND url_pattern = '/bff/mod/**'").fetchall()
                    unscoped = con.execute(
                        "SELECT mfa_required FROM gateway_route_access "
                        "WHERE domain IS NULL AND url_pattern = '/bff/mod/**' AND role = 'ROLE_ADMIN'").fetchall()
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
# ── (FIX 4b) the §1.2a EXCLUSION TABLE, cross-checked against the real list ────
# Hazard (f) again, one level up: the SQL blocks below are executed, but the §1.2a
# prose TABLE that enumerates the deliberately un-MFA'd admin surface was pure
# prose. #329 added a seventh exclusion to DOCUMENTED_EXCLUSIONS and to the SQL
# header, and the table -- the thing an operator actually reads to learn what a
# stolen session still reaches -- kept saying "Six" and omitted the most
# privileged row. The gate's own FAIL text promises the prose is checked; this is
# that promise made real. Both directions, so a stale row fails too.
doc_tbl_missing, doc_tbl_extra, doc_count_bad = [], [], []
if len(sys.argv) > 2 and os.path.isfile(sys.argv[2]):
    m = re.search(r'^###\s+1\.2a\b.*?(?=^###\s|\Z)', doctext, re.S | re.M)
    sect = m.group(0) if m else ""
    listed = set(re.findall(r'^\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|',
                            sect, re.M))
    if not sect:
        doc_count_bad.append("the runbook has no '### 1.2a' section any more — the "
                             "exclusion table this gate cross-checks is gone")
    else:
        doc_tbl_missing = sorted(DOCUMENTED_EXCLUSIONS - listed)
        doc_tbl_extra   = sorted(listed - DOCUMENTED_EXCLUSIONS)
        # the prose's own count word must equal the table it introduces
        WORDS = {"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,
                 "eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12}
        cm = re.search(r'\b([A-Za-z]+)\s+other admin-ish `/bff/` rows are', sect)
        if not cm:
            doc_count_bad.append("the '<N> other admin-ish /bff/ rows are' sentence is "
                                 "gone from §1.2a — the table's count is unverifiable")
        else:
            said = WORDS.get(cm.group(1).lower())
            if said is None:
                doc_count_bad.append("§1.2a count word %r is not a number word" % cm.group(1))
            elif said != len(DOCUMENTED_EXCLUSIONS):
                doc_count_bad.append(
                    "§1.2a prose says %s (%d) un-MFA'd admin-ish rows but "
                    "DOCUMENTED_EXCLUSIONS holds %d — the runbook is UNDER-reporting "
                    "the surface a stolen session still reaches"
                    % (cm.group(1), said, len(DOCUMENTED_EXCLUSIONS)))
# ── the runbook's DENY-FLOOR table, cross-checked against DELIBERATE_DENY_MFA ────
# A deny row at mfa_required=true is the one shape the runbook's `verify` query
# CANNOT show (that query is scoped to the flip's own `allow = true` predicate),
# and it is also the shape that decides the privileged floor for a whole subtree.
# So the runbook carries a `<!-- gate:deny-floor -->` table naming each one, and
# this is that table read back against the seed IN BOTH DIRECTIONS. Added
# 2026-09-17 (hugmesh-generator#485) after the doc was left saying "the 10 rows
# ... and nothing else" with eleven rows carrying the floor and no gate able to see
# the sentence. Prose that contradicts the seed is exactly the failure this file
# exists to make impossible.
doc_deny_missing, doc_deny_extra = [], []
doc_deny_absent = []
if len(sys.argv) > 2 and os.path.isfile(sys.argv[2]):
    dm = re.search(r'<!--\s*gate:deny-floor\s*-->\s*((?:[ \t]*\|.*\n)+)', doctext)
    if not dm:
        doc_deny_absent.append(
            "the runbook has no '<!-- gate:deny-floor -->' table any more — the deny "
            "rows that carry the privileged step-up floor are undocumented, and §5's "
            "`verify` query cannot show them")
    else:
        listed_deny = set(re.findall(
            r'^\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|',
            dm.group(1), re.M))
        doc_deny_missing = sorted(DELIBERATE_DENY_MFA - listed_deny)
        doc_deny_extra = sorted(listed_deny - DELIBERATE_DENY_MFA)
emit("DOC_DENY_ABSENT", len(doc_deny_absent))
for b in doc_deny_absent:
    emit("DOC_DENY_ABSENT_ROW", b)
emit("DOC_DENY_MISSING", len(doc_deny_missing))
for g_, p_, r_ in doc_deny_missing:
    emit("DOC_DENY_MISSING_ROW", "%s %s %s" % (g_, p_, r_))
emit("DOC_DENY_EXTRA", len(doc_deny_extra))
for g_, p_, r_ in doc_deny_extra:
    emit("DOC_DENY_EXTRA_ROW", "%s %s %s" % (g_, p_, r_))

emit("DOC_TBL_MISSING", len(doc_tbl_missing))
for g_, p_, r_ in doc_tbl_missing:
    emit("DOC_TBL_MISSING_ROW", "%s %s %s" % (g_, p_, r_))
emit("DOC_TBL_EXTRA", len(doc_tbl_extra))
for g_, p_, r_ in doc_tbl_extra:
    emit("DOC_TBL_EXTRA_ROW", "%s %s %s" % (g_, p_, r_))
emit("DOC_TBL_COUNT_BAD", len(doc_count_bad))
for b in doc_count_bad:
    emit("DOC_TBL_COUNT_BAD_ROW", b)

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
mkdir -p "${W}/docsql" && python3 "${W}/check.py" "${SQL}" "${DOC}" "${W}/docsql" > "${W}/real.out" 2>"${W}/real.err" \
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
  && ok "the only statements that write mfa_required are the single blanket flip UPDATE, $(g MFA_NULL_BACKFILLS) recognised in-place-upgrade NULL repair(s) (whole-statement shape 'SET mfa_required = false WHERE mfa_required IS NULL') and $(g MFA_ROW_SEEDS) recognised ROW-SCOPED seed(s) naming one full row identity; anything else — an appended un-flip in ANY spelling, schema-qualified, quoted or CTE-led — lands here" \
  || bad "$(g MFA_WRITE_UNEXPECTED) statement(s) write mfa_required and are neither the flip nor the exact NULL-repair shape: $(sed -n 's/^MFA_WRITE_UNEXPECTED_STMT //p' "${W}/real.out" | tr '\n' ';') — the file's NET effect is what matters (see the SIM_* checks) and an extra write is almost certainly an un-flip"

# ── #347 decision 28 = D: the ROW-SCOPED seed on the fe games-services DENY row ──
[ "$(g MFA_ROW_SEEDS)" = "1" ] && [ "$(g MFA_ROW_SEED_DECLARED)" = "yes" ] \
  && ok "exactly one ROW-SCOPED 'SET mfa_required = true' statement, and it names exactly the declared row ($(g MFA_ROW_SEED_TARGET), allow=false) — the blanket flip is 'WHERE allow = true' and can never reach a DENY row, so the fe games-services deny row would otherwise decide isMfaRequiredSurface() for its whole subtree with the floor OFF" \
  || bad "the row-scoped mfa seed is wrong: MFA_ROW_SEEDS=$(g MFA_ROW_SEEDS) declared=$(g MFA_ROW_SEED_DECLARED) target='$(g MFA_ROW_SEED_TARGET)'. Expected exactly one statement of the whole-statement shape 'UPDATE gateway_route_access SET mfa_required = true WHERE gateway=… AND url_pattern=… AND role=… AND allow = false AND mfa_required IS DISTINCT FROM true', naming hugmesh-fe-gateway /bff/superadmin/games-services/** ROLE_SUPERADMIN (#347 decision 28 = D)"

[ "$(g MFA_ROW_SEED_IDEMPOTENT)" = "yes" ] \
  && ok "…and it says so in its own text (mfa_required IS DISTINCT FROM true), so an in-place re-apply does not rewrite the row" \
  || bad "the row-scoped seed lacks 'AND mfa_required IS DISTINCT FROM true' — every in-place re-apply rewrites that row"

case "$(g MFA_ROW_SEED_BEFORE_FLIP)" in
  yes|n/a)
    ok "the row-scoped seed runs BEFORE the blanket flip, so the blanket flip stays the LAST 'SET mfa_required = true' statement in the file — which is the one docs/MFA-ROLLOUT.md's 'identical-to-seed' block quotes" ;;
  *)
    bad "the row-scoped seed runs AFTER the blanket flip: the runbook's expect=identical-to-seed comparison picks the LAST such statement, so it would silently start comparing against the row-scoped seed and the runbook's quoted UPDATE would stop being checked at all" ;;
esac

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
[ "$(g FLIPPED)" -ge 15 ] \
  && ok "AFTER the whole file runs, $(g FLIPPED) rows carry mfa_required=true: $(sed -n 's/^FLIP //p' "${W}/real.out" | tr '\n' ';' )" \
  || bad "after the whole file runs only $(g FLIPPED) rows carry mfa_required=true — expected at least the 15 rows (10 under /bff/admin/** + /bff/superadmin/**, 4 per-service admin consoles, and the 1 deliberate deny row)"

# ── #244 ACCEPT: the superadmin platform console at the PUBLIC browser door ────
# Behavioural, replayed over the FINAL rows, not a grep of the INSERT. The row is
# what moves a non-privileged caller's refusal from admin-bff (a bare 403, no
# X-Route-Denied, request already across the namespace boundary) to the gateway
# (403 WITH X-Route-Denied, logged, admin-bff never reached) — and it is what
# gives the D6/D8 step-up floor a governed surface to attach to at that door.
# NOTE what these do NOT claim: ROLE_ADMIN and ROLE_SUPERADMIN short-circuit in
# GatewayRouteAccessFilter BEFORE decide() runs, so no row here changes what a
# privileged principal reaches. This is the TABLE's verdict, not the filter's.
[ "$(g FE_SUPERADMIN_VERDICT)" = "DENY" ] \
  && ok "a plain ROLE_USER at hugmesh-fe-gateway /bff/superadmin/workloads/exec is DENY — governed-but-ungranted AT THE DOOR, so the 403 carries X-Route-Denied and admin-bff is never reached (before #244's row this read NO_RULE: forwarded, refused app-side, no header)" \
  || bad "the fe-gateway browser door for /bff/superadmin/** reads $(g FE_SUPERADMIN_VERDICT) for a plain ROLE_USER, not DENY — NO_RULE means the prefix is UNGOVERNED at the public door again and the refusal has fallen back to admin-bff with no X-Route-Denied header (#244)"

[ "$(g FE_SUPERADMIN_TIER_VERDICT)" = "ALLOW" ] \
  && ok "…and the tier the row admits at that door is ROLE_SUPERADMIN (rows alone; the filter's admin bypass is deliberately not modelled)" \
  || bad "the fe-gateway /bff/superadmin/** row does not admit ROLE_SUPERADMIN ($(g FE_SUPERADMIN_TIER_VERDICT)) — the floor has been raised past its own tier, so the console is unreachable at the public door by rows"

[ "$(g FE_SUPERADMIN_MFA)" = "yes" ] \
  && ok "…and the DECIDING row at that door carries mfa_required=true, so the privileged step-up floor can fire there once APP_MFA_ENFORCE_PRIVILEGED_FLOOR goes true — the gain #244 was answered ACCEPT for (isMfaRequiredSurface() returns false for an ungoverned path, which is what it was before)" \
  || bad "the deciding row at hugmesh-fe-gateway /bff/superadmin/workloads/exec is mfa_required=false — the step-up floor cannot fire on the superadmin surface at the public door, which is the one thing #244's ACCEPT buys"

[ "$(g FE_GAMES_SUBTREE_MFA)" = "yes" ] && [ "$(g FE_GAMES_SUBTREE_VERDICT)" = "DENY" ] \
  && ok "…and the games-services SUBTREE is BOTH walled and floored (#347 decision 28 = D): the seeded fe DENY row wins the longest match, so /bff/superadmin/games-services/catalog is DENY at the public browser door, and because the row itself carries mfa_required=true the privileged step-up floor still applies to that subtree. Read through isMfaRequiredSurface() (allow-blind, role-blind, ORs over the longest-pattern set), which is the function GatewayRouteAccessFilter's privileged floor calls — decide()'s D8 floor is grant-scoped and cannot see a deny row's flag at all" \
  || bad "the games-services subtree at hugmesh-fe-gateway is verdict=$(g FE_GAMES_SUBTREE_VERDICT) floor=$(g FE_GAMES_SUBTREE_MFA), expected DENY + yes. DENY comes from the seeded fe '/bff/superadmin/games-services/**' allow=false row; the floor comes from that SAME row carrying mfa_required=true, which the blanket flip cannot give it ('WHERE allow = true') — it is the row-scoped seed's job. Losing either one reverts #347 decision 28 = D"

[ "$(g PREFIX_UNFLIPPED)" = "0" ] \
  && ok "EVERY allow row under /bff/admin/** and /bff/superadmin/** ends up true — no longer sub-path row is left as a false deciding rule (longest-pattern-wins bypass), and nothing later in the file un-flips one" \
  || bad "$(g PREFIX_UNFLIPPED) allow row(s) under the two prefixes end up mfa_required=false, so decide() can settle on a false rule: $(sed -n 's/^PREFIX_UNFLIPPED_ROW //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g OVERREACH)" = "0" ] \
  && ok "nothing outside the two prefixes ends up flipped" \
  || bad "$(g OVERREACH) row(s) outside /bff/admin + /bff/superadmin ended up flipped: $(sed -n 's/^OVERREACH_ROW //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g DENY_FLIPPED)" = "0" ] \
  && ok "the BLANKET flip moved no allow=false (DENY) row — measured BEFORE/AFTER that one statement, not off the final state, because since #347 decision 28 the final state legitimately holds one deliberately-seeded deny row at true and a final-state reading could no longer tell the two apart" \
  || bad "$(g DENY_FLIPPED) DENY row(s) were flipped BY THE BLANKET UPDATE (its 'WHERE allow = true' arm is gone or broken): $(sed -n 's/^DENY_FLIPPED_ROW //p' "${W}/real.out" | tr '\n' ';')"

[ "$(g DENY_TRUE_UNDECLARED)" = "0" ] && [ "$(g DENY_DECLARED_MISSING)" = "0" ] \
  && ok "the deny rows carrying mfa_required=true are EXACTLY the declared set ($(g DENY_TRUE) row(s): $(sed -n 's/^DENY_TRUE_ROW //p' "${W}/real.out" | tr '\n' ';')). This is not cosmetic: isMfaRequiredSurface() is allow-blind and role-blind, so a deny row at the longest matching pattern DECIDES the privileged step-up floor for its whole subtree — an undeclared true silently raises a floor, and a declared one gone missing silently drops it" \
  || bad "the deny rows at mfa_required=true are not the declared set — undeclared: $(sed -n 's/^DENY_TRUE_UNDECLARED_ROW //p' "${W}/real.out" | tr '\n' ';') / declared-but-absent: $(sed -n 's/^DENY_DECLARED_MISSING_ROW //p' "${W}/real.out" | tr '\n' ';'). A deny row wins the longest match, and isMfaRequiredSurface() ignores allow and role, so each of these moves the privileged floor for a whole subtree. Add it to DELIBERATE_DENY_MFA with the decision that authorised it, or take the true off the row"

[ "$(( $(g SIM_MFA_CHANGES_1) + $(g SIM_ROWSEED_CHANGES_1) ))" = "$(g FLIPPED)" ] \
  && ok "the two authorised writers account for EVERY true row on the first apply: the blanket flip changed $(g SIM_MFA_CHANGES_1) and the row-scoped seed changed $(g SIM_ROWSEED_CHANGES_1), summing to the $(g FLIPPED) that end up true — no third statement contributes" \
  || bad "the blanket flip changed $(g SIM_MFA_CHANGES_1) rows and the row-scoped seed $(g SIM_ROWSEED_CHANGES_1), but $(g FLIPPED) end up true — another statement is also writing the column"

[ "$(g SIM_ROWSEED_CHANGES_1)" = "1" ] \
  && ok "the row-scoped seed changes exactly ONE row on the first apply — it is a row-scoped write in effect, not just in spelling" \
  || bad "the row-scoped seed changed $(g SIM_ROWSEED_CHANGES_1) row(s) on the first apply, not 1: 0 means it matches nothing (the row it names is absent or already true by some other route) and >1 means it is a second blanket"

[ "$(g SIM_MFA_CHANGES_2)" = "0" ] && [ "$(g SIM_ROWSEED_CHANGES_2)" = "0" ] && [ "$(g SIM_REAPPLY_STABLE)" = "yes" ] \
  && ok "re-applying the WHOLE file is a genuine no-op: the blanket flip and the row-scoped seed each change 0 rows the second time and the final state is byte-identical" \
  || bad "re-applying the file is NOT a no-op (blanket flip rewrote $(g SIM_MFA_CHANGES_2) rows and the row-scoped seed $(g SIM_ROWSEED_CHANGES_2) on the 2nd apply, state_stable=$(g SIM_REAPPLY_STABLE)) — an in-place cluster upgrade would not converge"

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

[ "$(g DOMAIN_SCOPED_SEED_ROWS)" = "0" ] \
  && ok "the seed's final state carries no domain-scoped row, so this gate's two behavioural models (isMfaRequiredSurface and decide, both domain-BLIND) answer for every row they rank — the omitted domainApplies() guard cannot change a reading" \
  || bad "$(g DOMAIN_SCOPED_SEED_ROWS) domain-scoped row(s) are in the seed's FINAL state, and this gate's behavioural models do not transcribe GatewayRouteAccessService.domainApplies() — every FE_*_MFA / *_VERDICT reading below is now answering for a row the real gateway would skip on another domain. Transcribe the domain guard into _mfa_surface()/_decide() before trusting them"

# ── (FIX 4) coverage of the admin surface, enumerated INDEPENDENTLY ────────────
[ "$(g ADMINISH_UNCOVERED)" = "0" ] \
  && ok "$(g ADMINISH) admin-ish /bff/ allow rows exist (enumerated independently: a path segment 'admin'/'superadmin', OR a ROLE_SUPERADMIN/*_ADMIN role); each is either flipped or one of the $(g EXCLUSIONS_DOCUMENTED) exclusions named in the SQL header + runbook §1.2a" \
  || bad "$(g ADMINISH_UNCOVERED) admin-ish /bff/ surface(s) are neither flipped nor a DOCUMENTED exclusion: $(sed -n 's/^ADMINISH_UNCOVERED_ROW //p' "${W}/real.out" | tr '\n' ';') — either widen the predicate or add them to DOCUMENTED_EXCLUSIONS *and* to the prose, so the docs never claim more coverage than exists"

# ── (FIX 4b) the runbook table must name exactly the documented exclusions ─────
[ "$(g DOC_TBL_MISSING)" = "0" ] && [ "$(g DOC_TBL_EXTRA)" = "0" ] && [ "$(g DOC_TBL_COUNT_BAD)" = "0" ] \
  && ok "runbook §1.2a lists exactly the $(g EXCLUSIONS_DOCUMENTED) documented exclusions, and its count word agrees — the operator-facing table cannot under-report the un-MFA'd admin surface" \
  || bad "runbook §1.2a has DRIFTED from DOCUMENTED_EXCLUSIONS: missing=$(sed -n 's/^DOC_TBL_MISSING_ROW //p' "${W}/real.out" | tr '\n' ';') extra=$(sed -n 's/^DOC_TBL_EXTRA_ROW //p' "${W}/real.out" | tr '\n' ';') count=$(sed -n 's/^DOC_TBL_COUNT_BAD_ROW //p' "${W}/real.out" | tr '\n' ';') — docs/MFA-ROLLOUT.md is the operator runbook; a row missing from that table is a privileged surface an operator believes is covered and is not"

# ── the runbook's DENY-FLOOR table must name exactly the declared deny rows ────
# §5's `verify` query is scoped to `allow = true` (the flip's own predicate), so a
# deny row carrying the floor is INVISIBLE to it by construction. That is legitimate
# — and it is why the row must be written down somewhere an operator reads. This
# pins the runbook's `gate:deny-floor` table to DELIBERATE_DENY_MFA in both
# directions, so neither the table nor the seed can move without the other.
[ "$(g DOC_DENY_ABSENT)" = "0" ] && [ "$(g DOC_DENY_MISSING)" = "0" ] && [ "$(g DOC_DENY_EXTRA)" = "0" ] \
  && ok "runbook §5's deny-floor table names exactly the $(g DENY_TRUE) deny row(s) that carry the privileged step-up floor — the rows the §5 'verify' query cannot show, because it is scoped to the flip's own allow = true predicate" \
  || bad "the runbook's deny-floor record has DRIFTED from DELIBERATE_DENY_MFA: absent=$(sed -n 's/^DOC_DENY_ABSENT_ROW //p' "${W}/real.out" | tr '\n' ';') missing=$(sed -n 's/^DOC_DENY_MISSING_ROW //p' "${W}/real.out" | tr '\n' ';') extra=$(sed -n 's/^DOC_DENY_EXTRA_ROW //p' "${W}/real.out" | tr '\n' ';') — a deny row at mfa_required=true decides the floor for a whole subtree and §5's verify query cannot show it, so an operator who cannot read it in the table cannot audit it at all"

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
[ "$(g DOC_SQL_BLOCKS)" -ge 5 ] \
  && ok "the runbook marks $(g DOC_SQL_BLOCKS) SQL blocks for execution ($(g DOC_SQL_NAMES)); each is RUN against the replayed database rather than eyeballed" \
  || bad "only $(g DOC_SQL_BLOCKS) '<!-- gate:doc-sql -->' block(s) found in ${DOC} — the runbook's operator queries are back to being unverified prose"

# The `floor` block is the one an operator uses to audit the step-up floor itself
# rather than the flip, and it is the ONLY marked query that can show a deny row
# carrying the floor. Losing it silently would take the runbook back to 2026-09-17,
# when §5 said "the 10 rows ... and nothing else" and eleven rows carried the floor.
case ",$(g DOC_SQL_NAMES)," in
  *,floor,*) ok "the runbook still carries the 'floor' query (expect=every-floor-row) — the only marked query scoped to the floor rather than to the flip, and the only one that can show a DENY row carrying it" ;;
  *) bad "the runbook's 'floor' query is GONE (names: $(g DOC_SQL_NAMES)) — §5's remaining queries are all scoped to 'allow = true', so an operator auditing the step-up floor would see 10 of the $(g DENY_TRUE)+10 rows that carry it and conclude the floor is off for the missing subtree" ;;
esac

[ "$(g DOC_SQL_BAD)" = "0" ] \
  && ok "every marked runbook query returns exactly what the prose around it promises (a previous revision told operators that LIKE '/bff/%admin%' 'also returns the six rows that are false by design' — run for real it returns THREE of the six, because the other three have no 'admin' substring in url_pattern)" \
  || bad "$(g DOC_SQL_BAD) runbook SQL block(s) do not do what the prose says: $(sed -n 's/^DOC_SQL_BAD_ROW //p' "${W}/real.out" | tr '\n' ';')"


# ── §9 operator checklist: the census block, the helper, and the posture-suite list ──
# docs/MFA-ROLLOUT.md §9 is what the operator runs on a real cluster. Three things in it
# are checkable here without one, and each had no gate before:
#   (1) the `census` query (privileged accounts vs enabled TOTP factors) — executed above
#       against a fixture schema (expect=mfa-census); here we only require it to EXIST,
#       because a deleted census silently takes §9 phase C5 back to "go and look";
#   (2) scripts/mfa-runbook-sql.sh, the thing an operator pipes the runbook's SQL through,
#       must print every marked block BYTE-FOR-BYTE as this gate parsed it — otherwise the
#       "executed by the gate" claim stops transferring to the cluster;
#   (3) §3 steps 6/7 and §9 must name EVERY suite that pins the cluster-OFF posture. The
#       2026-10-14 measurement found the runbook naming one of the three that go red when
#       the chart default flips; this makes the list a checked fact, and the discovery
#       below catches a FOURTH such suite being added without the runbook learning of it.
case ",$(g DOC_SQL_NAMES)," in
  *,census,*) ok "the runbook still carries the §9 'census' query (expect=mfa-census) — privileged accounts vs ENABLED TOTP factors, run for real against a fixture schema" ;;
  *) bad "the runbook's 'census' query is GONE (names: $(g DOC_SQL_NAMES)) — §9 phase C5 has no command for 'every privileged operator has a working second factor'" ;;
esac

HELPER="${REPO}/scripts/mfa-runbook-sql.sh"
if [ ! -f "${HELPER}" ]; then
  bad "scripts/mfa-runbook-sql.sh is missing — §9 tells the operator to pipe the runbook's SQL through it"
else
  list_got="$(bash "${HELPER}" --list 2>/dev/null | paste -sd, -)"
  [ "${list_got}" = "$(g DOC_SQL_NAMES)" ] \
    && ok "scripts/mfa-runbook-sql.sh --list names exactly the blocks this gate executes (${list_got})" \
    || bad "scripts/mfa-runbook-sql.sh --list says '${list_got}' but the gate executes '$(g DOC_SQL_NAMES)'"
  helper_bad=""; helper_n=0
  for f in "${W}/docsql/"*.sql; do
    n="$(basename "${f}" .sql)"; helper_n=$((helper_n+1))
    bash "${HELPER}" "${n}" 2>/dev/null | cmp -s - "${f}" || helper_bad="${helper_bad} ${n}"
  done
  [ "${helper_n}" = "$(g DOC_SQL_BLOCKS)" ] \
    && ok "the gate dumped all ${helper_n} runbook SQL block bodies for the byte comparison" \
    || bad "the gate dumped ${helper_n} block bodies but the runbook marks $(g DOC_SQL_BLOCKS) — the byte comparison below is not covering every block"
  [ -z "${helper_bad}" ] \
    && ok "scripts/mfa-runbook-sql.sh prints every marked block byte-for-byte as the gate parsed and executed it" \
    || bad "scripts/mfa-runbook-sql.sh output differs from the gate's parse for:${helper_bad} — an operator would run text the gate never proved"
  hn_out="$(bash "${HELPER}" no-such-block 2>/dev/null)"; hn_rc=$?
  [ "${hn_rc}" -ne 0 ] && [ -z "${hn_out}" ] \
    && ok "the helper fails closed on an unknown block name (rc=${hn_rc}, nothing on stdout, so a pipe into psql runs nothing)" \
    || bad "the helper answered an unknown block name with rc=${hn_rc} and stdout '${hn_out}' — a pipe into psql would run it"
  he_out="$(bash "${HELPER}" 2>/dev/null)"; he_rc=$?
  [ "${he_rc}" -ne 0 ] && [ -z "${he_out}" ] \
    && ok "the helper fails closed on no argument (rc=${he_rc})" \
    || bad "the helper accepted no argument (rc=${he_rc}, stdout '${he_out}')"
fi

# The suites that hard-code the cluster-OFF posture. Declared by hand AND re-discovered
# from the tree: a test script that mentions `mfa.enabled` and the shared gateway chart is
# presumed to pin it. NOT_POSTURE_SUITES records the reviewed exceptions, with the reason.
POSTURE_SUITES="tests/stack/test-gateway-mfa-env.sh tests/scripts/test-mfa-required-rules.sh tests/stack/test-mfa-flip-wiring.sh"
# test-kind-tor.sh only builds a fixture whose helm parameters include mfa.enabled; it asserts nothing about the chart default.
NOT_POSTURE_SUITES="tests/scripts/test-kind-tor.sh"
posture_discovered() { # <repo-root> -> relative paths of suites that look like posture pins
  ( cd "$1" && grep -rlE 'mfa\.enabled' tests --include='test-*.sh' 2>/dev/null \
      | while read -r f; do grep -qE 'charts/hugmesh-gateway|hugmesh-gateway/values\.yaml' "$f" && echo "$f"; done ) | sort
}
posture_undeclared() { # <repo-root> -> discovered suites that are neither declared nor reviewed-exempt
  local f; for f in $(posture_discovered "$1"); do
    case " ${POSTURE_SUITES} ${NOT_POSTURE_SUITES} " in *" ${f} "*) ;; *) echo "${f}" ;; esac
  done
}
posture_missing_files() { local f; for f in ${POSTURE_SUITES}; do [ -f "$1/${f}" ] || echo "${f}"; done; }
posture_doc_gaps() { # <doc> -> "<where>:<suite basename>" for each declared suite the runbook fails to name
  local doc="$1" f b s6 s9
  s6="$(sed -n '/^6\. \*\*Turn on/,/^### 3\.1/p' "${doc}")"
  s9="$(sed -n '/^## 9\. /,$p' "${doc}")"
  for f in ${POSTURE_SUITES}; do
    b="$(basename "${f}")"
    # a TABLE ROW (the lockstep tables), not just the name somewhere in the range: prose
    # that mentions a suite does not tell the flip commit what to move in it
    printf '%s' "${s6}" | grep -E '^[[:space:]]*\|.*'"${b//./\\.}" >/dev/null || echo "step6/7:${b}"
    printf '%s' "${s9}" | grep -F "${b}" >/dev/null || echo "section9:${b}"
  done
}
miss="$(posture_missing_files "${REPO}")"
[ -z "${miss}" ] \
  && ok "every declared posture suite exists ($(echo ${POSTURE_SUITES} | wc -w) suites)" \
  || bad "declared posture suite(s) missing from the tree: ${miss}"
und="$(posture_undeclared "${REPO}")"
[ -z "${und}" ] \
  && ok "no OTHER test suite looks like a cluster-posture pin (found by scanning tests/ for mfa.enabled + the shared gateway chart)" \
  || bad "suite(s) that look like cluster-posture pins are not in this gate's POSTURE_SUITES list, so the runbook cannot be naming them: ${und}"
gaps="$(posture_doc_gaps "${DOC}")"
[ -z "${gaps}" ] \
  && ok "runbook §3 steps 6-7 and §9 name every posture suite a cluster flip has to move" \
  || bad "the runbook does not name posture suite(s) a flip turns red: $(echo ${gaps})"


# ── §9 structure the first review found wrong: the census blocks exist, the break-glass
#    cannot commit before it is read, and nothing assumes the opt-in root Application ──
case ",$(g DOC_SQL_NAMES)," in
  *,fleet-census,*) ok "the runbook still carries the §9 'fleet-census' query (expect=mfa-fleet-census) — the pure fleet owners step 6 alone gates" ;;
  *) bad "the runbook's 'fleet-census' query is GONE (names: $(g DOC_SQL_NAMES)) — §9 C5b, the only pre-flight for the population step 6 changes, has no command" ;;
esac
case ",$(g DOC_SQL_NAMES)," in
  *,casdoor-machine-census,*) ok "the runbook still carries the 'casdoor-machine-census' query (expect=casdoor-token-census)" ;;
  *) bad "the runbook's 'casdoor-machine-census' query is GONE (names: $(g DOC_SQL_NAMES)) — §2.4/C4 has no empirical machine-token check" ;;
esac
cat > "${W}/s9pins.py" <<'PY'
import re, sys
doc = open(sys.argv[1], encoding="utf-8").read()
a = doc.find("\n## 9. ")
if a < 0:
    print("NO_SECTION_9"); sys.exit(0)
s9 = doc[a:]
bad = []
fences = re.findall(r"```[a-z]*\n(.*?)```", s9, re.S)
deletes = [f for f in fences if re.search(r"\bDELETE\s+FROM\b", f)]
if not deletes:
    bad.append("no fenced DELETE block in section 9 (the break-glass is gone)")
# the read step the dry run is compared against: a SELECT-only block counting the three tables
if not [f for f in fences if re.search(r"\bSELECT\b", f) and "mfa_recovery_code" in f and "webauthn_credential" in f and not re.search(r"\bDELETE\b", f)]:
    bad.append("no SELECT-only section 9 block counts the break-glass rows (the G1 look-first step is gone)")
for f in deletes:
    if re.search(r"\bSELECT\b", f):
        bad.append("a section 9 block both SELECTs and DELETEs in one input (a piped heredoc cannot be read before it commits)")
    if re.search(r"\bCOMMIT\s*;", f):
        bad.append("a section 9 DELETE block ships ending in COMMIT (the shipped form must be the ROLLBACK dry run)")
    if not re.search(r"\bROLLBACK\s*;", f):
        bad.append("a section 9 DELETE block has no ROLLBACK (the shipped form must be the dry run)")
# the opt-in root: every command that patches hugmesh-root says so, the read is tolerant of its absence
for ln in s9.split("\n"):
    if re.search(r"(patch|get)\s+app(lication)?\s+hugmesh-root\b", ln) and "root only" not in ln and "--ignore-not-found" not in ln:
        bad.append("section 9 command on hugmesh-root without 'root only' / --ignore-not-found: " + ln.strip()[:90])
if "HUGMESH_GITOPS_ROOT_RECURSE" not in s9:
    bad.append("section 9 never says the recursing root is opt-in (HUGMESH_GITOPS_ROOT_RECURSE)")
if not re.search(r"get application hugmesh-root --ignore-not-found", s9):
    bad.append("section 9 phase B does not detect whether hugmesh-root exists")
print("\n".join(bad) if bad else "OK")
PY
s9_gaps() { python3 "${W}/s9pins.py" "$1"; }
r9="$(s9_gaps "${DOC}")"
[ "${r9}" = "OK" ] \
  && ok "§9: the break-glass DELETE ships as a ROLLBACK dry run in its own block (no SELECT beside it), and every hugmesh-root command is marked root-only or tolerant of its absence" \
  || bad "§9 structure: ${r9}"
# the premise those pins rest on, read from the manifests rather than assumed
grep -qi 'OPT-IN' "${REPO}/specs/cluster/app-of-apps.yaml" \
  && grep -q 'HUGMESH_GITOPS_ROOT_RECURSE:-0' "${REPO}/specs/cluster/bootstrap/bootstrap.sh" \
  && ok "premise of the root-only wording: app-of-apps.yaml is still the OPT-IN root and bootstrap.sh still applies it only under HUGMESH_GITOPS_ROOT_RECURSE=1" \
  || bad "the recursing root is no longer opt-in (app-of-apps.yaml / bootstrap.sh changed): §3 step 7, §6 and §9 phases B, E-bypass and G say a default cluster has no hugmesh-root"

# ── …and each of those proven to bite on a corrupted copy ────────────────────
echo ""
echo "── 2c) negative controls (§9 checklist) ──"
nc9="${W}/nc9"; rm -rf "${nc9}"; mkdir -p "${nc9}/tests/stack"
# (a) the runbook stops naming one posture suite in steps 6-7
python3 - "${DOC}" "${nc9}/doc-noname.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = s.index("6. **Turn on `APP_MFA_ENABLED`")
b = s.index("### 3.1 ")
seg = s[a:b]
assert "test-mfa-flip-wiring.sh" in seg
open(sys.argv[2], "w", encoding="utf-8").write(s[:a] + seg.replace("test-mfa-flip-wiring.sh", "the-third-suite") + s[b:])
PY
g1="$(posture_doc_gaps "${nc9}/doc-noname.md")"
case "${g1}" in *"step6/7:test-mfa-flip-wiring.sh"*) ok "negative control: runbook step 6-7 text no longer naming test-mfa-flip-wiring.sh -> reported (${g1})" ;;
  *) bad "negative control: dropping a suite name from steps 6-7 was NOT reported (got '${g1}') — the doc pin is vacuous" ;; esac
# (b) §9 stops naming one
python3 - "${DOC}" "${nc9}/doc-no9.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = s.index("## 9. ")
seg = s[a:]
assert "test-gateway-mfa-env.sh" in seg
open(sys.argv[2], "w", encoding="utf-8").write(s[:a] + seg.replace("test-gateway-mfa-env.sh", "the-first-suite"))
PY
g2="$(posture_doc_gaps "${nc9}/doc-no9.md")"
case "${g2}" in *"section9:test-gateway-mfa-env.sh"*) ok "negative control: §9 no longer naming test-gateway-mfa-env.sh -> reported (${g2})" ;;
  *) bad "negative control: dropping a suite name from §9 was NOT reported (got '${g2}')" ;; esac
# (c) a FOURTH suite that pins the chart default appears
printf '#!/usr/bin/env bash\ngrep -q "enabled: false" specs/cluster/charts/hugmesh-gateway/values.yaml # mfa.enabled pin\n' > "${nc9}/tests/stack/test-new-posture-pin.sh"
u3="$(posture_undeclared "${nc9}")"
[ "${u3}" = "tests/stack/test-new-posture-pin.sh" ] \
  && ok "negative control: a new suite pinning mfa.enabled against the shared chart -> reported as undeclared (${u3})" \
  || bad "negative control: a new posture-pinning suite was NOT discovered (got '${u3}') — the discovery is vacuous"
# (d) the discovery does not cry wolf on a suite that only MENTIONS mfa.enabled
printf '#!/usr/bin/env bash\necho "mfa.enabled is documented elsewhere"\n' > "${nc9}/tests/stack/test-unrelated.sh"
u4="$(posture_undeclared "${nc9}")"
[ "${u4}" = "tests/stack/test-new-posture-pin.sh" ] \
  && ok "negative control (other direction): a suite that merely mentions mfa.enabled, with no gateway chart, stays silent" \
  || bad "negative control (other direction): discovery flagged '${u4}' — it cries wolf on an unrelated suite"
# (e) the declared suites disappear
m5="$(posture_missing_files "${nc9}" | wc -l)"
[ "${m5}" = "3" ] \
  && ok "negative control: a tree carrying none of the declared posture suites -> all 3 reported missing" \
  || bad "negative control: posture_missing_files reported ${m5} of 3 on an empty tree"
# (f) the helper against a runbook with a DUPLICATED block name, with no blocks, and unreadable
python3 - "${DOC}" "${nc9}/doc-dup.md" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'<!--\s*gate:doc-sql\s+name=floor\s+expect=every-floor-row\s*-->', s)
assert m
dup = s[:m.start()] + s[m.start():m.end()].replace("name=floor", "name=verify") + s[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(dup)
PY
d_out="$(MFA_RUNBOOK="${nc9}/doc-dup.md" bash "${HELPER}" verify 2>/dev/null)"; d_rc=$?
[ "${d_rc}" -ne 0 ] && [ -z "${d_out}" ] \
  && ok "negative control: the helper refuses a runbook with two blocks of the same name (rc=${d_rc}, stdout empty)" \
  || bad "negative control: the helper ran an AMBIGUOUS block (rc=${d_rc}, stdout $(printf '%s' "${d_out}" | wc -c) bytes)"
printf '# no blocks here\n' > "${nc9}/doc-empty.md"
e_out="$(MFA_RUNBOOK="${nc9}/doc-empty.md" bash "${HELPER}" floor 2>/dev/null)"; e_rc=$?
[ "${e_rc}" -ne 0 ] && [ -z "${e_out}" ] \
  && ok "negative control: the helper refuses a runbook with no marked blocks (rc=${e_rc})" \
  || bad "negative control: the helper answered a block-less runbook (rc=${e_rc}, stdout '${e_out}')"
u_out="$(MFA_RUNBOOK="${nc9}/does-not-exist.md" bash "${HELPER}" floor 2>/dev/null)"; u_rc=$?
[ "${u_rc}" -ne 0 ] && [ -z "${u_out}" ] \
  && ok "negative control: the helper refuses an unreadable runbook (rc=${u_rc})" \
  || bad "negative control: the helper answered an unreadable runbook (rc=${u_rc})"
# (g) the byte comparison itself bites: a runbook whose block was edited prints different text than the gate's dump
python3 - "${DOC}" "${nc9}/doc-edited.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = "    WHERE mfa_required = true\n    ORDER BY allow, 1, 2, 3;"
assert s.count(a) == 1
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(a, "    WHERE mfa_required = true\n    ORDER BY allow, 1, 2, 4;", 1))
PY
MFA_RUNBOOK="${nc9}/doc-edited.md" bash "${HELPER}" floor 2>/dev/null | cmp -s - "${W}/docsql/floor.sql" \
  && bad "negative control: an EDITED runbook block still compared byte-identical to the gate's dump — the comparison is vacuous" \
  || ok "negative control: an edited runbook block no longer matches the gate's dump byte-for-byte"

# (h) the suite named only in prose, not in the lockstep table row
python3 - "${DOC}" "${nc9}/doc-prose.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
row = "   | `tests/stack/test-mfa-flip-wiring.sh` |"
assert s.count(row) == 1
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(row, "   - `tests/stack/test-mfa-flip-wiring.sh` -", 1))
PY
g8="$(posture_doc_gaps "${nc9}/doc-prose.md")"
case "${g8}" in *"step6/7:test-mfa-flip-wiring.sh"*) ok "negative control: a suite named in step 6 prose but no longer in the lockstep table row -> reported (${g8})" ;;
  *) bad "negative control: moving a suite out of the lockstep table was NOT reported (got '${g8}') — the doc pin accepts a name anywhere" ;; esac
# (i) the break-glass: SELECT folded back into the delete input, and the dry run turned into a commit
python3 - "${DOC}" "${nc9}/doc-bg1.md" "${nc9}/doc-bg2.md" "${nc9}/doc-bg3.md" "${nc9}/doc-root1.md" "${nc9}/doc-root2.md" "${nc9}/doc-root3.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
def put(path, text):
    open(path, "w", encoding="utf-8").write(text)
a = "BEGIN;\nDELETE FROM mfa_recovery_code"
assert s.count(a) == 1
put(sys.argv[2], s.replace(a, "BEGIN;\nSELECT count(*) FROM mfa_factor;\nDELETE FROM mfa_recovery_code", 1))
b = "DELETE FROM mfa_factor          WHERE owner_subject = '<owner_subject>';\nROLLBACK;"
assert s.count(b) == 1
put(sys.argv[3], s.replace(b, b.replace("ROLLBACK;", "COMMIT;"), 1))
put(sys.argv[4], s.replace(b, b.replace("\nROLLBACK;", ""), 1))
r = "patch app hugmesh-root          --type merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}'   # root only (phase B printed specs/cluster/apps)\n$ $KC -n devops patch app hugmesh-gateway-fe"
assert s.count(r) == 2
put(sys.argv[5], s.replace(r, r.replace("   # root only (phase B printed specs/cluster/apps)", ""), 1))
r2 = "get application hugmesh-root --ignore-not-found"
assert s.count(r2) == 1
put(sys.argv[6], s.replace(r2, "get app hugmesh-root hugmesh-gateway-fe", 1))
i = s.index("\n## 9. ")
put(sys.argv[7], s[:i] + s[i:].replace("HUGMESH_GITOPS_ROOT_RECURSE", "THE_ROOT_FLAG"))
PY
for pair in "bg1:SELECTs and DELETEs in one input" "bg2:ending in COMMIT" "bg3:has no ROLLBACK" "root1:without 'root only'" "root2:does not detect whether hugmesh-root exists" "root3:never says the recursing root is opt-in"; do
  k="${pair%%:*}"; want="${pair#*:}"
  f="${nc9}/doc-${k}.md"; [ -f "${f}" ] || f="${nc9}/doc-$(echo "${k}" | sed 's/bg/bg/').md"
  out="$(s9_gaps "${f}")"
  case "${out}" in *"${want}"*) ok "negative control (§9 ${k}): reported (${want})" ;;
    *) bad "negative control (§9 ${k}): NOT reported (got '${out}')" ;; esac
done

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
# ⚠ ANCHORED ON `WHERE allow = true` since #347 decision 28 = D added a SECOND
# `SET mfa_required = true` statement (the row-scoped seed). Without that arm this
# pattern matched two statements and one() aborted the precondition of six
# controls at once — every one of which then reported "proves NOTHING" instead of
# silently passing, which is the only reason it was caught rather than rotting.
FLIP='UPDATE\s+gateway_route_access\s+SET\s+mfa_required\s*=\s*true\s+WHERE\s+allow\s*=\s*true[^;]*;'
# The row-scoped seed, addressed the same unambiguous way.
ROWSEED='UPDATE\s+gateway_route_access\s+SET\s+mfa_required\s*=\s*true\s+WHERE\s+gateway\s*=[^;]*;'

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
# literally `129` here while the true count was 152 (measured on this branch's merge
# base; 153 once #329's row lands), so the "(was N)" these controls print had been
# wrong for many row-additions -- still non-vacuous by luck (the mutated readings
# never happened to land on 129), but one unlucky DELETE size away from scoring a
# silent PASS on a control that never bit. Deriving it means adding a route row can
# no longer rot these two, which is exactly what #329 did to them.
HEALTHY_ROWS="$(g SIM_ROWS)"
[ -n "${HEALTHY_ROWS}" ] && [ "${HEALTHY_ROWS}" != "0" ] \
  || bad "cannot read a healthy SIM_ROWS from the real run, so the two row-count negative controls below would compare against nothing and score a vacuous PASS"

nc "an appended DELETE of flipped rows" SIM_ROWS "${HEALTHY_ROWS}" \
   's += "\nDELETE FROM gateway_route_access WHERE url_pattern LIKE %s;\n" % repr("/bff/admin/phone-fleet/%")'

nc "an appended SCHEMA-QUALIFIED DELETE that wipes every superadmin row" SIM_ROWS "${HEALTHY_ROWS}" \
   's += "\nDELETE FROM public.gateway_route_access WHERE url_pattern LIKE %s;\n" % repr("/bff/superadmin%")'

# ── #244 ACCEPT: the three ways the browser-door row can be undone ─────────────
# The row this battery defends is one line in a 150-row INSERT. Each control below
# removes or subverts it a DIFFERENT way and must move a DIFFERENT reading, so
# "the row is still there" is never inferred from the row's text.
FE_SA_ROW="('hugmesh-fe-gateway',  '/bff/superadmin/**',    'ROLE_SUPERADMIN', true),"

nc "the fe browser-door row DELETED (the surface goes back to ungoverned-and-forwarded)" \
   FE_SUPERADMIN_VERDICT DENY \
   'anchor("'"${FE_SA_ROW}"'")
s = s.replace("'"${FE_SA_ROW}"'", "")'

nc "the fe browser-door row's FLOOR LOWERED to ROLE_USER (governed, but admitting everyone)" \
   FE_SUPERADMIN_VERDICT DENY \
   'anchor("'"${FE_SA_ROW}"'")
s = s.replace("'"${FE_SA_ROW}"'", "'"${FE_SA_ROW}"'".replace("ROLE_SUPERADMIN", "ROLE_USER"))'

nc "the flip UPDATE narrowed so the fe browser-door row stays mfa_required=false" \
   FE_SUPERADMIN_MFA yes \
   's += "\nUPDATE gateway_route_access SET mfa_required = false WHERE url_pattern = %s AND role = %s;\n" % (repr("/bff/superadmin/**"), repr("ROLE_SUPERADMIN"))'

# ── #347 decision 28 = D: the four ways the games-services posture can be undone ──
# The row and its floor are two separate artefacts in two separate statements, and
# each can be lost on its own. Every control below moves a DIFFERENT reading.
nc "the ROW-SCOPED mfa seed deleted (the deny row reverts to 63c8952f's shape and strips the step-up floor from the subtree it now decides)" \
   FE_GAMES_SUBTREE_MFA yes \
   "s = s.replace(one(r'${ROWSEED}'), '', 1)"

nc "…the same deletion, seen by the declared-deny-set check" DENY_DECLARED_MISSING 0 \
   "s = s.replace(one(r'${ROWSEED}'), '', 1)"

nc "the games-services DENY row deleted while its mfa seed stays (the wall goes, and the seed silently matches nothing)" \
   SIM_ROWSEED_CHANGES_1 1 \
   'row = "  (\x27hugmesh-fe-gateway\x27,  \x27/bff/superadmin/games-services/**\x27, \x27ROLE_SUPERADMIN\x27, false),"
anchor(row)
s = s.replace(row, "", 1)'

nc "the row-scoped seed broadened to every deny row (a floor raised over surfaces nobody authorised)" \
   DENY_TRUE_UNDECLARED 0 \
   "up = one(r'${ROWSEED}')"'
new = ("UPDATE gateway_route_access\n   SET mfa_required = true\n WHERE allow = false\n"
       "   AND mfa_required IS DISTINCT FROM true;")
s = s.replace(up, new, 1)'

nc "'IS DISTINCT FROM true' dropped from the BLANKET flip (re-apply stops being a no-op)" SIM_MFA_CHANGES_2 0 \
   "up = one(r'${FLIP}')"'
new = up.replace("\n   AND mfa_required IS DISTINCT FROM true;", ";", 1)
assert new != up, "the idempotence arm was not found inside the blanket flip"
s = s.replace(up, new, 1)'

nc "'IS DISTINCT FROM true' dropped from the ROW-SCOPED seed" SIM_ROWSEED_CHANGES_2 0 \
   "up = one(r'${ROWSEED}')"'
new = up.replace("\n   AND mfa_required IS DISTINCT FROM true;", ";", 1)
assert new != up, "the idempotence arm was not found inside the row-scoped seed"
s = s.replace(up, new, 1)'

nc "a DOMAIN-SCOPED row appended to the seed (the two behavioural models are domain-blind and would answer for a row the gateway skips)" \
   DOMAIN_SCOPED_SEED_ROWS 0 \
   's += "\nINSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain) VALUES (%s, %s, %s, true, %s);\n" % (
    repr("hugmesh-fe-gateway"), repr("/bff/superadmin/games-services/**"), repr("ROLE_SUPERADMIN"), repr("brand-x.example"))'

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
    repr("hugmesh-fe-gateway"), repr("/bff/tube/ops/**"), repr("ROLE_ADMIN")), 1)'

# Decision 80b = B (hugmesh-generator#329): the per-service console shape. Each arm
# is proven to bite on its own, so dropping either one (or widening it into a
# second blanket) is a red build and not a silent narrowing of the MFA scope.
nc "the per-service ADMIN arm (LIKE '/bff/%/admin/%') dropped from the flip -- the forum/wiki/owncast admin consoles lose the floor" PREFIX_UNFLIPPED 0 \
   'a = "     OR url_pattern LIKE %s\n" % repr("/bff/%/admin/%")
anchor(a)
s = s.replace(a, "", 1)'

nc "the per-service SUPERADMIN arm (LIKE '/bff/%/superadmin/%') dropped from the flip -- the wiki superadmin console loses the floor" PREFIX_UNFLIPPED 0 \
   'a = "     OR url_pattern LIKE %s\n" % repr("/bff/%/superadmin/%")
anchor(a)
s = s.replace(a, "", 1)'

nc "the per-service admin arm widened to every /bff/ path (a second blanket)" OVERREACH 0 \
   'a = "url_pattern LIKE %s" % repr("/bff/%/admin/%")
anchor(a)
s = s.replace(a, "url_pattern LIKE %s" % repr("/bff/%"), 1)'

nc "a NEW per-service console row added later is flipped by the shape, with no edit to the UPDATE" FLIPPED 15 \
   'mod = "  (%s,  %s,           %s,       true)," % (
    repr("hugmesh-fe-gateway"), repr("/bff/mod/**"), repr("ROLE_MOD"))
anchor(mod)
s = s.replace(mod, mod + "\n  (%s, %s, %s, true)," % (
    repr("hugmesh-fe-gateway"), repr("/bff/tube/admin/**"), repr("ROLE_ADMIN")), 1)'

nc "a documented exclusion that no longer exists (the list rots)" STALE_EXCLUSIONS 0 \
   'anchor("'"'"'/bff/image-builds/arch/**'"'"'")
s = re.sub(r"^.*%s.*$\n" % re.escape("'"'"'/bff/image-builds/arch/**'"'"'"), "", s, flags=re.M)'

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
s = s.replace(a, "AND url_pattern IN (%s, %s)))" % (repr(""), repr("/bff/mod/**")), 1)'

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

# 2026-08-26, AMENDED 2026-09-16 (#351): the runbook's verify query gained
# `allow = true` — the same predicate the flip UPDATE uses — so the query and the
# UPDATE can never disagree about which rows are in scope. `integrate/superadmin`
# added it because that branch also seeded an explicit DENY row under
# /bff/superadmin% (the games app-store wall) which the flip correctly leaves at
# mfa_required=false, and an unfiltered query returned it and read as a failed
# rollout. THAT ROW IS NOT IN THE TREE: operator decision 8 (#244 ACCEPT) was
# answered "without the games-services deny row" and is SPECIFIC to it. Note the
# order, which an earlier draft of this comment had backwards: decision 8 is the
# EARLIER answer (2026-09-10) and decision 20 ("land the whole branch",
# 2026-09-16) is the LATER, GENERAL one, so recency argues FOR the row. The
# specific answer is what is applied, and the choice is parked for the operator as
# decision 28 — see the merge note in 20-schema.sql. The clause is kept anyway because it makes the
# doc's query agree with the UPDATE by construction rather than by coincidence, and
# because the first DENY row anyone adds under either prefix would otherwise make
# the runbook lie. The anchor tracks the live text; if it stops matching, this
# control fails LOUDLY (its own precondition check) rather than silently proving
# nothing.
nd "the runbook's verification query silently widened to every row" DOC_SQL_BAD 0 \
   'a = "    WHERE allow = true\n      AND (url_pattern LIKE %s\n        OR url_pattern LIKE %s\n        OR url_pattern LIKE %s\n        OR url_pattern LIKE %s)" % (
    repr("/bff/admin%"), repr("/bff/superadmin%"), repr("/bff/%/admin/%"), repr("/bff/%/superadmin/%"))
anchor(a)
s = s.replace(a, "    WHERE 1 = 1", 1)'

# REINSTATED 2026-09-17, exactly as the comment that stood here asked. That comment
# recorded a control `integrate/superadmin` had added — DROP the `allow = true`
# clause from the verify query and require DOC_SQL_BAD to move — explained that it
# could not bite while no DENY row existed under /bff/admin% or /bff/superadmin%
# (it ran vacuous and SAID so), and said: "reinstate it in the same commit as the
# first DENY row under either prefix, when it becomes falsifiable again". Operator
# decision 28 = D (#347) seeded that row, so it is falsifiable again and it is back.
# It is not a duplicate of the "silently widened to every row" control above: that
# one widens to WHERE 1 = 1 (every row in the table), this one keeps the prefix
# scoping and drops ONLY the allow filter — the smallest edit that makes the
# runbook's own query disagree with its own prose, and the one a future editor
# "tidying" the clause away would actually make.
nd "the runbook's verification query drops ONLY its allow = true clause (the deny row surfaces as an un-flipped row and reads as a failed rollout)" DOC_SQL_BAD 0 \
   'a = "    WHERE allow = true\n      AND (url_pattern LIKE %s\n        OR url_pattern LIKE %s\n        OR url_pattern LIKE %s\n        OR url_pattern LIKE %s)" % (
    repr("/bff/admin%"), repr("/bff/superadmin%"), repr("/bff/%/admin/%"), repr("/bff/%/superadmin/%"))
anchor(a)
s = s.replace(a, "    WHERE (url_pattern LIKE %s\n        OR url_pattern LIKE %s\n        OR url_pattern LIKE %s\n        OR url_pattern LIKE %s)" % (
    repr("/bff/admin%"), repr("/bff/superadmin%"), repr("/bff/%/admin/%"), repr("/bff/%/superadmin/%")), 1)'

# Decision 80b: the runbook's verify query must carry the per-service arms too, or
# it reports 10 of the 14 flipped rows and an operator reads the four consoles as
# un-gated. Dropping them must move DOC_SQL_BAD.
nd "the runbook's verification query loses the per-service console arms (it would show 10 of the 14 rows and hide the four consoles)" DOC_SQL_BAD 0 \
   'a = "\n        OR url_pattern LIKE %s\n        OR url_pattern LIKE %s)\n    ORDER BY 1, 2, 3;" % (repr("/bff/%/admin/%"), repr("/bff/%/superadmin/%"))
anchor(a)
s = s.replace(a, ")\n    ORDER BY 1, 2, 3;", 1)'

nd "the runbook's rollback block loses the per-service arms (it would leave the four consoles at mfa_required=true)" DOC_SQL_BAD 0 \
   'a = "\n       OR url_pattern LIKE %s OR url_pattern LIKE %s" % (repr("/bff/%/admin/%"), repr("/bff/%/superadmin/%"))
anchor(a)
s = s.replace(a, "", 1)'

# ── the §9 census query, proven to bite (it runs against a fixture schema) ────
# Each mutation is a way the census could quietly report an operator as covered when
# they are not. The first is the one that matters most: a TOTP row that is still
# mid-enrol (enabled = false) must not read as an enrolled factor.
nd "the census stops requiring the factor to be ENABLED (a mid-enrol TOTP reads as a working second factor)" DOC_SQL_BAD 0 \
   'a = "AND f.enabled AND f.type = %s)     AS totp," % repr("TOTP")
anchor(a, 2)   # the census, then the fleet census; replace(..., 1) mutates the first
s = s.replace(a, "AND f.type = %s)     AS totp," % repr("TOTP"), 1)'
nd "the census matches the role by SUBSTRING (administrator / superadministrator read as privileged)" DOC_SQL_BAD 0 \
   'a = repr("%,admin,%")
anchor(a, 2)
s = s.replace(a, repr("%admin%"), 1)'
nd "the census counts a WEBAUTHN factor as TOTP (the WebAuthn-only recovery-code lockout of section 2.2 reads as covered)" DOC_SQL_BAD 0 \
   'a = "AND f.enabled AND f.type = %s)     AS totp," % repr("TOTP")
anchor(a, 2)
s = s.replace(a, "AND f.enabled AND f.type IN (%s, %s))     AS totp," % (repr("TOTP"), repr("WEBAUTHN")), 1)'
nd "the census drops game-master from the privileged set (the floor's third role)" DOC_SQL_BAD 0 \
   'a = "\n    OR %s || replace(a.roles, %s, %s) || %s LIKE %s" % (repr(","), repr(" "), repr(""), repr(","), repr("%,game-master,%"))
anchor(a)
s = s.replace(a, "", 1)'

# ── the FLEET census (C5b) and the Casdoor machine-token census (C4), proven to bite ──
# These two blocks are the ones the first review found missing or vacuous, so every
# clause of each is broken in turn. The fleet block is the LAST of the census-shaped
# blocks in the runbook, so its mutators edit the LAST hit of an anchor.
LAST_HELPER='def _last(a, b, n=None):
    global s
    if n is not None:
        anchor(a, n)
    i = s.rindex(a)
    s = s[:i] + b + s[i+len(a):]
'
ndl() { nd "$1" "$2" "$3" "${LAST_HELPER}
$4"; }
ndl "the fleet census stops requiring the TOTP factor to be ENABLED (a mid-enrol TOTP reads as enrolled)" DOC_SQL_BAD 0 \
   'a = "AND f.enabled AND f.type = \x27TOTP\x27)     AS totp,"
_last(a, "AND f.type = \x27TOTP\x27)     AS totp,", 2)'
ndl "the fleet census counts an INACTIVE entitlement as entitled" DOC_SQL_BAD 0 \
   'a = "WHERE e.subject = a.id AND e.active\n"
_last(a, "WHERE e.subject = a.id\n", 1)'
ndl "the fleet census ignores entitlement EXPIRY" DOC_SQL_BAD 0 \
   'a = "\n                  AND (e.expires_at IS NULL OR e.expires_at > CURRENT_TIMESTAMP))"
_last(a, ")", 1)'
ndl "the fleet census stops excluding admin / game-master / superadmin co-holders (they short-circuit, so step 6 does not gate them)" DOC_SQL_BAD 0 \
   'a = "   AND NOT (    "
i = s.rindex(a)
k = s.index("\n ORDER BY 3, 5 DESC, 1;", i)
s = s[:i] + s[k:]'
ndl "the fleet census loses its LIKE escape, so the _ in fleet_admin becomes a wildcard (fleet-admin / fleetXadmin match)" DOC_SQL_BAD 0 \
   'a = "LIKE \x27%,fleet\\_admin,%\x27 ESCAPE \x27\\\x27"
_last(a, "LIKE \x27%,fleet_admin,%\x27", 1)'
ndl "the fleet census matches fleet_admin by SUBSTRING (fleet_administrator reads as a fleet owner)" DOC_SQL_BAD 0 \
   'a = "LIKE \x27%,fleet\\_admin,%\x27"
_last(a, "LIKE \x27%fleet\\_admin%\x27", 1)'
ndl "the fleet census loses its ordering (un-enrolled and entitled owners no longer sort first)" DOC_SQL_BAD 0 \
   'a = " ORDER BY 3, 5 DESC, 1;"
_last(a, " ORDER BY 1;", 1)'
nd "the Casdoor census goes back to keying a machine token on an EMPTY user (the vacuous form it shipped with)" DOC_SQL_BAD 0 \
   'a = "CASE WHEN grant_type = \x27client_credentials\x27 OR \"user\" = application\n            THEN \x27machine\x27"
anchor(a)
s = s.replace(a, "CASE WHEN COALESCE(\"user\", \x27\x27) = \x27\x27\n            THEN \x27machine\x27", 1)'
nd "the Casdoor census stops reading the grant_type column (a client_credentials token with an empty user is missed)" DOC_SQL_BAD 0 \
   'a = "grant_type = \x27client_credentials\x27 OR "
anchor(a)
s = s.replace(a, "", 1)'
nd "the Casdoor census stops reading the user = application placeholder (a row from before grant_type existed is missed)" DOC_SQL_BAD 0 \
   'a = " OR \"user\" = application"
anchor(a)
s = s.replace(a, "", 1)'
nd "the Casdoor census stops grouping by kind (a service that mints BOTH user and machine tokens collapses to one row)" DOC_SQL_BAD 0 \
   'a = "GROUP BY 1, 2\n ORDER BY 2, 1;"
anchor(a)
s = s.replace(a, "GROUP BY 1\n ORDER BY 1;", 1)'

# ── the FLOOR query and the deny-floor table (hugmesh-generator#485) ────────────
# §5 now carries a second marked query, scoped to the FLOOR rather than to the flip,
# plus a table naming every deny row that carries it. Both exist because the prose
# around the `verify` query said "the 10 rows … and nothing else" while ELEVEN rows
# carried the floor, and nothing could see the sentence. Each control below breaks a
# DIFFERENT half of that record.
nd "the runbook's FLOOR query is narrowed back to the flip's own predicate (the deny row vanishes from the floor audit and the runbook is back to under-reporting it)" DOC_SQL_BAD 0 \
   'a = "    WHERE mfa_required = true\n    ORDER BY allow, 1, 2, 3;"
anchor(a)
s = s.replace(a, "    WHERE mfa_required = true\n      AND allow = true\n    ORDER BY allow, 1, 2, 3;", 1)'

nd "the runbook's deny-floor TABLE loses the games-services row (the seed keeps a floor the operator cannot read anywhere)" DOC_DENY_MISSING 0 \
   'B = chr(96)
needle = "%shugmesh-fe-gateway%s | %s/bff/superadmin/games-services/**%s | %sROLE_SUPERADMIN%s |" % ((B,) * 6)
lines = s.split(chr(10))
hit = [i for i, l in enumerate(lines) if needle in l and l.lstrip().startswith("|")]
assert len(hit) == 1, "expected exactly 1 deny-floor table row for the games row, found %d" % len(hit)
del lines[hit[0]]
s = chr(10).join(lines)'

nd "the runbook's deny-floor TABLE grows a row the seed does not carry (a floor the operator believes is raised and is not)" DOC_DENY_EXTRA 0 \
   'B = chr(96)
needle = "%shugmesh-fe-gateway%s | %s/bff/superadmin/games-services/**%s | %sROLE_SUPERADMIN%s |" % ((B,) * 6)
lines = s.split(chr(10))
hit = [i for i, l in enumerate(lines) if needle in l and l.lstrip().startswith("|")]
assert len(hit) == 1, "expected exactly 1 deny-floor table row for the games row, found %d" % len(hit)
lines.insert(hit[0] + 1, "   | %shugmesh-fe-gateway%s | %s/bff/admin/phone-fleet/**%s | %sROLE_ADMIN%s | invented |" % ((B,) * 6))
s = chr(10).join(lines)'

nd "the runbook's deny-floor TABLE marker is deleted (the table stops being read at all)" DOC_DENY_ABSENT 0 \
   'a = "<!-- gate:deny-floor -->"
anchor(a)
s = s.replace(a, "", 1)'

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
