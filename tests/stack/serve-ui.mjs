// serve-ui.mjs — serve the built Angular host over HTTPS using the GENERATED
// certs, inject the GENERATED runtime values, and reverse-proxy the API calls
// to the mock Matrix/Mastodon servers so the browser sees a single origin.
import https from 'node:https';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const PORT = Number(process.env.PORT || 8443);
const CERTS = process.env.CERTS || path.resolve('tests/stack/certs');
const DIST = process.env.UI_DIST || path.resolve('tests/stack/.uidist');
const MATRIX_TARGET = process.env.MATRIX_TARGET || 'http://127.0.0.1:8401';
const MASTODON_TARGET = process.env.MASTODON_TARGET || 'http://127.0.0.1:8402';
const BFF_TARGET = process.env.BFF_TARGET || 'http://127.0.0.1:8403';
const values = JSON.parse(fs.readFileSync(path.join(CERTS, 'values.json'), 'utf8'));

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.ico': 'image/x-icon', '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2', '.map': 'application/json', '.txt': 'text/plain' };

// Runtime config the UI reads (same-origin '' base => calls get proxied below).
const CONFIG_SCRIPT = `<script>
  window.__SNAP_MATRIX_URL__='';
  window.__SNAP_MASTODON_URL__='';
  window.__SNAP_CASDOOR_ISSUER__=${JSON.stringify(values.casdoorIssuer)};
  window.__SNAP_UPTRACE_URL__=${JSON.stringify(values.uptraceUrl || 'https://uptrace.snapdragon.systems')};
  window.__SNAP_VALUES__=${JSON.stringify(values)};
</script>`;

function proxy(req, res, target) {
  const u = new URL(target);
  const opts = { hostname: u.hostname, port: u.port, path: req.url, method: req.method, headers: req.headers };
  const pr = http.request(opts, (pres) => { res.writeHead(pres.statusCode, pres.headers); pres.pipe(res); });
  pr.on('error', (e) => { res.writeHead(502); res.end('proxy error: ' + e.message); });
  req.pipe(pr);
}

function serveStatic(req, res) {
  const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = path.join(DIST, urlPath);
  if (!file.startsWith(DIST)) { res.writeHead(403); return res.end('forbidden'); }
  let stat = fs.existsSync(file) && fs.statSync(file);
  if (!stat || stat.isDirectory()) file = path.join(DIST, 'index.html'); // SPA fallback
  const ext = path.extname(file);
  let body = fs.readFileSync(file);
  if (ext === '.html') body = Buffer.from(body.toString().replace('</head>', `${CONFIG_SCRIPT}</head>`));
  res.writeHead(200, { 'content-type': MIME[ext] || 'application/octet-stream' });
  res.end(body);
}

const handler = (req, res) => {
  const p = new URL(req.url, 'http://x').pathname;
  if (p.startsWith('/_matrix/')) return proxy(req, res, MATRIX_TARGET);
  if (p.startsWith('/bff/')) return proxy(req, res, BFF_TARGET);
  if (p.startsWith('/api/') || p.startsWith('/oauth/')) return proxy(req, res, MASTODON_TARGET);
  return serveStatic(req, res);
};

https.createServer({
  key: fs.readFileSync(path.join(CERTS, 'server.key')),
  cert: fs.readFileSync(path.join(CERTS, 'fullchain.crt')),
}, handler).listen(PORT, () => console.log(`[serve-ui] https://localhost:${PORT}  dist=${DIST}`));
