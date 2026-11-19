// ingest.ts — the e2e reporter's live-event client for admin-bff's test-report ingest.
//
// WHY THIS EXISTS (hugmesh-generator#507, finding 25). The Job's reporter POSTed to
// `.../bff/admin/test-reports/ingest` and it could never have worked, in FOUR ways, which is
// why "results silently never ingested" went unnoticed (the POST swallowed every failure):
//   1. PATH     TestReportsController maps `POST /{id}/ingest` (and `POST /run`); there is no
//               `POST /ingest`, so a POST without the run id matches nothing.
//   2. CONTRACT it sent `{event:'run-begin'|'test-end'|'run-end', ...}`; the endpoint takes
//               TestRunIngestRequest `{kind: SUITE|RUN, state: running|passed|failed|skipped|
//               error, passed, failed, skipped, percent, ...}` and rejects a blank kind/state.
//   3. AUTH     no Authorization header at all, and the endpoint is @PreAuthorize.
//   4. TLS      admin-bff serves client-auth=need; nothing presented a certificate.
// This module fixes all four, and does NOT swallow failures silently any more: it counts the
// events the endpoint did not accept and the reporter prints that at the end.
//
// NODE BUILTINS ONLY, on purpose: the reporter runs under bare `node` on a checkout that has
// never had `npm ci` (tests/scripts/e2e-reporter-replay.mjs does exactly that).
//
// CONFIGURATION (environment; all optional; nothing set = no live events, as before):
//   SNAP_INGEST_BASE_URL   the API root, e.g. https://hugmesh-admin-bff-api.<ns>.svc:8080/bff/admin/test-reports
//                          (events go to <base>/<SNAP_RUN_ID>/ingest)
//   SNAP_RUN_ID            the run id the orchestrator created (required to post)
//   the credential, either
//     SNAP_INGEST_TOKEN_URL + SNAP_INGEST_CLIENT_ID + SNAP_INGEST_CLIENT_SECRET
//                          a Casdoor client-credentials machine account (the narrow, ingest-only
//                          credential), minted and refreshed here; or
//     SNAP_INGEST_TOKEN    a static bearer, for a dev run only (it expires)
//   mTLS (PEM file paths), for a TLS peer that requires a client certificate:
//     SNAP_INGEST_TLS_CERT / SNAP_INGEST_TLS_KEY / SNAP_INGEST_TLS_CA
//   SNAP_INGEST_URL        RETIRED. Setting it without the BASE_URL warns and posts nothing.

import * as fs from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';

/** admin-bff TestRunIngestRequest (net.hugmesh.adminbff.web.dto), field for field. */
export interface IngestBody {
  kind: 'SUITE' | 'RUN';
  suite?: string;
  role?: string;
  state: 'running' | 'passed' | 'failed' | 'skipped' | 'error';
  passed: number;
  failed: number;
  skipped: number;
  percent: number;
  durationMs?: number;
  message?: string;
}

const MAX_SUITE = 255;
const MAX_ROLE = 64;
const MAX_MESSAGE = 1000;
const MAX_COUNT = 1_000_000;

const clip = (s: unknown, n: number): string | undefined => {
  if (s === undefined || s === null) return undefined;
  const t = String(s);
  return t.length > n ? t.slice(0, n) : t;
};
const count = (v: unknown): number => {
  const n = Math.trunc(Number(v));
  return Number.isFinite(n) && n > 0 ? Math.min(n, MAX_COUNT) : 0;
};

/**
 * Translate one reporter event into the endpoint's contract, or null when it has no
 * counterpart (nothing is invented for an event the endpoint cannot represent).
 */
export function toIngestBody(event: string, p: Record<string, unknown>): IngestBody | null {
  switch (event) {
    case 'run-begin':
      return { kind: 'RUN', state: 'running', passed: 0, failed: 0, skipped: 0, percent: 0,
        message: clip(`tier=${p['tier'] ?? ''}`, MAX_MESSAGE) };
    case 'test-end': {
      const status = String(p['status'] ?? '');
      const state = status === 'passed' ? 'passed' : status === 'skipped' ? 'skipped' : 'failed';
      const why = state === 'failed' ? p['error'] : state === 'skipped' ? p['skipReason'] : undefined;
      return {
        kind: 'SUITE',
        suite: clip(p['specFile'] || p['title'], MAX_SUITE),
        role: clip(p['role'], MAX_ROLE),
        state,
        passed: state === 'passed' ? 1 : 0,
        failed: state === 'failed' ? 1 : 0,
        skipped: state === 'skipped' ? 1 : 0,
        percent: 100,
        durationMs: Number.isFinite(Number(p['durationMs'])) ? Math.max(0, Math.trunc(Number(p['durationMs']))) : undefined,
        message: clip(why, MAX_MESSAGE),
      };
    }
    case 'run-end': {
      const r = String(p['result'] ?? '');
      const state = r === 'passed' ? 'passed' : r === 'failed' ? 'failed' : 'error';
      return { kind: 'RUN', state, passed: count(p['passed']), failed: count(p['failed']),
        skipped: count(p['skipped']), percent: 100,
        message: clip(`tier=${p['tier'] ?? ''} result=${r}`, MAX_MESSAGE) };
    }
    default:
      return null;
  }
}

export interface IngestConfig {
  baseUrl: string;
  runId: string;
  tokenUrl?: string;
  clientId?: string;
  clientSecret?: string;
  staticToken?: string;
  tlsCert?: string;
  tlsKey?: string;
  tlsCa?: string;
}

interface Reply { status: number; body: string }

function request(url: string, method: string, headers: Record<string, string>, body: string,
                 tls: { cert?: Buffer; key?: Buffer; ca?: Buffer }): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const secure = u.protocol === 'https:';
    const opts: https.RequestOptions = {
      method, hostname: u.hostname, port: u.port || (secure ? 443 : 80),
      path: u.pathname + u.search, timeout: 10_000,
      headers: { ...headers, 'content-length': String(Buffer.byteLength(body)) },
    };
    if (secure) Object.assign(opts, tls);
    const req = (secure ? https : http).request(opts, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c: Buffer) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode || 0, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end(body);
  });
}

export class IngestClient {
  private token = '';
  private tokenExpiresAt = 0;
  private minting: Promise<string> | null = null;
  private queue: Promise<void> = Promise.resolve();
  private tls: { cert?: Buffer; key?: Buffer; ca?: Buffer } = {};
  private attempted = 0;
  private failed = 0;
  private firstFailure = '';
  private tlsError = '';

  private cfg: IngestConfig;

  // NOT a parameter property: the reporter runs under bare node's type STRIPPING, which only
  // accepts erasable syntax (no parameter properties, no enums).
  constructor(cfg: IngestConfig) {
    this.cfg = cfg;
    // A file that cannot be read must not throw: this runs while Playwright builds its
    // reporters, so a throw here failed the whole test run before one test started. Each
    // event is then counted as not accepted, with this reason, and reported at the end.
    try {
      if (cfg.tlsCert && cfg.tlsKey) {
        this.tls.cert = fs.readFileSync(cfg.tlsCert);
        this.tls.key = fs.readFileSync(cfg.tlsKey);
      }
      if (cfg.tlsCa) this.tls.ca = fs.readFileSync(cfg.tlsCa);
    } catch (e) {
      this.tlsError = `cannot read the TLS files (SNAP_INGEST_TLS_CERT/KEY/CA): ${(e as Error).message}`;
    }
  }

  /** The client the environment describes, or null when live ingest is not configured. */
  static fromEnv(env: NodeJS.ProcessEnv = process.env, warn: (m: string) => void = (m) => process.stderr.write(m + '\n')): IngestClient | null {
    const base = env['SNAP_INGEST_BASE_URL'] || '';
    if (!base) {
      if (env['SNAP_INGEST_URL']) {
        warn('[hugmesh-reporter] SNAP_INGEST_URL is retired and is NOT used: the ingest endpoint is '
          + '<base>/{runId}/ingest. Set SNAP_INGEST_BASE_URL (the .../bff/admin/test-reports root); no live events will be sent.');
      }
      return null;
    }
    return new IngestClient({
      baseUrl: base.replace(/\/+$/, ''),
      runId: env['SNAP_RUN_ID'] || '',
      tokenUrl: env['SNAP_INGEST_TOKEN_URL'], clientId: env['SNAP_INGEST_CLIENT_ID'],
      clientSecret: env['SNAP_INGEST_CLIENT_SECRET'], staticToken: env['SNAP_INGEST_TOKEN'],
      tlsCert: env['SNAP_INGEST_TLS_CERT'], tlsKey: env['SNAP_INGEST_TLS_KEY'], tlsCa: env['SNAP_INGEST_TLS_CA'],
    });
  }

  /** Events attempted, events the endpoint did not accept, and the first reason. */
  get stats(): { attempted: number; failed: number; firstFailure: string } {
    return { attempted: this.attempted, failed: this.failed, firstFailure: this.firstFailure };
  }

  /**
   * The bearer token. The reporter fires its events CONCURRENTLY, so many callers see an empty
   * cache at once: they share ONE in-flight mint instead of each minting their own (measured:
   * 26 events minted 26 tokens before this). On a 401 the caller names the token that failed,
   * and a new one is minted only if nobody has already replaced it.
   */
  private async bearer(failed = ''): Promise<string> {
    if (this.cfg.staticToken) return this.cfg.staticToken;
    if (!this.cfg.tokenUrl || !this.cfg.clientId || !this.cfg.clientSecret) return '';
    const fresh = this.token && Date.now() < this.tokenExpiresAt - 30_000;
    if (fresh && (!failed || this.token !== failed)) return this.token;
    if (!this.minting) {
      this.minting = this.mint().finally(() => { this.minting = null; });
    }
    return this.minting;
  }

  private async mint(): Promise<string> {
    const form = new URLSearchParams({ grant_type: 'client_credentials',
      client_id: this.cfg.clientId || '', client_secret: this.cfg.clientSecret || '' }).toString();
    const r = await request(this.cfg.tokenUrl || '', 'POST', { 'content-type': 'application/x-www-form-urlencoded' }, form, this.tls);
    if (r.status < 200 || r.status >= 300) throw new Error(`token endpoint answered ${r.status}`);
    const j = JSON.parse(r.body) as { access_token?: string; expires_in?: number };
    if (!j.access_token) throw new Error('token endpoint returned no access_token');
    this.token = j.access_token;
    this.tokenExpiresAt = Date.now() + (j.expires_in && j.expires_in > 0 ? j.expires_in : 3600) * 1000;
    return this.token;
  }

  private note(reason: string): void {
    this.failed++;
    if (!this.firstFailure) this.firstFailure = reason;
  }

  /**
   * Send one event, IN ORDER: events are delivered one after another, because a live console
   * wants run-begin before the tests and run-end after them, and concurrent POSTs arrive in any
   * order (measured: a SUITE event was seen before run-begin). NEVER throws (the report on disk
   * is authoritative); failures are COUNTED.
   */
  send(event: string, payload: Record<string, unknown>): Promise<void> {
    const next = this.queue.then(() => this.deliver(event, payload));
    this.queue = next.catch(() => undefined);
    return next;
  }

  private async deliver(event: string, payload: Record<string, unknown>): Promise<void> {
    const body = toIngestBody(event, payload);
    if (!body) return;
    this.attempted++;
    if (!this.cfg.runId) return this.note('SNAP_RUN_ID is not set, so there is no run id to post to');
    if (this.tlsError) return this.note(this.tlsError);
    const url = `${this.cfg.baseUrl}/${encodeURIComponent(this.cfg.runId)}/ingest`;
    const json = JSON.stringify(body);
    try {
      let failedToken = '';
      for (let attempt = 0; attempt < 2; attempt++) {
        const token = await this.bearer(failedToken);
        const headers: Record<string, string> = { 'content-type': 'application/json' };
        if (token) headers['authorization'] = `Bearer ${token}`;
        const r = await request(url, 'POST', headers, json, this.tls);
        if (r.status >= 200 && r.status < 300) return;
        if (r.status === 401 && attempt === 0 && !this.cfg.staticToken) { failedToken = token; continue; }   // expired: mint once more
        return this.note(`${event}: ${url} answered ${r.status}`);
      }
    } catch (e) {
      this.note(`${event}: ${(e as Error).message}`);
    }
  }
}
