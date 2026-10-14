// print-plan.mjs — turn run.sh's `--print-command` plan into JSON.
//
// The plan is built in bash, where quoting a command line into valid JSON by
// hand is how you end up with a plan that is subtly not what runs. So bash
// emits TAB-separated key/value lines on stdin (one argv element per line, in
// order) and this file is the only thing that serialises. The argv printed here
// is the SAME array run.sh execs — it is assembled once, then either run or
// printed, never assembled twice.
//
// Executes nothing. Reads stdin, writes one JSON object, exits 0.
import { createInterface } from 'node:readline';

const plan = {
  env: null, baseUrl: null, startHint: null,
  lane: 'legacy', generate: false, tags: null,
  features: [], reportDir: null, runId: null, evidenceDir: null,
  hostResolver: null, generateArgv: [], argv: [],
  via: null, onionBaseUrl: null, proxy: null, onionNote: null,
  // --via onion-domains: {slug: "https://<onion>"} per Tor domain, from the same
  // "<slug>=<url> ..." list run.sh exports as SNAP_ONION_DOMAIN_URLS; null when the
  // lane has none (the tab-separated plan carries it as ONION_DOMAIN_URLS).
  onionDomainUrls: null,
};

const domainUrls = (value) => {
  const out = {};
  for (const entry of value.split(/\s+/).filter(Boolean)) {
    const eq = entry.indexOf('=');
    if (eq > 0) out[entry.slice(0, eq)] = entry.slice(eq + 1);
  }
  return Object.keys(out).length ? out : null;
};

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of rl) {
  if (!line) continue;
  const tab = line.indexOf('\t');
  if (tab < 0) continue;
  const key = line.slice(0, tab);
  const value = line.slice(tab + 1);
  switch (key) {
    case 'ENV_ID':        plan.env = value || null; break;
    case 'BASE_URL':      plan.baseUrl = value || null; break;
    case 'HINT':          plan.startHint = value || null; break;
    case 'LANE':          plan.lane = value; break;
    case 'GENERATE':      plan.generate = value === '1'; break;
    case 'TAGS':          plan.tags = value || null; break;
    case 'REPORT_DIR':    plan.reportDir = value || null; break;
    case 'RUN_ID':        plan.runId = value || null; break;
    case 'HOST_RESOLVER': plan.hostResolver = value || null; break;
    case 'VIA':           plan.via = value || null; break;
    case 'ONION_BASE_URL': plan.onionBaseUrl = value || null; break;
    case 'PROXY':         plan.proxy = value || null; break;
    case 'ONION_NOTE':    plan.onionNote = value || null; break;
    case 'ONION_DOMAIN_URLS': plan.onionDomainUrls = domainUrls(value); break;
    case 'FEATURE':       plan.features.push(value); break;
    case 'GENARGV':       plan.generateArgv.push(value); break;
    case 'ARGV':          plan.argv.push(value); break;
    default: break;
  }
}

// Where this run's per-step evidence would land. Mirrors steps/evidence.ts:
// BDD_SHOTS = <reportDir>/bdd-steps, runDir = BDD_SHOTS/slug(runId).
const slug = (s) => (String(s).replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '') || 'unnamed').slice(0, 60);
if (plan.reportDir && plan.runId) {
  plan.evidenceDir = `${plan.reportDir}/bdd-steps/${slug(plan.runId)}`;
}

// ONE LINE, deliberately: the harness step `the command output is valid JSON`
// parses the LAST stdout line, and every other machine-readable surface in this
// suite answers the same way. Pipe through `python3 -m json.tool` to read it.
process.stdout.write(`${JSON.stringify(plan)}\n`);
