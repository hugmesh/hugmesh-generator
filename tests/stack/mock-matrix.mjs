// mock-matrix.mjs — Angular UI UNIT-TEST double ONLY (fast, in-memory).
// DO NOT use for integration tests: those run the REAL Matrix homeserver
// (tuwunel) from tests/stack/compose.real.yaml. This double implements just
// the client-server endpoints the UI calls, for component/unit tests.
//
//   POST /_matrix/client/v3/register            {username,password} -> {user_id,access_token}
//   POST /_matrix/client/v3/login               {user,password}     -> {user_id,access_token}
//   GET  /_matrix/client/v3/account/whoami                          -> {user_id}
//   POST /_matrix/client/v3/createRoom          {name,invite[],preset} -> {room_id}  creator JOINED, invitees PENDING
//   POST /_matrix/client/v3/rooms/{id}/join  (+ /join/{id})         -> {room_id}    invited->joined; public rooms open; idempotent
//   POST /_matrix/client/v3/rooms/{id}/invite   {user_id}           -> {}           pending invite (tracks the inviting sender)
//   POST /_matrix/client/v3/rooms/{id}/leave                        -> {}           leave; while invited = DECLINE
//   GET  /_matrix/client/v3/joined_rooms                            -> {joined_rooms:[]}
//   GET  /_matrix/client/v3/rooms/{id}/joined_members               -> {joined:{userId:{display_name}}}
//   PUT  /_matrix/client/v3/rooms/{id}/send/m.room.message/{txn}    -> {event_id}
//   GET  /_matrix/client/v3/rooms/{id}/messages                     -> {chunk:[events]}
//   POST /_matrix/client/v3/rooms/{id}/receipt/{type}/{eventId}     -> {}           records the caller's last-read event
//   POST /_matrix/client/v3/rooms/{id}/read_markers                 -> {}           m.read / m.fully_read do the same
//   GET/PUT /_matrix/client/v3/user/{uid}/account_data/{type}       per-user store; GET 404 M_NOT_FOUND when unset
//   GET  /_matrix/client/v3/rooms/{id}/state                        -> [full state events] joined members only; synthesizes
//                                                                      m.room.member (join) + m.room.name rows alongside the stored ones
//   GET/PUT /_matrix/client/v3/rooms/{id}/state/{type}[/{key}]      per-room state (chat3d etc.); joined members only;
//                                                                      GET -> content | 404 M_NOT_FOUND; PUT -> {event_id};
//                                                                      the empty state key rides the trailing-slash form /state/{type}/
//   GET  /_matrix/client/v3/sync    rooms.join {timeline,name state,unread_notifications} + rooms.invite {invite_state}
import http from 'node:http';

const PORT = Number(process.env.PORT || 8401);
const SERVER = process.env.MATRIX_SERVER_NAME || 'hugmesh.systems';
const users = new Map();   // token -> userId
const accounts = new Map();// userId -> {password}
// roomId -> { name, preset, joined:Set, invited:Set, inviters:Map(userId->inviter),
//             reads:Map(userId->last-read event_id), events:[],
//             state:Map(`${type} ${state_key}` -> {type,state_key,content,sender,event_id,origin_server_ts}) }
const rooms = new Map();
const accountData = new Map(); // userId -> Map(type -> content)
let nextRoom = 1, nextEvent = 1, syncSeq = 0;

const uid = (name) => `@${name}:${SERVER}`;
const tok = (name) => `mxt_${name}_${Math.random().toString(36).slice(2, 10)}`;
const localpart = (userId) => userId.replace(/^@/, '').split(':')[0];
// Unread = timeline events past the user's last m.read receipt that they did
// not send themselves (an unknown/absent receipt counts from the beginning).
function unreadFor(r, userId) {
  const from = r.events.findIndex((e) => e.event_id === r.reads.get(userId)) + 1;
  return r.events.slice(from).filter((e) => e.sender !== userId).length;
}

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
      // Real invite semantics: the creator is JOINED; the invite list is
      // PENDING (rooms.invite on the invitee's /sync) until each one joins.
      // The creator is stripped from their own invite list (a homeserver never
      // leaves the creator in both shades — /sync checks invited first, so a
      // self-invite would present the creator's own room as a pending invite).
      const invited = new Set(b.invite || []);
      invited.delete(me);
      rooms.set(roomId, { name: b.name || roomId, preset: b.preset || 'private_chat',
        joined: new Set([me]), invited, inviters: new Map([...invited].map((u) => [u, me])),
        reads: new Map(), events: [], state: new Map() });
      syncSeq++;
      return send(res, 200, { room_id: roomId });
    }

    // Join by either CS-API spelling: invited -> joined (idempotent for a
    // member); an UNinvited caller may only join a public room (403 otherwise
    // — this is what makes decline-then-rejoin honest for private rooms).
    const joinAs = (roomId) => {
      const r = rooms.get(roomId);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      if (!r.joined.has(me)) {
        if (!r.invited.has(me) && r.preset !== 'public_chat') {
          return send(res, 403, { errcode: 'M_FORBIDDEN', error: 'not invited to this private room' });
        }
        r.invited.delete(me); r.inviters.delete(me); r.joined.add(me); syncSeq++;
      }
      return send(res, 200, { room_id: roomId });
    };
    let m;
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/join$`))) && req.method === 'POST') {
      return joinAs(decodeURIComponent(m[1]));
    }
    if ((m = p.match(new RegExp(`^${M}/join/([^/]+)$`))) && req.method === 'POST') {
      return joinAs(decodeURIComponent(m[1]));
    }
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/invite$`))) && req.method === 'POST') {
      const roomId = decodeURIComponent(m[1]); const r = rooms.get(roomId); const b = await bodyOf(req);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      if (!r.joined.has(b.user_id)) { r.invited.add(b.user_id); r.inviters.set(b.user_id, me); syncSeq++; }
      return send(res, 200, {});
    }
    // Leave removes BOTH membership shades: leaving while invited is the
    // CS-API's decline (the UI's Decline button posts exactly this).
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/leave$`))) && req.method === 'POST') {
      const r = rooms.get(decodeURIComponent(m[1]));
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      r.joined.delete(me); r.invited.delete(me); r.inviters.delete(me); syncSeq++;
      return send(res, 200, {});
    }
    if (p === `${M}/joined_rooms` && req.method === 'GET') {
      const list = [...rooms.entries()].filter(([, r]) => r.joined.has(me)).map(([id]) => id);
      return send(res, 200, { joined_rooms: list });
    }
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/joined_members$`))) && req.method === 'GET') {
      const r = rooms.get(decodeURIComponent(m[1]));
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      const joined = {};
      for (const u of r.joined) joined[u] = { display_name: localpart(u) };
      return send(res, 200, { joined });
    }
    // Read receipts: both the explicit receipt POST and read_markers advance
    // the caller's last-read event (feeds unread_notifications in /sync).
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/receipt/([^/]+)/([^/]+)$`))) && req.method === 'POST') {
      const r = rooms.get(decodeURIComponent(m[1]));
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      r.reads.set(me, decodeURIComponent(m[3])); syncSeq++;
      return send(res, 200, {});
    }
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/read_markers$`))) && req.method === 'POST') {
      const r = rooms.get(decodeURIComponent(m[1])); const b = await bodyOf(req);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      const evId = b['m.read'] || b['m.fully_read'];
      if (evId) { r.reads.set(me, evId); syncSeq++; }
      return send(res, 200, {});
    }
    // Per-user account_data (m.direct DM tagging etc.): GET of an unset type
    // is the spec'd 404 M_NOT_FOUND, PUT stores verbatim and returns {}.
    if ((m = p.match(new RegExp(`^${M}/user/([^/]+)/account_data/([^/]+)$`)))) {
      const userId = decodeURIComponent(m[1]); const type = decodeURIComponent(m[2]);
      if (req.method === 'GET') {
        const val = accountData.get(userId)?.get(type);
        if (val === undefined) return send(res, 404, { errcode: 'M_NOT_FOUND' });
        return send(res, 200, val);
      }
      if (req.method === 'PUT') {
        const b = await bodyOf(req);
        if (!accountData.has(userId)) accountData.set(userId, new Map());
        accountData.get(userId).set(type, b);
        return send(res, 200, {});
      }
    }
    // Room STATE (net.hugmesh.chat3d / chat3d.avatar etc.). Matrix hides state
    // from non-members, so every shape below is joined-members-only (403
    // M_FORBIDDEN otherwise). Room ids/state keys may arrive with RAW pchars
    // (':' '@' — the raw-pchar spelling every client on this stack sends).
    // Full current state: the STORED events plus synthesized m.room.member
    // (join) + m.room.name rows — a real homeserver always carries membership
    // in /state, and matrix-ui's avatar roster fails CLOSED without it.
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/state$`))) && req.method === 'GET') {
      const roomId = decodeURIComponent(m[1]); const r = rooms.get(roomId);
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      if (!r.joined.has(me)) return send(res, 403, { errcode: 'M_FORBIDDEN', error: 'not a joined member' });
      const members = [...r.joined].map((u) => ({ type: 'm.room.member', state_key: u, sender: u,
        content: { membership: 'join', displayname: localpart(u) }, event_id: `$member_${u}`, origin_server_ts: 0 }));
      const nameEv = { type: 'm.room.name', state_key: '', sender: me,
        content: { name: r.name }, event_id: `$name_${roomId}`, origin_server_ts: 0 };
      return send(res, 200, [...members, nameEv, ...r.state.values()]);
    }
    // One state event by {type} + optional {key}. matrix.service spells the
    // EMPTY state key as the trailing-slash form `/state/<type>/`, so the final
    // segment may be empty or absent — both mean state_key ''.
    if ((m = p.match(new RegExp(`^${M}/rooms/([^/]+)/state/([^/]+)(?:/([^/]*))?$`)))) {
      const r = rooms.get(decodeURIComponent(m[1]));
      const type = decodeURIComponent(m[2]); const key = decodeURIComponent(m[3] || '');
      if (!r) return send(res, 404, { errcode: 'M_NOT_FOUND' });
      if (!r.joined.has(me)) return send(res, 403, { errcode: 'M_FORBIDDEN', error: 'not a joined member' });
      if (req.method === 'GET') {
        const ev = r.state.get(`${type} ${key}`);
        if (!ev) return send(res, 404, { errcode: 'M_NOT_FOUND' });
        return send(res, 200, ev.content); // the CS-API returns the content json alone
      }
      if (req.method === 'PUT') {
        const b = await bodyOf(req);
        const ev = { type, state_key: key, content: b, sender: me,
          event_id: `$ev${nextEvent++}`, origin_server_ts: Date.now() };
        r.state.set(`${type} ${key}`, ev); syncSeq++;
        return send(res, 200, { event_id: ev.event_id });
      }
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
    // joined rooms with their full timeline + room-name state + real unread
    // counts, and the caller's PENDING invites as rooms.invite (stripped
    // invite_state carrying the room name + the inviting sender, which is what
    // the UI's pending-invite rows render). Light long-poll — if the caller is
    // already caught up (since >= syncSeq) honour the timeout briefly so the
    // client loop doesn't spin.
    if (p === `${M}/sync` && req.method === 'GET') {
      const since = Number(url.searchParams.get('since'));
      const timeout = Number(url.searchParams.get('timeout') || 0);
      if (Number.isFinite(since) && since >= syncSeq && timeout > 0) {
        await new Promise((rsl) => setTimeout(rsl, Math.min(timeout, 1000)));
      }
      const join = {}, invite = {};
      for (const [roomId, r] of rooms) {
        if (r.invited.has(me)) {
          const inviter = r.inviters.get(me) || me;
          invite[roomId] = { invite_state: { events: [
            { type: 'm.room.name', state_key: '', sender: inviter, content: { name: r.name } },
            { type: 'm.room.member', state_key: me, sender: inviter, content: { membership: 'invite' } },
          ] } };
          continue;
        }
        if (!r.joined.has(me)) continue;
        join[roomId] = {
          timeline: { events: r.events, prev_batch: 's0', limited: false },
          state: { events: [{ type: 'm.room.name', state_key: '', sender: me,
            content: { name: r.name }, event_id: `$name_${roomId}`, origin_server_ts: 0 }] },
          ephemeral: { events: [] },
          unread_notifications: { notification_count: unreadFor(r, me), highlight_count: 0 },
        };
      }
      return send(res, 200, { next_batch: String(syncSeq), rooms: { join, invite } });
    }
    return send(res, 404, { errcode: 'M_UNRECOGNIZED', error: p });
  } catch (e) {
    return send(res, 500, { errcode: 'M_UNKNOWN', error: String(e) });
  }
});
server.listen(PORT, () => console.log(`[mock-matrix] listening on :${PORT} (server_name ${SERVER})`));
