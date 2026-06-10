# Cryptography audit & post-quantum / SHA-3 migration

Audit of every cryptographic choice this repo controls, the change made, and the
post-quantum (PQC) readiness of each. The goal is **crypto agility**: each
algorithm decision is a single, centralised knob the brand/operator can re-tune
without editing logic, so we can swap in stronger (incl. PQC) primitives as the
toolchain (OpenSSL / keytool / the JVM / Vault) gains portable support — without
re-architecting.

This is a **real cluster that must still boot**, so the defaults are the
strongest the deployed openssl + keytool + JVM + Vault stack handles
**interoperably today**. Where a primitive (notably SHA-3 *inside* an X.509
signature, and true PQC KEM/signatures) is not yet portable across all of those,
it is wired behind a gate and **documented as the migration path** rather than
forced into a configuration that would fail to validate or fail to boot.

## Algorithm decisions

| # | Location | Usage | Old | New (default) | PQC-ready? | Notes / migration path |
|---|----------|-------|-----|---------------|------------|------------------------|
| 1 | `scripts/gen-keystores.sh` | Cluster CA + per-service mTLS leaf **key** | RSA-2048 | **RSA-4096** (knob `KEY_TYPE=ec` → EC P-384) | No (classical) | Raised, never lowered. Centralised: `KEY_TYPE`/`KEY_BITS`/`EC_CURVE`. PQC sigs (ML-DSA/SLH-DSA) blocked on keytool+JVM X.509 support — see row 10. |
| 2 | `scripts/gen-keystores.sh` | CA + leaf X.509 **signature digest** | default SHA-256 | **SHA-384** (`SIG_HASH`) — `sha384WithRSAEncryption` / `ecdsa-with-SHA384` | n/a (digest) | SHA-3 in the signature is NOT yet validated by the SunRsaSign JCA provider used by the Java truststores → kept as `SIG_HASH=sha3-384` opt-in only. |
| 3 | `scripts/gen-keystores.sh` | Internal key↔cert **fingerprint** compare | `openssl sha256` | **SHA3-512** (`FP_HASH`, auto-falls back to SHA-512 if the host openssl lacks sha3) | Yes (hash) | No interop constraint here (local compare only) → highest-bit SHA-3 used directly. |
| 4 | `specs/cluster/manifests/vault-pki/pki-init-configmap.yaml` | Vault `pki_int` self-gen root **key** | `key_type=rsa key_bits=2048` | **RSA-4096** (`PKI_KEY_TYPE`/`PKI_KEY_BITS`; `ec`/`384` supported) | No (classical) | Kept in lockstep with row 1 so issued certs match the offline truststore. |
| 5 | `specs/cluster/manifests/vault-pki/pki-init-configmap.yaml` | Vault issuing **roles** key + signature | `key_type=rsa key_bits=2048` (no `signature_bits`) | **RSA-4096 + `signature_bits=384`** (`PKI_SIG_BITS`) | n/a (digest) | `server_flag`/`client_flag`/`allowed_domains` unchanged. SHA-3 sig path same gate as row 2. |
| 6 | `specs/cluster/charts/snapdragon-gateway/templates/deployment.yaml` | In-pod keystore + TLS server config | PKCS12, no protocol floor | PKCS12 + **`server.ssl.enabled-protocols=TLSv1.3`** (`keystore.tlsProtocols`) | Path ready | TLS 1.3 is the prerequisite for PQC hybrid KEX (row 7). PKCS12 store unchanged (Spring-native). |
| 7 | `specs/cluster/charts/snapdragon-gateway/values.yaml` | TLS **key exchange** group | classical (X25519/secp384r1) implicit | classical default + **gated `keystore.pqcGroups`** (e.g. `X25519MLKEM768`) | **Yes, gated** | Empty by default (no PQC forced onto a JVM that can't do it). Set the value once the JVM/proxy advertises the hybrid group; classical fallback retained. |
| 8 | `scripts/gen-cluster-secrets.sh` | Casdoor admin **password hash** | `openssl passwd -6` (SHA-512 crypt) | unchanged (SHA-512 crypt) | n/a (KDF) | Kept: `openssl passwd` has no argon2 option, and Casdoor re-hashes with bcrypt internally. Argon2id is the documented followup (needs a tool with argon2 support in the offline path). |
| 9 | `scripts/gen-cluster-secrets.sh`, gateway initContainer | Secret / store-password **generation** | `openssl rand` (CSPRNG) | unchanged | Yes (RNG) | Already a CSPRNG; high-entropy. No change needed. |
| 10 | `scripts/gen-provision-keys.sh`, `sshd_config.d/hardened.conf` | SSH host/user keys + KEX | **Ed25519** keys, `curve25519-sha256` KEX | unchanged | Partial | Already the strongest classical SSH choice. PQC SSH (`sntrup761x25519-sha512`) is the documented followup once the baked OpenSSH advertises it. |
| 11 | `specs/etc/kubernetes/kubelet-config.yaml` | kubelet TLS cipher suites | ECDHE + AES-GCM (incl. SHA384) | unchanged | No (classical) | Already AEAD/forward-secret. Tightening to 1.3-only tracked with the apiserver TLS posture. |

## Centralised knobs (crypto agility)

Re-tune the whole chain by overriding these — no logic edits required:

| Knob | File | Default | Effect |
|------|------|---------|--------|
| `KEY_TYPE` | `gen-keystores.sh` (env/`brand.conf`) | `rsa` | `rsa` or `ec` for the CA + every leaf |
| `KEY_BITS` | `gen-keystores.sh` | `4096` | RSA modulus bits |
| `EC_CURVE` | `gen-keystores.sh` | `P-384` | named curve when `KEY_TYPE=ec` |
| `SIG_HASH` | `gen-keystores.sh` | `sha384` | X.509 signature digest (set `sha3-384` to trial SHA-3 certs) |
| `FP_HASH` | `gen-keystores.sh` | `sha3-512`→`sha512` | internal fingerprint digest |
| `PKI_KEY_TYPE` / `PKI_KEY_BITS` / `PKI_SIG_BITS` | `pki-init-configmap.yaml` (Job env) | `rsa` / `4096` / `384` | Vault-issued cert strength |
| `keystore.tlsProtocols` | gateway `values.yaml` | `TLSv1.3` | served TLS protocol floor |
| `keystore.pqcGroups` | gateway `values.yaml` | `""` (off) | PQC hybrid KEX group(s) |

## Documented-as-followup (NOT yet implemented, with reason)

- **SHA-3 inside X.509 certificate signatures** (rows 2, 5). The offline Java
  truststores (`SunRsaSign` provider) and many TLS stacks do not yet validate
  `id-rsassa-pkcs1-v1_5-with-sha3-*` / RSASSA-PSS-SHA3 cert signatures. Forcing
  it would break mTLS validation and could stop services booting. SHA-3 IS used
  today for non-signature hashing (row 3). Migration: flip `SIG_HASH=sha3-384`
  (and `PKI_SIG_BITS` equivalent) once the deployed JVM/openssl validate it.
- **True PQC certificate signatures (ML-DSA / SLH-DSA)** (rows 1, 4). No portable
  X.509 + keytool + JVM truststore support yet. Migration path: an OpenSSL 3.x
  oqs/ML-DSA provider issuing certs that the JVM can validate, swapped in via
  `KEY_TYPE`/`PKI_KEY_TYPE`.
- **PQC hybrid TLS key exchange** (row 7). IMPLEMENTED but **gated OFF**
  (`keystore.pqcGroups=""`): turn it on per-gateway once the JVM/proxy advertises
  e.g. `X25519MLKEM768`. Classical fallback is retained so a non-PQC peer still
  negotiates.
- **Argon2id password KDF** (row 8). `openssl passwd` offers no argon2; Postgres
  stays on `scram-sha-256` (already strong — unchanged). Followup needs an
  argon2-capable tool in the offline provisioning path.
- **PQC SSH key exchange** (row 10). Followup once the baked OpenSSH advertises
  `sntrup761x25519-sha512`.

## Unchanged on purpose (already strong)

- Postgres auth: `--auth-host=scram-sha-256` (every `*-db` manifest) — kept.
- SSH: Ed25519 host/user keys, `curve25519-sha256` KEX — kept.
- Secret generation: `openssl rand` CSPRNG — kept.
- No algorithm was weakened. RSA only went **up** (2048 → 4096); digests only
  went **up** (SHA-256 → SHA-384 / SHA-3).
