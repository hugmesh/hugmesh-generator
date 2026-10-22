# Security Policy — hugmesh-generator

## Reporting a vulnerability

If you find a vulnerability in this repository (or in any HugMesh repository),
report it privately. Do not open a public issue, pull request or discussion.

Use GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
on this repository (Security tab, then "Report a vulnerability"), or open a draft
security advisory. We will acknowledge your report as quickly as we can and agree
a fix and disclosure timeline with you.

Keep exploit details out of public issues and discussions until a fix has shipped.

## What counts

This repository builds device images, renders the cluster manifests and runs the
local development stack, so the most useful reports are about:

- anything that lets one mesh, tenant or foreign base run code or publish under
  another's identity (the foreign-ingest gate, provenance signing, the
  templating renderer);
- secrets or private keys that a build, image or rendered repository would ship;
- privilege escalation on a device image or in the cluster manifests;
- the Studio desktop app running something with more privilege than it asked for.

## Deliberately public test material

These files are throwaway development fixtures, are public on purpose, and must
never be trusted or reused anywhere real. Reporting them is not needed:

- `tests/stack/certs/` — the mock UI server's TLS leaf certificate and its private
  key. The CA that signed it is name-constrained (it can only vouch for the cluster
  domain, `localhost` and the loopback addresses), and its private key is not in the
  repository: `tests/e2e/run-all.sh` mints a fresh one on every run.
- The `${VAR:-default}` dev defaults in `tests/stack/compose.local.yaml`, such as
  `APP_BFF_CUSTODY_KEY`, `APP_MFA_FACTOR_KEY` and `dev-app-user-bff-secret`. They only
  make the local stack start; a real cluster gets its own values from
  `scripts/gen-cluster-secrets.sh` and the secret store.
- Token- and key-shaped strings inside tests and fixtures (for example the
  secret-scanner and redaction test cases). They are fake.

If you find a key or credential that is NOT one of these, please report it.
