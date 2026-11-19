// e2e-ingest-unit.mjs — drive IngestClient directly for what the replay harness hides: the replay
// deletes SNAP_INGEST_URL and defaults SNAP_RUN_ID, so those two cases cannot go through it.
// Usage: node e2e-ingest-unit.mjs <case>   (prints one JSON line)
import { IngestClient } from '../e2e/reporters/ingest.ts';

const which = process.argv[2];
const warnings = [];
const warn = (m) => warnings.push(m);
if (which === 'legacy-url') {
  const c = IngestClient.fromEnv({ SNAP_INGEST_URL: 'https://example.invalid/bff/admin/test-reports/ingest', SNAP_RUN_ID: 'r' }, warn);
  console.log(JSON.stringify({ client: c === null, warnings }));
} else if (which === 'no-env') {
  console.log(JSON.stringify({ client: IngestClient.fromEnv({}, warn) === null, warnings }));
} else if (which === 'no-run-id') {
  // a base URL that would answer 200 if anything reached it: nothing must be sent to it
  const c = IngestClient.fromEnv({ SNAP_INGEST_BASE_URL: 'http://127.0.0.1:9/bff/admin/test-reports', SNAP_RUN_ID: '' }, warn);
  await c.send('run-begin', { tier: 'LEAN' });
  console.log(JSON.stringify({ stats: c.stats }));
} else {
  console.error('unknown case'); process.exit(2);
}
