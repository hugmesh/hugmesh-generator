#!/usr/bin/env bash
# test-gen-sso-session-start.sh — unit test for the GEN-SSO session-start leg of
# desktop-app-governance: the OIDC-token DEPOSIT (Seam #1), the XDG autostart +
# session-start wrapper (Seam #2), and the self-contained session-install.sh that
# renders + publishes them. Headless, NO root (no real provisioning, mounts,
# flatpak, mapper cron, or display manager).
#
# Proves:
#   DEPOSIT (oidc-token-deposit.sh):
#     * governed + token in env  => writes ${XDG_RUNTIME_DIR}/hugmesh/oidc-token
#       mode 0600, content == token, never exported into the environment.
#     * governed + token in a user-private drop => same.
#     * UNGOVERNED                => writes NOTHING (ships-dark).
#     * governed + NO token       => writes NOTHING (fail-closed, empty store).
#     * --clear                   => removes a pre-existing token.
#   SESSION-INSTALL (session-install.sh):
#     * governed + valid domain   => renders the 2 helper scripts (0755) and
#       publishes /etc/xdg/autostart/...desktop (0644), @@CLUSTER_DOMAIN@@ gone.
#     * UNGOVERNED                => renders/publishes NOTHING.
#     * invalid domain (sed metachars / newline) => refuses (no render, exit 0).
#     * idempotent re-run.
#     * the rendered .desktop has NO OnlyShowIn (LXDE+XFCE).
#   WRAPPER (hugmesh-desktop-sso-start.sh):
#     * governed-gated; UNGOVERNED => inert (no bash_logout edit, no deposit).
#     * installs an LXDE/XFCE ~/.bash_logout clear (NOT a Plasma-only path).
#   BRIDGE: after a governed run, bearer-forward's token source IS satisfied
#     (the deposit wrote the file bearer-forward reads).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL="${REPO}/specs/etc/hugmesh/desktop-governance"
DEP_TPL="${TPL}/discover/oidc-token-deposit.sh.tmpl"
WRAP_TPL="${TPL}/autostart/hugmesh-desktop-sso-start.sh.tmpl"
DESKTOP_TPL="${TPL}/autostart/hugmesh-desktop-sso.desktop.tmpl"
INSTALL_TPL="${TPL}/autostart/session-install.sh.tmpl"
for f in "${DEP_TPL}" "${WRAP_TPL}" "${DESKTOP_TPL}" "${INSTALL_TPL}"; do
    [ -f "${f}" ] || { echo "  FAIL template missing: ${f}"; exit 1; }
done

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

SANDBOXES=()
cleanup(){ for d in "${SANDBOXES[@]:-}"; do rm -rf "${d}" 2>/dev/null; done; }
trap cleanup EXIT

# Build a sandbox. $1 = governed|ungoverned. Lays out:
#   ROOT  -> stands in for /  (so /etc/... -> ROOT/etc/..., /etc/xdg -> ROOT/etc/xdg)
#   RUN   -> XDG_RUNTIME_DIR
#   HOME  -> the user's home
#   KEYS  -> the mounted KEYS USB (carries desktop-governance/ templates)
# A GOVERNED sandbox has a rendered desktop-sudo mapper + bearer-forward.sh (the
# two is_governed markers) + a baked desktop-governance dir; an UNGOVERNED one
# has none of them.
new_sandbox() {
    WORK="$(mktemp -d)"; SANDBOXES+=("${WORK}")
    ROOT="${WORK}/root"; RUN="${WORK}/run"; HOMED="${WORK}/home"; KEYS="${WORK}/keys"
    mkdir -p "${ROOT}/etc" "${RUN}" "${HOMED}" "${KEYS}"
    if [ "${1:-governed}" = "governed" ]; then
        mkdir -p "${ROOT}/etc/hugmesh/desktop-governance"
        # (governed) rendered desktop-sudo mapper + bearer-forward.sh. The mapper
        # gets its PRODUCTION mode 0700 (provision.sh renders it root-only).
        printf '#!/bin/sh\nexit 0\n' > "${ROOT}/etc/hugmesh/desktop-governance/desktop-sudo-mapper"
        chmod 0700 "${ROOT}/etc/hugmesh/desktop-governance/desktop-sudo-mapper"
        printf '#!/bin/sh\nexit 0\n' > "${ROOT}/etc/hugmesh/desktop-governance/bearer-forward.sh"
        chmod 0755 "${ROOT}/etc/hugmesh/desktop-governance/bearer-forward.sh"
        # KEYS carries the templates (the is_governed KEYS branch + render source)
        cp -r "${TPL}" "${KEYS}/desktop-governance"
    fi
}

# Render a template, redirecting every absolute system path into the sandbox ROOT,
# and run it. Echoes nothing; the caller inspects the sandbox FS.
# $1=template-file  $2..=args to the rendered script.  Env knobs:
#   TOKEN_ENV : value for HUGMESH_OIDC_ACCESS_TOKEN (unset if empty)
run_script() {
    local src="$1"; shift
    local rendered; rendered="$(sed \
        -e "s#/etc/hugmesh/desktop-governance#${ROOT}/etc/hugmesh/desktop-governance#g" \
        -e "s#/etc/hugmesh/domains#${ROOT}/etc/hugmesh/domains#g" \
        -e "s#/etc/flatpak#${ROOT}/etc/flatpak#g" \
        -e "s#/etc/xdg/autostart#${ROOT}/etc/xdg/autostart#g" \
        "${src}")"
    XDG_RUNTIME_DIR="${RUN}" HOME="${HOMED}" KEYS_BASE="${KEYS}" \
    HUGMESH_OIDC_ACCESS_TOKEN="${TOKEN_ENV:-}" \
    bash -c "${rendered}" "_" "$@"
}

# session-install renders its source templates; point its SRC search at the KEYS
# copy by exporting KEYS_BASE (done in run_script) and making the baked path the
# rewritten ROOT one. The script's first SRC candidate is /etc/hugmesh/...
# which run_script rewrites to ROOT/etc/hugmesh/... — on a governed sandbox we
# also place the template *.tmpl there so the baked branch is exercised.
seed_baked_templates() {
    cp -r "${TPL}/." "${ROOT}/etc/hugmesh/desktop-governance/" 2>/dev/null || true
}

# Render the deposit template into the governance dir WITH absolute /etc paths
# rewritten to the sandbox ROOT, so when the wrapper chains to it its is_governed()
# and token paths resolve inside the sandbox (not the test host's real /etc).
seed_rendered_deposit() {
    local dst="${ROOT}/etc/hugmesh/desktop-governance/oidc-token-deposit.sh"
    sed -e "s#/etc/hugmesh/desktop-governance#${ROOT}/etc/hugmesh/desktop-governance#g" \
        "${DEP_TPL}" > "${dst}"
    chmod 0755 "${dst}"
}

echo "== GEN-SSO session-start unit test =="

# ── DEPOSIT 1: governed + env token => 0600 file, content matches, no export ───
new_sandbox governed
TOKEN_ENV="tok-abc.DEF-123" run_script "${DEP_TPL}" >/dev/null 2>&1
TF="${RUN}/hugmesh/oidc-token"
if [ -f "${TF}" ]; then
    [ "$(cat "${TF}")" = "tok-abc.DEF-123" ] && ok "deposit: token written verbatim" || bad "deposit: token content wrong"
    m="$(stat -c '%a' "${TF}" 2>/dev/null)"; [ "${m}" = "600" ] && ok "deposit: token file mode 0600" || bad "deposit: mode ${m} != 600"
else
    bad "deposit: governed+env => no token written"
fi
# The script must NOT export the token. (Run it and dump env; token value absent.)
new_sandbox governed
envdump="$(TOKEN_ENV="leaky-tok-xyz" run_script "${DEP_TPL}" 2>/dev/null; echo "---"; \
    XDG_RUNTIME_DIR="${RUN}" HOME="${HOMED}" HUGMESH_OIDC_ACCESS_TOKEN="leaky-tok-xyz" \
    bash -c "$(sed -e "s#/etc/hugmesh/desktop-governance#${ROOT}/etc/hugmesh/desktop-governance#g" "${DEP_TPL}"); env" 2>/dev/null | grep -c 'leaky-tok-xyz' || true)"
# Only the HUGMESH_OIDC_ACCESS_TOKEN input itself appears in env (count 1); the
# script must not create a SECOND exported var carrying it. We assert no NEW export
# named *TOKEN*/*BEARER* beyond the input.
extra="$(XDG_RUNTIME_DIR="${RUN}" HOME="${HOMED}" HUGMESH_OIDC_ACCESS_TOKEN="leaky-tok-xyz" \
    bash -c "$(sed -e "s#/etc/hugmesh/desktop-governance#${ROOT}/etc/hugmesh/desktop-governance#g" "${DEP_TPL}"); env | grep -E 'leaky-tok-xyz' | grep -vE '^HUGMESH_OIDC_ACCESS_TOKEN='" 2>/dev/null || true)"
[ -z "${extra}" ] && ok "deposit: token never re-exported into the environment" || bad "deposit: token leaked to env: ${extra}"

# ── DEPOSIT 2: governed + user-private drop (no env) => deposited ──────────────
new_sandbox governed
mkdir -p "${RUN}/hugmesh"; printf 'drop-token-777\n' > "${RUN}/hugmesh/oidc-token.src"
TOKEN_ENV="" run_script "${DEP_TPL}" >/dev/null 2>&1
[ -f "${RUN}/hugmesh/oidc-token" ] && [ "$(cat "${RUN}/hugmesh/oidc-token")" = "drop-token-777" ] \
    && ok "deposit: reads user-private greeter drop when env unset" || bad "deposit: drop-file source not honored"

# ── DEPOSIT 3: UNGOVERNED => writes nothing (ships-dark) ───────────────────────
new_sandbox ungoverned
TOKEN_ENV="should-not-land" run_script "${DEP_TPL}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "${RUN}/hugmesh/oidc-token" ] \
    && ok "deposit: UNGOVERNED => no token written (ships-dark), rc 0" || bad "deposit: wrote token on ungoverned image"

# ── DEPOSIT 4: governed + NO token => writes nothing (fail-closed) ─────────────
new_sandbox governed
TOKEN_ENV="" run_script "${DEP_TPL}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "${RUN}/hugmesh/oidc-token" ] \
    && ok "deposit: governed + no token => empty store (fail-closed), rc 0" || bad "deposit: no-token did not fail closed"

# ── DEPOSIT 5: --clear removes a pre-existing token ────────────────────────────
new_sandbox governed
mkdir -p "${RUN}/hugmesh"; printf 'stale\n' > "${RUN}/hugmesh/oidc-token"
TOKEN_ENV="" run_script "${DEP_TPL}" --clear >/dev/null 2>&1
[ ! -e "${RUN}/hugmesh/oidc-token" ] && ok "deposit: --clear removes the deposited token" || bad "deposit: --clear left the token"

# ── DEPOSIT 6: KEYS-USB delivery reality — mapper-only, and root-only ──────────
# On the KEYS-USB path provision.sh renders bearer-forward.sh next to the KEYS
# templates, NOT into /etc, so the 0700 root:root mapper is the ONLY marker under
# /etc/hugmesh/desktop-governance. This script runs as the SESSION USER, for whom
# a root-only file is neither readable nor executable — mode 0000 reproduces that
# exactly (even the owner loses r/x). is_governed() must therefore test EXISTENCE:
# a `-x`/`-r` marker check reads the governed image as ungoverned and silently
# kills the deposit (and with it the whole sudo leg) on its only delivery path.
new_sandbox governed
rm -f "${ROOT}/etc/hugmesh/desktop-governance/bearer-forward.sh"
chmod 0000 "${ROOT}/etc/hugmesh/desktop-governance/desktop-sudo-mapper"
TOKEN_ENV="keys-path-token" run_script "${DEP_TPL}" >/dev/null 2>&1
[ -f "${RUN}/hugmesh/oidc-token" ] && [ "$(cat "${RUN}/hugmesh/oidc-token")" = "keys-path-token" ] \
    && ok "deposit: root-only mapper alone marks the image governed (KEYS-USB path)" \
    || bad "deposit: root-only mapper not recognized => KEYS-USB path deposits nothing"

# Same invariant for the session-start wrapper, which shares the marker check.
new_sandbox governed
rm -f "${ROOT}/etc/hugmesh/desktop-governance/bearer-forward.sh"
seed_rendered_deposit
chmod 0000 "${ROOT}/etc/hugmesh/desktop-governance/desktop-sudo-mapper"
TOKEN_ENV="keys-path-token" run_script "${WRAP_TPL}" >/dev/null 2>&1
[ -f "${RUN}/hugmesh/oidc-token" ] \
    && ok "wrapper: root-only mapper alone marks the image governed (KEYS-USB path)" \
    || bad "wrapper: root-only mapper not recognized => wrapper stays inert on a governed image"

# ── INSTALL 1: governed + valid domain => renders + publishes ──────────────────
new_sandbox governed
seed_baked_templates
printf 'acme.example\n' > "${ROOT}/etc/hugmesh/domains"
run_script "${INSTALL_TPL}" >/dev/null 2>&1; rc=$?
DESK="${ROOT}/etc/xdg/autostart/hugmesh-desktop-sso.desktop"
DEPSH="${ROOT}/etc/hugmesh/desktop-governance/oidc-token-deposit.sh"
WRAPSH="${ROOT}/etc/hugmesh/desktop-governance/hugmesh-desktop-sso-start.sh"
[ "${rc}" -eq 0 ] && ok "install: governed+valid domain rc 0" || bad "install: rc ${rc}"
if [ -f "${DESK}" ]; then
    m="$(stat -c '%a' "${DESK}")"; [ "${m}" = "644" ] && ok "install: .desktop published 0644" || bad "install: .desktop mode ${m}"
    ! grep -q '^OnlyShowIn=' "${DESK}" && ok "install: .desktop has NO OnlyShowIn key (LXDE+XFCE honored)" || bad "install: .desktop carries an OnlyShowIn key"
    grep -q 'Exec=/etc/hugmesh/desktop-governance/hugmesh-desktop-sso-start.sh' "${DESK}" \
        || grep -q "Exec=${ROOT}/etc/hugmesh/desktop-governance/hugmesh-desktop-sso-start.sh" "${DESK}" \
        && ok "install: .desktop Exec -> session-start wrapper" || bad "install: .desktop Exec wrong"
else
    bad "install: .desktop not published"
fi
[ -f "${DEPSH}" ] && [ "$(stat -c '%a' "${DEPSH}")" = "755" ] && ok "install: deposit script rendered 0755" || bad "install: deposit script not 0755"
[ -f "${WRAPSH}" ] && [ "$(stat -c '%a' "${WRAPSH}")" = "755" ] && ok "install: wrapper script rendered 0755" || bad "install: wrapper script not 0755"
# No leftover placeholder anywhere rendered.
if grep -rq '@@CLUSTER_DOMAIN@@' "${DESK}" "${DEPSH}" "${WRAPSH}" 2>/dev/null; then
    bad "install: @@CLUSTER_DOMAIN@@ placeholder left in a rendered file"
else
    ok "install: no @@CLUSTER_DOMAIN@@ placeholder left in rendered outputs"
fi

# ── INSTALL 2: idempotent re-run ───────────────────────────────────────────────
run_script "${INSTALL_TPL}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && [ -f "${DESK}" ] && ok "install: idempotent re-run (rc 0, .desktop still present)" || bad "install: re-run not idempotent"

# ── INSTALL 3: UNGOVERNED => nothing rendered/published ────────────────────────
new_sandbox ungoverned
mkdir -p "${ROOT}/etc/hugmesh"
printf 'acme.example\n' > "${ROOT}/etc/hugmesh/domains"
run_script "${INSTALL_TPL}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "${ROOT}/etc/xdg/autostart/hugmesh-desktop-sso.desktop" ] \
    && ok "install: UNGOVERNED => nothing published (ships-dark)" || bad "install: published on ungoverned image"

# ── INSTALL 4: invalid first-line domain (sed metachars / spaces) => refuse ────
# (The domains file is read first-line-only via grep, so a trailing injected line
# cannot survive; the threat is a metacharacter IN the first/primary domain.)
for craft in 'evil.example/g; s/x/y' 'a&b\c.example' 'UPPER.example' 'under_score.example'; do
    new_sandbox governed
    seed_baked_templates
    printf '%s\n' "${craft}" > "${ROOT}/etc/hugmesh/domains"
    run_script "${INSTALL_TPL}" >/dev/null 2>&1; rc=$?
    if [ "${rc}" -eq 0 ] && [ ! -e "${ROOT}/etc/xdg/autostart/hugmesh-desktop-sso.desktop" ]; then
        ok "install: invalid domain refused fail-closed (no render): $(printf '%q' "${craft}")"
    else
        bad "install: invalid domain NOT refused: $(printf '%q' "${craft}") rc=${rc}"
    fi
done

# ── WRAPPER 1: UNGOVERNED => inert (no ~/.bash_logout edit, no deposit) ─────────
new_sandbox ungoverned
TOKEN_ENV="x" run_script "${WRAP_TPL}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && ok "wrapper: UNGOVERNED rc 0 (inert)" || bad "wrapper: ungoverned rc ${rc}"
[ ! -e "${HOMED}/.bash_logout" ] && ok "wrapper: UNGOVERNED => no ~/.bash_logout written" || bad "wrapper: edited bash_logout on ungoverned image"
[ ! -e "${RUN}/hugmesh/oidc-token" ] && ok "wrapper: UNGOVERNED => no token deposited" || bad "wrapper: deposited token on ungoverned image"

# ── WRAPPER 2: governed => installs LXDE/XFCE bash_logout clear (NOT Plasma) ────
new_sandbox governed
seed_baked_templates
# Provide the rendered deposit script (sandbox-path-rewritten) the wrapper chains to.
seed_rendered_deposit
TOKEN_ENV="wraptok-1" run_script "${WRAP_TPL}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && ok "wrapper: governed rc 0" || bad "wrapper: governed rc ${rc}"
if [ -f "${HOMED}/.bash_logout" ]; then
    grep -q 'hugmesh-desktop-sso: clear SSO bearer/token on logout' "${HOMED}/.bash_logout" \
        && ok "wrapper: installs an LXDE/XFCE ~/.bash_logout logout clear" || bad "wrapper: bash_logout clear missing"
    ! grep -q 'plasma-workspace/shutdown' "${HOMED}/.bash_logout" \
        && ok "wrapper: logout clear is NOT the Plasma-only shutdown/ path" || bad "wrapper: used Plasma-only path"
else
    bad "wrapper: governed => no ~/.bash_logout written"
fi
# Idempotent: re-run does not duplicate the block.
TOKEN_ENV="wraptok-2" run_script "${WRAP_TPL}" >/dev/null 2>&1
cnt="$(grep -c 'hugmesh-desktop-sso: clear SSO bearer/token on logout' "${HOMED}/.bash_logout" 2>/dev/null || echo 0)"
[ "${cnt}" = "1" ] && ok "wrapper: ~/.bash_logout clear is idempotent (single block)" || bad "wrapper: bash_logout block duplicated (${cnt})"

# ── BRIDGE: governed wrapper run satisfies bearer-forward's token source ────────
new_sandbox governed
seed_baked_templates
seed_rendered_deposit
# Make the chained bearer-forward a no-op stub so the wrapper completes; the point
# is the deposit ran and wrote the token bearer-forward reads.
printf '#!/bin/sh\nexit 0\n' > "${ROOT}/etc/hugmesh/desktop-governance/bearer-forward.sh"
chmod 0755 "${ROOT}/etc/hugmesh/desktop-governance/bearer-forward.sh"
TOKEN_ENV="bridge-tok-999" run_script "${WRAP_TPL}" >/dev/null 2>&1
# bearer-forward.sh.tmpl reads ${XDG_RUNTIME_DIR}/hugmesh/oidc-token — assert it now exists.
[ -f "${RUN}/hugmesh/oidc-token" ] && [ "$(cat "${RUN}/hugmesh/oidc-token")" = "bridge-tok-999" ] \
    && ok "bridge: deposit wrote the exact path bearer-forward reads (token source satisfied)" \
    || bad "bridge: bearer-forward token source NOT satisfied after wrapper run"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
