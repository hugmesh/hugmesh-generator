# Cassandra client-credential wiring (DB-hardening, ADR-32 — DARK, flip-time patch)

These are the consumer-side env additions applied **at the auth-flip step**
(Stage 1 step 5 in `docs/CLUSTER-HARDENING-PLAN.md` §H). They are documented here
rather than baked into the live deployments because adding `CASSANDRA_USER` /
`CASSANDRA_PASSWORD` while the server is still `AllowAllAuthenticator` is harmless
*but* rolling all six consumers blind in the same change is the cutover risk we are
deliberately staging. Each consumer reads its **own least-privilege role** password
from the `cassandra-app-creds` ESO Secret (one key per role).

The Spring apps already read `CASSANDRA_CONTACT_POINTS`; the DataStax driver picks
up `CASSANDRA_USER` / `CASSANDRA_PASSWORD` (Spring `spring.cassandra.username` /
`.password`) when present — so this is purely additive env.

## admin-bff-api (ns hugmesh-backend) — role `admin_bff_cass`
```yaml
- name: CASSANDRA_USER
  value: "admin_bff_cass"
- name: CASSANDRA_PASSWORD
  valueFrom: { secretKeyRef: { name: cassandra-app-creds, key: admin-bff } }
```
(`cassandra-app-creds` must be mirrored into `hugmesh-backend` — add the same
ExternalSecret with `target.name: cassandra-app-creds` in that namespace, or use a
`PushSecret`/`ClusterExternalSecret`. The DB-hardening ESO convention is one ES per
namespace; the overlay ships the `hugmesh-pki` copy used by the bootstrap Job.)

## federation-api (ns hugmesh-backend) — role `federation_cass`
```yaml
- name: CASSANDRA_USER
  value: "federation_cass"
- name: CASSANDRA_PASSWORD
  valueFrom: { secretKeyRef: { name: cassandra-app-creds, key: federation } }
```
Federation's manifest cache is gated by `MANIFEST_CACHE_ENABLED=false`; if it stays
off, federation never opens a Cassandra session and these can be deferred until the
cache is enabled.

## Gateways (hugmesh-gateway chart) — roles `pki_gw_cass` / `be_gw_cass` / `fe_gw_cass` / `sa_gw_cass`
Add to `specs/cluster/charts/hugmesh-gateway/values.yaml` `cassandra:` block (and
template the env in `templates/deployment.yaml` next to `CASSANDRA_CONTACT_POINTS`):
```yaml
cassandra:
  contactPoints: cassandra.hugmesh-pki.svc.cluster.local:9042
  keyspace: snapdragon_gateway
  localDc: dc1
  # NEW (flip-time): per-gateway least-privilege role + creds Secret.
  username: ""                 # be:be_gw_cass  fe:fe_gw_cass  pki:pki_gw_cass  superadmin:sa_gw_cass
  passwordSecret: ""           # cassandra-app-creds
  passwordSecretKey: ""        # be-gateway / fe-gateway / pki-gateway / superadmin-gateway
```
Per-gateway override in `apps/20-gateway-be.yaml` / `20-gateway-fe.yaml` /
`20-gateway-pki.yaml` / `22-gateway-superadmin.yaml`. Each gateway namespace
(`hugmesh-backend`, `hugmesh-frontend`, `hugmesh-pki`) needs the
`cassandra-app-creds` ES mirrored into it (same note as admin-bff above).

## TLS (Stage 2) — additional per-consumer wiring
When `clientEncryption: true` is flipped, each consumer must trust the cluster CA
and connect over TLS. The Spring apps already carry the cluster-CA truststore for
mTLS; point the Cassandra driver at it:
```yaml
- name: CASSANDRA_SSL
  value: "true"
# (driver truststore = the existing /pki ca.crt / cluster truststore the app uses
#  for API mTLS; no new material needed.)
```
`clientEncryption` defaults `require_client_auth` to optional, so flipping the
server does not instantly sever a not-yet-TLS client — flip consumers, confirm, then
tighten to required.
