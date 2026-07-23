// report-tags.ts — the role/layer tagging convention the hugmesh reporter maps
// each test onto, so the admin-bff TestReportsController + the admin-ui console can
// pivot the run by ROLE and by ENFORCEMENT LAYER (not just pass/fail counts).
//
// A test opts in by putting a tag in its TITLE using the `@role:<x>` / `@layer:<y>`
// convention (Playwright surfaces the full title path to the reporter), OR by
// passing the tag through the `tag()` helper below which simply formats it. The
// reporter parses these out of the title; an untagged test is bucketed as
// role:unknown / layer:unknown (still counted, never dropped).

/** Canonical enforcement layers a control can be asserted at — the "every enacted
 *  control works at EACH layer" axis of the final sweep matrix. */
export type Layer =
  | 'gateway'        // the route-access gateway decision (fe/be/pki)
  | 'bff'            // BFF method-security / API gating
  | 'homeserver'    // akkoma MRF / Matrix power-levels
  | 'egress'         // the egress NetworkPolicy + proxy (non-federation)
  | 'casdoor'        // role/claim issuance + derived-role sync
  | 'ui'             // the rendered surface (nav visibility, disabled+helptext)
  | 'sse';           // per-principal action messaging (Server-Sent Events)

/** Format a `@role:<x>` tag for a test title. */
export function roleTag(role: string): string {
  return `@role:${role}`;
}

/** Format a `@layer:<y>` tag for a test title. */
export function layerTag(layer: Layer): string {
  return `@layer:${layer}`;
}

/** Compose a set of tags into a single suffix for a test title, e.g.
 *  test(`mod denied infra ${tags({role:'ROLE_MOD', layer:'gateway'})}`, …). */
export function tags(opts: { role?: string; layer?: Layer }): string {
  const out: string[] = [];
  if (opts.role) out.push(roleTag(opts.role));
  if (opts.layer) out.push(layerTag(opts.layer));
  return out.join(' ');
}

/** Parse the role/layer tags out of a (possibly full-path) test title. Used by
 *  the reporter. Returns the LAST occurrence of each (the most specific). */
export function parseTags(title: string): { role: string; layer: string } {
  const roleMatches = [...title.matchAll(/@role:([A-Za-z0-9_-]+)/g)];
  const layerMatches = [...title.matchAll(/@layer:([A-Za-z0-9_-]+)/g)];
  return {
    role: roleMatches.length ? roleMatches[roleMatches.length - 1][1] : 'unknown',
    layer: layerMatches.length ? layerMatches[layerMatches.length - 1][1] : 'unknown',
  };
}
