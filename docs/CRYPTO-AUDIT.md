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
| 1 | `scripts/gen-keystores.sh` | Cluster CA + per-service mTLS leaf **key** | RSA-2048 | **RSA-4096** (knob `KEY_TYPE=ec` → EC P-384) | No (classical) | Raised, never lowered. Centralised: `KEY_TYPE`/`KEY_BITS`/`EC_CURVE`. PQC sigs (ML-DSA/SLH-DSA) blocked on keytool+JVM X.509 support — 2026-07-15 re-verified: OpenSSL 3.6.3 issues real ML-DSA-65/SLH-DSA-SHA2-128s certs (`openssl verify`: OK) and the JVM (Temurin 25.0.3, matching the gateway's pinned `eclipse-temurin:25-*`) even parses/self-verifies the ML-DSA CA cert — but `keytool -importkeystore` fails building the **per-service identity keystore** (`UnrecoverableKeyException: Cannot parse input` for ML-DSA; `... KeyFactory not available` for SLH-DSA), i.e. the PKCS12→JKS private-key step `gen-keystores.sh` needs for every leaf still breaks. Still blocked. |
| 2 | `scripts/gen-keystores.sh` | CA + leaf X.509 **signature digest** | default SHA-256 | **SHA-384** (`SIG_HASH`) — `sha384WithRSAEncryption` / `ecdsa-with-SHA384` | n/a (digest) | 2026-07-15 re-verified with `SIG_HASH=sha3-384` (both RSA and EC via `KEY_TYPE=ec`): `openssl verify` passes and, surprisingly, standalone `Certificate.verify()` + a real `PKIXCertPathValidator` also pass under Temurin 25.0.3 (SunRsaSign/SunEC do implement `SHA3-384withRSA`/`SHA3-384withECDSA`). BUT a real loopback **mTLS handshake** (the thing that actually matters) fails both directions: `CertPathValidatorException: Algorithm constraints check failed on signature algorithm: SHA3-384withRSA` — TLS 1.3's negotiated `signature_algorithms` codepoint set (`ecdsa_secp*`, `rsa_pss_*`, `rsa_pkcs1_sha{256,384,512}`, …) simply has no SHA3 entry, so SunJSSE's handshake-time `AlgorithmChecker` rejects it even though the raw JCA primitive works. Confirms the doc's original caution (mTLS would break) — kept as `SIG_HASH=sha3-384` opt-in only, default unchanged. |
| 3 | `scripts/gen-keystores.sh` | Internal key↔cert **fingerprint** compare | `openssl sha256` | **SHA3-512** (`FP_HASH`, auto-falls back to SHA-512 if the host openssl lacks sha3) | Yes (hash) | No interop constraint here (local compare only) → highest-bit SHA-3 used directly. |
| 4 | `specs/cluster/manifests/vault-pki/pki-init-configmap.yaml` | Vault `pki_int` self-gen root **key** | `key_type=rsa key_bits=2048` | **RSA-4096** (`PKI_KEY_TYPE`/`PKI_KEY_BITS`; `ec`/`384` supported) | No (classical) | Kept in lockstep with row 1 so issued certs match the offline truststore. Same ML-DSA/SLH-DSA blocker as row 1 (2026-07-15 finding) applies here too. |
| 5 | `specs/cluster/manifests/vault-pki/pki-init-configmap.yaml` | Vault issuing **roles** key + signature | `key_type=rsa key_bits=2048` (no `signature_bits`) | **RSA-4096 + `signature_bits=384`** (`PKI_SIG_BITS`) | n/a (digest) | `server_flag`/`client_flag`/`allowed_domains` unchanged. SHA-3 sig path same gate as row 2 (2026-07-15: re-verified still blocked at the real-mTLS-handshake layer, not just the raw-crypto layer — see row 2 notes). |
| 6 | `specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml` | In-pod keystore + TLS server config | PKCS12, no protocol floor | PKCS12 + **`server.ssl.enabled-protocols=TLSv1.3`** (`keystore.tlsProtocols`) | Path ready | TLS 1.3 is the prerequisite for PQC hybrid KEX (row 7). PKCS12 store unchanged (Spring-native). |
| 7 | `specs/cluster/charts/hugmesh-gateway/values.yaml` | TLS **key exchange** group | classical (X25519/secp384r1) implicit | classical default + **gated `keystore.pqcGroups`** (e.g. `X25519MLKEM768`) | **Yes, gated** | Empty by default (no PQC forced onto a JVM that can't do it). Set the value once the JVM/proxy advertises the hybrid group; classical fallback retained. 2026-07-15 re-verified against the gateway's exact pinned JDK (Temurin 25.0.3, matching `eclipse-temurin:25-jdk`/`25-jre` in the gateway `Dockerfile`): `SunJCE` already has the raw `ML-KEM` primitive (`KeyFactory`/`KEM`/`KeyPairGenerator`), but `SunJSSE`'s `NamedGroup` registry does not — `-Djdk.tls.namedGroups=X25519MLKEM768` throws `IllegalArgumentException: ... contains no supported named groups`, and a real TLS 1.3 loopback handshake forced onto that group fails with `missing_extension` (the group gets silently dropped, leaving an empty `supported_groups`). Still gated OFF; `keystore.pqcGroups` left empty. |
| 8 | `scripts/gen-cluster-secrets.sh` | Casdoor admin **password hash** | `openssl passwd -6` (SHA-512 crypt) | unchanged (SHA-512 crypt) | n/a (KDF) | Kept: `openssl passwd` has no argon2 option. 2026-07-15 downstream trace: `CASDOOR_ADMIN_HASH` (the `-6` hash, Vault field `casdoor.admin_password`) has **zero consumers** anywhere in this repo — every ExternalSecret/init-job reads `admin_password_plain` instead (ends up as `/secrets/admin/password`, POSTed plaintext to Casdoor's `/api/login`/add-user, which re-hashes with bcrypt server-side). The `-6` hash is write-only/dead for that Vault document, so its KDF strength has no real crack-resistance impact today — upgrading it to argon2id would be cosmetic. (`manifests/casdoor-domain/external-secrets.yaml` does read a property named `admin_password`, but from the per-domain path `<slug>/casdoor`, which `gen-cluster-secrets.sh` does not write; it is operator-seeded.) (An `argon2` CLI happens to be present on this dev host, but that's incidental to this sandbox, not a proven property of the actual offline provisioning pipeline, so it wasn't treated as a basis to add a new hard dependency here regardless.) Left unchanged. NOTE: `scripts/gen-provision-keys.sh` also calls `openssl passwd -6` (line ~849) for the KEYS-USB `users.json` password that DOES land in real `/etc/shadow` via `chpasswd -e` — that one is genuinely offline-crack-relevant, but it's outside this row's scope (row 10 covers that script's SSH/KEX surface only); flagged here as a real gap for a future audit pass, not touched in this change. **2026-07-16: that flagged gap is now IMPLEMENTED as yescrypt — see row 12.** |
| 9 | `scripts/gen-cluster-secrets.sh`, gateway initContainer | Secret / store-password **generation** | `openssl rand` (CSPRNG) | unchanged | Yes (RNG) | Already a CSPRNG; high-entropy. No change needed. |
| 10 | `scripts/gen-provision-keys.sh`, `sshd_config.d/hardened.conf` | SSH host/user keys + KEX | **Ed25519** keys, `curve25519-sha256` KEX | Ed25519 keys unchanged; KEX gains **`sntrup761x25519-sha512`** (additive; classical `curve25519-sha256[@libssh.org]` kept as fallback) | **Yes** | 2026-07-15: IMPLEMENTED — empirically verified. `net-misc/openssh-10.3_p1` (OpenSSH_10.3p1) is both the version installed on this host and the latest available from the same portage tree (`emerge-webrsync`, synced 2026-07-04) the image builders (`build-*-stage4.sh`, which install openssh via the unpinned `@system` set) would pull from around the same time, so it stands in as a genuine proxy for the baked version. `ssh -Q kex` advertises `sntrup761x25519-sha512`; a real loopback `sshd`↔`ssh` handshake with `KexAlgorithms sntrup761x25519-sha512,curve25519-sha256` negotiated `sntrup761x25519-sha512` (`debug1: kex: algorithm: sntrup761x25519-sha512`) and completed full pubkey auth + command exec, while a classical-only client (`KexAlgorithms=curve25519-sha256`) still connected fine (fallback intact). `gen-provision-keys.sh` sets no client-side `KexAlgorithms` list, so no change needed there. |
| 11 | `specs/etc/kubernetes/kubelet-config.yaml` | kubelet TLS cipher suites | ECDHE + AES-GCM (incl. SHA384) | unchanged | No (classical) | Already AEAD/forward-secret. Tightening to 1.3-only tracked with the apiserver TLS posture. |
| 12 | `scripts/gen-provision-keys.sh` (KEYS-USB `users.json` hashes), `build-*-stage4.sh` `--local-pass`, shared `scripts/_passhash-lib.sh` | **/etc/shadow password KDF** on the baked images (the offline-crack surface of a stolen device/image) | `openssl passwd -6` (SHA-512 crypt, `$6$` — CPU-only) | **yescrypt (`$y$`, memory-hard, libxcrypt default cost)** via shared `ph_crypt_hash`, generated with python3+ctypes against the host libcrypt and **round-trip self-verified before use**; auto-falls back to `$6$` (`openssl passwd -6 -stdin`) on hosts whose libcrypt lacks yescrypt — mirrors row 3's `FP_HASH` idiom | n/a (KDF) | 2026-07-16: IMPLEMENTED — empirically verified end-to-end on the same-portage-tree proxy stack (see the dated bullet below for the full quoted evidence). Consumers take the hash VERBATIM (`chpasswd -e` in `specs/etc/keys-provision/provision.sh` and `specs/etc/local.d/01-firstboot.start.tmpl`), and `provision.sh` already documented `$y$` as an accepted `device_password_hash` format, so no image-side logic change was needed. |

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
| `PH_KDF` | `scripts/_passhash-lib.sh` (env) | auto (`yescrypt`→`sha512crypt`) | /etc/shadow password KDF; `sha512crypt` forces the `$6$` fallback |

## Documented-as-followup (NOT yet implemented, with reason)

- **SHA-3 inside X.509 certificate signatures** (rows 2, 5). 2026-07-15
  empirically re-tested (OpenSSL 3.6.3, Temurin JDK/keytool 25.0.3 — the exact
  JDK family the gateway is pinned to): generating `SIG_HASH=sha3-384` RSA and
  EC certs, `openssl verify` passes, and even a standalone JCA
  `Certificate.verify()` / `PKIXCertPathValidator` call passes (`SunRsaSign`
  *can* verify `SHA3-384withRSA` outside a TLS context). But a real loopback
  **mTLS handshake** using those exact keystores fails on both sides:
  `CertPathValidatorException: Algorithm constraints check failed on signature
  algorithm: SHA3-384withRSA` (same for `SHA3-384withECDSA`) — TLS 1.3's
  negotiated `signature_algorithms` codepoint set has no SHA3 entry, so
  SunJSSE's handshake-time checker rejects it regardless of the raw-crypto
  result. Confirms the original caution: forcing it would break mTLS and stop
  services booting. SHA-3 IS used today for non-signature hashing (row 3).
  Migration: flip `SIG_HASH=sha3-384` (and `PKI_SIG_BITS` equivalent) once the
  deployed JVM adds a TLS `signature_algorithms` codepoint for SHA3-based
  RSA/ECDSA cert signatures — not just JCA-level verify support.
- **True PQC certificate signatures (ML-DSA / SLH-DSA)** (rows 1, 4). 2026-07-15
  empirically re-tested: OpenSSL 3.6.3 has **native** ML-DSA-65/SLH-DSA-SHA2-128s
  support (no oqs-provider needed) and issues real, `openssl verify`-clean
  certs. Temurin JDK 25.0.3 even parses ML-DSA certs and self-verifies the CA
  (`Certificate.verify()` OK, `KeyFactory.getInstance("ML-DSA-65")` resolves via
  the `SUN` provider) — further along than expected. But `gen-keystores.sh`'s
  per-service **identity** keystore step (`keytool -importkeystore` of a
  PKCS12 key+cert into JKS) still hard-fails: `UnrecoverableKeyException:
  Cannot parse input` for ML-DSA, `... KeyFactory not available` for SLH-DSA.
  No portable X.509 + keytool + JVM **identity-keystore** support yet.
  Migration path unchanged: swapped in via `KEY_TYPE`/`PKI_KEY_TYPE` once
  keytool can round-trip a PQC private key through PKCS12→JKS.
- **PQC hybrid TLS key exchange** (row 7). IMPLEMENTED but **gated OFF**
  (`keystore.pqcGroups=""`). 2026-07-15 re-tested against Temurin JDK 25.0.3
  (matching the gateway's pinned `eclipse-temurin:25-jdk`/`25-jre`): the raw
  `ML-KEM` JCA primitive exists in `SunJCE`, but `SunJSSE`'s TLS `NamedGroup`
  registry does not recognize `X25519MLKEM768` — `-Djdk.tls.namedGroups=
  X25519MLKEM768` throws `IllegalArgumentException: ... contains no supported
  named groups`, and a forced real handshake fails with `missing_extension`.
  Turn `keystore.pqcGroups` on per-gateway once a JDK that actually registers
  the hybrid group is deployed. Classical fallback is retained so a non-PQC
  peer still negotiates.
- **Argon2id password KDF** (row 8). 2026-07-15 downstream trace of
  `scripts/gen-cluster-secrets.sh`'s `CASDOOR_ADMIN_HASH` (`openssl passwd -6`)
  found it is **never read** anywhere in this repo — every ExternalSecret/
  init-job path uses `admin_password_plain` instead (POSTed to Casdoor's
  login/add-user API, which re-hashes with bcrypt server-side). So this
  particular hash's KDF has no real crack-resistance stake today; upgrading it
  would be cosmetic, and no portable/offline argon2 tool is proven to exist in
  the actual provisioning pipeline (only incidentally present on this dev
  host). Left unchanged. Postgres stays on `scram-sha-256` (already strong —
  unchanged). Separately noted: `scripts/gen-provision-keys.sh` also generates
  a `-6` hash (for the KEYS-USB `users.json` → real `/etc/shadow` via
  `chpasswd -e`) that DOES matter for offline crack-resistance — that one is a
  genuine gap, out of this row's scope (tracked as a followup for a future
  pass, not implemented here). **Resolved 2026-07-16: implemented as yescrypt
  (row 12 + the dated bullet below).**
- **/etc/shadow password KDF → yescrypt** (row 12). **IMPLEMENTED 2026-07-16**
  — empirically verified leg by leg, on the same "host portage tree = what the
  image builders bake" proxy argument row 10 established for OpenSSH (the
  builders install `@system` unpinned from this tree; `emerge -pv --nodeps`
  shows `[ebuild R] sys-libs/libxcrypt-4.4.38-r1` and `[ebuild R]
  sys-apps/shadow-4.19.4`, i.e. installed == tree-latest for both the crypt
  library and the `chpasswd` consumer).
  - *Consumer chain (verbatim-hash, so generator-side upgrade suffices):*
    `gen-provision-keys.sh` `gen_hash` → `users.json` `password_hash` →
    `provision.sh`: `printf '%s:%s\n' "${name}" "${phash}" | chpasswd -e` (and
    `printf 'root:%s\n' "${rhash}" | chpasswd -e`); builders' `--local-pass` →
    `@@LOCAL_PASSHASH@@` → `01-firstboot.start.tmpl`:
    `echo '@@DEFAULT_USER@@:@@LOCAL_PASSHASH@@' | chpasswd -e`. `provision.sh`'s
    device-password path already listed `$y$`=yescrypt as an accepted crypt(3)
    format before this change.
  - *libcrypt leg:* python3+ctypes against the installed libxcrypt —
    `crypt_gensalt(b"$y$", 0, NULL, 0)` returned setting
    `$y$j9T$P7XOobas1htA4lO03w8HL1`; `crypt(pw, setting)` produced
    `$y$j9T$P7XOobas1htA4lO03w8HL1$Htqzn1RZJu0cDrCrjkoaPuN3HuMsmgukNuQV3bYRLO5`;
    `crypt(pw, hash) == hash` → `True` for the correct password, `False` for a
    wrong one — on **both** `libcrypt.so.2` and the compat `libcrypt.so.1` ABI.
  - *chpasswd leg:* this host/tree `chpasswd --help` itself lists
    `-c, --crypt-method METHOD (one of NONE DES MD5 SHA256 SHA512 BCRYPT
    YESCRYPT)`; piping `alice:$y$j9T$...` into `chpasswd -e -P
    <throwaway-root>` (a scratch `etc/{passwd,shadow,group}` tree — the real
    `/etc/shadow` was never touched) exited 0 and landed the hash **verbatim**:
    `alice:$y$j9T$RJaJ.KQhBRwpG53DVWN8W/$HEZ...:20650:0:99999:7:::`, which then
    re-verified via `crypt()` (the pam_unix login path) — correct password
    `True`, wrong password `False`.
  - *Tool choice (why python3+ctypes):* `openssl passwd` has **no yescrypt
    mode** (only `-6`/`-5`/`-1`/apr1/aixmd5/crypt); `mkpasswd` (whois) is not
    installed and would be a NEW hard dependency; python 3.13+ **removed** the
    stdlib `crypt` module (`ModuleNotFoundError: No module named 'crypt'` on
    this host's 3.14.6). `python3` is already a hard dependency of
    `gen-provision-keys.sh` (its existing `for t in openssl ssh-keygen python3`
    check), and ctypes→libcrypt adds no new package. `ph_crypt_hash`
    self-verifies every hash before emitting it and otherwise falls back to the
    exact pre-change `$6$` behavior (fallback exercised in
    `tests/scripts/test-passhash-lib.sh`), so a glibc-era host without yescrypt
    still provisions.
  - *Not verifiable here:* an actual image boot (no QEMU/container in this
    environment) — same caveat as row 10; the image-side pieces are the same
    libxcrypt/shadow versions this was proven against, installed from the same
    unpinned tree.
- **PQC SSH key exchange** (row 10). **IMPLEMENTED 2026-07-15** —
  `sntrup761x25519-sha512` added to `sshd_config.d/hardened.conf`'s
  `KexAlgorithms`, additively ahead of the retained classical
  `curve25519-sha256[@libssh.org]` fallback. Empirically verified via a real
  loopback OpenSSH_10.3p1 handshake (see row 10 table notes).

## Unchanged on purpose (already strong)

- Postgres auth: `--auth-host=scram-sha-256` in the dedicated app databases'
  manifests (admin-bff, mod-bff, user-bff, federation, forum-bff, wiki-bff,
  mesh-bff, character-forge-bff, route-access, phpBB, Headwind) — kept. The
  casdoor, casdoor-games and casdoor-domain Postgres, akkoma-db and the
  observability Postgres manifests do not set it (`grep scram` finds nothing in
  them).
- SSH: Ed25519 host/user keys — kept (KEX gained an additive PQC hybrid option,
  row 10; `curve25519-sha256` classical fallback is still kept, never dropped).
- Secret generation: `openssl rand` CSPRNG — kept.
- No algorithm was weakened. RSA only went **up** (2048 → 4096); digests only
  went **up** (SHA-256 → SHA-384 / SHA-3).

## ✅ Supply-chain hardening (landed)

The build's remote trust roots are now verified fail-closed in **all ten**
`build-*-stage4.sh` builders (each one calls the `dlv_verify_*` helpers). One
shared, audited implementation: [`scripts/_download-lib.sh`](../scripts/_download-lib.sh)
(unit-tested by `tests/scripts/test-download-verify.sh`).

- **Gentoo stage3 tarball** — `dlv_verify_stage3`: the matching `.DIGESTS(.asc)`
  is fetched and GPG-verified against the pinned Gentoo release-engineering key
  (fingerprint knob `DLV_GENTOO_KEY`; air-gapped via `DLV_OFFLINE_KEYRING`), then
  the tarball's SHA512/SHA256 is checked against the signed DIGESTS. Any
  signature/checksum failure (or a missing signature/entry) **aborts the build**
  and deletes the unverified file — never warn-and-continue.
- **headscale / tailscale binaries** — verified against the publishers' digests
  (headscale `checksums.txt` via `dlv_verify_from_sumsfile`, fail-closed when the
  basename is absent; tailscale `<tgz>.sha256` sidecar via
  `dlv_verify_sha256_sidecar`) before install/extract; mismatch aborts.
- **De-defaulted baked-in credentials** — the first-boot finaliser
  (`specs/etc/local.d/01-firstboot.start.tmpl`) no longer bakes any known default
  password: real credentials come from the KEYS USB (`users.json` crypt(3)
  hashes — yescrypt `$y$` preferred, `$6$` fallback; row 12); a keyless boot
  mints a **random one-time** password (forced change on first login) and root
  is locked. Standalone desktops take a build-time crypt(3) **hash**
  (`--local-pass`), never plaintext.
