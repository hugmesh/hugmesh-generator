# Identity providers — Casdoor (built-in) and external OIDC

A mesh node checks the tokens its services accept against an **identity provider
(IdP)**. The built-in provider is **Casdoor**, and it is the default. Build with no
`--idp` flag (or `--idp casdoor`) and every image, argv byte and baked file is what it
was before this option existed. You can instead point a node at an **external OIDC
provider** (Azure Entra ID, AWS Cognito, or any generic OIDC issuer) for the
token-validation leg.

You can make this choice wherever a node is configured: the Studio wizard's
**Identity provider** screen (early, right after the mode pick), the local-mesh
bootstrap tab, the ncurses `idp` screen, the cloud-deploy flow, and the raw builder
flags below.

## What external mode changes

`--idp entra|aws|oidc --idp-issuer <https-url> [--idp-client-id <id>] [--idp-jwks <url>]`
makes the builder, after the normal `rebrand_sysroot` pass:

1. **bakes `/etc/hugmesh/idp.conf`** (`provider` / `issuer` / `client_id` /
   `jwks_uri`, mode `0644`, no secrets; issuer, client id and JWKS URL are public
   identifiers);
2. **re-points the baked cluster tree's issuer and JWKS pins** from the derived
   `https://id.<cluster-domain>` and in-cluster `…/.well-known/jwks` to your external
   issuer and JWKS URL;
3. **gates the in-cluster Casdoor apps out** (`apps/05-casdoor.yaml`,
   `apps/06-casdoor-games.yaml`), since an external IdP means the node runs no IdP of
   its own;
4. **drops `README-IDP.md`** into the baked tree. It says what does not work in
   external mode (below).

`--idp-jwks` is optional; left empty it is derived per provider — Entra →
`<issuer>/discovery/v2.0/keys` (Entra does **not** serve `/.well-known/jwks`),
AWS Cognito → `<issuer>/.well-known/jwks.json`, generic OIDC →
`<issuer>/.well-known/jwks`. Override it when your provider differs.

Client **secrets are never passed as flags** and never baked. Only the public client
id travels. Where a confidential-client secret is needed, the operator provisions it
at runtime. It is not an image input.

## Honest limits — what external mode does NOT do

Casdoor does more than issue tokens. Several platform legs depend on Casdoor's own
API and token shape. Switching the validation issuer does **not** port them. They
need service-repo work that an image build cannot do:

| Coupled leg | Why it doesn't port for free |
|---|---|
| **Native `/bff/login`** | user-bff calls Casdoor's proprietary `POST /api/login` (headless credential grant). Entra/Cognito have no headless password API (ROPC is legacy and blocks MFA/federated users) — external mode requires the browser redirect flow, which the native-login posture removed. |
| **MFA step-up** | admin-bff stamps `Properties.mfa_satisfied` into the Casdoor user via the Casdoor API; the gateway reads that claim. Entra's analog is `acr`/`amr`/auth-context — different names, different types, no stamping API. |
| **Role / group claims** | Casdoor emits the full platform role set and groups as `"<owner>/<name>"` strings (e.g. `hugmesh/headscale`). Entra `roles` are per-app appRole assignments scoped to one audience; `groups` are GUIDs. AWS Cognito emits `cognito:groups` (not `roles`). Consumers keyed on those exact claim names — headscale `allowed_groups`, Harbor `oidc_group_claim_name`, the desktop-sudo mapper's `roles`→`desktop-sudo` gate (desktop-governance) — need remapping. |
| **Pairwise subject** | Entra v2.0 `sub` is **pairwise per client**, so one human has different `sub`s across services. The canonical identity fold must key on the tenant-stable `oid` instead of `sub` — a resolver change in user-bff/auth-core. |
| **Role-sync / signup-gate Jobs** | The Casdoor-API reconcile Jobs (role membership sync, signup-gate reverse proxy) have no external-IdP analog — they must be dropped or reimplemented against the provider's directory API (MS Graph / Cognito). |

External mode covers the **token-validation** leg of a node's services, and stops
there. The five legs above stay Casdoor-only until the service-repo changes land.

## Builder flags

```
--idp casdoor|entra|aws|oidc     identity provider the baked services trust
                                 (default casdoor = built-in, no change)
--idp-issuer URL                 external OIDC issuer (https://, must byte-match
                                 the token `iss`); REQUIRED unless --idp casdoor
--idp-client-id ID               external OIDC public client id; REQUIRED unless
                                 --idp casdoor (secrets are never flags)
--idp-jwks URL                   JWKS override; empty derives per provider
                                 (Entra: /discovery/v2.0/keys, aws: /.well-known/jwks.json,
                                 oidc: /.well-known/jwks)
```

Placeholder issuer shapes: Entra
`https://login.microsoftonline.com/<tenant>/v2.0`; Cognito
`https://cognito-idp.<region>.amazonaws.com/<pool-id>`.

Only the two mesh-node builders (`build-x86-host-stage4.sh`,
`build-rpi5-stage4.sh`) take these flags. Client and standalone desktop images have no
cluster plane to re-point. The Studio spec channel carries the same fields through
`IMAGE_SPEC_JSON`. The legacy `docker/build-image.sh` env channel forwards `IDP` /
`IDP_ISSUER` / `IDP_CLIENT_ID` / `IDP_JWKS` for x86 and rpi5.

## Local mesh (test stack)

The local-mesh bootstrap passes an external issuer into the stack env
(`OIDC_ISSUER` / `OIDC_CLIENT_ID` / `OIDC_JWKS_URI`). The Makefile reads all three
and maps them onto the frozen cross-repo compose names:

| Studio / `make` var | Compose name it rides | Reaches |
|---|---|---|
| `OIDC_ISSUER` | `CASDOOR_ISSUER_URI` | every service's issuer (`iss`) validation |
| `OIDC_CLIENT_ID` | `CASDOOR_APP_CLIENT_ID` | admin-bff/user-bff `APP_BFF_OIDC_CLIENT_ID` |
| `OIDC_JWKS_URI` | `CASDOOR_JWKS_URI` | gateway + resource-server signing-key fetch |

Set all three together (`make stack-up OIDC_ISSUER=… OIDC_CLIENT_ID=…
OIDC_JWKS_URI=…`). The Makefile derives no per-provider JWKS; the Studio derives and
exports it. The local stack's gateways and BFFs then **validate tokens against the
external issuer and JWKS**. Unset, every default is byte-identical to the Casdoor-only
stack.

The limit that remains: the coupled legs in the table above (native `/bff/login`, MFA
step-up, role claims) stay Casdoor-only, and `make stack-seed` still seeds the
in-stack Casdoor. So the **test** environment validates external tokens but does not
run a full external login round-trip. That is a production-cluster concern.
