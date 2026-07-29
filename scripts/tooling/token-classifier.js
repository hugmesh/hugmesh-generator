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
const FROZEN_LABEL_NS = FROZEN.label_key_namespaces || [];
const FROZEN_HEADERS = (FROZEN.wire_headers || []).map((h) => h.toLowerCase());
const FROZEN_SUBPROTO = FROZEN.subprotocol_prefixes || [];

/** A token whose render TARGET is a frozen protocol constant — a k8s label-KEY
 *  namespace (hugmesh.systems/…), a wire header name, or a Sec-WebSocket
 *  subprotocol prefix. These are compiled-in wire/label identity, NOT tenant
 *  brand; templating one would corrupt the protocol (and, for label keys, need a
 *  per-tenant recompile). Fail-closed: any token string that lands on one of
 *  these is refused at emit. This is the Phase-3 red-team gate — a brand profile
 *  that tries to override e.g. `hugmesh.systems/domain` is BLOCKED.
 *  Match is on the token STRING (a frozen-namespace substring, or an exact
 *  header/subprotocol identity), so it fires even though these are not valid
 *  {{identifier}} names. */
function isFrozen(token) {
  const t = String(token);
  const tl = t.toLowerCase();
  if (FROZEN_LABEL_NS.some((ns) => t.includes(ns))) return true;
  if (FROZEN_HEADERS.includes(tl)) return true;
  if (FROZEN_SUBPROTO.some((p) => t.startsWith(p) || t.includes(p))) return true;
  return false;
}

module.exports = { isDenied, isAllowed, isFrozen, ALLOW, DENY_KEYS, DENY_NAME_RE, FROZEN, spec };
