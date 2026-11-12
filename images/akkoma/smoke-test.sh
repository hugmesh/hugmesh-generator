#!/usr/bin/env bash
# Boot-tests a hugmesh-akkoma image the way the cluster runs it, with throwaway
# docker resources only (a private network, two volumes, two containers, all named
# hm-akkoma-smoke-<pid>-*, removed on exit). Used by .github/workflows/akkoma-image-ci.yml
# on every pull request that touches images/akkoma/, and by hand:
#
#   bash images/akkoma/smoke-test.sh <image> [expected-akkoma-version]
#
# What it proves, each as a PASS/FAIL line:
#   1. the image ships no Erlang cookie (releases/COOKIE) and runs as uid 1000;
#   2. a world-readable config.exs (a ConfigMap's default 0644) is refused at boot,
#      and the same file at 0440 root:1000 (defaultMode 0440 + fsGroup 1000) is read;
#   3. `pleroma_ctl migrate` (the initContainer) succeeds against Postgres with a
#      read-only root filesystem, /tmp as tmpfs and every capability dropped;
#   4. `pleroma start` serves /api/v1/instance and reports the expected version, and
#      the image's HEALTHCHECK turns healthy;
#   5. `pleroma_ctl user new` over rpc from a second process in the same container
#      works (the per-container cookie is shared), and the same task in a SEPARATE
#      container with PLEROMA_CTL_RPC_DISABLED=true works (the admin-sync Job shape);
#   6. Erlang distribution and epmd listen on loopback only;
#   7. python3 can import what the sync Jobs' scripts import;
#   8. the cluster's OWN configs boot: config.exs is extracted verbatim from the
#      akkoma-config ConfigMap in specs/cluster/manifests/akkoma/akkoma.yaml and
#      from akkoma-peer-config in specs/cluster/manifests/test-runner/akkoma-peer.yaml
#      (nothing in it is edited: Postgres answers to the host names those configs
#      name), then migrate + start must serve /api/v1/instance for the host the
#      config declares, each on a fresh database. Steps 2-7 use a minimal config of
#      their own; this step is what catches a manifest the image cannot boot (it
#      did: neither ConfigMap set the Pleroma.Upload base_url `pleroma start`
#      requires, and steps 2-7 passed).
# Needs docker, python3 (stdlib, to read the manifests) and network access for
# postgres:16-alpine. Exit 0 only if all pass.
#
# SMOKE_AKKOMA_MANIFEST / SMOKE_PEER_MANIFEST override the two manifest paths (to
# boot another revision's ConfigMap, e.g. one written by `git show`).
set -euo pipefail

image="${1:?usage: smoke-test.sh <image> [expected-akkoma-version]}"
want_version="${2:-}"
pg_image="${SMOKE_PG_IMAGE:-postgres:16-alpine}"
p="hm-akkoma-smoke-$$"
net="$p-net"; db="$p-db"; app="$p-app"; cfg="$p-cfg"; pgdata="$p-pgdata"
pass=0; fail=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
akkoma_manifest="${SMOKE_AKKOMA_MANIFEST:-$repo/specs/cluster/manifests/akkoma/akkoma.yaml}"
peer_manifest="${SMOKE_PEER_MANIFEST:-$repo/specs/cluster/manifests/test-runner/akkoma-peer.yaml}"
ok()  { echo "  PASS $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }

cleanup() {
  docker rm -f "$app" "$db" >/dev/null 2>&1 || true
  docker volume rm -f "$cfg" "$pgdata" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rand() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
db_password="$(rand 16)"
secret_key_base="$(rand 48)"
signing_salt="$(rand 8)"

docker network create --internal "$net" >/dev/null
docker volume create "$cfg" >/dev/null
docker volume create "$pgdata" >/dev/null

# A minimal instance config for steps 2-7, which prove the IMAGE. Step 8 boots the
# cluster's own ConfigMaps, which prove the MANIFESTS.
config="$(cat <<'EOF'
import Config
config :pleroma, Pleroma.Web.Endpoint,
  url: [host: "akkoma.smoke.invalid", scheme: "https", port: 443],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  signing_salt: System.get_env("SIGNING_SALT")
config :pleroma, :instance, name: "smoke", email: "admin@smoke.invalid", registrations_open: false
config :pleroma, Pleroma.Upload, base_url: "https://media.smoke.invalid/media/"
config :pleroma, Pleroma.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "akkoma",
  password: System.get_env("DB_PASSWORD"),
  database: "akkoma",
  hostname: System.get_env("DB_HOST")
EOF
)"

# write_config MODE: the config volume holds config.exs owned root:1000 at MODE,
# written by a root helper from the image under test (no extra image needed).
write_config() {
  printf '%s\n' "$config" | docker run --rm -i --network none --user 0:0 \
    -v "$cfg:/c" --entrypoint sh "$image" \
    -c "rm -f /c/erl_crash.dump; cat > /c/config.exs && chown 0:1000 /c/config.exs && chmod $1 /c/config.exs"
}

# run_app ARGS...: the akkoma container as the cluster runs it.
app_flags=(--network "$net" --read-only --tmpfs /tmp --cap-drop ALL
  --security-opt no-new-privileges:true
  -e DB_PASSWORD="$db_password" -e SECRET_KEY_BASE="$secret_key_base"
  -e SIGNING_SALT="$signing_salt" -e DB_HOST="$db"
  -v "$cfg:/etc/akkoma:ro")

echo "== image $image"

# 1. no baked cookie, non-root
if docker run --rm --network none --entrypoint sh "$image" -c 'test ! -e /opt/akkoma/releases/COOKIE'; then
  ok "image ships no releases/COOKIE"
else
  bad "image ships /opt/akkoma/releases/COOKIE: every container would share a public cookie"
fi
uid="$(docker run --rm --network none --entrypoint id "$image" -u)"
if [ "$uid" = 1000 ]; then ok "image runs as uid 1000"; else bad "image runs as uid '$uid', not 1000"; fi

# 7. python3 for the sync Jobs (admin-sync-job.yaml, domainlock-sync-job.yaml)
if docker run --rm --network none --entrypoint python3 "$image" \
     -c 'import json, os, base64, subprocess, urllib.request, urllib.error' 2>/dev/null; then
  ok "python3 imports what the sync Jobs need"
else
  bad "python3 cannot import json/os/base64/subprocess/urllib.request: the sync Jobs would die"
fi

# The aliases are the Repo host names the cluster's ConfigMaps name (step 8).
docker run -d --name "$db" --network "$net" \
  --network-alias akkoma-db --network-alias akkoma-peer-db \
  -e POSTGRES_USER=akkoma -e POSTGRES_DB=akkoma -e POSTGRES_PASSWORD="$db_password" \
  -v "$pgdata:/var/lib/postgresql/data" "$pg_image" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$db" pg_isready -U akkoma -h 127.0.0.1 >/dev/null 2>&1; then break; fi
  sleep 1
done

# 2. world-readable config is refused
write_config 0644
out="$(docker run --rm "${app_flags[@]}" "$image" /opt/akkoma/bin/pleroma_ctl migrate 2>&1)" && rc=0 || rc=$?
case "$rc:$out" in
  0:*) bad "a 0644 config.exs was accepted; the 0440 rule below would prove nothing" ;;
  *"has world-permissions"*) ok "a 0644 config.exs is refused (the reason the manifests mount it 0440)" ;;
  *) bad "a 0644 config.exs failed for another reason (rc $rc): $(printf '%s' "$out" | tail -n 3)" ;;
esac

# 3. migrate with 0440 root:1000, read-only root, tmpfs /tmp, no capabilities
write_config 0440
if out="$(docker run --rm "${app_flags[@]}" "$image" /opt/akkoma/bin/pleroma_ctl migrate 2>&1)"; then
  ok "pleroma_ctl migrate succeeds (0440 config, read-only root, tmpfs /tmp, cap-drop ALL)"
else
  bad "pleroma_ctl migrate failed: $(printf '%s' "$out" | tail -n 5)"
fi

# 4. start, serve, healthcheck
docker run -d --name "$app" "${app_flags[@]}" "$image" >/dev/null
body=""
for _ in $(seq 1 90); do
  if body="$(docker exec "$app" curl -fsS http://127.0.0.1:4000/api/v1/instance 2>/dev/null)"; then break; fi
  body=""
  sleep 2
done
if [ -n "$body" ]; then
  ok "/api/v1/instance answers"
  version="$(printf '%s' "$body" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  case "$version" in
    *"Akkoma ${want_version}"*) ok "reports version '$version'" ;;
    *) bad "reports version '$version', expected it to name Akkoma ${want_version:-<any>}" ;;
  esac
else
  bad "/api/v1/instance never answered; last log lines: $(docker logs --tail 15 "$app" 2>&1)"
fi
health=""
for _ in $(seq 1 30); do
  health="$(docker inspect -f '{{.State.Health.Status}}' "$app" 2>/dev/null || true)"
  [ "$health" = healthy ] && break
  sleep 5
done
if [ "$health" = healthy ]; then ok "HEALTHCHECK is healthy"; else bad "HEALTHCHECK is '$health'"; fi

# 5. rpc from a second process in the same container; eval from a separate one
if out="$(docker exec "$app" /opt/akkoma/bin/pleroma_ctl user new smoke smoke@smoke.invalid \
            --password "$(rand 12)" --moderator -y 2>&1)"; then
  ok "pleroma_ctl over rpc works from a second process (shared per-container cookie)"
else
  bad "pleroma_ctl over rpc failed: $(printf '%s' "$out" | tail -n 5)"
fi
out="$(docker run --rm "${app_flags[@]}" -e PLEROMA_CTL_RPC_DISABLED=true "$image" \
         /opt/akkoma/bin/pleroma_ctl user list 2>&1)" || true
case "$out" in
  *"smoke moderator: true"*) ok "pleroma_ctl in a separate container (PLEROMA_CTL_RPC_DISABLED=true) sees the rpc-made user" ;;
  *) bad "pleroma_ctl user list in a separate container did not list the user: $(printf '%s' "$out" | tail -n 5)" ;;
esac

# 6. listeners: only :4000 may be off loopback
listen="$(docker exec "$app" sh -c "awk 'NR>1 && \$4==\"0A\" {print \$2}' /proc/net/tcp /proc/net/tcp6")"
offloop=""
while IFS= read -r a; do
  [ -n "$a" ] || continue
  addr="${a%:*}"; port="${a##*:}"
  case "$addr" in
    ??????7F) continue ;;                                    # 127.0.0.0/8 (docker DNS is 127.0.0.11)
    00000000000000000000000001000000) continue ;;            # ::1
  esac
  [ "$port" = 0FA0 ] && continue                            # 4000, the HTTP endpoint
  offloop="$offloop $a"
done <<< "$listen"
if [ -z "$offloop" ] && [ -n "$listen" ]; then
  ok "only :4000 listens off loopback (distribution and epmd are loopback-only)"
else
  bad "listeners off loopback besides :4000:${offloop:- (none read at all)}"
fi

# 8. the cluster's own ConfigMaps, extracted verbatim, boot on a fresh database
# extract_config MANIFEST CONFIGMAP: print data["config.exs"] of that ConfigMap.
# A block-scalar reader, stdlib only (no PyYAML on every runner); it fails closed:
# no such ConfigMap, no config.exs key or an empty body is exit 1.
extract_config() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
path, want = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
for doc in re.split(r"(?m)^---[ \t]*$", text):
    if not re.search(r"(?m)^kind:\s*ConfigMap\s*$", doc):
        continue
    if not re.search(r"(?m)^\s+name:\s*%s\s*$" % re.escape(want), doc):
        continue
    lines = doc.split("\n")
    for i, l in enumerate(lines):
        m = re.match(r"^(\s+)config\.exs:\s*\|[-+]?\s*$", l)
        if not m:
            continue
        key = len(m.group(1))
        body = []
        for b in lines[i + 1:]:
            if b.strip() and len(b) - len(b.lstrip()) <= key:
                break
            body.append(b)
        while body and not body[-1].strip():
            body.pop()
        ind = min(len(b) - len(b.lstrip()) for b in body if b.strip()) if body else 0
        out = "\n".join(b[ind:] for b in body).strip("\n")
        if out:
            print(out)
            sys.exit(0)
sys.exit("no non-empty config.exs in ConfigMap %s of %s" % (want, path))
PY
}

docker rm -f "$app" >/dev/null 2>&1 || true
for spec in "akkoma-config|$akkoma_manifest" "akkoma-peer-config|$peer_manifest"; do
  cm="${spec%%|*}"; manifest="${spec#*|}"
  if ! command -v python3 >/dev/null 2>&1; then
    bad "$cm: python3 is not installed, so the as-shipped config cannot be read (not skipped)"
    continue
  fi
  if [ ! -f "$manifest" ] || ! shipped="$(extract_config "$manifest" "$cm" 2>&1)"; then
    bad "$cm: cannot read config.exs from $manifest: ${shipped:-missing file}"
    continue
  fi
  host="$(printf '%s\n' "$shipped" | sed -n 's/.*url: \[host: "\([^"]*\)".*/\1/p' | head -n 1)"
  # a fresh database, as a new cluster's PVC is
  docker exec "$db" psql -q -U akkoma -d postgres -c 'DROP DATABASE IF EXISTS akkoma WITH (FORCE)' >/dev/null
  docker exec "$db" psql -q -U akkoma -d postgres -c 'CREATE DATABASE akkoma OWNER akkoma' >/dev/null
  config="$shipped"
  write_config 0440
  if ! out="$(docker run --rm "${app_flags[@]}" "$image" /opt/akkoma/bin/pleroma_ctl migrate 2>&1)"; then
    bad "$cm (as shipped): pleroma_ctl migrate failed: $(printf '%s' "$out" | tail -n 5)"
    continue
  fi
  docker run -d --name "$app" "${app_flags[@]}" "$image" >/dev/null
  body=""
  for _ in $(seq 1 90); do
    if body="$(docker exec "$app" curl -fsS http://127.0.0.1:4000/api/v1/instance 2>/dev/null)"; then break; fi
    body=""
    [ "$(docker inspect -f '{{.State.Running}}' "$app" 2>/dev/null)" = true ] || break
    sleep 2
  done
  uri="$(printf '%s' "$body" | sed -n 's/.*"uri":"\([^"]*\)".*/\1/p')"
  if [ -n "$body" ] && [ -n "$host" ] && [ "$uri" = "$host" ]; then
    ok "$cm (as shipped in $(basename "$manifest")): migrate + start serve /api/v1/instance as $uri"
  else
    bad "$cm (as shipped in $(basename "$manifest")): did not serve /api/v1/instance as '${host:-<no host in config>}' (got '${uri}'); last log lines: $(docker logs --tail 12 "$app" 2>&1 | grep -v '^\s*$' | tail -n 12)"
  fi
  docker rm -f "$app" >/dev/null 2>&1 || true
done

echo "== smoke-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
