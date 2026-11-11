#!/usr/bin/env bash
# test-mastodon-front.sh — gate for the compose lane's Mastodon front
# (tests/stack/mastodon-front/default.conf), the ONE origin user-bff-api's
# hsproxy and media proxy talk to (GUI-35).
#
#   bash tests/stack/test-mastodon-front.sh
#
# WHAT WAS BROKEN, measured on the running compose mesh before the front existed
# (mesh-operator, /social/mastodon through `make view LANE=compose`):
#   * GET /bff/user/mastodon/api/v1/streaming/user -> 301
#       Location: https://localhost/api/v1/streaming/user
#     The hsproxy's one upstream was mastodon-web, and Rails does not serve the
#     streaming API. mastodon-ui concluded "this deployment does not stream" and
#     polled every 30 s. A post took 21 s to appear in the Home column.
#   * every avatar and header img had naturalWidth 0, because the browser got
#     ERR_CONNECTION_REFUSED on https://localhost/avatars/original/missing.png.
#     Mastodon mints asset URLs from LOCAL_DOMAIN (`localhost`, its federation
#     identity), and on any door but localhost:8488 that host is nothing.
#
# WHAT THIS PINS
#   1. wiring (static): the service exists in the social profile, is not
#      published, mounts this conf, and BOTH user-bff upstreams
#      (APP_HS_TOKEN_MASTODON_URL, MEDIA_PROXY_MASTODON_BASE_URL) default to it
#      on the port the conf really listens on. up-real.sh starts it.
#   2. agreement (static): the host the conf rewrites is the LOCAL_DOMAIN
#      gen-mastodon-env.sh writes, and the Host the conf pins is in the
#      ALTERNATE_DOMAINS it writes. Either one drifting is silent on a live mesh:
#      no rewrite at all, or a 403 on every proxied call.
#   3. behaviour (functional): the REAL conf, run by a real nginx in front of two
#      stand-ins that behave like the pieces they replace. The web stand-in
#      answers /api/v1/streaming with Rails' 301, 403s an unknown Host
#      (HostAuthorization), 301s a request without X-Forwarded-Proto: https
#      (force_ssl) and gzips when asked. The streaming stand-in sends one frame
#      and then holds the stream open. Through the front:
#        - /api/v1/streaming/user is 200 text/event-stream, and frame 1 arrives
#          while the stream is still open;
#        - avatars, headers, /system/ and /packs/ URLs come back as
#          /bff/user/mastodon/..., in JSON and in a live frame;
#        - account url/uri and links in post HTML stay https://localhost/...
#          (identity and permalinks, never media);
#        - a 2 MB upload is not refused (nginx's default limit is 1 MB).
#      Each has a CONTROL against the stand-in directly, so the assertion cannot
#      pass because the stand-in never did the bad thing.
#
# nginx: the host's `nginx` when it has the sub module (CI's alpine job installs
# it), else the compose service's own image through docker. With neither, the
# functional leg cannot run and the suite exits 2. A gate that silently skips
# its behaviour leg would read as green while checking nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CONF="${HERE}/mastodon-front/default.conf"
REAL="${HERE}/compose.real.yaml"
SOCIAL="${HERE}/compose.social-profile.yaml"
LOCAL="${HERE}/compose.local.yaml"
GENENV="${HERE}/gen-mastodon-env.sh"
UPREAL="${HERE}/up-real.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
check() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }
has()   { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (found '$2')";; *) ok "$3";; esac; }

for f in "${CONF}" "${REAL}" "${SOCIAL}" "${LOCAL}" "${GENENV}" "${UPREAL}"; do
  [ -f "$f" ] || { echo "missing ${f}" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "python3 + PyYAML are required" >&2; exit 2; }

# Directives only: comments are prose here and must never satisfy a check.
conf_body() { sed -e 's/#.*$//' "$1"; }

echo "== mastodon-front (GUI-35) =="
echo "-- 1) wiring --"

LISTEN="$(conf_body "${CONF}" | sed -n 's/^[[:space:]]*listen[[:space:]]\{1,\}\([0-9]\{1,5\}\);.*/\1/p' | head -1)"
[ -n "${LISTEN}" ] && ok "the conf listens on :${LISTEN}" || bad "could not find the conf's listen port"

svc_json() {  # $1=compose file -> the mastodon-front service as JSON ({} when absent)
  python3 - "$1" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(json.dumps((d.get("services") or {}).get("mastodon-front") or {}))
PY
}
FRONT="$(svc_json "${REAL}")"
[ "${FRONT}" != "{}" ] && ok "compose.real.yaml defines mastodon-front" || bad "compose.real.yaml has no mastodon-front service"
has "${FRONT}" '"./mastodon-front/default.conf:/etc/nginx/conf.d/default.conf:ro"' "it mounts the committed mastodon-front/default.conf read-only"
has "${FRONT}" '"image": "nginx:' "it runs the stock nginx image"
hasnt "${FRONT}" '"ports"' "it is NOT published on the host (only the compose network dials it)"
has "${FRONT}" '"mastodon-web"' "it depends on mastodon-web"
has "${FRONT}" '"mastodon-streaming"' "it depends on mastodon-streaming"
has "$(svc_json "${SOCIAL}")" '"social"' "compose.social-profile.yaml puts it in the social profile with the rest of the tier"

ubff() {  # $1=compose file $2=key -> the user-bff env value
  python3 - "$1" "$2" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
env = d["services"]["hugmesh-user-bff-api"]["environment"]
env = dict(e.split("=", 1) for e in env) if isinstance(env, list) else env
print(env.get(sys.argv[2], ""))
PY
}
for k in APP_HS_TOKEN_MASTODON_URL MEDIA_PROXY_MASTODON_BASE_URL; do
  v="$(ubff "${LOCAL}" "$k")"
  has "$v" ":-http://mastodon-front:${LISTEN}}" "user-bff ${k} defaults to the front on its listen port"
done
grep -E '^\$\{COMPOSE\} up -d .*\bmastodon-front\b' "${UPREAL}" >/dev/null
check $? "up-real.sh starts mastodon-front with the rest of the Mastodon tier"

echo "-- 2) agreement with gen-mastodon-env.sh --"
envlit() { sed -n "s/^ensure[[:space:]]\{1,\}$1[[:space:]]\{1,\}lit[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p" "${GENENV}" | head -1; }
LD="$(envlit LOCAL_DOMAIN)"; AD="$(envlit ALTERNATE_DOMAINS)"
[ -n "${LD}" ] && ok "gen-mastodon-env.sh writes LOCAL_DOMAIN=${LD}" || bad "cannot read LOCAL_DOMAIN from gen-mastodon-env.sh"
RW_HOSTS="$(conf_body "${CONF}" | sed -n "s|^[[:space:]]*sub_filter[[:space:]]\{1,\}'https://\([^/']*\)/.*|\1|p" | sort -u)"
[ -n "${RW_HOSTS}" ] && [ "${RW_HOSTS}" = "${LD}" ]
check $? "every media rewrite matches https://${LD}/ — the host Mastodon mints (got: $(echo ${RW_HOSTS}))"
PIN="$(conf_body "${CONF}" | sed -n 's/^[[:space:]]*proxy_set_header[[:space:]]\{1,\}Host[[:space:]]\{1,\}\([^;]*\);.*/\1/p' | sort -u)"
[ -n "${PIN}" ] && case ",${AD}," in *",${PIN},"*) true;; *) false;; esac
check $? "the pinned upstream Host (${PIN:-none}) is in ALTERNATE_DOMAINS (${AD:-none}), so HostAuthorization admits it"
[ "$(printf '%s\n' "${PIN}" | wc -l)" -eq 1 ]
check $? "exactly one Host is pinned, at server level (no location overrides it)"

# ── 3) behaviour ──────────────────────────────────────────────────────────────
echo "-- 3) the real conf, through a real nginx --"
TMP="$(mktemp -d)"
KIDS=""
cleanup() {
  for pid in ${KIDS}; do kill "${pid}" 2>/dev/null; done
  [ -n "${NGINX_CTR:-}" ] && docker rm -f "${NGINX_CTR}" >/dev/null 2>&1
  rm -rf "${TMP}"
}
trap cleanup EXIT
chmod 755 "${TMP}"

NGINX_IMAGE="$(printf '%s' "${FRONT}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("image",""))')"
RUNNER=""
if command -v nginx >/dev/null 2>&1 && nginx -V 2>&1 | grep -- '--with-http_sub_module' >/dev/null; then
  RUNNER=host
elif command -v docker >/dev/null 2>&1 && [ -n "${NGINX_IMAGE}" ] \
     && docker image inspect "${NGINX_IMAGE}" >/dev/null 2>&1; then
  RUNNER=docker
fi
if [ -z "${RUNNER}" ]; then
  echo "SKIPPED-LOUDLY: no nginx with http_sub_module on PATH and no local ${NGINX_IMAGE:-nginx} image;" \
       "the behaviour leg checked NOTHING (static: ${PASS} passed, ${FAIL} failed)" >&2
  exit 2
fi
ok "nginx runner: ${RUNNER}$([ "${RUNNER}" = docker ] && echo " (${NGINX_IMAGE}, the compose service's own image)")"

freeport() { python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
WEB_PORT="$(freeport)"; STREAM_PORT="$(freeport)"; FRONT_PORT="$(freeport)"

cat > "${TMP}/stand_ins.py" <<'PY'
"""mastodon-web and mastodon-streaming stand-ins: each does the thing that broke."""
import gzip, http.server, json, sys, threading, time

PIN_HOST = sys.argv[3]
LD = sys.argv[4]
SEEN = {}

ACCOUNT = {
    "acct": "e2e_usera",
    "url": f"https://{LD}/@e2e_usera",
    "uri": f"https://{LD}/users/e2e_usera",
    "avatar": f"https://{LD}/avatars/original/missing.png",
    "header": f"https://{LD}/headers/original/missing.png",
    "note": f'<p><a href="https://{LD}/tags/hello">#hello</a></p>',
    "emojis": [{"shortcode": "blob", "url": f"https://{LD}/system/custom_emojis/images/1/blob.png"}],
}
STATUS = {"id": "1", "url": f"https://{LD}/@e2e_usera/1", "account": ACCOUNT,
          "media_attachments": [{"type": "image",
                                 "url": f"https://{LD}/system/media_attachments/files/1/original/a.png",
                                 "preview_url": f"https://{LD}/system/media_attachments/files/1/small/a.png"}]}
INSTANCE = {"thumbnail": {"url": f"https://{LD}/packs/media/images/preview.png"}}


class Web(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", ctype="application/json; charset=utf-8", extra=()):
        if "gzip" in (self.headers.get("Accept-Encoding") or "") and body:
            body = gzip.compress(body)
            extra = tuple(extra) + (("Content-Encoding", "gzip"),)
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _gate(self):
        # Rails HostAuthorization, then force_ssl — in that order, like Mastodon.
        if self.headers.get("Host") != PIN_HOST:
            self._send(403, b"Blocked hosts: " + (self.headers.get("Host") or "").encode(), "text/html")
            return False
        if self.headers.get("X-Forwarded-Proto") != "https":
            # force_ssl: 301 for GET, 308 for anything else (measured on
            # mastodon-web: POST /api/v2/media without the header -> 308).
            self._send(301 if self.command == "GET" else 308, b"", "text/html",
                       (("Location", f"https://{PIN_HOST}{self.path}"),))
            return False
        return True

    def do_GET(self):
        if self.path == "/__seen":
            return self._send(200, json.dumps(SEEN).encode())
        if not self._gate():
            return
        if self.path.startswith("/api/v1/streaming"):
            # Api::V1::StreamingController: Rails does not stream, it redirects.
            return self._send(301, b"<html>moved</html>", "text/html; charset=utf-8",
                              (("Location", f"https://{LD}{self.path}"),))
        if self.path.startswith("/api/v1/accounts/lookup"):
            return self._send(200, json.dumps(ACCOUNT).encode())
        if self.path.startswith("/api/v1/timelines/home"):
            return self._send(200, json.dumps([STATUS]).encode())
        if self.path.startswith("/api/v2/instance"):
            return self._send(200, json.dumps(INSTANCE).encode())
        if self.path == "/avatars/original/missing.png":
            return self._send(200, b"\x89PNG\r\n\x1a\nstand-in", "image/png")
        self._send(404, b"{}")

    def do_POST(self):
        if not self._gate():
            return
        n = int(self.headers.get("Content-Length") or 0)
        got = 0
        while got < n:
            chunk = self.rfile.read(min(65536, n - got))
            if not chunk:
                break
            got += len(chunk)
        self._send(200, json.dumps({"received": got,
                                    "url": f"https://{LD}/system/media_attachments/files/2/original/b.png"}).encode())

    def log_message(self, *a):
        pass


class Stream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/__seen":
            b = json.dumps(SEEN).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b); return
        SEEN["stream_auth"] = self.headers.get("Authorization")
        SEEN["stream_path"] = self.path
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        frame = json.dumps({"id": "9", "account": {"avatar": f"https://{LD}/system/accounts/avatars/9/original/me.png",
                                                   "url": f"https://{LD}/@me"}})
        self.wfile.write(f"event: update\ndata: {frame}\n\n".encode())
        self.wfile.flush()
        time.sleep(6)          # the stream stays OPEN, like a real one
        self.wfile.write(b"event: delete\ndata: 9\n\n")
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, *a):
        pass


class Quiet(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # nginx dropping an idle keep-alive connection is not a test event.
        if not isinstance(sys.exc_info()[1], ConnectionError):
            super().handle_error(request, client_address)


for port, cls in ((int(sys.argv[1]), Web), (int(sys.argv[2]), Stream)):
    srv = Quiet(("127.0.0.1", port), cls)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
while True:
    time.sleep(3600)
PY
python3 "${TMP}/stand_ins.py" "${WEB_PORT}" "${STREAM_PORT}" "${PIN}" "${LD}" & KIDS="${KIDS} $!"

# The REAL conf, with exactly four edits: the compose service names become
# 127.0.0.1, their ports become the stand-ins', and the listen port becomes a
# free one. Each edit must land exactly once. If the conf is restructured so an
# edit no longer applies, the leg fails, so it can never quietly test a conf
# that differs from the committed one in some other way.
python3 - "${CONF}" "${TMP}/front.conf" "${WEB_PORT}" "${STREAM_PORT}" "${FRONT_PORT}" "${LISTEN}" <<'PY' || exit 1
import re, sys
src, dst, web, stream, front, listen = sys.argv[1:]
text = open(src).read()
edits = [
    (r"(?m)^(\s*set\s+\$mastodon_web\s+)mastodon-web;", r"\g<1>127.0.0.1;"),
    (r"(?m)^(\s*set\s+\$mastodon_streaming\s+)mastodon-streaming;", r"\g<1>127.0.0.1;"),
    (r"http://\$mastodon_web:3000\$request_uri", f"http://$mastodon_web:{web}$request_uri"),
    (r"http://\$mastodon_streaming:4000\$request_uri", f"http://$mastodon_streaming:{stream}$request_uri"),
    (rf"(?m)^(\s*listen\s+){listen};", rf"\g<1>127.0.0.1:{front};"),
]
for pat, rep in edits:
    text, n = re.subn(pat, rep, text)
    if n != 1:
        sys.exit(f"test harness: expected exactly one match for {pat!r}, got {n} — the conf changed shape")
open(dst, "w").write(text)
PY
cat > "${TMP}/nginx.conf" <<EOF
daemon off;
pid ${TMP}/nginx.pid;
error_log ${TMP}/error.log warn;
events {}
http {
    access_log off;
    client_body_temp_path ${TMP}/t-body;
    proxy_temp_path ${TMP}/t-proxy;
    fastcgi_temp_path ${TMP}/t-fcgi;
    uwsgi_temp_path ${TMP}/t-uwsgi;
    scgi_temp_path ${TMP}/t-scgi;
    include ${TMP}/front.conf;
}
EOF
if [ "${RUNNER}" = host ]; then
  nginx -e "${TMP}/error.log" -c "${TMP}/nginx.conf" & KIDS="${KIDS} $!"
else
  NGINX_CTR="hugmesh-test-mastodon-front-$$"
  docker run -d --rm --name "${NGINX_CTR}" --network host --user "$(id -u):$(id -g)" \
    -v "${TMP}:${TMP}" "${NGINX_IMAGE}" nginx -e "${TMP}/error.log" -c "${TMP}/nginx.conf" >/dev/null \
    || { bad "could not start ${NGINX_IMAGE}"; NGINX_CTR=""; }
fi
up=1
for _ in $(seq 100); do
  python3 -c "import socket,sys;s=socket.socket();s.settimeout(.3);sys.exit(0 if s.connect_ex(('127.0.0.1',${FRONT_PORT}))==0 and s.connect_ex(('127.0.0.1',${WEB_PORT}))==0 else 1)" 2>/dev/null \
    && { up=0; break; }
  sleep 0.1
done
check "${up}" "nginx serves the committed conf (only the upstream addresses and the listen port changed)"
[ "${up}" -eq 0 ] || { cat "${TMP}/error.log" >&2 2>/dev/null; echo "== mastodon-front: ${PASS} passed, ${FAIL} failed =="; exit 1; }

FRONT_URL="http://127.0.0.1:${FRONT_PORT}"
WEB_URL="http://127.0.0.1:${WEB_PORT}"
# What user-bff sends: its WebClient dials the front by name and asserts
# X-Forwarded-Proto: https on a plain-http leg; the browser's Accept-Encoding
# passes through the hsproxy untouched.
get() {  # $1=url [$2=Host] -> "<status> <content-type>\n<body>"
  python3 - "$1" "${2:-mastodon-front:${LISTEN}}" <<'PY'
import gzip, sys, urllib.error, urllib.request
req = urllib.request.Request(sys.argv[1], headers={
    "Host": sys.argv[2], "X-Forwarded-Proto": "https",
    "Accept-Encoding": "gzip, deflate, br", "Authorization": "Bearer native-token"})
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
try:
    r = urllib.request.build_opener(NoRedirect).open(req, timeout=20)
    code, h, b = r.status, r.headers, r.read()
except urllib.error.HTTPError as e:
    code, h, b = e.code, e.headers, e.read()
if h.get("Content-Encoding") == "gzip":
    b = gzip.decompress(b)
print(code, h.get("Content-Type"), h.get("Location") or "")
print(b.decode("utf-8", "replace"))
PY
}

acct_direct="$(get "${WEB_URL}/api/v1/accounts/lookup?acct=e2e_usera" "${PIN}")"
acct="$(get "${FRONT_URL}/api/v1/accounts/lookup?acct=e2e_usera")"
has   "${acct_direct}" "\"avatar\": \"https://${LD}/avatars/original/missing.png\"" "control: the stand-in mints https://${LD}/avatars/..., like Mastodon"
has   "${acct}" "200 application/json" "through the front: 200 (Host pinned, https asserted, so neither HostAuthorization nor force_ssl fires)"
has   "${acct}" '"avatar": "/bff/user/mastodon/avatars/original/missing.png"' "the default avatar comes back root-relative under /bff/user/mastodon"
has   "${acct}" '"header": "/bff/user/mastodon/headers/original/missing.png"' "...the default header too"
has   "${acct}" '"url": "/bff/user/mastodon/system/custom_emojis/images/1/blob.png"' "...and a /system/ URL (custom emoji)"
hasnt "${acct}" "https://${LD}/avatars/" "no avatar URL is left pointing at https://${LD}"
has   "${acct}" "\"url\": \"https://${LD}/@e2e_usera\"" "the account url (a permalink) is NOT rewritten"
has   "${acct}" "\"uri\": \"https://${LD}/users/e2e_usera\"" "the account uri (federation identity) is NOT rewritten"
has   "${acct}" "href=\\\"https://${LD}/tags/hello\\\"" "a link inside the note HTML is NOT rewritten"

home="$(get "${FRONT_URL}/api/v1/timelines/home?limit=20")"
has "${home}" '"preview_url": "/bff/user/mastodon/system/media_attachments/files/1/small/a.png"' "a media attachment's preview_url is rewritten"
has "${home}" '"url": "/bff/user/mastodon/system/media_attachments/files/1/original/a.png"' "...and its url"
has "${home}" "\"url\": \"https://${LD}/@e2e_usera/1\"" "...while the status permalink is left alone"
has "$(get "${FRONT_URL}/api/v2/instance")" '"url": "/bff/user/mastodon/packs/media/images/preview.png"' "a /packs/ asset URL (instance thumbnail) is rewritten"
has "$(get "${FRONT_URL}/avatars/original/missing.png")" "200 image/png" "the rewritten path's bytes are served through the front (what the hsproxy forwards to)"

# The streaming route. A python client times frame 1: the stand-in holds the
# stream open for 6 s after it, so frame 1 arriving before that proves the front
# relays frame by frame instead of buffering the stream.
sse() {  # $1=base url $2=Host
  python3 - "$1" "$2" <<'PY'
import http.client, sys, time, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1])
c = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
t0 = time.monotonic()
c.request("GET", "/api/v1/streaming/user", headers={
    "Host": sys.argv[2], "X-Forwarded-Proto": "https", "Accept": "text/event-stream",
    "Authorization": "Bearer native-token"})
r = c.getresponse()
first, f1, frames = None, "", 0
if r.status == 200:
    while True:
        line = r.readline()
        if not line:
            break
        if line.startswith(b"data:"):
            frames += 1
            if first is None:
                first, f1 = round(time.monotonic() - t0, 1), line.decode().strip()
print(f"status={r.status} ct={r.getheader('Content-Type')} location={r.getheader('Location')} "
      f"first={first} frames={frames}")
print(f1)
PY
}
s_direct="$(sse "${WEB_URL}" "${PIN}")"
s_front="$(sse "${FRONT_URL}" "mastodon-front:${LISTEN}")"
has "${s_direct}" "status=301" "control: mastodon-web (stand-in) answers /api/v1/streaming/user with Rails' 301"
has "${s_direct}" "location=https://${LD}/api/v1/streaming/user" "control: ...to https://${LD}/..., the redirect the browser saw"
has "${s_front}" "status=200 ct=text/event-stream" "through the front: /api/v1/streaming/user is 200 text/event-stream (the streaming server, not Rails)"
first="$(printf '%s' "${s_front}" | sed -n 's/.* first=\([^ ]*\) .*/\1/p' | head -1)"
python3 -c "import sys; sys.exit(0 if '${first}' not in ('', 'None') and float('${first}') < 4 else 1)"
check $? "frame 1 arrives while the stream is still open (first=${first:-never}s, held 6 s): not buffered"
has "${s_front}" "frames=2" "the stream runs to its end through the front"
has "${s_front}" '"avatar": "/bff/user/mastodon/system/accounts/avatars/9/original/me.png"' "a media URL inside a LIVE frame is rewritten too"
has "${s_front}" "\"url\": \"https://${LD}/@me\"" "...and a permalink inside it is not"
seen="$(python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:${STREAM_PORT}/__seen',timeout=5).read().decode())")"
has "${seen}" '"stream_auth": "Bearer native-token"' "the native token user-bff injects reaches the streaming server"

# The upload is sent WITHOUT X-Forwarded-Proto, the way the media proxy sends it:
# user-bff's MediaWebClientConfig builds its client with no such default (only the
# hsproxy's HsProxyConfig adds one). Rails' force_ssl answers that with a 308
# (measured on mastodon-web: POST /api/v2/media -> 308 https://mastodon-web:3000/...),
# so the front's own `X-Forwarded-Proto https` is what lets a cloaked upload land.
up_body="$(python3 - "${FRONT_URL}" "${LISTEN}" <<'PY'
import sys, urllib.request, urllib.error
data = b"x" * (2 * 1024 * 1024)
req = urllib.request.Request(sys.argv[1] + "/api/v2/media", data=data, method="POST", headers={
    "Host": "mastodon-front:" + sys.argv[2], "Content-Type": "application/octet-stream"})
try:
    r = urllib.request.urlopen(req, timeout=30); print(r.status, r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read()[:80])
PY
)"
has "${up_body}" '200 {"received": 2097152' "a 2 MB upload with no X-Forwarded-Proto reaches mastodon-web whole (no 413 from nginx's 1 MB default, no force_ssl 308)"
has "${up_body}" '"url": "/bff/user/mastodon/system/media_attachments/files/2/original/b.png"' "the upload's answer is rewritten like any other (the media proxy's path)"

echo
echo "== mastodon-front: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
