// mock-bff.mjs — stands in for the Spring user/admin BFF (behind the gateway) for
// the NATIVE-LOGIN model. The browser's ONLY login surface is our own login-ui
// username/password form, which POSTs { username, password } to POST /bff/login;
// this mock verifies the credential, mints an opaque httpOnly `bff_session` cookie
// (Set-Cookie) and returns ONLY non-secret routing hints (registrationComplete,
// status) — never a token. Casdoor is never browser-exposed. Auth for every other
// /bff/** call is that cookie (credentials: 'include'); the browser holds no bearer.
//
// TWO-STAGE registration is preserved:
//   1. an admin INVITES an identity via POST /bff/admin/allowlist { email } — that
//      provisions a native account (registrationComplete=false, password=E2E) so
//      the identity becomes sign-in-able. An UN-invited identity has no account, so
//      POST /bff/login 401s { error:'invalid_credentials' } and the form shows
//      "Sign-in failed" (native login has NO self-registration surface).
//   2. POST /bff/register/complete { displayName, screenReaderName } finishes
//      registration; the Matrix/Mastodon service tokens are brokered server-side on
//      POST /bff/provision/{matrix,mastodon} and injected by the /bff/user/**
//      hsproxy — the browser never holds a homeserver token. In-memory.
import http from 'node:http';

const PORT = Number(process.env.PORT || 8403);
const ADMINS = new Set((process.env.ADMIN_EMAILS || 'admin@hugmesh.systems').split(','));
// The deterministic native password every seeded/invited persona signs in with —
// matches the e2e helper's LOGIN_PASSWORD (E2E_PASSWORD ?? 'e2e-pass').
const LOGIN_PASSWORD = process.env.E2E_PASSWORD || 'e2e-pass';
const allowEmails = new Set([...ADMINS]);     // emails an admin invited (provisioned)
const allowDiscord = new Set();               // discord handles an admin invited
const accounts = new Map();                   // username -> {username,label,roles,registrationComplete,password,matrix?,mastodon?}
const sessions = new Map();                   // bff_ token -> username
const grants = new Map();                     // username -> Set(namespace) (admin-granted namespace access)
const usageMem = [];                          // in-memory usage events (fallback when ClickHouse is absent)
const NAMESPACES = ['hugmesh-pki', 'hugmesh-backend', 'hugmesh-frontend', 'hugmesh-games', 'observability'];
// Per-gateway role->URL external access rules (stands in for the Postgres
// gateway_route_access table the gateways read + Cassandra-cache).
let nextRule = 1;
const routeAccess = [
  { id: String(nextRule++), gateway: 'hugmesh-fe-gateway', url_pattern: '/admin/**', role: 'ROLE_ADMIN', allow: true },
  { id: String(nextRule++), gateway: 'hugmesh-fe-gateway', url_pattern: '/social/**', role: 'ROLE_USER', allow: true },
  { id: String(nextRule++), gateway: 'hugmesh-be-gateway', url_pattern: '/api/**', role: 'ROLE_USER', allow: true },
];
// Latest delivered ISO artifacts (stands in for the GitLab generic package "latest" links).
const ISOS = [
  { name: 'gentoo-rpi5-arm64-pki-k8s-2026.0.iso', url: 'https://gitlab.hugmesh.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-rpi5-arm64-pki-k8s-2026.0.iso' },
  { name: 'gentoo-rpi5-arm64-backend-k8s-2026.0.iso', url: 'https://gitlab.hugmesh.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-rpi5-arm64-backend-k8s-2026.0.iso' },
  { name: 'gentoo-rpi5-arm64-frontend-k8s-2026.0.iso', url: 'https://gitlab.hugmesh.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-rpi5-arm64-frontend-k8s-2026.0.iso' },
  { name: 'gentoo-x86-hugmesh-host-2026.0.iso', url: 'https://gitlab.hugmesh.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-x86-hugmesh-host-2026.0.iso' },
];
// Real-service brokering: the BFF mints Matrix (Synapse) + Mastodon tokens
// server-side so the UI never holds homeserver admin creds. Point at the real
// Synapse/Mastodon; default to the integration stack ports.
const SYNAPSE_URL = process.env.SYNAPSE_URL || 'http://localhost:8008';
const MASTODON_URL = process.env.MASTODON_URL || 'http://localhost:8402';
const SVC_PW = process.env.SVC_PASSWORD || 'hugmesh-svc-pw';

const send = (res, code, obj, extraHeaders = {}) => {
  res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*',
    'access-control-allow-credentials': 'true',
    'access-control-allow-headers': 'authorization,content-type,x-csrf-token',
    'access-control-allow-methods': '*', ...extraHeaders });
  res.end(JSON.stringify(obj));
};
async function bodyOf(req) { let d=''; for await (const c of req) d+=c; return d ? JSON.parse(d) : {}; }

// ── Opaque bff_ session cookie (httpOnly) — the ONLY auth the browser holds ──
function newSession(acct) {
  const t = `bff_${Math.random().toString(36).slice(2, 12)}`;
  sessions.set(t, acct.username);
  return t;
}
const setCookieHeader = (token) =>
  ({ 'set-cookie': `bff_session=${token}; HttpOnly; Path=/; SameSite=Lax` });
/** Resolve the caller from the httpOnly bff_session cookie (native model); fall
 *  back to a legacy Authorization: Bearer for any pre-cookie caller. */
function sessionOf(req) {
  const cookie = req.headers['cookie'] || '';
  const m = cookie.match(/(?:^|;\s*)bff_session=([^;]+)/);
  let token = m ? m[1] : null;
  if (!token) {
    const h = req.headers['authorization'] || '';
    if (h.startsWith('Bearer ')) token = h.slice(7);
  }
  const username = token ? sessions.get(token) : null;
  return username ? accounts.get(username) : null;
}

// ── Usage analytics → ClickHouse ───────────────────────────────────
const CH_URL = process.env.CLICKHOUSE_URL || 'http://localhost:8123';
const CH_USER = process.env.CLICKHOUSE_USER || 'snap';
const CH_PASS = process.env.CLICKHOUSE_PASSWORD || 'snap';
const chErr = (s) => console.log('[mock-bff] clickhouse:', s);
async function ch(sql) {
  const r = await fetch(`${CH_URL}/`, { method: 'POST',
    headers: { 'X-ClickHouse-User': CH_USER, 'X-ClickHouse-Key': CH_PASS }, body: sql });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.text();
}
async function ensureUsageTable() {
  try {
    await ch('CREATE DATABASE IF NOT EXISTS hugmesh');
    await ch('CREATE TABLE IF NOT EXISTS hugmesh.usage_events ' +
             '(ts DateTime DEFAULT now(), actor String, role String, action String, module String) ' +
             'ENGINE = MergeTree ORDER BY ts');
    chErr('usage_events ready');
  } catch (e) { chErr('unavailable: ' + e.message); }
}
const MODULE_OF = { login: 'login-ui', register: 'login-ui', complete: 'login-ui',
  'admin.invite': 'admin-ui', 'admin.grant': 'admin-ui',
  'matrix.entitled': 'matrix-ui', 'mastodon.entitled': 'mastodon-ui' };
function record(actor, roles, action) {
  const role = (roles || []).includes('admin') ? 'admin' : 'user';
  const mod = MODULE_OF[action] || 'host';
  usageMem.push({ actor: String(actor), role, action, module: mod, ts: Date.now() });
  const esc = (s) => String(s).replace(/'/g, "\\'");
  ch(`INSERT INTO hugmesh.usage_events (actor, role, action, module) VALUES ('${esc(actor)}','${role}','${action}','${mod}')`).catch((e) => chErr('insert: ' + e.message));
}
function usageFromMemory() {
  const hourAgo = Date.now() - 3600_000;
  const mods = new Map(), acts = new Map(), recent = new Set();
  for (const e of usageMem) {
    const m = mods.get(e.module) || { module: e.module, events: 0, users: new Set() };
    m.events++; m.users.add(e.actor); mods.set(e.module, m);
    acts.set(e.action, (acts.get(e.action) || 0) + 1);
    if (e.ts > hourAgo) recent.add(e.actor);
  }
  return {
    byModule: [...mods.values()].map((m) => ({ module: m.module, events: m.events, users: m.users.size })).sort((a, b) => b.events - a.events),
    byAction: [...acts.entries()].map(([action, events]) => ({ action, events })).sort((a, b) => b.events - a.events),
    activeUsers: recent.size, totalEvents: usageMem.length, source: 'in-memory',
  };
}

// ── Real-service token brokering (Synapse / Mastodon) ──────────────
const matrixUser = (handle) => (handle || 'user').split('@')[0].toLowerCase().replace(/[^a-z0-9._=\/-]/g, '');
async function synapseToken(username) {
  const reg = (auth) => fetch(`${SYNAPSE_URL}/_matrix/client/v3/register`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify(auth ? { username, password: SVC_PW, auth } : { username, password: SVC_PW }) });
  let r = await reg(null); let j = await r.json();
  if (r.status === 401 && j.session) { r = await reg({ type: 'm.login.dummy', session: j.session }); j = await r.json(); }
  if (j.access_token) return { access_token: j.access_token, user_id: j.user_id };
  // Already registered → password login.
  const lr = await fetch(`${SYNAPSE_URL}/_matrix/client/v3/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'm.login.password', identifier: { type: 'm.id.user', user: username }, password: SVC_PW }) });
  const lj = await lr.json();
  if (!lj.access_token) throw new Error('synapse: ' + JSON.stringify(lj));
  return { access_token: lj.access_token, user_id: lj.user_id };
}
async function mastodonToken(username) {
  const r = await fetch(`${MASTODON_URL}/oauth/token`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ grant_type: 'password', username, password: SVC_PW }) });
  return r.json();
}

// ── Native accounts (a Casdoor stand-in) ───────────────────────────
/** Provision a native account (the mock's "Casdoor account"). An admin invite +
 *  the seed set both land here. registrationComplete starts false unless seeded
 *  complete; the deterministic native password lets the login-ui form sign in. */
function provisionAccount(username, { roles, complete = false } = {}) {
  const key = username.toLowerCase();
  if (!accounts.has(key)) {
    const r = roles || (ADMINS.has(key) ? ['user', 'admin'] : ['user']);
    accounts.set(key, { username: key, label: username, roles: r,
      registrationComplete: complete, password: LOGIN_PASSWORD, matrix: null, mastodon: null });
  }
  return accounts.get(key);
}
const sessionView = (a) => ({ id: a.username, label: a.label, provider: 'password',
  roles: a.roles, registrationComplete: a.registrationComplete });

// Seed the personas the specs expect to sign in WITHOUT a prior in-suite invite:
// the bootstrap admin (fully registered), plus the direct-onboard personas. The
// gating specs' un-invited identities (mallory@, rando, rbac-*-uninvited) are
// DELIBERATELY absent so their POST /bff/login 401s. Invited/onboarded emails
// (alice@…eve@, frank@) are also seeded so file-order independence holds; a later
// admin invite is idempotent.
function seedPersonas() {
  // Admins seed registrationComplete=FALSE so the journey specs' onboard(admin) drives the
  // real two-stage flow (login -> complete-view -> display name -> complete); an already-complete
  // seed would skip the complete-view and time out at register-display-name. The admin ROLE is
  // still granted, so nav-admin appears once onboarding completes.
  for (const a of ADMINS) provisionAccount(a, { roles: ['user', 'admin'], complete: false });
  for (const u of ['alice@gmail.com', 'bob@gmail.com', 'carol@gmail.com', 'dave@gmail.com',
                   'eve@gmail.com', 'frank@gmail.com', 'dragoneer', 'e2e-user']) {
    provisionAccount(u, { complete: false });
  }
}

// ── CSRF: native mutating /bff/** (non-mint) use an XSRF double-submit. The mock
//    accepts any request whose X-CSRF-TOKEN echoes the XSRF-TOKEN cookie, and is
//    lenient when neither is present (the e2e API context may omit it). ──
function csrfOk(req) {
  const cookie = req.headers['cookie'] || '';
  const m = cookie.match(/(?:^|;\s*)XSRF-TOKEN=([^;]+)/);
  const header = req.headers['x-csrf-token'];
  if (!m) return true;                 // no cookie issued → nothing to double-submit
  return header === m[1];
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'OPTIONS') return send(res, 204, {});
    const url = new URL(req.url, 'http://x'); const p = url.pathname;

    // ── NATIVE LOGIN: our own username/password form → opaque bff_ cookie ──
    if (req.method === 'POST' && p === '/bff/login') {
      const b = await bodyOf(req);
      const username = (b.username || '').toLowerCase();
      const a = accounts.get(username);
      if (!a || a.password !== b.password) {
        // No account (un-invited) or bad password → the form shows "Sign-in failed".
        return send(res, 401, { error: 'invalid_credentials', message: 'invalid username or password' });
      }
      record(username, a.roles, 'login');
      // Non-secret routing hints ONLY; the session token is the httpOnly cookie.
      return send(res, 200, { registrationComplete: a.registrationComplete, status: 'active', mfaRequired: false },
        setCookieHeader(newSession(a)));
    }

    // ── Session hydrate (cookie-read): the ONLY browser-readable identity ──
    if (req.method === 'GET' && p === '/bff/session') {
      const me = sessionOf(req);
      if (!me) return send(res, 401, { error: 'no session' });
      return send(res, 200, sessionView(me));
    }
    // Native logout — clears the session (login-ui posts /bff/sessionOut; DELETE too).
    if ((req.method === 'POST' && p === '/bff/sessionOut') ||
        (req.method === 'DELETE' && p === '/bff/session')) {
      const cookie = req.headers['cookie'] || '';
      const m = cookie.match(/(?:^|;\s*)bff_session=([^;]+)/);
      if (m) sessions.delete(m[1]);
      return send(res, 200, { ok: true },
        { 'set-cookie': 'bff_session=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0' });
    }

    const me = sessionOf(req);

    // ── Registration (stage 2): complete; releases service entitlement ──
    if (req.method === 'POST' && p === '/bff/register/complete') {
      if (!me) return send(res, 401, { error: 'login required' });
      if (!csrfOk(req)) return send(res, 403, { error: 'csrf' });
      const b = await bodyOf(req);
      if (b && b.displayName) me.label = String(b.displayName);
      me.registrationComplete = true;
      record(me.username, me.roles, 'complete');
      record(me.username, me.roles, 'matrix.entitled');
      record(me.username, me.roles, 'mastodon.entitled');
      return send(res, 200, { id: me.username, registrationComplete: true });
    }
    if (req.method === 'GET' && p === '/bff/me') {
      if (!me) return send(res, 401, { error: 'login required' });
      return send(res, 200, sessionView(me));
    }

    // ── Broker + inject real Matrix/Mastodon service tokens (post full reg) ──
    if (req.method === 'POST' && (p === '/bff/provision/matrix' || p === '/bff/provision/mastodon')) {
      if (!me) return send(res, 401, { error: 'login required' });
      if (!me.registrationComplete) return send(res, 403, { error: 'complete registration first' });
      const u = matrixUser(me.username);
      try {
        if (p.endsWith('matrix')) { me.matrix = await synapseToken(u); return send(res, 200, { ok: true }); }
        me.mastodon = await mastodonToken(u); return send(res, 200, { ok: true });
      } catch (e) { return send(res, 502, { error: String(e) }); }
    }
    // ── hsproxy: same-origin Matrix/Mastodon CS-API. Auth is SOLELY the bff_
    //    cookie; the mock injects the server-held token so the browser holds none. ──
    if (p.startsWith('/bff/user/matrix/') || p.startsWith('/bff/user/mastodon/')) {
      if (!me) return send(res, 401, { error: 'login required' });
      const isMatrix = p.startsWith('/bff/user/matrix/');
      const tok = isMatrix ? me.matrix : me.mastodon;
      if (!tok || !tok.access_token) return send(res, 403, { error: 'service not provisioned' });
      const upstream = (isMatrix ? SYNAPSE_URL : MASTODON_URL) +
        p.replace(isMatrix ? '/bff/user/matrix' : '/bff/user/mastodon', '') + (url.search || '');
      const init = { method: req.method, headers: { authorization: `Bearer ${tok.access_token}` } };
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        const raw = await bodyOf(req).catch(() => ({}));
        init.headers['content-type'] = 'application/json';
        init.body = JSON.stringify(raw);
      }
      try {
        const r = await fetch(upstream, init);
        const text = await r.text();
        res.writeHead(r.status, { 'content-type': r.headers.get('content-type') || 'application/json',
          'access-control-allow-origin': '*', 'access-control-allow-credentials': 'true' });
        return res.end(text);
      } catch (e) { return send(res, 502, { error: String(e) }); }
    }

    // ── Admin allowlist (the INVITE = provision a native account) ──
    if (p === '/bff/admin/allowlist') {
      if (!me) return send(res, 401, { error: 'login required' });                            // anon → 401 (unauthenticated): mirrors the real gateway's anyExchange().authenticated() entry-point
      if (!me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' }); // authenticated but not admin → 403 (forbidden by the route-access role rule)
      if (req.method === 'GET') return send(res, 200, { emails: [...allowEmails], discord: [...allowDiscord] });
      if (req.method === 'POST') {
        if (!csrfOk(req)) return send(res, 403, { error: 'csrf' });
        const b = await bodyOf(req);
        // Inviting an identity PROVISIONS its native account so it can sign in
        // (registrationComplete=false — it still has to complete the 2nd stage).
        if (b.email) { allowEmails.add(b.email.toLowerCase()); provisionAccount(b.email.toLowerCase(), { complete: false }); }
        if (b.discord) { allowDiscord.add(b.discord.toLowerCase()); provisionAccount(b.discord.toLowerCase(), { complete: false }); }
        record(me.username, me.roles, 'admin.invite');
        return send(res, 200, { emails: [...allowEmails], discord: [...allowDiscord] });
      }
      if (req.method === 'DELETE') {
        const b = await bodyOf(req);
        if (b.email) allowEmails.delete(b.email.toLowerCase());
        if (b.discord) allowDiscord.delete(b.discord.toLowerCase());
        return send(res, 200, { emails: [...allowEmails], discord: [...allowDiscord] });
      }
    }
    // ── Admin usage analytics (from ClickHouse), admin role only ──
    if (req.method === 'GET' && p === '/bff/admin/usage') {
      if (!me) return send(res, 401, { error: 'login required' });                            // anon → 401 (unauthenticated): mirrors the real gateway's anyExchange().authenticated() entry-point
      if (!me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' }); // authenticated but not admin → 403 (forbidden by the route-access role rule)
      try {
        const J = async (sql) => JSON.parse(await ch(sql + ' FORMAT JSON')).data;
        const byModule = await J('SELECT module, count() AS events, uniqExact(actor) AS users FROM hugmesh.usage_events GROUP BY module ORDER BY events DESC');
        const byAction = await J('SELECT action, count() AS events FROM hugmesh.usage_events GROUP BY action ORDER BY events DESC');
        const active = (await J("SELECT uniqExact(actor) AS n FROM hugmesh.usage_events WHERE ts > now() - INTERVAL 1 HOUR"))[0] || { n: 0 };
        const total = (await J('SELECT count() AS n FROM hugmesh.usage_events'))[0] || { n: 0 };
        const out = { byModule, byAction, activeUsers: Number(active.n), totalEvents: Number(total.n) };
        return send(res, 200, out.totalEvents > 0 ? out : usageFromMemory());
      } catch (e) {
        return send(res, 200, usageFromMemory());
      }
    }

    // ── A caller's own granted namespaces (gates Uptrace/observability views) ──
    if (req.method === 'GET' && p === '/bff/me/namespaces') {
      if (!me) return send(res, 401, { error: 'login required' });
      const own = me.roles.includes('admin') ? NAMESPACES : [...(grants.get(me.username) || [])];
      return send(res, 200, { namespaces: own });
    }

    // ── Admin: grant/revoke registered users access to namespaces ──
    if (p === '/bff/admin/namespace-access') {
      if (!me) return send(res, 401, { error: 'login required' });                            // anon → 401 (unauthenticated): mirrors the real gateway's anyExchange().authenticated() entry-point
      if (!me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' }); // authenticated but not admin → 403 (forbidden by the route-access role rule)
      if (req.method === 'GET') {
        const out = [...grants.entries()].map(([user, ns]) => ({ user, namespaces: [...ns] }));
        return send(res, 200, { namespaces: NAMESPACES, grants: out });
      }
      const b = await bodyOf(req);
      const user = (b.user || '').toLowerCase();
      if (!user || !NAMESPACES.includes(b.namespace)) return send(res, 400, { error: 'user + valid namespace required' });
      if (!grants.has(user)) grants.set(user, new Set());
      if (req.method === 'POST') { grants.get(user).add(b.namespace); record(me.username, me.roles, 'admin.grant'); }
      if (req.method === 'DELETE') grants.get(user).delete(b.namespace);
      const out = [...grants.entries()].map(([u, ns]) => ({ user: u, namespaces: [...ns] }));
      return send(res, 200, { namespaces: NAMESPACES, grants: out });
    }

    // ── Admin: per-gateway role->URL external access rules (Postgres-backed) ──
    if (p === '/bff/admin/route-access') {
      if (!me) return send(res, 401, { error: 'login required' });                            // anon → 401 (unauthenticated): mirrors the real gateway's anyExchange().authenticated() entry-point
      if (!me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' }); // authenticated but not admin → 403 (forbidden by the route-access role rule)
      if (req.method === 'GET') return send(res, 200, { rules: routeAccess });
      if (req.method === 'POST') {
        const b = await bodyOf(req);
        if (!b.gateway || !b.url_pattern || !b.role) return send(res, 400, { error: 'gateway+url_pattern+role required' });
        const rule = { id: String(nextRule++), gateway: b.gateway, url_pattern: b.url_pattern,
                       role: b.role, casdoor_user: b.casdoor_user || null, allow: b.allow !== false };
        routeAccess.push(rule); record(me.username, me.roles, 'admin.route');
        return send(res, 200, { rules: routeAccess, added: rule });
      }
      if (req.method === 'DELETE') {
        const b = await bodyOf(req);
        const i = routeAccess.findIndex((r) => r.id === b.id);
        if (i >= 0) routeAccess.splice(i, 1);
        return send(res, 200, { rules: routeAccess });
      }
    }

    // ── Admin: latest delivered ISO download links (from the CI pipeline) ──
    if (req.method === 'GET' && p === '/bff/admin/isos') {
      if (!me) return send(res, 401, { error: 'login required' });                            // anon → 401 (unauthenticated): mirrors the real gateway's anyExchange().authenticated() entry-point
      if (!me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' }); // authenticated but not admin → 403 (forbidden by the route-access role rule)
      return send(res, 200, { isos: ISOS });
    }

    return send(res, 404, { error: 'not found', path: p });
  } catch (e) { return send(res, 500, { error: String(e) }); }
});
seedPersonas();
server.listen(PORT, () => {
  console.log(`[mock-bff] :${PORT} NATIVE login (username/password → httpOnly bff_ cookie); `
    + `admins=${[...ADMINS]}; seeded=${[...accounts.keys()].length} accounts; two-stage reg + hsproxy`);
  ensureUsageTable();
});
