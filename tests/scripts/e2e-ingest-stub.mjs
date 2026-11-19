// e2e-ingest-stub.mjs — a stand-in for admin-bff's test-report ingest that ENFORCES THE REAL
// CONTRACT, so the reporter's live events are checked against what the endpoint accepts, not
// against what the reporter believes it sends.
//
// Usage: node e2e-ingest-stub.mjs <log.jsonl> <ready-file> [--tls cert.pem key.pem ca.pem] [--expire-first-token] [--require-bearer]
//
// The contract below is admin-bff's, copied from the sources it names (verified 2026-11-18):
//   TestReportsController   @RequestMapping("/bff/admin/test-reports"), POST "/{id}/ingest",
//                           @PreAuthorize("hasRole('ADMIN')") (a bearer is required here)
//   TestRunIngestRequest    kind SUITE|RUN (@NotBlank), suite <=255, role <=64,
//                           state running|passed|failed|skipped|error (@NotBlank),
//                           passed/failed/skipped >=0 <=1_000_000, percent 0..100, message <=1000
// If admin-bff changes that DTO, this file is what must change with it (and the reporter).
//
// Two listeners: the ingest (https with a REQUIRED client certificate when --tls is given, else
// http) and a plain-http token endpoint that mints "client_credentials" tokens like Casdoor.
// Every request is appended to <log.jsonl>; the shell driver asserts on that log.
import * as fs from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';

const [logPath, readyPath, ...rest] = process.argv.slice(2);
const tlsIdx = rest.indexOf('--tls');
const tls = tlsIdx >= 0 ? { cert: rest[tlsIdx + 1], key: rest[tlsIdx + 2], ca: rest[tlsIdx + 3] } : null;
const expireFirst = rest.includes('--expire-first-token');
const requireBearer = !rest.includes('--no-bearer-required');

const log = (o) => fs.appendFileSync(logPath, JSON.stringify(o) + '\n');
let mints = 0;
const validTokens = new Set();   // like a real IdP: every unexpired token it issued is accepted

function violations(b) {
  const v = [];
  if (typeof b !== 'object' || b === null) return ['body is not an object'];
  if (!['SUITE', 'RUN'].includes(b.kind)) v.push('kind must be SUITE or RUN');
  if (!['running', 'passed', 'failed', 'skipped', 'error'].includes(b.state)) v.push('state must be running, passed, failed, skipped or error');
  if (b.suite != null && String(b.suite).length > 255) v.push('suite is too long');
  if (b.role != null && String(b.role).length > 64) v.push('role is too long');
  if (b.message != null && String(b.message).length > 1000) v.push('message is too long');
  for (const k of ['passed', 'failed', 'skipped']) {
    if (!Number.isInteger(b[k]) || b[k] < 0 || b[k] > 1_000_000) v.push(`${k} must be an integer 0..1000000`);
  }
  if (!Number.isInteger(b.percent) || b.percent < 0 || b.percent > 100) v.push('percent must be an integer 0..100');
  if (b.durationMs != null && !(Number.isInteger(b.durationMs) && b.durationMs >= 0)) v.push('durationMs must be an integer >= 0');
  return v;
}

const ingest = (req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const peer = req.socket.getPeerCertificate ? req.socket.getPeerCertificate() : null;
    const m = /^\/bff\/admin\/test-reports\/([^/]+)\/ingest$/.exec(req.url || '');
    const rec = { t: 'ingest', method: req.method, url: req.url, peerCN: peer && peer.subject ? peer.subject.CN : null };
    const reply = (status, why) => { rec.status = status; if (why) rec.why = why; log(rec); res.writeHead(status).end(why || ''); };
    if (req.method !== 'POST' || !m) return reply(404, 'no such mapping (the endpoint is POST /bff/admin/test-reports/{id}/ingest)');
    rec.runId = decodeURIComponent(m[1]);
    const auth = req.headers['authorization'] || '';
    rec.authorization = auth ? auth.replace(/(Bearer\s+).+/, '$1<redacted>') : '';
    if (requireBearer && (!auth.startsWith('Bearer ') || !validTokens.has(auth.slice(7)))) return reply(401, 'unauthenticated');
    let body;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return reply(400, 'not json'); }
    const v = violations(body);
    rec.body = body;
    if (v.length) return reply(400, v.join('; '));
    return reply(200);
  });
};

const token = (req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const form = new URLSearchParams(Buffer.concat(chunks).toString('utf8'));
    mints++;
    const ok = form.get('grant_type') === 'client_credentials' && form.get('client_id') === 'app-test-ingest' && form.get('client_secret') === 's3cret';
    log({ t: 'token', n: mints, ok, grant: form.get('grant_type'), client: form.get('client_id') });
    if (!ok) return res.writeHead(401).end('bad client');
    // --expire-first-token: the FIRST token this stub mints is never accepted by the ingest (it "expired")
    const issued = expireFirst && mints === 1 ? 'expired-token-never-valid' : `tok-${mints}`;
    if (!(expireFirst && mints === 1)) validTokens.add(issued);
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ access_token: issued, expires_in: 3600 }));
  });
};

const ingestServer = tls
  ? https.createServer({ cert: fs.readFileSync(tls.cert), key: fs.readFileSync(tls.key), ca: fs.readFileSync(tls.ca),
      requestCert: true, rejectUnauthorized: true }, ingest)
  : http.createServer(ingest);
ingestServer.on('tlsClientError', (e) => log({ t: 'tls-client-error', error: String(e.message || e) }));
const tokenServer = http.createServer(token);
ingestServer.listen(0, '127.0.0.1', () => tokenServer.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(readyPath, JSON.stringify({ ingest: ingestServer.address().port, token: tokenServer.address().port }));
}));
process.on('SIGTERM', () => process.exit(0));
