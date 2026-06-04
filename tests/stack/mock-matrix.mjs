// mock-matrix.mjs — Angular UI UNIT-TEST double ONLY (fast, in-memory).
// DO NOT use for integration tests: those run the REAL Matrix homeserver
// (Synapse) from tests/stack/compose.real.yaml. This double implements just
// the client-server endpoints the UI calls, for component/unit tests.
//
//   POST /_matrix/client/v3/register            {username,password} -> {user_id,access_token}
//   POST /_matrix/client/v3/login               {user,password}     -> {user_id,access_token}
//   GET  /_matrix/client/v3/account/whoami                          -> {user_id}
//   POST /_matrix/client/v3/createRoom          {name,invite[]}     -> {room_id}
//   POST /_matrix/client/v3/rooms/{id}/join                          -> {room_id}
//   POST /_matrix/client/v3/rooms/{id}/invite   {user_id}
//   GET  /_matrix/client/v3/joined_rooms                            -> {joined_rooms:[]}
//   PUT  /_matrix/client/v3/rooms/{id}/send/m.room.message/{txn}    -> {event_id}
//   GET  /_matrix/client/v3/rooms/{id}/messages                     -> {chunk:[events]}
import http from 'node:http';

const PORT = Number(process.env.PORT || 8401);
const SERVER = process.env.MATRIX_SERVER_NAME || 'snapdragon.systems';
const users = new Map();   // token -> userId
const accounts = new Map();// userId -> {password}
const rooms = new Map();   // roomId -> {members:Set, events:[]}
let nextRoom = 1, nextEvent = 1, syncSeq = 0;

const uid = (name) => `@${name}:${SERVER}`;
const tok = (name) => `mxt_${name}_${Math.random().toString(36).slice(2, 10)}`;

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*',
    'access-control-allow-headers': 'authorization,content-type', 'access-control-allow-methods': '*' });
  res.end(body);
}
function bearer(req) {
  const h = req.headers['authorization'] || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  return users.get(t) || null;
}
async function bodyOf(req) {
  let d = ''; for await (const c of req) d += c; return d ? JSON.parse(d) : {};
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'OPTIONS') return send(res, 204, {});
    const url = new URL(req.url, 'http://x');
    const p = url.pathname;
    const M = '/_matrix/client/v3';

    if (req.method === 'POST' && (p === `${M}/register` || p === `${M}/login`)) {
      const b = await bodyOf(req);
      const name = b.username || b.user || (b.identifier && b.identifier.user) || 'user';
      const userId = uid(name);
      accounts.set(userId, { password: b.password || '' });
      const t = tok(name); users.set(t, userId);
      return send(res, 200, { user_id: userId, access_token: t, device_id: 'TEST', home_server: SERVER });
    }

    const me = bearer(req);
    if (!me) return send(res, 401, { errcode: 'M_UNKNOWN_TOKEN', error: 'missing/invalid token' });

    if (req.method === 'GET' && p === `${M}/account/whoami`) return send(res, 200, { user_id: me });

    if (req.method === 'POST' && p === `${M}/createRoom`) {
      const b = await bodyOf(req);
      const roomId = `!room${nextRoom++}:${SERVER}`;
      const members = new Set([me]); (b.invite || []).forEach((u) => members.add(u));
      rooms.set(roomId, { name: b.name || roomId, members, events: [] });
      return send(res, 200, { room_id: roomId });
    }

    let m;
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/join$`))) && req.method === 'POST') {
      const roomId = decodeURIComponent(m[1]); const r = rooms.get(roomId);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      r.members.add(me); return send(res, 200, { room_id: roomId });
    }
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/invite$`))) && req.method === 'POST') {
      const roomId = decodeURIComponent(m[1]); const r = rooms.get(roomId); const b = await bodyOf(req);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      r.members.add(b.user_id); return send(res, 200, {});
    }
    if (p === `${M}/joined_rooms` && req.method === 'GET') {
      const list = [...rooms.entries()].filter(([, r]) => r.members.has(me)).map(([id]) => id);
      return send(res, 200, { joined_rooms: list });
    }
    // Generic event send — m.room.message AND m.call.* (WebRTC signalling).
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/send/([^/]+)/([^/]+)$`))) && req.method === 'PUT') {
      const roomId = decodeURIComponent(m[1]); const evType = decodeURIComponent(m[2]);
      const r = rooms.get(roomId); const b = await bodyOf(req);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      const ev = { type: evType, event_id: `$ev${nextEvent++}`, sender: me,
        origin_server_ts: Date.now(), content: b };
      r.events.push(ev); syncSeq++; return send(res, 200, { event_id: ev.event_id });
    }
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/messages$`))) && req.method === 'GET') {
      const roomId = decodeURIComponent(m[1]); const r = rooms.get(roomId);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      return send(res, 200, { chunk: r.events, start: 's0', end: `s${r.events.length}` });
    }
    // Minimal /sync (Element-style clients long-poll this): return the caller's
    // joined rooms with their full timeline + room-name state. Light long-poll —
    // if the caller is already caught up (since >= syncSeq) honour the timeout
    // briefly so the client loop doesn't spin.
    if (p === `${M}/sync` && req.method === 'GET') {
      const since = Number(url.searchParams.get('since'));
      const timeout = Number(url.searchParams.get('timeout') || 0);
      if (Number.isFinite(since) && since >= syncSeq && timeout > 0) {
        await new Promise((rsl) => setTimeout(rsl, Math.min(timeout, 1000)));
      }
      const join = {};
      for (const [roomId, r] of rooms) {
        if (!r.members.has(me)) continue;
        join[roomId] = {
          timeline: { events: r.events, prev_batch: 's0', limited: false },
          state: { events: [{ type: 'm.room.name', state_key: '', sender: me,
            content: { name: r.name }, event_id: `$name_${roomId}`, origin_server_ts: 0 }] },
          ephemeral: { events: [] },
          unread_notifications: { notification_count: 0, highlight_count: 0 },
        };
      }
      return send(res, 200, { next_batch: String(syncSeq), rooms: { join } });
    }
    return send(res, 404, { errcode: 'M_UNRECOGNIZED', error: p });
  } catch (e) {
    return send(res, 500, { errcode: 'M_UNKNOWN', error: String(e) });
  }
});
server.listen(PORT, () => console.log(`[mock-matrix] listening on :${PORT} (server_name ${SERVER})`));
