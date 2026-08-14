// mock-mastodon.mjs — a tiny, stateful, multi-user Mastodon client-API double
// implementing exactly the endpoints hugmesh's MastodonService + the
// Playwright tests use. In-memory; for integration testing only.
//
//   POST /oauth/token                        {username,password} -> {access_token}
//   GET  /api/v1/accounts/verify_credentials                     -> account
//   POST /api/v1/statuses                    {status}            -> status
//   GET  /api/v1/timelines/home                                  -> [status] (all, newest first)
//   GET  /api/v1/timelines/public?local=true                     -> [status]
import http from 'node:http';

const PORT = Number(process.env.PORT || 8402);
const tokens = new Map();    // token -> username
const accounts = new Map();  // username -> {id, display_name}
const statuses = [];         // newest pushed to front
let nextAcct = 1, nextStatus = 1;

const tok = (u) => `msk_${u}_${Math.random().toString(36).slice(2, 10)}`;
function acct(u) {
  if (!accounts.has(u)) accounts.set(u, {
    id: String(nextAcct++), username: u, acct: u, display_name: u,
    url: `https://mastodon.hugmesh.net/@${u}`, avatar: '', avatar_static: '',
    header: '', header_static: '', note: '', locked: false, bot: false,
    created_at: new Date().toISOString(), followers_count: 0, following_count: 0,
    statuses_count: 0, fields: [], emojis: [],
  });
  return accounts.get(u);
}
// Real Mastodon ALWAYS returns the full Status entity (empty arrays/zero counts,
// never omitted). The UI's TootCard renders media_attachments/emojis/poll/counts,
// so the double must mirror that shape — a minimal status breaks the card.
function fullStatus(p) {
  return {
    id: p.id, uri: `https://mastodon.hugmesh.net/statuses/${p.id}`,
    url: `https://mastodon.hugmesh.net/@${p.account.acct}/${p.id}`,
    created_at: p.created_at, edited_at: null, content: p.content,
    visibility: p.visibility || 'public', sensitive: false, spoiler_text: p.spoiler_text || '',
    language: 'en', replies_count: 0, reblogs_count: 0, favourites_count: 0,
    favourited: false, reblogged: false, bookmarked: false, pinned: false, muted: false,
    account: p.account, media_attachments: [], mentions: [], tags: [], emojis: [],
    reblog: null, in_reply_to_id: null, in_reply_to_account_id: null, poll: null, card: null,
  };
}
function send(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*',
    'access-control-allow-headers': 'authorization,content-type', 'access-control-allow-methods': '*' });
  res.end(JSON.stringify(obj));
}
function user(req) {
  const h = req.headers['authorization'] || '';
  return h.startsWith('Bearer ') ? (tokens.get(h.slice(7)) || null) : null;
}
async function bodyOf(req) {
  let d = ''; for await (const c of req) d += c;
  const ct = req.headers['content-type'] || '';
  if (!d) return {};
  if (ct.includes('application/json')) return JSON.parse(d);
  return Object.fromEntries(new URLSearchParams(d)); // form-encoded
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'OPTIONS') return send(res, 204, {});
    const url = new URL(req.url, 'http://x');
    const p = url.pathname;

    if (req.method === 'POST' && p === '/oauth/token') {
      const b = await bodyOf(req);
      const u = b.username || b.user || 'user'; acct(u);
      const t = tok(u); tokens.set(t, u);
      return send(res, 200, { access_token: t, token_type: 'Bearer', scope: 'read write', created_at: Date.now() });
    }
    if (req.method === 'POST' && p === '/api/v1/apps') {
      return send(res, 200, { id: '1', client_id: 'mock', client_secret: 'mock', redirect_uri: 'urn:ietf:wg:oauth:2.0:oob' });
    }

    const u = user(req);
    if (!u) return send(res, 401, { error: 'The access token is invalid' });

    if (req.method === 'GET' && p === '/api/v1/accounts/verify_credentials') return send(res, 200, acct(u));

    if (req.method === 'POST' && p === '/api/v1/statuses') {
      const b = await bodyOf(req);
      const s = fullStatus({ id: String(nextStatus++),
        content: `<p>${(b.status || '').replace(/</g, '&lt;')}</p>`,
        account: acct(u), created_at: new Date().toISOString(),
        visibility: b.visibility || 'public', spoiler_text: b.spoiler_text || '' });
      statuses.unshift(s);
      return send(res, 200, s);
    }
    if (req.method === 'GET' && (p === '/api/v1/timelines/home' || p === '/api/v1/timelines/public')) {
      return send(res, 200, statuses.slice(0, 40)); // everyone sees everyone (test fixture)
    }
    return send(res, 404, { error: 'not found', path: p });
  } catch (e) {
    return send(res, 500, { error: String(e) });
  }
});
server.listen(PORT, () => console.log(`[mock-mastodon] listening on :${PORT}`));
