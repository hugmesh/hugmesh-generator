#!/usr/bin/env bash
# ============================================================================
# secret-scan.sh — emit-time secret scanner (FAIL-CLOSED).
# ============================================================================
#
# Gitleaks-style guard that scans a candidate output tree (a rendered repo about
# to be emitted in Phase 2) and exits NON-ZERO if any secret-looking value is
# present. Combines high-signal REGEX patterns with a SHANNON-ENTROPY heuristic
# over long opaque tokens (both pillars are live and self-tested — the generic
# high-entropy detector catches keyless base64/token credentials that no key-name
# rule would see; SRI/content hashes are suppressed to keep it FP-free on real repos).
#
# Deliberately node-free (pure bash + awk): unlike the Handlebars renderer this
# guard may also run on the constrained mesh path, so it must not depend on Node.
# The secret-KEY denylist mirrors scripts/tooling/tokens.json (denylist.keys +
# denylist.key_name_regex); keep the two in sync.
#
# Usage:
#   scripts/secret-scan.sh <dir-or-file> [more...]   # scan; exit 1 on findings
#   scripts/secret-scan.sh --self-test               # prove pass-clean/fail-dirty
#
# Exit codes: 0 = clean, 1 = secret(s) found, 2 = usage/error.

set -euo pipefail

ENTROPY_MIN_LEN=20        # only entropy-test opaque tokens at least this long
ENTROPY_THRESHOLD=4.0     # bits/char, KEYED (secret-assign) rule; random base64/hex ~5-6, prose ~3-4
ENTROPY_HIGH_THRESHOLD=4.5 # bits/char, GENERIC opaque-token rule. Deliberately stricter
                           # than the keyed rule: the keyless detector runs over WHOLE
                           # real repos (Angular src, openapi.json, lockfiles) where dotted
                           # API paths / dns slugs sit ~4.2-4.4; real base64/hex credentials
                           # sit >=5. 4.5 catches the credential class with ~zero FPs.

_usage() { echo "Usage: $0 [--exclude GLOB]... <dir-or-file>... | --self-test" >&2; exit 2; }

# The awk engine: reads files named on the command line, prints "path:line: RULE: detail"
# for every finding. Returns via a trailing "FINDINGS=<n>" line on stderr-substitute.
_scan_files() {
  awk -v elen="$ENTROPY_MIN_LEN" -v ethr="$ENTROPY_THRESHOLD" -v hthr="$ENTROPY_HIGH_THRESHOLD" '
    function shannon(s,   i, c, n, freq, p, h) {
      n = length(s); if (n == 0) return 0
      for (i = 1; i <= n; i++) { c = substr(s,i,1); freq[c]++ }
      h = 0
      for (c in freq) { p = freq[c]/n; h -= p * (log(p)/log(2)) }
      for (c in freq) delete freq[c]
      return h
    }
    function report(rule, detail) {
      printf("%s:%d: %s: %s\n", FILENAME, FNR, rule, detail)
      findings++
    }
    {
      line = $0

      # ---- High-signal regex patterns ----
      if (line ~ /-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----/) report("private-key", "PEM private key header")
      if (line ~ /AKIA[0-9A-Z]{16}/)                     report("aws-akid", "AWS access key id")
      if (line ~ /ghp_[A-Za-z0-9]{30,}/)                 report("github-pat", "GitHub personal access token")
      if (line ~ /xox[baprs]-[A-Za-z0-9-]{10,}/)         report("slack-token", "Slack token")
      if (line ~ /-----BEGIN OPENSSH PRIVATE KEY-----/)  report("ssh-key", "OpenSSH private key")

      # ---- Secret-KEY assignment with a non-trivial value (mirrors tokens.json) ----
      # key = ...PASS/PASSWORD/SECRET/TOKEN/SIGNING_KEY/PRIVATE_KEY/API_KEY/CLIENT_SECRET/DKIM/CREDENTIAL...
      if (match(line, /(^|[^A-Za-z0-9_])([A-Za-z0-9_]*(PASSWORD|PASSWD|PASS|SECRET|TOKEN|SIGNING_KEY|PRIVATE_KEY|API_KEY|CLIENT_SECRET|DKIM|CREDENTIAL)[A-Za-z0-9_]*)[ \t]*[:=][ \t]*["\x27]?([^"\x27#[:space:]]+)/, m)) {
        key = m[2]; val = m[4]
        # Ignore empty / obvious non-secret reference values:
        #  - k8s "existingSecret*" style NAME references (dns-labels, low entropy)
        #  - ALL-CAPS_SNAKE env-var key NAMES being referenced (not a value)
        #  - short values
        if (length(val) >= 12 && val !~ /^[A-Z][A-Z0-9_]+$/ && shannon(val) >= ethr) {
          report("secret-assign", key "=<" length(val) " chars, H=" sprintf("%.2f", shannon(val)) ">")
        }
      }

      # ---- Generic high-entropy opaque token ----
      # NOTE (regression fixed): the length quantifier MUST be built as a STRING.
      # A single-quoted awk program cannot interpolate a shell/awk value inside a
      # /literal/ regex, so the old `/...{'elen',}/` reached awk as the literal
      # text {elen,}, which gawk treats as ordinary characters (not an interval) —
      # silently disabling this entire rule. Compose the regex dynamically instead.
      s = line
      re = "[A-Za-z0-9+/=_-]{" elen ",}"
      while (match(s, re)) {
        tok = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        # Skip subresource-integrity / content-hash values (npm lockfiles, SRI):
        # high-entropy but NOT secrets, and they carry a recognizable algo prefix.
        if (tok ~ /^(sha1|sha256|sha384|sha512|md5)-/) continue
        # Pure lowercase-hyphen dns slugs and pure numbers fall under the threshold.
        h = shannon(tok)
        if (h >= hthr && length(tok) >= elen && tok ~ /[A-Za-z]/ && tok ~ /[0-9+\/=_]/) {
          report("high-entropy", "opaque token len=" length(tok) " H=" sprintf("%.2f", h))
        }
      }
    }
    END { printf("__FINDINGS__=%d\n", findings) }
  ' "$@"
}

# EXCLUDES: an optional set of path GLOBs (populated from leading --exclude GLOB
# args in main). A scanned file whose path matches ANY glob is skipped. Default is
# EMPTY, so with no --exclude the behavior is byte-identical to before (the pilot
# login-ui emit + --self-test are unaffected). Used by render-repo-tree.sh to scope
# the EMIT scan away from a compiled base's own upstream Java SOURCE + unit-test
# fixtures — trees where a brand token never lands and whose content integrity is
# the base repo's own CI concern (the base is trusted-transport, re-verification is
# the Phase-8 deferral documented in pull-repo-base.sh). The full config/manifest/
# resource/CI surface — where a templated secret WOULD appear — is still scanned.
EXCLUDES=()
_is_excluded() {
  local f="$1" g
  for g in "${EXCLUDES[@]}"; do
    # shellcheck disable=SC2053
    [[ "$f" == $g ]] && return 0
  done
  return 1
}

_scan_paths() {
  local files=()
  local p f
  for p in "$@"; do
    if [[ -d "$p" ]]; then
      while IFS= read -r -d '' f; do
        _is_excluded "$f" || files+=("$f")
      done < <(find "$p" -type f -print0)
    elif [[ -f "$p" ]]; then
      _is_excluded "$p" || files+=("$p")
    else
      echo "secret-scan: no such path: $p" >&2; return 2
    fi
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "[secret-scan] no files to scan"; return 0
  fi
  local out; out="$(_scan_files "${files[@]}")"
  local n; n="$(printf '%s\n' "$out" | sed -n 's/^__FINDINGS__=//p' | tail -1)"
  printf '%s\n' "$out" | grep -v '^__FINDINGS__=' || true
  if [[ "${n:-0}" -gt 0 ]]; then
    echo "[secret-scan] FAIL: ${n} secret-looking finding(s)"; return 1
  fi
  echo "[secret-scan] OK: scanned ${#files[@]} file(s), 0 findings"; return 0
}

_self_test() {
  local td; td="$(mktemp -d)"; trap 'rm -rf "$td"' RETURN
  echo "=== secret-scan self-test ==="

  # 1) CLEAN tree — a benign rendered-CRD-like file. Expect PASS.
  mkdir -p "$td/clean"
  cat > "$td/clean/app.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: example-harbor
spec:
  source:
    repoURL: https://github.com/Snapdragon-Systems/snapdragon-generator.git
    helm:
      values: |
        harborAdminPassword: ""
        existingSecretAdminPassword: harbor-admin
        existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD
        externalURL: https://registry.example.test
YAML
  echo "--- [1] clean tree (expect: OK, exit 0) ---"
  if _scan_paths "$td/clean"; then r1=0; else r1=$?; fi
  echo "    exit=$r1"

  # 2) DIRTY tree — a planted secret + a private key + an entropy token. Expect FAIL.
  mkdir -p "$td/dirty"
  cat > "$td/dirty/leak.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
data:
  ROOT_PASS: "gentoo"
  CASDOOR_ADMIN_CLIENT_SECRET: "s3cr3t-Kx9fQp2Lm7Vb8Nz4Wt6Rd1Yh0Jc5Ug"
  APP_REGISTRY_SIGNING_KEY: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEabc123"
YAML
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA2Zx\n-----END RSA PRIVATE KEY-----\n' > "$td/dirty/id_rsa"
  echo "--- [2] dirty tree (expect: FAIL, exit 1) ---"
  if _scan_paths "$td/dirty"; then r2=0; else r2=$?; fi
  echo "    exit=$r2"

  # 3) KEYLESS high-entropy credential — a bare token on a NON-denylisted field
  #    name and NO PEM header, so ONLY the generic high-entropy rule can catch it.
  #    This exercises the entropy pillar directly (the dirty case above is caught
  #    by the key-name/PEM rules and would pass even if entropy were broken).
  mkdir -p "$td/entropy"
  cat > "$td/entropy/creds.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
data:
  note: "no denylisted key name on the next line — only entropy can catch it"
  auth: "authorization: Bearer BqYq2wYQ0Km7v8Nx3Rd1Yh0Jc5UgKx9fQp2Lm7Vb8Nz4Wt6Rd1Yh0Jc5Ug"
YAML
  echo "--- [3] keyless high-entropy blob (expect: FAIL via high-entropy rule) ---"
  local e_out e3
  if e_out="$(_scan_paths "$td/entropy" 2>&1)"; then e3=0; else e3=$?; fi
  printf '%s\n' "$e_out" | sed 's/^/    /'
  echo "    exit=$e3"
  local e_rule=1
  printf '%s\n' "$e_out" | grep -q ' high-entropy: ' || e_rule=0

  echo ""
  if [[ "$r1" -eq 0 && "$r2" -eq 1 && "$e3" -eq 1 && "$e_rule" -eq 1 ]]; then
    echo "SELF-TEST: PASS (clean=>0, dirty=>1, keyless-entropy=>1 via high-entropy rule)"; return 0
  else
    echo "SELF-TEST: FAIL (clean=>$r1 want 0, dirty=>$r2 want 1, entropy=>$e3 want 1, entropy-rule-fired=>$e_rule want 1)"; return 1
  fi
}

# ---- main ----
[[ $# -ge 1 ]] || _usage
if [[ "$1" == "--self-test" ]]; then
  _self_test
else
  # Leading, repeatable `--exclude GLOB` options (path globs to skip); everything
  # after is the scan path list. Default: no excludes (unchanged behavior).
  while [[ $# -gt 0 && "$1" == "--exclude" ]]; do
    [[ $# -ge 2 ]] || _usage
    EXCLUDES+=("$2"); shift 2
  done
  [[ $# -ge 1 ]] || _usage
  _scan_paths "$@"
fi
