#!/usr/bin/env bash
# mfa-runbook-sql.sh — print ONE of docs/MFA-ROLLOUT.md's executable SQL blocks,
# byte-for-byte, so an operator pipes the runbook's own text into psql instead of
# retyping (and silently altering) it.
#
# WHY. The runbook's operator queries are each marked
#     <!-- gate:doc-sql name=<name> expect=<kind> -->
# followed by a ```sql fence, and tests/scripts/test-mfa-required-rules.sh EXECUTES
# every one against a replayed database. That proof only transfers to the cluster if
# the operator runs the SAME text. Copy-pasting out of rendered Markdown mangles
# quotes and wraps lines; this prints the block exactly as the gate ran it.
#
# Usage:
#   scripts/mfa-runbook-sql.sh <name>          # print the block (name: verify, floor, ...)
#   scripts/mfa-runbook-sql.sh --list          # print every block name, one per line
#   MFA_RUNBOOK=/path/to/MFA-ROLLOUT.md scripts/mfa-runbook-sql.sh floor
#
# Typical use (see docs/MFA-ROLLOUT.md section 9):
#   scripts/mfa-runbook-sql.sh floor | kubectl -n hugmesh-pki exec -i deploy/route-access-db -- \
#       sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -U gateway -d gateway'
#
# FAIL-CLOSED. An unknown name, a duplicated name, an empty block, an unreadable
# runbook or no argument exits non-zero with the reason on stderr and prints
# nothing on stdout, so a pipe into psql never runs an empty or partial statement.
# This script only READS a file; it never touches a cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${MFA_RUNBOOK:-${HERE}/../docs/MFA-ROLLOUT.md}"

die() { echo "mfa-runbook-sql.sh: $*" >&2; exit "${2:-1}"; }

command -v python3 >/dev/null 2>&1 || die "python3 not on PATH" 2
[ -r "${DOC}" ] || die "cannot read the runbook at ${DOC}" 2

case "${1:-}" in
  "")      die "missing block name (try --list)" 2 ;;
  --list)  MODE=list; NAME="" ;;
  -*)      die "unknown option '$1' (expected a block name or --list)" 2 ;;
  *)       MODE=print; NAME="$1" ;;
esac
[ "$#" -le 1 ] || die "expected exactly one argument" 2

python3 - "${DOC}" "${MODE}" "${NAME}" <<'PY'
import re, sys

doc, mode, name = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(doc, encoding="utf-8").read()

# The SAME marker + fence shape tests/scripts/test-mfa-required-rules.sh parses
# (DOC_RE there); keep the two in step.
RE = re.compile(
    r'<!--\s*gate:doc-sql\s+name=(\S+)\s+expect=(\S+)\s*-->\s*\n[ \t]*```sql\n(.*?)\n[ \t]*```',
    re.S)

def dedent(block):
    ls = block.split("\n")
    pad = min((len(l) - len(l.lstrip()) for l in ls if l.strip()), default=0)
    return "\n".join(l[pad:] if len(l) >= pad else l for l in ls)

blocks = {}
dups = []
for n, _expect, body in RE.findall(text):
    if n in blocks:
        dups.append(n)
    blocks[n] = dedent(body).strip()

def die(msg):
    sys.stderr.write("mfa-runbook-sql.sh: " + msg + "\n")
    sys.exit(1)

if not blocks:
    die("no '<!-- gate:doc-sql -->' blocks found in %s" % doc)
if dups:
    die("duplicate block name(s): %s — which one to run is ambiguous" % ", ".join(sorted(set(dups))))

if mode == "list":
    print("\n".join(blocks))
    sys.exit(0)

if name not in blocks:
    die("no block named %r (have: %s)" % (name, ", ".join(blocks)))
if not blocks[name]:
    die("block %r is empty" % name)
sys.stdout.write(blocks[name] + "\n")
PY
