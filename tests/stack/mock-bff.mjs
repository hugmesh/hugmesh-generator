// mock-bff.mjs — stands in for the Spring admin BFF (backend namespace, behind
// the gateway). It owns the Casdoor-admin-managed allowlist and the rule that
// registration is **Google- or Discord-only** AND only for identities an admin
// invited. It also models the TWO-STAGE registration:
//   1. register/{google,discord}  -> creates a real internal Casdoor account
//      (here: an `accounts` entry) but registrationComplete=false.
//   2. register/complete          -> finishes registration; ONLY THEN are the
//      Matrix/Mastodon service tokens released (the UI/host enforces this).
// In a real deployment the admin API reaches Casdoor through the snapdragon-pki
// gateway (JWT) — direct Casdoor calls are only for OAuth2 grants. In-memory.
import http from 'node:http';

const PORT = Number(process.env.PORT || 8403);
const ADMINS = new Set((process.env.ADMIN_EMAILS || 'admin@snapdragon.systems').split(','));
const allowEmails = new Set([...ADMINS]);     // Gmail addresses an admin invited
const allowDiscord = new Set();               // Discord usernames an admin invited
const accounts = new Map();                   // id -> {id, provider, registrationComplete, roles}
const sessions = new Map();                   // token -> id
const grants = new Map();                     // actorId -> Set(namespace)  (admin-granted namespace access)
const NAMESPACES = ['snapdragon-pki', 'snapdragon-backend', 'snapdragon-frontend', 'snapdragon-games', 'observability'];
// Per-gateway role->URL external access rules (stands in for the Postgres
// gateway_route_access table the gateways read + Cassandra-cache).
let nextRule = 1;
const routeAccess = [
  { id: String(nextRule++), gateway: 'snapdragon-fe-gateway', url_pattern: '/admin/**', role: 'ROLE_ADMIN', allow: true },
  { id: String(nextRule++), gateway: 'snapdragon-fe-gateway', url_pattern: '/social/**', role: 'ROLE_USER', allow: true },
  { id: String(nextRule++), gateway: 'snapdragon-be-gateway', url_pattern: '/api/**', role: 'ROLE_USER', allow: true },
];
// Latest delivered ISO artifacts (stands in for the GitLab generic package "latest" links).
const ISOS = [
  { name: 'gentoo-rpi5-arm64-pki-k8s-2026.0.iso', url: 'https://gitlab.snapdragon.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-rpi5-arm64-pki-k8s-2026.0.iso' },
  { name: 'gentoo-rpi5-arm64-backend-k8s-2026.0.iso', url: 'https://gitlab.snapdragon.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-rpi5-arm64-backend-k8s-2026.0.iso' },
  { name: 'gentoo-rpi5-arm64-frontend-k8s-2026.0.iso', url: 'https://gitlab.snapdragon.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-rpi5-arm64-frontend-k8s-2026.0.iso' },
  { name: 'gentoo-x86-snapdragon-host-2026.0.iso', url: 'https://gitlab.snapdragon.systems/api/v4/projects/1/packages/generic/iso/latest/gentoo-x86-snapdragon-host-2026.0.iso' },
];
// Real-service brokering: the BFF mints Matrix (Synapse) + Mastodon tokens
// server-side so the UI never holds homeserver admin creds. Point at the real
// Synapse/Casdoor; default to the integration stack ports.
const SYNAPSE_URL = process.env.SYNAPSE_URL || 'http://localhost:8008';
const MASTODON_URL = process.env.MASTODON_URL || 'http://localhost:8402';
const SVC_PW = process.env.SVC_PASSWORD || 'snapdragon-svc-pw';

const idFor = (provider, handle) => `${provider}:${handle.toLowerCase()}`;
const send = (res, code, obj) => {
  res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*',
    'access-control-allow-headers': 'authorization,content-type', 'access-control-allow-methods': '*' });
  res.end(JSON.stringify(obj));
};
const sessionOf = (req) => {
  const h = req.headers['authorization'] || '';
  const id = h.startsWith('Bearer ') ? sessions.get(h.slice(7)) : null;
  return id ? accounts.get(id) : null;
};
async function bodyOf(req) { let d=''; for await (const c of req) d+=c; return d ? JSON.parse(d) : {}; }

// ── Usage analytics → ClickHouse ───────────────────────────────────
// In production the BFF produces usage events to Kafka and a consumer writes
// them to ClickHouse; here (test double) we write directly to the real
// ClickHouse so the admin "Usage" view shows live infra usage by users.
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
    await ch('CREATE DATABASE IF NOT EXISTS snapdragon');
    await ch('CREATE TABLE IF NOT EXISTS snapdragon.usage_events ' +
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
  const esc = (s) => String(s).replace(/'/g, "\\'");
  ch(`INSERT INTO snapdragon.usage_events (actor, role, action, module) VALUES ('${esc(actor)}','${role}','${action}','${mod}')`).catch((e) => chErr('insert: ' + e.message));
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

function ensureAccount(provider, handle) {
  const id = idFor(provider, handle);
  if (!accounts.has(id)) {
    const roles = (provider === 'google' && ADMINS.has(handle.toLowerCase())) ? ['user', 'admin'] : ['user'];
    accounts.set(id, { id, provider, handle, registrationComplete: false, roles });
  }
  return accounts.get(id);
}
function newSession(acct) { const t = `bff_${Math.random().toString(36).slice(2, 12)}`; sessions.set(t, acct.id); return t; }
const sessOut = (t, a) => ({ token: t, id: a.id, provider: a.provider, roles: a.roles, registrationComplete: a.registrationComplete });

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'OPTIONS') return send(res, 204, {});
    const url = new URL(req.url, 'http://x'); const p = url.pathname;

    // ── Registration (stage 1): create a real Casdoor account if invited ──
    if (req.method === 'POST' && p === '/bff/register/google') {
      const b = await bodyOf(req); const email = (b.email || '').toLowerCase();
      if (!allowEmails.has(email)) return send(res, 403, { error: 'email not invited by an admin' });
      const a = ensureAccount('google', email); a.registrationComplete = false; // (re)start onboarding
      record(email, a.roles, 'register');
      return send(res, 200, sessOut(newSession(a), a));
    }
    if (req.method === 'POST' && p === '/bff/register/discord') {
      const b = await bodyOf(req); const handle = (b.username || '').toLowerCase();
      if (!allowDiscord.has(handle)) return send(res, 403, { error: 'discord username not invited by an admin' });
      const a = ensureAccount('discord', handle); a.registrationComplete = false;
      record(handle, a.roles, 'register');
      return send(res, 200, sessOut(newSession(a), a));
    }

    // ── Login: only for an existing (invited+created) Casdoor account ──
    if (req.method === 'POST' && p === '/bff/login') {
      const b = await bodyOf(req);
      const provider = b.provider || (b.username ? 'discord' : 'google');
      const handle = (b.email || b.username || '').toLowerCase();
      const id = idFor(provider, handle);
      const a = accounts.get(id);
      if (!a) return send(res, 401, { error: 'no account — register first' });
      record(handle, a.roles, 'login');
      return send(res, 200, sessOut(newSession(a), a));
    }

    const me = sessionOf(req);

    // ── Registration (stage 2): complete; releases service entitlement ──
    if (req.method === 'POST' && p === '/bff/register/complete') {
      if (!me) return send(res, 401, { error: 'login required' });
      me.registrationComplete = true;
      record(me.id, me.roles, 'complete');
      record(me.id, me.roles, 'matrix.entitled');
      record(me.id, me.roles, 'mastodon.entitled');
      return send(res, 200, { id: me.id, registrationComplete: true });
    }
    if (req.method === 'GET' && p === '/bff/me') {
      if (!me) return send(res, 401, { error: 'login required' });
      return send(res, 200, { id: me.id, provider: me.provider, roles: me.roles, registrationComplete: me.registrationComplete });
    }

    // ── Admin allowlist (Gmail + Discord), admin role only ──
    if (p === '/bff/admin/allowlist') {
      if (!me || !me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' });
      if (req.method === 'GET') return send(res, 200, { emails: [...allowEmails], discord: [...allowDiscord] });
      if (req.method === 'POST') {
        const b = await bodyOf(req);
        if (b.email) allowEmails.add(b.email.toLowerCase());
        if (b.discord) allowDiscord.add(b.discord.toLowerCase());
        record(me.id, me.roles, 'admin.invite');
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
      if (!me || !me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' });
      try {
        const J = async (sql) => JSON.parse(await ch(sql + ' FORMAT JSON')).data;
        const byModule = await J('SELECT module, count() AS events, uniqExact(actor) AS users FROM snapdragon.usage_events GROUP BY module ORDER BY events DESC');
        const byAction = await J('SELECT action, count() AS events FROM snapdragon.usage_events GROUP BY action ORDER BY events DESC');
        const active = (await J("SELECT uniqExact(actor) AS n FROM snapdragon.usage_events WHERE ts > now() - INTERVAL 1 HOUR"))[0] || { n: 0 };
        const total = (await J('SELECT count() AS n FROM snapdragon.usage_events'))[0] || { n: 0 };
        return send(res, 200, { byModule, byAction, activeUsers: Number(active.n), totalEvents: Number(total.n) });
      } catch (e) {
        return send(res, 200, { byModule: [], byAction: [], activeUsers: 0, totalEvents: 0, error: String(e) });
      }
    }
    // ── Broker real Matrix/Mastodon service tokens (post full registration) ──
    if (req.method === 'POST' && (p === '/bff/provision/matrix' || p === '/bff/provision/mastodon')) {
      if (!me) return send(res, 401, { error: 'login required' });
      if (!me.registrationComplete) return send(res, 403, { error: 'complete registration first' });
      const u = matrixUser(me.handle);
      try {
        const t = p.endsWith('matrix') ? await synapseToken(u) : await mastodonToken(u);
        return send(res, 200, t);
      } catch (e) { return send(res, 502, { error: String(e) }); }
    }

    // ── A caller's own granted namespaces (gates Uptrace/observability views) ──
    if (req.method === 'GET' && p === '/bff/me/namespaces') {
      if (!me) return send(res, 401, { error: 'login required' });
      const own = me.roles.includes('admin') ? NAMESPACES : [...(grants.get(me.id) || [])];
      return send(res, 200, { namespaces: own });
    }

    // ── Admin: grant/revoke registered users access to namespaces ──
    if (p === '/bff/admin/namespace-access') {
      if (!me || !me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' });
      if (req.method === 'GET') {
        const out = [...grants.entries()].map(([user, ns]) => ({ user, namespaces: [...ns] }));
        return send(res, 200, { namespaces: NAMESPACES, grants: out });
      }
      const b = await bodyOf(req);
      const user = (b.user || '').toLowerCase();
      if (!user || !NAMESPACES.includes(b.namespace)) return send(res, 400, { error: 'user + valid namespace required' });
      if (!grants.has(user)) grants.set(user, new Set());
      if (req.method === 'POST') { grants.get(user).add(b.namespace); record(me.id, me.roles, 'admin.grant'); }
      if (req.method === 'DELETE') grants.get(user).delete(b.namespace);
      const out = [...grants.entries()].map(([u, ns]) => ({ user: u, namespaces: [...ns] }));
      return send(res, 200, { namespaces: NAMESPACES, grants: out });
    }

    // ── Admin: per-gateway role->URL external access rules (Postgres-backed) ──
    if (p === '/bff/admin/route-access') {
      if (!me || !me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' });
      if (req.method === 'GET') return send(res, 200, { rules: routeAccess });
      if (req.method === 'POST') {
        const b = await bodyOf(req);
        if (!b.gateway || !b.url_pattern || !b.role) return send(res, 400, { error: 'gateway+url_pattern+role required' });
        const rule = { id: String(nextRule++), gateway: b.gateway, url_pattern: b.url_pattern,
                       role: b.role, casdoor_user: b.casdoor_user || null, allow: b.allow !== false };
        routeAccess.push(rule); record(me.id, me.roles, 'admin.route');
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
      if (!me || !me.roles.includes('admin')) return send(res, 403, { error: 'admin role required' });
      return send(res, 200, { isos: ISOS });
    }

    return send(res, 404, { error: 'not found', path: p });
  } catch (e) { return send(res, 500, { error: String(e) }); }
});
server.listen(PORT, () => {
  console.log(`[mock-bff] :${PORT} admins=${[...ADMINS]} (two-stage reg; google+discord; clickhouse usage)`);
  ensureUsageTable();
});
