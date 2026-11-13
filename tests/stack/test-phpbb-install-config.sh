#!/usr/bin/env bash
# test-phpbb-install-config.sh — the phpBB headless install (PHPBB=1) must
# authenticate with the SAME password phpbb-db was initialised with.
#
# WHY. Since #857 phpbb-db's POSTGRES_PASSWORD is a random ${PHPBB_DB_PASSWORD},
# but compose.alt-social.yaml pointed PHPBB_INSTALL_CONFIG at the extension repo's
# docker/install-config.compose.yml (`dbhost: db`, `dbpasswd: phpbb`). On every
# fresh phpbb-pg volume the one-time install failed `password authentication
# failed for user "phpbb"`, the entrypoint still logged "headless install
# complete" and removed install/, and the board never got a table:
# /api/v1/hugmesh/* answered 503 for good (2026-11-12, the operator's mesh).
#
# HOW. Render the REAL compose files with `docker compose config` from a COPY of
# tests/stack (the checkout's own .env is never read or written), with a .env of
# random values, and assert on the rendered model:
#   [mount]   phpbb's PHPBB_INSTALL_CONFIG is the target of a config it mounts;
#   [same-pw] that config's dbpasswd == phpbb-db's POSTGRES_PASSWORD ==
#             phpbb's PHPBB_APP_PASSWORD == PHPBB_DB_PASSWORD from .env;
#   [host]    its dbhost is the phpbb-db service, and no `db` alias is left;
#   [legacy]  no rendered `dbpasswd: phpbb` anywhere;
#   [yaml]    the rendered content parses as the installer's YAML shape (python
#             yaml when available, else the indentation is checked by awk).
# NEGATIVE CONTROL: the same assertions run against a COPY whose dbpasswd is the
# old literal must go red (proving the guard bites), and so must one whose
# PHPBB_INSTALL_CONFIG points back at the extension repo's file.
# Needs docker compose (>= 2.23, for configs.content); no daemon, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "FATAL: docker compose required (refusing to skip)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-phpbb-install-config.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

mk_tree() { # mk_tree <dir>: a copy of tests/stack with a random-valued .env
  mkdir -p "$1"
  cp -a "${HERE}/." "$1/stack/"
  rm -f "$1/stack/.env" "$1"/stack/.compose.*.yaml
  : > "$1/stack/.mastodon.env"
  { echo "ROUTE_ACCESS_DB_PASSWORD=guard"
    awk -F'\t' '!/^#/ && NF >= 5 { print $1 }' "${HERE}/stack-db-passwords.tsv" | while read -r k; do
      printf '%s=%s\n' "${k}" "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
    done
  } > "$1/stack/.env"
}

render() { # render <dir> -> json on stdout
  local keys
  keys="$(awk -F'\t' '!/^#/ && NF >= 5 { printf "-u %s ", $1 }' "${HERE}/stack-db-passwords.tsv")"
  # shellcheck disable=SC2086  # keys is a list of `-u KEY` words on purpose
  (cd "$1" && env -u COMPOSE_PROJECT_NAME -u ROUTE_ACCESS_DB_PASSWORD ${keys} \
     docker compose -p phpbb-guard -f stack/compose.local.yaml --profile phpbb config --format json)
}

check() { # check <dir> <label> -> 0 when every assertion holds; prints PASS/FAIL lines only when <label> is "real"
  local dir="$1" json
  json="$(render "${dir}" 2>"${WORK}/err")" || { echo "render failed: $(head -2 "${WORK}/err" | tr '\n' '|')"; return 1; }
  printf '%s' "${json}" > "${dir}/cfg.json"
  python3 - "${dir}/cfg.json" "${dir}/stack/.env" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
env = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[2], encoding="utf-8") if "=" in l)
want = env["PHPBB_DB_PASSWORD"]
problems = []
svc = cfg["services"]["phpbb"]; db = cfg["services"]["phpbb-db"]
target = svc["environment"].get("PHPBB_INSTALL_CONFIG", "")
mounted = {c.get("target"): c.get("source") for c in svc.get("configs", [])}
if target not in mounted:
    problems.append(f"[mount] PHPBB_INSTALL_CONFIG={target!r} is not the target of any config phpbb mounts {sorted(mounted)}")
    content = ""
else:
    content = cfg.get("configs", {}).get(mounted[target], {}).get("content", "")
    if not content:
        problems.append(f"[mount] config {mounted[target]!r} has no inline content")
m = re.search(r"^\s*dbpasswd:\s*'?([^'\n]*)'?\s*$", content, re.M)
got = m.group(1) if m else None
if got != want:
    problems.append("[same-pw] the install YAML's dbpasswd is not PHPBB_DB_PASSWORD")
if db["environment"].get("POSTGRES_PASSWORD") != want or svc["environment"].get("PHPBB_APP_PASSWORD") != want:
    problems.append("[same-pw] phpbb-db / phpbb do not read PHPBB_DB_PASSWORD")
h = re.search(r"^\s*dbhost:\s*(\S+)\s*$", content, re.M)
if not h or h.group(1) != "phpbb-db":
    problems.append(f"[host] dbhost is {h.group(1) if h else None!r}, want phpbb-db")
aliases = (db.get("networks") or {}).get("default") or {}
if "db" in ((aliases or {}).get("aliases") or []):
    problems.append("[host] phpbb-db still carries the `db` alias the old file needed")
if re.search(r"dbpasswd:\s*'?phpbb'?\s*$", json.dumps(cfg).replace("\\n", "\n"), re.M):
    problems.append("[legacy] a rendered `dbpasswd: phpbb` is left")
try:
    import yaml  # optional
    doc = yaml.safe_load(content)
    d = doc["installer"]["database"]
    if str(d["dbpasswd"]) != want or d["dbhost"] != "phpbb-db" or d["dbname"] != "phpbb":
        problems.append("[yaml] parsed installer.database does not carry the stack's values")
except ImportError:
    if not re.search(r"^installer:\n(    .*\n)+", content):
        problems.append("[yaml] content is not an `installer:` block indented by 4")
except Exception as exc:  # noqa: BLE001 - any parse error is the finding
    problems.append(f"[yaml] does not parse: {exc}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}

echo "-- real compose files --"
mk_tree "${WORK}/real"
if out="$(check "${WORK}/real")"; then
  ok "the install YAML phpbb mounts uses PHPBB_DB_PASSWORD, host phpbb-db, no db alias, no legacy literal"
else
  bad "real files: ${out}"
fi
if ! grep -qF "$(sed -n 's/^PHPBB_DB_PASSWORD=//p' "${WORK}/real/stack/.env")" "${WORK}/real/stack/compose.alt-social.yaml"; then
  ok "the compose file itself spells no password (it is interpolated from .env)"
else
  bad "a .env value leaked into the compose file"
fi

echo "-- negative controls (the guard must bite) --"
mk_tree "${WORK}/mut1"
python3 - "${WORK}/mut1/stack/compose.alt-social.yaml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
t = re.sub(r"dbpasswd: '\$\{PHPBB_DB_PASSWORD[^}]*\}'", "dbpasswd: phpbb", s)
assert t != s, "mutation did not apply"
open(p, "w").write(t)
PY
if cmp -s "${HERE}/compose.alt-social.yaml" "${WORK}/mut1/stack/compose.alt-social.yaml"; then
  bad "[mut-literal] the mutated copy is identical to the original"
elif out="$(check "${WORK}/mut1")"; then
  bad "[mut-literal] the old literal password PASSED the guard"
else
  ok "[mut-literal] dbpasswd: phpbb goes red ($(printf '%s' "${out}" | head -1))"
fi
mk_tree "${WORK}/mut2"
sed -i 's#PHPBB_INSTALL_CONFIG: /run/hugmesh/phpbb-install.yml#PHPBB_INSTALL_CONFIG: /var/www/html/ext/hugmesh/forumapi/docker/install-config.compose.yml#' \
  "${WORK}/mut2/stack/compose.alt-social.yaml"
if cmp -s "${HERE}/compose.alt-social.yaml" "${WORK}/mut2/stack/compose.alt-social.yaml"; then
  bad "[mut-path] the mutated copy is identical to the original"
elif out="$(check "${WORK}/mut2")"; then
  bad "[mut-path] pointing back at the extension repo's file PASSED the guard"
else
  ok "[mut-path] the extension repo's static file goes red ($(printf '%s' "${out}" | head -1))"
fi

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
