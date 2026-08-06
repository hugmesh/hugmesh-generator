#!/usr/bin/env bash
# _github-auth-lib.sh — SOURCED helper: make a GitHub clone ASK for credentials
# instead of hanging or dying with a git-level message nobody can act on.
#
# WHY THIS EXISTS.
# Snapdragon-Systems is a PRIVATE org (an anonymous API GET of any repo returns
# 404, GitHub's masking for private). Every first-party clone therefore needs
# credentials, and before this lib the two failure modes were both bad:
#
#   * no TTY (the Studio drives the build, stdout piped into the session log):
#       fatal: could not read Username for 'https://github.com'
#     — a git-level message that never says "log in to GitHub".
#   * a TTY (operator terminal): git PROMPTS for Username/Password, and GitHub
#     has not accepted passwords since 2021. The operator types credentials that
#     CANNOT work, and the build blocks until they give up.
#
# So: resolve credentials up front, use them, and when there are none say so in
# one actionable line — prompting only where a human can actually answer.
#
# NEVER LOG THE TOKEN. The obvious implementation embeds it in the clone URL
# (https://oauth2:$TOKEN@github.com/...), which is what scripts/gitlab-mirror-org.sh
# does. That is fine for a one-shot admin script, but a builder's stdout is teed
# into out/sessions/*.log and rendered in the Studio, so a token in the URL would
# be written to disk and shown on screen. This lib passes the token through
# GIT_ASKPASS instead: it never reaches argv (ps), never reaches the URL, and
# never reaches the log.

# ── credential resolution ───────────────────────────────────────────────────────
# Order is deliberate: an EXPLICIT env token wins (that is how CI injects one),
# then the gh keyring.
#
# THE GH_TOKEN TRAP, learned the hard way on this fleet: an exported read-only
# GH_TOKEN SHADOWS a perfectly good `gh auth login` keyring session, so a clone
# fails 404 while `gh auth status` looks healthy. gh_auth_hint() names that case
# explicitly rather than leaving the operator to rediscover it.
gh_auth_token() {
    if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "${GH_TOKEN}"; return 0; fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "${GITHUB_TOKEN}"; return 0; fi
    if command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null && return 0
    fi
    return 1
}

gh_auth_source() {
    if [ -n "${GH_TOKEN:-}" ]; then printf 'GH_TOKEN'; return 0; fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then printf 'GITHUB_TOKEN'; return 0; fi
    if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
        printf 'gh keyring'; return 0
    fi
    printf 'none'
}

# True when a human is actually there to answer a prompt. A build driven by the
# Studio, cron or CI has no answerable terminal, and prompting there is exactly
# how a build wedges forever.
gh_auth_interactive() {
    [ -t 0 ] && [ -t 2 ] && [ -z "${CI:-}" ] && [ "${HUGMESH_NONINTERACTIVE:-0}" != "1" ]
}

gh_auth_hint() {
    local what="${1:-github.com/Snapdragon-Systems}"
    echo "[github-auth] No usable GitHub credentials for ${what}." >&2
    echo "[github-auth]   This org is PRIVATE — an anonymous clone gets 404, not a login prompt." >&2
    echo "[github-auth]   Fix (any one):" >&2
    echo "[github-auth]     gh auth login                  # interactive, stores in the keyring" >&2
    echo "[github-auth]     export GH_TOKEN=<PAT>          # non-interactive / CI" >&2
    if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
        echo "[github-auth]   NOTE: a token IS set ($(gh_auth_source)) and was refused." >&2
        echo "[github-auth]   An exported read-only GH_TOKEN SHADOWS your gh keyring login." >&2
        echo "[github-auth]   If \`gh auth status\` looks fine, retry with:  env -u GH_TOKEN <cmd>" >&2
    fi
}

# ── the askpass shim ────────────────────────────────────────────────────────────
# git calls GIT_ASKPASS with a human prompt and reads one line of stdout. We answer
# from the environment, so the token stays out of argv and out of the log.
_GH_ASKPASS_FILE=""
gh_auth_askpass_begin() {
    local tok="$1"
    _GH_ASKPASS_FILE="$(mktemp "${TMPDIR:-/tmp}/hugmesh-askpass.XXXXXX")" || return 1
    chmod 0700 "${_GH_ASKPASS_FILE}" 2>/dev/null || true
    # The token is NOT written into this file — only a reference to the variable.
    cat >"${_GH_ASKPASS_FILE}" <<'ASKPASS'
#!/bin/sh
# git asks for "Username" first, then "Password". x-access-token is GitHub's
# documented username for token auth.
case "$1" in
  *[Uu]sername*) printf '%s\n' "x-access-token" ;;
  *)             printf '%s\n' "${HUGMESH_GH_TOKEN}" ;;
esac
ASKPASS
    chmod 0700 "${_GH_ASKPASS_FILE}"
    export HUGMESH_GH_TOKEN="${tok}"
    export GIT_ASKPASS="${_GH_ASKPASS_FILE}"
    # Belt and braces: even with an askpass set, never let git fall through to a
    # blocking terminal prompt. A wedged build is worse than a failed one.
    export GIT_TERMINAL_PROMPT=0
}

gh_auth_askpass_end() {
    [ -n "${_GH_ASKPASS_FILE}" ] && rm -f "${_GH_ASKPASS_FILE}"
    _GH_ASKPASS_FILE=""
    unset HUGMESH_GH_TOKEN GIT_ASKPASS
}

# ── the one call sites use ──────────────────────────────────────────────────────
# gh_auth_ensure [what]
#   0 = credentials are in place (askpass armed; caller must gh_auth_askpass_end)
#   1 = none available; the caller should fail with gh_auth_hint already printed.
#
# Interactive callers get ONE offer to log in — that is the operator's
# "ask for github authentication". Non-interactive callers never prompt: they get
# the hint and a clean non-zero, so the build fails fast and legibly instead of
# blocking on a question nobody will answer.
gh_auth_ensure() {
    local what="${1:-github.com/Snapdragon-Systems}" tok=""
    if tok="$(gh_auth_token)" && [ -n "${tok}" ]; then
        gh_auth_askpass_begin "${tok}" || return 1
        return 0
    fi
    if gh_auth_interactive && command -v gh >/dev/null 2>&1; then
        echo "[github-auth] ${what} needs GitHub credentials and none were found." >&2
        printf '[github-auth] Run `gh auth login` now? [y/N] ' >&2
        local reply=""
        read -r reply </dev/tty 2>/dev/null || reply=""
        case "${reply}" in
            [yY]*)
                gh auth login || true
                if tok="$(gh_auth_token)" && [ -n "${tok}" ]; then
                    gh_auth_askpass_begin "${tok}" || return 1
                    return 0
                fi
                ;;
        esac
    fi
    # No TTY, no gh, or the operator declined / the login did not take.
    export GIT_TERMINAL_PROMPT=0
    gh_auth_hint "${what}"
    return 1
}
