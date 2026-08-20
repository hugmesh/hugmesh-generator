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
// THE BAN SIDE — protocol identity the rebrand RETIRED (tokens.json
// `retired_protocol_constants`). Folded into the SAME fail-closed match as the live
// constants: a retired spelling in a template/profile/emitted repo is drift, and
// refusing it at emit is the only place the templating path can still catch it.
// Kept as its own spec block (and its own isRetired()) so callers that must tell
// "our live identity" from "a dead spelling" — ingest-foreign-base.sh's
// impersonation scan reads frozen_protocol_constants ONLY — are not misled.
const RETIRED = spec.retired_protocol_constants || {};
const FROZEN_LABEL_NS = [...(FROZEN.label_key_namespaces || []), ...(RETIRED.label_key_namespaces || [])];
const FROZEN_HEADERS = [...(FROZEN.wire_headers || []), ...(RETIRED.wire_headers || [])].map((h) => h.toLowerCase());
const FROZEN_SUBPROTO = [...(FROZEN.subprotocol_prefixes || []), ...(RETIRED.subprotocol_prefixes || [])];
const RETIRED_TERMS = [
  ...(RETIRED.label_key_namespaces || []),
  ...(RETIRED.wire_headers || []),
  ...(RETIRED.subprotocol_prefixes || []),
];

/** A token whose render TARGET is a RETIRED protocol constant — a spelling the
 *  rebrand killed. isFrozen() already refuses these; this narrower predicate tells
 *  a caller WHY, and lets the impersonation scan keep asking only about live ones. */
function isRetired(token) {
  const t = String(token);
  const tl = t.toLowerCase();
  return RETIRED_TERMS.some((term) => t.includes(term) || tl === term.toLowerCase());
}

/** A token whose render TARGET is a frozen protocol constant — a k8s label-KEY
 *  namespace (hugmesh.net/…), a wire header name, or a Sec-WebSocket
 *  subprotocol prefix. These are compiled-in wire/label identity, NOT tenant
 *  brand; templating one would corrupt the protocol (and, for label keys, need a
 *  per-tenant recompile). Fail-closed: any token string that lands on one of
 *  these is refused at emit. This is the Phase-3 red-team gate — a brand profile
 *  that tries to override e.g. `hugmesh.net/domain` is BLOCKED.
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

// ── THE THEME CONTRACT (tokens.json `theme_contract_constants`) ─────────────
// A SEPARATE category from the frozen protocol constants, deliberately kept out
// of isFrozen(): those are wire/label identity that a foreign base carrying them
// is IMPERSONATING us with (ingest-foreign-base.sh scans for exactly that), while
// these are an intra-fleet delivery hand-off — env-var name -> entrypoint hook ->
// css filename -> <link> href -> --hug-*/--sd-* custom property. Nobody impersonates us
// by shipping a snap-theme.css. What they DO is rename one end of the chain and
// silently serve an unthemed page, so the names get their own predicate and their
// own refusal message rather than being smuggled into the protocol block.
const THEME = spec.theme_contract_constants || {};
const THEME_ENV_KEYS = new Set(THEME.env_keys || []);
const THEME_CSS_PREFIXES = [...(THEME.css_variable_prefixes || [])];

// ── DECLARED rename contracts (any block's `rename_denylist`) ────────────────
// PATHS, not tokens: fixed-name files whose NAME a process OTHER than the one
// that writes them depends on. Collected from EVERY top-level block that
// declares a `rename_denylist` array, so adding a future contract family is a
// tokens.json edit with no code change here — while each contract's filenames,
// its other halves and its _comment stay colocated in ONE block instead of
// being split across a generic name-bucket and a floating comment key.
// Deliberately NOT routed through isAllowed/isDenied/isFrozen: those classify
// {{token}} identifiers, and putting a FILENAME on denylist.keys would also make
// scripts/secret-scan.sh (which mirrors that list) report it as a secret.
const DECLARED_RENAME_DENYLIST = new Set(
  Object.values(spec)
    .filter((b) => b && typeof b === 'object' && !Array.isArray(b))
    .flatMap((b) => (Array.isArray(b.rename_denylist) ? b.rename_denylist : []))
);

/** True when `name`'s BASENAME is a declared fixed-name contract file that no
 *  emitted tree may rename (currently the theme delivery chain: .theme.css,
 *  50-snap-theme.sh, snap-theme.css). render-recipe.js unions this into its
 *  renames[] contract denylist. Basename-matched so a subdirectory copy — the
 *  same laundering move A12 pins for the admission stamps — cannot slip past. */
function isRenameContractFile(name) {
  return DECLARED_RENAME_DENYLIST.has(path.basename(String(name)));
}

/** A token whose render TARGET is a theme-contract IDENTIFIER — the env/ARG key
 *  the css text travels under (SNAP_THEME_CSS, SNAP_THEME_OUT) or the locale-set
 *  key in BOTH its live and retired spellings (HUG_WEB_LOCALES — what the
 *  producers emit since rename phase 3c — and SNAP_WEB_LOCALES, still written as
 *  a skew mirror and still read by the login-ui image),
 *  or a custom property under either pinned palette prefix — the live one
 *  (--hug-…) and the retired one it replaced (--sd-…), both still read somewhere
 *  in the fleet. Both ends of each are pinned literals in DIFFERENT repos, so
 *  templating one rebrands exactly one end and breaks the hand-off with no build
 *  or boot error. Substring match on the css prefixes (--hug-accent, --sd-bg-0, …
 *  are one contract, not an enumerable list).
 *  NB: spell these with an ellipsis, never with a trailing asterisk. A glob-style
 *  prefix written immediately before a slash closes the JSDoc block early and
 *  takes the rest of this file's parse down with it (SyntaxError at require
 *  time, so every gate that loads the classifier fails at once). */
function isThemeContract(token) {
  const t = String(token);
  if (THEME_ENV_KEYS.has(t)) return true;
  return THEME_CSS_PREFIXES.some((p) => p && t.includes(p));
}

module.exports = {
  isDenied, isAllowed, isFrozen, isRetired, isThemeContract, isRenameContractFile,
  ALLOW, DENY_KEYS, DENY_NAME_RE, FROZEN, RETIRED, THEME, DECLARED_RENAME_DENYLIST, spec,
};
