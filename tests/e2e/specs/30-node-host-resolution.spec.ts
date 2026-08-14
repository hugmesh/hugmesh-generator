import { test, expect } from '@playwright/test';

// 30 — STACK-FREE unit coverage for resolveForNode(), the helper that lets Node-side
// API contexts reach a kind cluster.
//
// WHY IT NEEDS ITS OWN TESTS. `--host-resolver-rules` is BROWSER-ONLY. Kind runs
// address the cluster by its real hostname (the fe-gateway Ingress matches on Host)
// and hand Chromium SNAP_HOST_RESOLVER so no /etc/hosts edit or sudo is needed. Node
// never sees that flag, so `request.newContext()` — and `page.request`, which is easy
// to mistake for browser-side because it shares the cookie jar — die on
// `getaddrinfo ENOTFOUND hugmesh.net`. resolveForNode() dials the mapped IP and
// carries the hostname in the Host header, which is what ingress-nginx routes on.
// Proven live on kind with its own control: with the Host header the BFF answered
// 401 (routed); without it nginx answered 404 (default backend, did not route).
//
// THE PROPERTY THESE TESTS DEFEND is the one that makes the helper safe to adopt in
// specs that only ever run against compose: **with SNAP_HOST_RESOLVER unset it is a
// no-op**. If that ever stops being true, every compose run starts rewriting URLs it
// must not touch, and nothing else in the suite would notice.
//
// Stack-free by construction — like spec 29's RFC 6238 vectors, these run anywhere,
// with no cluster, no compose and no network.

// resolveForNode takes its rule map as an argument, so each case simply passes the
// rules it wants. No module-cache tricks, no env mutation, no ordering coupling.
import { resolveForNode, parseResolverRules } from './helpers';

const NO_RULES = parseResolverRules(undefined);

const RULES = parseResolverRules('MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1');

test.describe('resolveForNode: Node-side host resolution for kind', () => {
  test('NO-OP when SNAP_HOST_RESOLVER is unset (the compose lane must be untouched)', () => {
    const r = resolveForNode('https://hugmesh.net:8443/bff/session', NO_RULES);
    expect(r.url).toBe('https://hugmesh.net:8443/bff/session');
    expect(r.headers).toEqual({});
  });

  test('rewrites a mapped host to its IP and carries the hostname in Host', () => {
    const r = resolveForNode('https://hugmesh.net:8443/bff/session', RULES);
    expect(new URL(r.url).hostname).toBe('127.0.0.1');
    expect(new URL(r.url).port).toBe('8443');
    // Hostname WITHOUT the port — the exact shape proven to route on kind.
    expect(r.headers.Host).toBe('hugmesh.net');
  });

  test('honours a wildcard rule for subdomains', () => {
    const r = resolveForNode('https://registry.hugmesh.net/v2/', RULES);
    expect(new URL(r.url).hostname).toBe('127.0.0.1');
    expect(r.headers.Host).toBe('registry.hugmesh.net');
  });

  test('leaves an UNMAPPED host alone even when rules are present', () => {
    const r = resolveForNode('https://example.invalid/whatever', RULES);
    expect(r.url).toBe('https://example.invalid/whatever');
    expect(r.headers).toEqual({});
  });

  test('leaves a relative path alone rather than throwing on URL parsing', () => {
    const r = resolveForNode('/bff/session', RULES);
    expect(r.url).toBe('/bff/session');
    expect(r.headers).toEqual({});
  });

  test('ignores malformed resolver entries instead of half-applying them', () => {
    const messy = parseResolverRules('MAP, NOTARULE, MAP hugmesh.net 127.0.0.1');
    const good = resolveForNode('https://hugmesh.net:8443/x', messy);
    expect(new URL(good.url).hostname).toBe('127.0.0.1');
    const other = resolveForNode('https://elsewhere.test/x', messy);
    expect(other.headers).toEqual({});
  });
});
