#!/usr/bin/env bash
# test-host-guard-rust-std.sh — hostguard_ensure_cross_rust_std (scripts/_host-guard-lib.sh),
# offline. A fake rustc stands in for the build container's; a local "dist" directory
# stands in for static.rust-lang.org (HOSTGUARD_RUST_DIST_URL=file://..., fetched by a
# local copy: the real _hg_rust_fetch is https-only). Proves:
#   1. no host rustc            -> 0, nothing fetched
#   2. the target std is present -> 0, nothing fetched
#   3. a real host (no container, no override) -> 1, prints the commands, writes nothing
#   4. a tarball signed by ANOTHER key that IS in the key file -> refused by the fingerprint
#      pin (1), nothing installed, cached copy deleted
#   5. a tarball signed by the pinned key (a throwaway key pinned for the test) -> installed
#      into the fake sysroot, and the probe rustc then succeeds -> 0
# The real download was proven in the builder image (2026-11-12: rust-std 1.97.1 for
# aarch64-unknown-linux-gnu verified with the Rust release key, then an aarch64 binary
# linked); this suite pins the refusals, which a live run cannot exercise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
LIB="${ROOT}/scripts/_host-guard-lib.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
command -v gpg >/dev/null 2>&1 || { echo "gpg is required"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
T=aarch64-unknown-linux-gnu; REL=1.97.1

# Fake rustc: -Vv prints a release, --print sysroot prints SYSROOT, a --target compile
# succeeds only when SYSROOT/lib/rustlib/<target>/lib/libstd-*.rlib exists.
mk_rustc() {
    local sr="$1"; mkdir -p "${sr}/lib/rustlib/x86_64-unknown-linux-gnu/lib" "${TMP}/bin"
    cat > "${TMP}/bin/rustc" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -Vv) echo "rustc ${REL}"; echo "release: ${REL}"; exit 0 ;;
  --print) echo "${sr}"; exit 0 ;;
esac
tgt=""; while [ \$# -gt 0 ]; do [ "\$1" = --target ] && tgt="\$2"; shift; done
ls "${sr}/lib/rustlib/\${tgt}/lib/"libstd-*.rlib >/dev/null 2>&1 && exit 0
echo "error[E0463]: can't find crate for \\\`std\\\`" >&2; exit 1
EOF
    chmod +x "${TMP}/bin/rustc"
}
# A dist dir holding rust-std-REL-T.tar.xz, signed by the key in GNUPGHOME $1.
mk_dist() {
    local gh="$1" d="${TMP}/dist-$2"; mkdir -p "${d}/w/rust-std-${REL}-${T}/rust-std-${T}/lib/rustlib/${T}/lib"
    : > "${d}/w/rust-std-${REL}-${T}/rust-std-${T}/lib/rustlib/${T}/lib/libstd-test.rlib"
    tar -C "${d}/w" -cJf "${d}/rust-std-${REL}-${T}.tar.xz" "rust-std-${REL}-${T}"
    GNUPGHOME="${gh}" gpg --batch --yes --quiet --armor --detach-sign \
        -o "${d}/rust-std-${REL}-${T}.tar.xz.asc" "${d}/rust-std-${REL}-${T}.tar.xz"
    echo "${d}"
}
mk_key() {  # GNUPGHOME with a fresh signing key; prints "<gnupghome> <fpr>"
    local gh="${TMP}/gpg-$1"; mkdir -p "${gh}"; chmod 700 "${gh}"
    GNUPGHOME="${gh}" gpg --batch --quiet --passphrase '' --quick-gen-key "test-$1@example.invalid" ed25519 sign never 2>/dev/null
    echo "${gh} $(GNUPGHOME="${gh}" gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
}
run() {  # run the guard in a subshell: $1 = env assignments
    env -i PATH="${TMP}/bin:/usr/bin:/bin" HOME="${TMP}" TMPDIR="${TMP}" bash -c \
        "$1; . '${LIB}'; hostguard_in_container() { \${FAKE_CONTAINER:-false}; }
         _hg_rust_fetch() { cp \"\${1#file://}\" \"\$2\"; }   # the real one is https-only
         hostguard_ensure_cross_rust_std ${T} '${TMP}/cache'" 2>&1
}

echo "== 1. no host rustc"
out="$(env -i PATH=/usr/bin:/bin HOME="${TMP}" bash -c ". '${LIB}'; HOSTGUARD_RUSTC=no-such-rustc-here; hostguard_ensure_cross_rust_std ${T}" 2>&1)" \
    && ok "no rustc -> 0 (${out##*] })" || bad "no rustc: ${out}"

echo "== 2. std already present"
SR="${TMP}/sr2"; mk_rustc "${SR}"; mkdir -p "${SR}/lib/rustlib/${T}/lib"; : > "${SR}/lib/rustlib/${T}/lib/libstd-x.rlib"
out="$(run 'HOSTGUARD_RUST_DIST_URL=file:///nonexistent')" && ok "std present -> 0 without a fetch" || bad "present: ${out}"

read -r GOOD_GH GOOD_FPR <<<"$(mk_key good)"
read -r EVIL_GH _ <<<"$(mk_key evil)"
GOOD_KEY="${TMP}/good.asc"; GNUPGHOME="${GOOD_GH}" gpg --batch --armor --export > "${GOOD_KEY}" 2>/dev/null
# The key FILE carries both keys (as a vendored keyring could): only the fingerprint PIN
# can refuse the other key's signature, which is what case 4 must prove.
BOTH_KEY="${TMP}/both.asc"; { cat "${GOOD_KEY}"; GNUPGHOME="${EVIL_GH}" gpg --batch --armor --export 2>/dev/null; } > "${BOTH_KEY}"

echo "== 3. a real host writes nothing"
SR="${TMP}/sr3"; mk_rustc "${SR}"; D="$(mk_dist "${GOOD_GH}" host)"
if out="$(run "export FAKE_CONTAINER=false HOSTGUARD_RUST_DIST_URL=file://${D} HOSTGUARD_RUST_KEYFILE=${GOOD_KEY} HOSTGUARD_RUST_KEY_FPR=${GOOD_FPR}")"; then
    bad "a real host returned 0"
else
    case "${out}" in *"will NOT change your system"*) ok "real host -> 1 with the commands to run";; *) bad "real host said: ${out}";; esac
fi
[ ! -d "${SR}/lib/rustlib/${T}" ] && ok "real host: nothing installed" || bad "real host installed into the sysroot"

echo "== 4. signed by another key"
SR="${TMP}/sr4"; mk_rustc "${SR}"; D="$(mk_dist "${EVIL_GH}" evil)"; rm -rf "${TMP}/cache"
if out="$(run "export FAKE_CONTAINER=true; id() { echo 0; }; export -f id; HOSTGUARD_RUST_DIST_URL=file://${D} HOSTGUARD_RUST_KEYFILE=${BOTH_KEY} HOSTGUARD_RUST_KEY_FPR=${GOOD_FPR}")"; then
    bad "a tarball signed by another key was accepted"
else
    case "${out}" in *"GPG verification FAILED"*) ok "another key's signature -> refused";; *) bad "evil said: ${out}";; esac
fi
[ ! -d "${SR}/lib/rustlib/${T}" ] && ok "refused: nothing installed" || bad "refused but installed"
[ ! -e "${TMP}/cache/rust-std-${REL}-${T}.tar.xz" ] && ok "refused: the cached tarball is deleted" || bad "refused tarball kept in the cache"

echo "== 5. signed by the pinned key"
SR="${TMP}/sr5"; mk_rustc "${SR}"; D="$(mk_dist "${GOOD_GH}" good)"; rm -rf "${TMP}/cache"
if out="$(run "export FAKE_CONTAINER=true; id() { echo 0; }; export -f id; HOSTGUARD_RUST_DIST_URL=file://${D} HOSTGUARD_RUST_KEYFILE=${GOOD_KEY} HOSTGUARD_RUST_KEY_FPR=${GOOD_FPR}")"; then
    ok "pinned key -> installed, probe passes"
else bad "good: ${out}"; fi
[ -e "${SR}/lib/rustlib/${T}/lib/libstd-test.rlib" ] && ok "std landed in the host rustc's sysroot" || bad "std not installed"

echo "== 6. the shipped pin is the Rust release key"
G="${TMP}/gpg-real"; mkdir -p "${G}"; chmod 700 "${G}"
GNUPGHOME="${G}" gpg --batch --quiet --import "${ROOT}/scripts/rust-release-key.asc" 2>/dev/null
fpr="$(GNUPGHOME="${G}" gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
pin="$(sed -n 's/^: "\${HOSTGUARD_RUST_KEY_FPR:=\([0-9A-F]*\)}"$/\1/p' "${LIB}")"
[ -n "${pin}" ] && [ "${fpr}" = "${pin}" ] && [ "${pin}" = 108F66205EAEB0AAA8DD5E1C85AB96E6FA1BE5FE ] \
    && ok "vendored key's primary fingerprint == the pin == the Rust release key" || bad "pin '${pin}' vs key '${fpr}'"
# the call is the line right after "if ${ROLE_CLIENT}; then", fatal, and before the first cross_emerge
B="${ROOT}/build-rpi5-stage4.sh"
call="$(grep -n '^    hostguard_ensure_cross_rust_std aarch64-unknown-linux-gnu .* || exit 1$' "${B}" | head -1 | cut -d: -f1)"
first="$(grep -n '^[[:space:]]*cross_emerge ' "${B}" | head -1 | cut -d: -f1)"
if [ -n "${call}" ] && [ "$(sed -n "$((call - 1))p" "${B}")" = 'if ${ROLE_CLIENT}; then' ] \
        && [ -n "${first}" ] && [ "${call}" -lt "${first}" ]; then
    ok "build-rpi5-stage4.sh runs the guard (fatal) for the desktop role, before the first cross_emerge"
else bad "rpi5 builder: guard call line '${call}', first cross_emerge '${first}'"; fi

echo; echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
