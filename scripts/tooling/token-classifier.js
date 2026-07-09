'use strict';
// token-classifier.js — allow/deny classification for mesh repo-templating tokens.
//
// BUILD-HOST ONLY. See docs/MESH-TEMPLATING.md: this tooling requires Node and
// MUST NOT run as root on the mesh-node fail-closed root-cron path (Phase 6).
//
// Loads scripts/tooling/tokens.json and exposes pure classification helpers used
// by render-handlebars.js (fail-closed on any denylisted token) and available to
// other guardrails. No I/O beyond reading the JSON once at require time.

const fs = require('fs');
const path = require('path');

const TOKENS_PATH = path.join(__dirname, 'tokens.json');
const spec = JSON.parse(fs.readFileSync(TOKENS_PATH, 'utf8'));

const ALLOW = new Set([
  ...spec.allowlist.live,
  ...spec.allowlist.dead,
  ...spec.allowlist.reserved_pilot,
]);
const DENY_KEYS = new Set(spec.denylist.keys);
const DENY_NAME_RE = new RegExp(spec.denylist.key_name_regex);

/** A token explicitly on the secret denylist, or whose NAME matches the
 *  secret-key regex (PASS/SECRET/TOKEN/...). Fail-closed: deny wins. */
function isDenied(token) {
  return DENY_KEYS.has(token) || DENY_NAME_RE.test(token);
}

/** A git-safe brand-delta token that may be substituted/emitted. */
function isAllowed(token) {
  return ALLOW.has(token) && !isDenied(token);
}

const FROZEN = spec.frozen_protocol_constants;

module.exports = { isDenied, isAllowed, ALLOW, DENY_KEYS, DENY_NAME_RE, FROZEN, spec };
