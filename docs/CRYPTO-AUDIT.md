# Cryptography audit & post-quantum / SHA-3 migration

This is an audit of every cryptographic choice this repo controls, the change made,
and the post-quantum (PQC) readiness of each. The goal is **crypto agility**: each
algorithm decision is one central knob that the brand or operator can re-tune
without editing logic. When OpenSSL, keytool, the JVM and Vault gain portable
support, stronger (including PQC) primitives can then be swapped in without
re-architecting.

This is a **real cluster that must still boot**. The defaults are therefore the
strongest that the deployed openssl, keytool, JVM and Vault stack handles
**interoperably today**. Where a primitive is not yet portable across all of them
(notably SHA-3 *inside* an X.509 signature, and true PQC KEM and signatures), it is
wired behind a gate and **documented as the migration path**. It is not forced into
a configuration that would fail to validate or fail to boot.

Evidence dated 2026-07-15 and 2026-07-16 was measured on the authoring host with
the tool versions named in each entry. It is a point-in-time result, not a
property of the images.

## Algorithm decisions

| # | Location | Usage | Old | New (default) | PQC-ready? | Notes / migration path |
|---|----------|-------|-----|---------------|------------|------------------------|
| 1 | `scripts/gen-keystores.sh` | Cluster CA + per-service mTLS leaf **key** | RSA-2048 | **RSA-4096** (knob `KEY_TYPE=ec` → EC P-384) | No (classical) | Raised, never lowered. Centralised: `KEY_TYPE`/`KEY_BITS`/`EC_CURVE`. PQC signatures (ML-DSA/SLH-DSA) are still blocked on keytool and JVM X.509 support. Evidence: "True PQC certificate signatures" below. |
| 2 | `scripts/gen-keystores.sh` | CA + leaf X.509 **signature digest** | default SHA-256 | **SHA-384** (`SIG_HASH`) — `sha384WithRSAEncryption` / `ecdsa-with-SHA384` | n/a (digest) | `SIG_HASH=sha3-384` is an opt-in only; the default is unchanged because a real mTLS handshake fails with it. Evidence: "SHA-3 inside X.509 certificate signatures" below. |
| 3 | `scripts/gen-keystores.sh` | Internal key↔cert **fingerprint** compare | `openssl sha256` | **SHA3-512** (`FP_HASH`, auto-falls back to SHA-512 if the host openssl lacks sha3) | Yes (hash) | No interop constraint (local compare only), so the highest-bit SHA-3 is used directly. |
| 4 | `specs/cluster/manifests/vault-pki/pki-init-configmap.yaml` | Vault `pki_int` self-gen root **key** | `key_type=rsa key_bits=2048` | **RSA-4096** (`PKI_KEY_TYPE`/`PKI_KEY_BITS`; `ec`/`384` supported) | No (classical) | Kept in lockstep with row 1 so issued certs match the offline truststore. The same ML-DSA/SLH-DSA blocker as row 1 applies. |
| 5 | `specs/cluster/manifests/vault-pki/pki-init-configmap.yaml` | Vault issuing **roles** key + signature | `key_type=rsa key_bits=2048` (no `signature_bits`) | **RSA-4096 + `signature_bits=384`** (`PKI_SIG_BITS`) | n/a (digest) | `server_flag`/`client_flag`/`allowed_domains` unchanged. The SHA-3 signature path has the same gate as row 2: still blocked at the real-mTLS-handshake layer, not just the raw-crypto layer. |
| 6 | `specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml` | In-pod keystore + TLS server config | PKCS12, no protocol floor | PKCS12 + **`server.ssl.enabled-protocols=TLSv1.3`** (`keystore.tlsProtocols`) | Path ready | TLS 1.3 is the prerequisite for PQC hybrid KEX (row 7). The PKCS12 store is unchanged (Spring-native). |
| 7 | `specs/cluster/charts/hugmesh-gateway/values.yaml` | TLS **key exchange** group | classical (X25519/secp384r1) implicit | classical default + **gated `keystore.pqcGroups`** (e.g. `X25519MLKEM768`) | **Yes, gated** | Empty by default, so no PQC is forced onto a JVM that cannot do it. Set the value once the JVM or proxy advertises the hybrid group; the classical fallback is kept. Still gated OFF. Evidence: "PQC hybrid TLS key exchange" below. |
| 8 | `scripts/gen-cluster-secrets.sh`, gateway initContainer | Casdoor admin **password hash** | `openssl passwd -6` (SHA-512 crypt) | unchanged (SHA-512 crypt) | n/a (KDF) | Kept: `openssl passwd` has no argon2 option. The hash is write-only (see "Argon2id password KDF" below), so its strength has no real crack-resistance impact today. `gen-provision-keys.sh` also used `openssl passwd -6` for the KEYS-USB `users.json` hash, and that one matters: it lands in a real `/etc/shadow`. **Implemented as yescrypt on 2026-07-16, see row 12.** |
| 9 | `scripts/gen-cluster-secrets.sh`, gateway initContainer | Secret / store-password **generation** | `openssl rand` (CSPRNG) | unchanged | Yes (RNG) | Already a CSPRNG with high entropy. No change needed. |
| 10 | `scripts/gen-provision-keys.sh`, `sshd_config.d/hardened.conf` | SSH host/user keys + KEX | **Ed25519** keys, `curve25519-sha256` KEX | Ed25519 keys unchanged; KEX gains **`sntrup761x25519-sha512`** (additive; classical `curve25519-sha256[@libssh.org]` kept as fallback) | **Yes** | IMPLEMENTED 2026-07-15 and verified (see the "PQC SSH key exchange" entry). `gen-provision-keys.sh` sets no client-side `KexAlgorithms` list, so it needs no change. |
| 11 | `specs/etc/kubernetes/kubelet-config.yaml` | kubelet TLS cipher suites | ECDHE + AES-GCM (incl. SHA384) | unchanged | No (classical) | Already AEAD and forward-secret. Tightening to TLS 1.3 only is tracked with the apiserver TLS posture. |
| 12 | `scripts/gen-provision-keys.sh` (KEYS-USB `users.json` hashes), `build-*-stage4.sh` `--local-pass`, shared `scripts/_passhash-lib.sh` | **/etc/shadow password KDF** on the baked images (the offline-crack surface of a stolen device or image) | `openssl passwd -6` (SHA-512 crypt, `$6$` — CPU-only) | **yescrypt (`$y$`, memory-hard, libxcrypt default cost)** via shared `ph_crypt_hash`, generated with python3+ctypes against the host libcrypt and **round-trip self-verified before use**; falls back to `$6$` (`openssl passwd -6 -stdin`) on hosts whose libcrypt lacks yescrypt, the same idiom as row 3's `FP_HASH` | n/a (KDF) | IMPLEMENTED 2026-07-16, verified end to end (see the "/etc/shadow password KDF" entry). Consumers take the hash VERBATIM (`chpasswd -e` in `specs/etc/keys-provision/provision.sh` and `specs/etc/local.d/01-firstboot.start.tmpl`), and `provision.sh` already listed `$y$` as an accepted `device_password_hash` format, so no image-side change was needed. |

## Centralised knobs (crypto agility)

Override these to re-tune the whole chain. No logic edits are needed.

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

- **SHA-3 inside X.509 certificate signatures** (rows 2, 5). Re-tested 2026-07-15
  with OpenSSL 3.6.3 and Temurin JDK/keytool 25.0.3, the JDK family the gateway is
  pinned to. A `SIG_HASH=sha3-384` RSA cert and EC cert both pass `openssl verify`.
  A standalone JCA `Certificate.verify()` and a `PKIXCertPathValidator` call also
  pass: `SunRsaSign` and `SunEC` do implement `SHA3-384withRSA` and
  `SHA3-384withECDSA` outside a TLS context. But a real loopback **mTLS handshake**
  using those exact keystores fails on both sides:
  `CertPathValidatorException: Algorithm constraints check failed on signature
  algorithm: SHA3-384withRSA` (the same for `SHA3-384withECDSA`). TLS 1.3's
  negotiated `signature_algorithms` codepoint set (`ecdsa_secp*`, `rsa_pss_*`,
  `rsa_pkcs1_sha{256,384,512}`, …) has no SHA3 entry, so SunJSSE's handshake-time
  `AlgorithmChecker` rejects the signature even though the raw JCA primitive works.
  Forcing it would break mTLS and stop services booting. SHA-3 IS used today for
  non-signature hashing (row 3).
  Migration: flip `SIG_HASH=sha3-384` (and the `PKI_SIG_BITS` equivalent) once the
  deployed JVM adds a TLS `signature_algorithms` codepoint for SHA3-based RSA/ECDSA
  cert signatures, not just JCA-level verify support.
- **True PQC certificate signatures (ML-DSA / SLH-DSA)** (rows 1, 4). Re-tested
  2026-07-15. OpenSSL 3.6.3 has **native** ML-DSA-65 and SLH-DSA-SHA2-128s support
  (no oqs-provider needed) and issues real certs that pass `openssl verify`.
  Temurin JDK 25.0.3 parses ML-DSA certs and self-verifies the CA
  (`Certificate.verify()` OK, `KeyFactory.getInstance("ML-DSA-65")` resolves through
  the `SUN` provider). But the per-service **identity** keystore step in
  `gen-keystores.sh` (`keytool -importkeystore` of a PKCS12 key and cert into JKS)
  still hard-fails: `UnrecoverableKeyException: Cannot parse input` for ML-DSA, and
  `... KeyFactory not available` for SLH-DSA. There is no portable X.509 + keytool +
  JVM **identity-keystore** support yet.
  Migration path unchanged: switch through `KEY_TYPE`/`PKI_KEY_TYPE` once keytool
  can round-trip a PQC private key through PKCS12→JKS.
- **PQC hybrid TLS key exchange** (row 7). IMPLEMENTED but **gated OFF**
  (`keystore.pqcGroups=""`). Re-tested 2026-07-15 against Temurin JDK 25.0.3 (the
  gateway's pinned `eclipse-temurin:25-jdk`/`25-jre`). The raw `ML-KEM` JCA
  primitive exists in `SunJCE`, but `SunJSSE`'s TLS `NamedGroup` registry does not
  recognise `X25519MLKEM768`. `-Djdk.tls.namedGroups=X25519MLKEM768` throws
  `IllegalArgumentException: ... contains no supported named groups`, and a real
  TLS 1.3 loopback handshake forced onto that group fails with `missing_extension`
  (the group is silently dropped, leaving an empty `supported_groups`). Turn
  `keystore.pqcGroups` on per gateway once a JDK that registers the hybrid group is
  deployed. The classical fallback stays, so a non-PQC peer still negotiates.
- **Argon2id password KDF** (row 8). A 2026-07-15 downstream trace of
  `scripts/gen-cluster-secrets.sh`'s `CASDOOR_ADMIN_HASH` (`openssl passwd -6`,
  Vault field `casdoor.admin_password`) found that it is **never read** from that
  document. Every ExternalSecret and init-job path uses `admin_password_plain`
  instead (it ends up as `/secrets/admin/password`, is POSTed in plaintext to
  Casdoor's `/api/login` or add-user call, and Casdoor re-hashes it with bcrypt
  server-side). So upgrading this hash to argon2id would be cosmetic, and no
  portable offline argon2 tool is proven to exist in the real provisioning pipeline
  (an `argon2` CLI happened to be on the authoring host). It is left unchanged.
  (`manifests/casdoor-domain/external-secrets.yaml` does read a property named
  `admin_password`, but from the per-domain path `<slug>/casdoor`, which
  `gen-cluster-secrets.sh` does not write. That path is operator-seeded.)
  Postgres stays on `scram-sha-256`. The separate `-6` hash that
  `gen-provision-keys.sh` generated for the KEYS-USB `users.json` (it reaches the
  real `/etc/shadow` through `chpasswd -e`) did matter for offline crack
  resistance. **Resolved 2026-07-16: implemented as yescrypt (row 12 and the next
  entry).**
- **/etc/shadow password KDF → yescrypt** (row 12). **IMPLEMENTED 2026-07-16**,
  verified leg by leg on the same "host portage tree = what the image builders
  bake" proxy that row 10 uses for OpenSSH. The builders install `@system` unpinned
  from this tree, and `emerge -pv --nodeps` showed
  `[ebuild R] sys-libs/libxcrypt-4.4.38-r1` and `[ebuild R] sys-apps/shadow-4.19.4`,
  so installed equals tree-latest for both the crypt library and the `chpasswd`
  consumer.
  - *Consumer chain (the hash is passed verbatim, so a generator-side upgrade is
    enough):* `gen-provision-keys.sh` `gen_hash` → `users.json` `password_hash` →
    `provision.sh`: `printf '%s:%s\n' "${name}" "${phash}" | chpasswd -e` (and
    `printf 'root:%s\n' "${rhash}" | chpasswd -e`). For builders, `--local-pass` →
    `@@LOCAL_PASSHASH@@` → `01-firstboot.start.tmpl`:
    `echo '@@DEFAULT_USER@@:@@LOCAL_PASSHASH@@' | chpasswd -e`.
  - *libcrypt leg:* python3+ctypes against the installed libxcrypt.
    `crypt_gensalt(b"$y$", 0, NULL, 0)` returned the setting
    `$y$j9T$P7XOobas1htA4lO03w8HL1`. `crypt(pw, setting)` produced
    `$y$j9T$P7XOobas1htA4lO03w8HL1$Htqzn1RZJu0cDrCrjkoaPuN3HuMsmgukNuQV3bYRLO5`.
    `crypt(pw, hash) == hash` was `True` for the correct password and `False` for a
    wrong one, on **both** `libcrypt.so.2` and the compat `libcrypt.so.1` ABI.
  - *chpasswd leg:* on this host and tree, `chpasswd --help` lists
    `-c, --crypt-method METHOD (one of NONE DES MD5 SHA256 SHA512 BCRYPT YESCRYPT)`.
    Piping `alice:$y$j9T$...` into `chpasswd -e -P <throwaway-root>` (a scratch
    `etc/{passwd,shadow,group}` tree; the real `/etc/shadow` was never touched)
    exited 0 and landed the hash **verbatim**:
    `alice:$y$j9T$RJaJ.KQhBRwpG53DVWN8W/$HEZ...:20650:0:99999:7:::`. It then
    re-verified through `crypt()` (the pam_unix login path): correct password
    `True`, wrong password `False`.
  - *Tool choice (why python3+ctypes):* `openssl passwd` has **no yescrypt mode**
    (only `-6`/`-5`/`-1`/apr1/aixmd5/crypt). `mkpasswd` (whois) is not installed
    and would be a NEW hard dependency. Python 3.13+ **removed** the stdlib `crypt`
    module (`ModuleNotFoundError: No module named 'crypt'` on this host's 3.14.6).
    `python3` is already a hard dependency of `gen-provision-keys.sh` (its existing
    `for t in openssl ssh-keygen python3` check), and ctypes→libcrypt adds no new
    package. `ph_crypt_hash` self-verifies every hash before it emits it, and
    otherwise falls back to the exact pre-change `$6$` behaviour (the fallback is
    exercised in `tests/scripts/test-passhash-lib.sh`), so a glibc-era host without
    yescrypt still provisions.
  - *Not verifiable there:* an actual image boot (no QEMU or container in that
    environment). The image-side pieces are the same libxcrypt and shadow versions
    this was proven against, installed from the same unpinned tree.
- **PQC SSH key exchange** (row 10). **IMPLEMENTED 2026-07-15.**
  `sntrup761x25519-sha512` is added to `sshd_config.d/hardened.conf`'s
  `KexAlgorithms`, additively ahead of the retained classical
  `curve25519-sha256[@libssh.org]` fallback. `net-misc/openssh-10.3_p1`
  (OpenSSH_10.3p1) was both the version installed on the authoring host and the
  latest in the same portage tree (`emerge-webrsync`, synced 2026-07-04) that the
  image builders (`build-*-stage4.sh`, which install openssh through the unpinned
  `@system` set) would pull from around then, so it stands in for the baked
  version. `ssh -Q kex` advertises `sntrup761x25519-sha512`. A real loopback
  `sshd`↔`ssh` handshake with `KexAlgorithms sntrup761x25519-sha512,curve25519-sha256`
  negotiated `sntrup761x25519-sha512`
  (`debug1: kex: algorithm: sntrup761x25519-sha512`) and completed pubkey auth and
  command exec. A classical-only client (`KexAlgorithms=curve25519-sha256`) still
  connected, so the fallback is intact.

## Unchanged on purpose (already strong)

- Postgres auth: `--auth-host=scram-sha-256` in the dedicated app databases'
  manifests (admin-bff, mod-bff, user-bff, federation, forum-bff, wiki-bff,
  mesh-bff, character-forge-bff, route-access, phpBB, Headwind) — kept. The
  casdoor, casdoor-games and casdoor-domain Postgres, akkoma-db and the
  observability Postgres manifests do not set it (`grep scram` finds nothing in
  them).
- SSH: Ed25519 host/user keys — kept. The KEX gained an additive PQC hybrid option
  (row 10); the classical `curve25519-sha256` fallback is kept, never dropped.
- Secret generation: `openssl rand` CSPRNG — kept.
- No algorithm was weakened. RSA only went **up** (2048 → 4096). Digests only went
  **up** (SHA-256 → SHA-384 / SHA-3).

## ✅ Supply-chain hardening (landed)

The build's remote trust roots are now verified fail-closed in **all ten**
`build-*-stage4.sh` builders (each one calls the `dlv_verify_*` helpers). One
shared, audited implementation:
[`scripts/_download-lib.sh`](../scripts/_download-lib.sh), unit-tested by
`tests/scripts/test-download-verify.sh`.

- **Gentoo stage3 tarball** — `dlv_verify_stage3`. The matching `.DIGESTS(.asc)` is
  fetched and GPG-verified against the pinned Gentoo release-engineering key
  (fingerprint knob `DLV_GENTOO_KEY`; air-gapped builds use `DLV_OFFLINE_KEYRING`).
  Then the tarball's SHA512/SHA256 is checked against the signed DIGESTS. Any
  signature or checksum failure (or a missing signature or entry) **aborts the
  build** and deletes the unverified file. It never warns and continues.
- **headscale / tailscale binaries** — verified against the publishers' digests
  before install or extract. headscale uses `checksums.txt` through
  `dlv_verify_from_sumsfile` and fails closed when the basename is absent.
  tailscale uses the `<tgz>.sha256` sidecar through `dlv_verify_sha256_sidecar`. A
  mismatch aborts.
- **De-defaulted baked-in credentials** — the first-boot finaliser
  (`specs/etc/local.d/01-firstboot.start.tmpl`) no longer bakes any known default
  password. Real credentials come from the KEYS USB (`users.json` crypt(3) hashes:
  yescrypt `$y$` preferred, `$6$` fallback; row 12). A keyless boot mints a
  **random one-time** password (forced change on first login) and locks root.
  Standalone desktops take a build-time crypt(3) **hash** (`--local-pass`), never
  plaintext.
