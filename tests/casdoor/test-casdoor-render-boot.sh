#!/usr/bin/env bash
# =============================================================================
# test-casdoor-render-boot.sh — a Casdoor rendered from its manifests boots on a
# password an operator could really have typed into Vault.
#
# WHY. Every Casdoor here (manifests/casdoor, casdoor-games, casdoor-domain) renders
# conf/app.conf in a render-app-conf initContainer from a __TOKEN__ template and the
# ESO-materialized Secret. The first renderer was `sed -e "s|__T__|${V}|g"`: a value
# with `|` ended the expression, `&` pasted the token back in, `\1` was an invalid
# reference, and in every case the pod rendered a WRONG conf without a word and
# Casdoor exited 2 on `password authentication failed`, or started with a password
# that was not the one in Vault. The renderer is now a literal replacement and the
# DB user and password are percent-encoded into a postgres:// URL (the keyword form
# cannot carry a space at all: xorm splits it on whitespace before lib/pq sees it);
# this suite proves that END TO END, on the real image and a real Postgres, with a
# password built from exactly those bytes.
#
# WHAT RUNS (throwaway containers, unique names, everything removed on exit):
#   for casdoor (the systems IdP), casdoor-games and casdoor-domain, the template,
#   the initContainer's args, its env names and the init_data.json are taken from the
#   manifests by PyYAML;
#   1. the render runs in the pinned casdoor image, as that image's own uid, with a
#      hostile user and password: rc 0, NOT ONE BYTE on stdout or stderr, no token
#      left, and the dataSourceName URL decoded the way lib/pq decodes it gives back
#      the typed user and password byte for byte, newline included;
#   2. the pinned casdoor image boots on that rendered conf against postgres:16-alpine
#      started with the same credentials: /api/health ok; the password is in no
#      stream (render, Casdoor log, Postgres log); games seeds its seven threewizards
#      roles, no mesh-* role, and its three permissions (Casdoor adds its own
#      built-in one, which is reported, not asserted); domain's issuer is the origin;
#   3. control: the old sed shape, run on the same password, does NOT give the typed
#      password back (so the first point is not vacuous).
#
# Needs docker (a daemon the caller can use), python3 + PyYAML. Exits 2 when it cannot
# run at all — never a silent pass. tests/scripts/test-games-two-realms.sh carries the
# hermetic half (the renderer under sh with the same values, no containers).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
M="${REPO}/specs/cluster/manifests"

command -v docker >/dev/null 2>&1 || { echo "CANNOT RUN: docker not found"; exit 2; }
docker info >/dev/null 2>&1 || { echo "CANNOT RUN: no usable docker daemon"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT RUN: python3 required"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "CANNOT RUN: PyYAML required"; exit 2; }

P="casdoor-render-$$-$(date +%s)"
NET="${P}-net"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${P}.XXXXXX")"
chmod 755 "${WORK}"
cleanup(){
  docker ps -aq --filter "name=^${P}-" | xargs -r docker rm -f >/dev/null 2>&1
  docker network rm "${NET}" >/dev/null 2>&1
  rm -rf "${WORK}"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS $*"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $*"; }

# The hostile bytes, with a per-run suffix so no fixed secret is ever committed or
# reused: sed's delimiter, its backreferences, a backslash, both quotes, a shell
# variable, a percent, a hash and a semicolon (ini comment leaders), a question
# mark and an at sign (URL delimiters), spaces and a tab. A newline is proven
# separately: the official postgres image provisions POSTGRES_PASSWORD through
# initdb's --pwfile, which keeps the FIRST LINE only (measured: the full value is
# refused over the network, the first line accepted), so a newline password is
# set with ALTER USER after the boot and Casdoor is restarted on it.
SUFFIX="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
PW="$(printf 'p|a&s/s\\w'"'"'d"x$y%%z &&\\\\ \\1 #;c ?@\tq %s' "${SUFFIX}")"
PW_NL="$(printf 'top%s\nline2 %s' "${SUFFIX}" "${PW}")"
# Postgres itself refuses a bootstrap role name carrying `"`, `$`, `'` or `\`
# (initdb: "invalid character in extension owner"), so the user names carry the
# bytes that broke sed and the password carries the rest.
USER_G="three|wiz&ards"
USER_D="cas&door|x"
USER_S="sys|cas&door"
# The systems Casdoor also renders its SMTP settings; the password is hostile too.
CASDOOR_SMTP_HOST=smtp.render-boot.test; CASDOOR_SMTP_PORT=587; CASDOOR_SMTP_USER="mail|er&x"; CASDOOR_SMTP_FROM=noreply@render-boot.test
CASDOOR_SMTP_PASSWORD="sm&tp|p\\w'\"$ \\1 ${SUFFIX}"
SENT="${SUFFIX}"   # distinctive, greppable in every stream
ORIGIN="https://id.render-boot.test"
export PW PW_NL USER_G USER_D USER_S ORIGIN CASDOOR_SMTP_HOST CASDOOR_SMTP_PORT CASDOOR_SMTP_USER CASDOOR_SMTP_FROM CASDOOR_SMTP_PASSWORD

docker network create "${NET}" >/dev/null 2>&1 || { echo "CANNOT RUN: docker network create failed"; exit 2; }

# ── extract everything from the manifests (never retyped here) ────────────────
extract(){ # $1 dir, $2 app-conf ConfigMap name, $3 init-data ConfigMap name or ""
  python3 - "${M}/$1" "$2" "$3" "${WORK}/$1" <<'PY'
import os, sys, yaml
d, cm_name, init_name, out = sys.argv[1:5]
os.makedirs(f"{out}/template", exist_ok=True); os.makedirs(f"{out}/rendered", exist_ok=True)
os.chmod(f"{out}/template", 0o755); os.chmod(f"{out}/rendered", 0o777)
docs = lambda p: [x for x in yaml.safe_load_all(open(p)) if x]
cm = next(x for x in docs(f"{d}/app-conf-configmap.yaml") if x["kind"] == "ConfigMap" and x["metadata"]["name"] == cm_name)
open(f"{out}/template/app.conf.template", "w").write(cm["data"]["app.conf.template"])
os.chmod(f"{out}/template/app.conf.template", 0o644)
dep = next(x for x in docs(f"{d}/deployment.yaml") if x["kind"] == "Deployment")
pod = dep["spec"]["template"]["spec"]
init = next(c for c in pod["initContainers"] if c["name"] == "render-app-conf")
assert init["command"] == ["sh", "-c"] and len(init["args"]) == 1, "render-app-conf is not `sh -c <one script>`"
open(f"{out}/init-args.sh", "w").write(init["args"][0])
open(f"{out}/init-env", "w").write("\n".join(e["name"] for e in init.get("env") or []) + "\n")
open(f"{out}/init-image", "w").write(init["image"])
main = next(c for c in pod["containers"] if c["name"] == "casdoor")
open(f"{out}/image", "w").write(main["image"])
mm = next(m for m in main["volumeMounts"] if m["name"] == "rendered-conf")
open(f"{out}/conf-path", "w").write(mm["mountPath"])
if init_name:
    icm = next(x for x in docs(f"{d}/init-data-configmap.yaml") if x["kind"] == "ConfigMap" and x["metadata"]["name"] == init_name)
    open(f"{out}/init_data.json", "w").write(icm["data"]["init_data.json"])
    os.chmod(f"{out}/init_data.json", 0o644)
    im = next(m for m in main["volumeMounts"] if m["name"] == "init-data")
    open(f"{out}/init-path", "w").write(im["mountPath"])
PY
}
extract casdoor        casdoor-app-conf        casdoor-init-data       || { echo "CANNOT RUN: casdoor manifests did not parse"; exit 2; }
extract casdoor-games  casdoor-games-app-conf  casdoor-games-init-data || { echo "CANNOT RUN: casdoor-games manifests did not parse"; exit 2; }
extract casdoor-domain casdoor-domain-app-conf ""                      || { echo "CANNOT RUN: casdoor-domain manifests did not parse"; exit 2; }

# The URL the way lib/pq's ParseURL reads it (net/url: userinfo percent-decoded).
# Casdoor hands dataSourceName to xorm, which only takes the database name from the
# path, and to lib/pq verbatim.
url_part(){ # $1 rendered app.conf, $2 user|password -> prints the decoded value
  python3 - "$1" "$2" <<'PY'
import sys, urllib.parse
conf, key = sys.argv[1:3]
line = next(l for l in open(conf) if l.startswith("dataSourceName"))
val = line.split("=", 1)[1].strip()
if val.startswith('"'): val = val.strip('"')   # beego ini: a leading " means trim quotes
u = urllib.parse.urlsplit(val)
assert u.scheme == "postgres", u.scheme
raw = u.netloc.rpartition("@")[0]
user, _, pw = raw.partition(":")
sys.stdout.write(urllib.parse.unquote(user if key == "user" else pw, errors="strict"))
PY
}

render(){ # $1 short, $2 user, $3 password, $4 origin, $5 out file -> rc; stdout+stderr in $5.out
  local short="$1"
  local args
  args="$(cat "${WORK}/${short}/init-args.sh")"
  rm -f "${WORK}/${short}/rendered/app.conf"
  local envflags=""
  local n; while read -r n; do [ -n "${n}" ] && envflags="${envflags} -e ${n}"; done < "${WORK}/${short}/init-env"
  # shellcheck disable=SC2086
  CASDOOR_DB_USER="$2" CASDOOR_DB_PASSWORD="$3" CASDOOR_ORIGIN="$4" \
  docker run --rm --name "${P}-render-${short}-$RANDOM" --entrypoint sh ${envflags} \
    -v "${WORK}/${short}/template:/template:ro" -v "${WORK}/${short}/rendered:/rendered" \
    "$(cat "${WORK}/${short}/init-image")" -c "${args}" > "$5" 2>&1
}

judge_render(){ # $1 short, $2 user, $3 label
  local short="$1" user="$2" label="$3"
  local out="${WORK}/${short}/render.out" conf="${WORK}/${short}/rendered/app.conf"
  if render "${short}" "${user}" "${PW}" "${ORIGIN}" "${out}"; then ok "${label}: the render exits 0 in $(cat "${WORK}/${short}/init-image") as uid $(docker run --rm --entrypoint id "$(cat "${WORK}/${short}/init-image")" -u 2>/dev/null || echo '?')"
  else bad "${label}: the render exited $? ($(head -c 200 "${out}" | tr '\n' ' '))"; return; fi
  [ "$(wc -c < "${out}")" -eq 0 ] && ok "${label}: not one byte on stdout or stderr" || bad "${label}: the render printed $(wc -c < "${out}") bytes (a value could be among them)"
  grep -qF -- "${SENT}" "${out}" && bad "${label}: the password is in the render output" || ok "${label}: the password is in no render stream"
  [ -s "${conf}" ] || { bad "${label}: no rendered app.conf"; return; }
  [ "$(grep -c '__[A-Z_]*__' "${conf}")" -eq 0 ] && ok "${label}: no __TOKEN__ survives" || bad "${label}: tokens left: $(grep -o '__[A-Z_]*__' "${conf}" | sort -u | tr '\n' ' ')"
  local got_pw got_user
  got_pw="$(url_part "${conf}" password)"; got_user="$(url_part "${conf}" user)"
  [ "${got_pw}" = "${PW}" ] && ok "${label}: lib/pq reads the password back byte for byte (${#PW} bytes: | & / \\ ' \" \$ % # ; ? @ space tab)" || bad "${label}: lib/pq would read a DIFFERENT password (${#got_pw} bytes) than the one in Vault (${#PW} bytes)"
  [ "${got_user}" = "${user}" ] && ok "${label}: lib/pq reads the user back byte for byte (${user})" || bad "${label}: lib/pq would read user '${got_user}', not '${user}'"
}

wait_pg(){ # $1 container, $2 user
  local i
  for i in $(seq 1 45); do docker exec "$1" pg_isready -q -U postgres >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

boot(){ # $1 short, $2 db, $3 user, $4 pg alias, $5 label -> container name in BOOTED
  local short="$1" db="$2" user="$3" alias="$4" label="$5"
  local pg="${P}-pg-${short}" c="${P}-casdoor-${short}"
  local img; img="$(cat "${WORK}/${short}/image")"
  POSTGRES_PASSWORD="${PW}" POSTGRES_USER="${user}" docker run -d --name "${pg}" --network "${NET}" --network-alias "${alias}" \
    -e POSTGRES_DB="${db}" -e POSTGRES_USER -e POSTGRES_PASSWORD postgres:16-alpine >/dev/null 2>&1 || { bad "${label}: postgres did not start"; return 1; }
  wait_pg "${pg}" "${user}" || { bad "${label}: postgres never became ready: $(docker logs "${pg}" 2>&1 | tail -2 | tr '\n' ' ')"; return 1; }
  local initmount=""
  [ -f "${WORK}/${short}/init_data.json" ] && initmount="-v ${WORK}/${short}/init_data.json:$(cat "${WORK}/${short}/init-path"):ro"
  # shellcheck disable=SC2086
  docker run -d --name "${c}" --network "${NET}" -e RUNNING_IN_DOCKER=true -e CASDOOR_ORIGIN="${ORIGIN}" \
    -v "${WORK}/${short}/rendered/app.conf:$(cat "${WORK}/${short}/conf-path"):ro" ${initmount} "${img}" >/dev/null 2>&1 \
    || { bad "${label}: casdoor did not start"; return 1; }
  local i state health=""
  for i in $(seq 1 60); do
    state="$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null)"
    [ "${state}" = "exited" ] && break
    health="$(docker exec "${c}" wget -qO- -T 3 http://127.0.0.1:8000/api/health 2>/dev/null)" && [ -n "${health}" ] && break
    sleep 2
  done
  docker logs "${c}" > "${WORK}/${short}/casdoor.log" 2>&1
  docker logs "${pg}" > "${WORK}/${short}/pg.log" 2>&1
  case "${health}" in *'"status":"ok"'*) ok "${label}: ${img} is up on the rendered conf, /api/health ok after ~$((i*2)) s";;
    *) bad "${label}: no healthy Casdoor (state ${state}; log: $(grep -m2 -E 'panic|password authentication|exit' "${WORK}/${short}/casdoor.log" | cut -c1-160 | tr '\n' ';'))"; return 1;; esac
  grep -qF -- "${SENT}" "${WORK}/${short}/casdoor.log" && bad "${label}: the password is in Casdoor's log" || ok "${label}: the password is not in Casdoor's log"
  grep -qF -- "${SENT}" "${WORK}/${short}/pg.log" && bad "${label}: the password is in Postgres's log" || ok "${label}: the password is not in Postgres's log"
  BOOTED_C="${c}"; BOOTED_PG="${pg}"
  return 0
}
psq(){ # $1 pg container, $2 user, $3 db, $4 sql
  docker exec -e PGPASSWORD="${PW}" "$1" psql -U "$2" -d "$3" -Atc "$4" 2>/dev/null
}

echo "== 1. the render, as the initContainer runs it =="
judge_render casdoor        "${USER_S}" "systems"
grep -qF -- "smtpPassword = \"${CASDOOR_SMTP_PASSWORD}\"" "${WORK}/casdoor/rendered/app.conf" 2>/dev/null && ok "systems: the SMTP password is rendered literally (| & \\ ' \" \$ \\1)" || bad "systems: smtpPassword rendered as $(grep '^smtpPassword' "${WORK}/casdoor/rendered/app.conf" 2>/dev/null | sed "s/${SUFFIX}/<suffix>/")"
judge_render casdoor-games  "${USER_G}" "games"
judge_render casdoor-domain "${USER_D}" "domain"
grep -q "^origin = \"${ORIGIN}\"" "${WORK}/casdoor-domain/rendered/app.conf" 2>/dev/null && ok "domain: origin rendered from CASDOOR_ORIGIN" || bad "domain: origin not rendered ($(grep '^origin' "${WORK}/casdoor-domain/rendered/app.conf" 2>/dev/null))"
# A newline survives the render (percent-encoded %0A) and decodes back.
if render casdoor-games "${USER_G}" "${PW_NL}" "${ORIGIN}" "${WORK}/casdoor-games/render-nl.out" && [ "$(url_part "${WORK}/casdoor-games/rendered/app.conf" password)" = "${PW_NL}" ]; then
  ok "games: a password with a newline renders (rc 0, $(wc -c < "${WORK}/casdoor-games/render-nl.out") bytes printed) and decodes back byte for byte"
else bad "games: a password with a newline does not round-trip ($(head -c 120 "${WORK}/casdoor-games/render-nl.out" | tr '\n' ' '))"; fi
grep -qF -- "${SENT}" "${WORK}/casdoor-games/render-nl.out" && bad "games: the newline password is in the render output" || ok "games: the newline password is in no render stream"
render casdoor-games "${USER_G}" "${PW}" "${ORIGIN}" "${WORK}/casdoor-games/render.out" >/dev/null 2>&1   # back to the boot password

echo "== 2. Casdoor boots on it =="
if [ -s "${WORK}/casdoor/rendered/app.conf" ] && boot casdoor casdoor "${USER_S}" casdoor-pg "systems"; then
  n="$(psq "${BOOTED_PG}" "${USER_S}" casdoor "select count(*) from organization")"
  [ -n "${n}" ] && [ "${n}" -ge 1 ] && ok "systems: ${n} organization(s) seeded through init_data.json" || bad "systems: no organization table rows (${n:-no answer})"
  docker rm -f "${BOOTED_C}" "${BOOTED_PG}" >/dev/null 2>&1
fi
if [ -s "${WORK}/casdoor-games/rendered/app.conf" ] && boot casdoor-games threewizards "${USER_G}" casdoor-games-pg "games"; then
  roles="$(psq "${BOOTED_PG}" "${USER_G}" threewizards "select count(*) from role where owner='threewizards'")"
  mesh="$(psq "${BOOTED_PG}" "${USER_G}" threewizards "select count(*) from role where name like 'mesh-%'")"
  perms_tw="$(psq "${BOOTED_PG}" "${USER_G}" threewizards "select count(*) from permission where owner='threewizards'")"
  perms_all="$(psq "${BOOTED_PG}" "${USER_G}" threewizards "select string_agg(owner||'/'||name, ' ' order by 1) from permission")"
  [ "${roles}" = "7" ] && ok "games: 7 threewizards roles seeded through init_data.json" || bad "games: ${roles:-?} threewizards roles (wanted 7)"
  [ "${mesh}" = "0" ] && ok "games: no mesh-* role" || bad "games: ${mesh} mesh-* roles"
  [ "${perms_tw}" = "3" ] && ok "games: 3 threewizards permissions seeded; every permission on the instance: ${perms_all}" || bad "games: ${perms_tw:-?} threewizards permissions (wanted 3); all: ${perms_all}"
  # The newline password, end to end: ALTER USER (psql interpolates :'pw' from stdin,
  # never from -c), a fresh render, Casdoor restarted on it.
  docker rm -f "${BOOTED_C}" >/dev/null 2>&1
  if printf "alter user \"${USER_G}\" password :'pw';" | docker exec -i -e PGPASSWORD="${PW}" "${BOOTED_PG}" psql -U "${USER_G}" -d threewizards -v ON_ERROR_STOP=1 -v pw="${PW_NL}" -q >/dev/null 2>&1 \
     && render casdoor-games "${USER_G}" "${PW_NL}" "${ORIGIN}" "${WORK}/casdoor-games/render-nl2.out"; then
    c2="${P}-casdoor-nl"
    docker run -d --name "${c2}" --network "${NET}" -e RUNNING_IN_DOCKER=true \
      -v "${WORK}/casdoor-games/rendered/app.conf:$(cat "${WORK}/casdoor-games/conf-path"):ro" \
      -v "${WORK}/casdoor-games/init_data.json:$(cat "${WORK}/casdoor-games/init-path"):ro" "$(cat "${WORK}/casdoor-games/image")" >/dev/null 2>&1
    health=""
    for i in $(seq 1 60); do
      [ "$(docker inspect -f '{{.State.Status}}' "${c2}" 2>/dev/null)" = "exited" ] && break
      health="$(docker exec "${c2}" wget -qO- -T 3 http://127.0.0.1:8000/api/health 2>/dev/null)" && [ -n "${health}" ] && break
      sleep 2
    done
    docker logs "${c2}" > "${WORK}/casdoor-games/casdoor-nl.log" 2>&1
    case "${health}" in *'"status":"ok"'*) ok "games: Casdoor is up on a password carrying a NEWLINE (set by ALTER USER, rendered as %0A)";;
      *) bad "games: Casdoor did not come up on the newline password ($(grep -m1 -E 'panic|password authentication' "${WORK}/casdoor-games/casdoor-nl.log" | cut -c1-140))";; esac
    grep -qF -- "${SENT}" "${WORK}/casdoor-games/casdoor-nl.log" && bad "games: the newline password is in Casdoor's log" || ok "games: the newline password is not in Casdoor's log"
    docker rm -f "${c2}" >/dev/null 2>&1
  else
    bad "games: could not set the newline password or render it"
  fi
  docker rm -f "${BOOTED_PG}" >/dev/null 2>&1
fi
if [ -s "${WORK}/casdoor-domain/rendered/app.conf" ] && boot casdoor-domain casdoor "${USER_D}" casdoor-domain-pg "domain"; then
  iss="$(docker exec "${BOOTED_C}" wget -qO- -T 3 http://127.0.0.1:8000/.well-known/openid-configuration 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("issuer",""))' 2>/dev/null)"
  [ "${iss}" = "${ORIGIN}" ] && ok "domain: openid-configuration issuer is the rendered origin" || bad "domain: issuer '${iss}' is not '${ORIGIN}'"
  docker rm -f "${BOOTED_C}" "${BOOTED_PG}" >/dev/null 2>&1
fi

echo "== 3. control: the old sed shape on the same password =="
# The pre-fix renderer, rebuilt from the token list; it must NOT give the password back.
sedargs="sed"
while read -r n; do [ -n "${n}" ] && sedargs="${sedargs} -e \"s|__${n}__|\${${n}}|g\""; done < "${WORK}/casdoor-games/init-env"
sedargs="${sedargs} /template/app.conf.template > /rendered/app.conf"
rm -f "${WORK}/casdoor-games/rendered/app.conf"
CASDOOR_DB_USER="${USER_G}" CASDOOR_DB_PASSWORD="${PW}" docker run --rm --name "${P}-render-sed" --entrypoint sh \
  -e CASDOOR_DB_USER -e CASDOOR_DB_PASSWORD -v "${WORK}/casdoor-games/template:/template:ro" -v "${WORK}/casdoor-games/rendered:/rendered" \
  "$(cat "${WORK}/casdoor-games/init-image")" -c "${sedargs}" > "${WORK}/casdoor-games/render-sed.out" 2>&1
sed_rc=$?
if [ -s "${WORK}/casdoor-games/rendered/app.conf" ] && [ "$(url_part "${WORK}/casdoor-games/rendered/app.conf" password 2>/dev/null)" = "${PW}" ]; then
  bad "control: the sed shape reproduced the password (this suite would prove nothing)"
else
  ok "control: the sed shape does not give the password back (rc ${sed_rc}, $(head -c 100 "${WORK}/casdoor-games/render-sed.out" | tr '\n' ' ')); the literal renderer is doing real work"
fi

echo
echo "== test-casdoor-render-boot: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
