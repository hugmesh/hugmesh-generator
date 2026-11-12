#!/usr/bin/env bash
# test-headscale-policy-fallback.sh — keys-provision's headscale policy step fails
# CLOSED in every branch: headscale never starts on a policy that gives a security tag
# an owner, on one that could not be read, or on none at all.
#
# WHY. provision_headscale checks the policy it is about to load
# (headscale_policy_owned_security_tags). A KEYS-stick override (or a stale baked file)
# that gives tag:superadmin / tag:mesh_* / tag:dev_* / tag:dom_* an owner lets any
# pre-auth key holder claim that tag. When the clean baked bootstrap policy could not be
# used instead, three fallback branches used to fail OPEN, each with only a warning:
#   1. an override that could not be narrowed was "loaded UNSAFE";
#   2. an unreadable override was kept (headscale parses hujson that jq cannot, e.g. a
#      trailing comma, so its owners were loaded unchecked);
#   3. with no policy file at all, headscale was started anyway.
# The check itself also read the policy differently from headscale: a "TagOwners"
# member, or the first of two "tagOwners" members, was invisible to it, while headscale
# 0.23.0 (Go JSON: case-insensitive member names, repeated objects merged) granted the
# tags they own. Now every such outcome stages a static deny-all policy and marks
# first-boot health UNPROTECTED, and when even that cannot be written headscale is not
# started.
# All of that checks /etc/headscale/policy.hujson, but headscale loads the file its
# EFFECTIVE config names, and that config comes from the KEYS stick. A stick
# config.yaml naming another file (policy.path: /etc/headscale/acl.hujson, next to a
# stick acl.hujson that owns tag:superadmin), naming none (allow-all) or selecting
# database mode bypassed every check above while keys-provision reported success. The
# CONFIG GATE now asks headscale itself (`headscale dumpConfig`) what it will load and
# refuses to start it unless that is policy.mode file + /etc/headscale/policy.hujson.
#
# HOW (offline: bash + jq + perl + awk + python3, which publish_cp_dns_record runs). The REAL provision_headscale and its helpers
# are cut out of specs/etc/keys-provision/provision.sh, every absolute path they touch
# is rewritten into a per-scenario sandbox (and the run is refused if one is left
# over), and the commands around them (headscale, rc-service, rc-update, chown, logger)
# are stubs. The rc-service stub snapshots, whenever headscale would (re)start, the
# policy headscale would read then: the file the INSTALLED config.yaml names (or no file
# at all, or the database), as tests/device-registry/fixtures/
# headscale-config-policy-variants.tsv records it for each config variant. That table
# is MEASURED against the pinned headscale binary by the live suite, and the
# `headscale dumpConfig` stub replays it, so the production gate is fed what headscale
# would report. A config.yaml the table does not know reads as UNSAFE. Each snapshot is
# judged by THIS file's own reader, not the production one: it strips hujson the way
# headscale tolerates it (comments, trailing commas), folds member names, unions
# repeated members, and calls anything it cannot parse UNSAFE.
#
# Scenarios cover every branch (clean override, bootstrap swap, narrowing, narrowing
# that cannot be written, unreadable with and without a bootstrap, no policy, the
# case-variant and repeated-member spellings, a bad baked bootstrap, a deny-all that
# cannot be written, a stale mark) and every config-gate outcome (a stick config that
# redirects the policy, names none, selects database mode or a relative path; no dump;
# a stale dump; a dump that cannot be removed; odd dump shapes; a HEADSCALE_* variable
# in keys-provision's own environment; config edits after the gate). Negative controls
# re-run scenarios with the production check, the deny-all writer or the config gate
# disabled and require this file to see it. The live half (pinned headscale really
# starts on the deny-all text, really grants the spellings the old check missed, and
# really loads what dumpConfig reports) is test-headscale-policy-fallback-live.sh.
#
# HS_FALLBACK_PROVISION=<file> points the suite at another copy of provision.sh (the
# mutation battery, or origin/main to watch it fail).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION="${HS_FALLBACK_PROVISION:-${REPO}/specs/etc/keys-provision/provision.sh}"
BOOTSTRAP_SRC="${REPO}/specs/etc/headscale/policy.bootstrap.hujson"
BAKED_CFG="${REPO}/specs/etc/headscale/config.yaml"
TEMPLATE_CFG="${REPO}/keys-template/headscale/config.yaml"
VARIANTS="${REPO}/tests/device-registry/fixtures/headscale-config-policy-variants.tsv"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
cannot() { echo "CANNOT RUN: $* — this guard checked NOTHING"; exit 2; }

for t in jq perl awk sed cmp python3; do command -v "$t" >/dev/null 2>&1 || cannot "$t is required"; done
[ -f "${PROVISION}" ] || cannot "${PROVISION} not found"
[ -f "${BOOTSTRAP_SRC}" ] || cannot "${BOOTSTRAP_SRC} not found"
for f in "${BAKED_CFG}" "${TEMPLATE_CFG}" "${VARIANTS}"; do [ -f "${f}" ] || cannot "${f} not found"; done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
SEC_RE='^tag:(superadmin$|mesh_|dev_|dom_)'

# ── this file's own reader (independent of the production check) ─────────────
# hujson -> JSON as headscale tolerates it: // and /* */ comments, trailing commas.
to_json() { perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g; s{,(\s*[\]\}])}{$1}g' "$1" 2>/dev/null; }
# owners_seen <file>: prints "<tag>" for every security tag with an owner under ANY
# member whose name folds to "tagowners", across repeats; rc 1 when it does not parse.
owners_seen() {
    local j
    j="$(to_json "$1")" || return 1
    printf '%s' "${j}" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    printf '%s' "${j}" | jq -nr --stream --arg re "${SEC_RE}" '
        [inputs | select(length == 2)
         | select((.[0] | length) > 1 and (.[0][0] | type) == "string")
         # Go folds U+017F to "s" and U+212A (Kelvin) to "k" when it matches names.
         | select((.[0][0] | ascii_downcase | gsub("\u017f"; "s") | gsub("\u212a"; "k")) == "tagowners")
         | select((.[0][1] | tostring) | test($re))
         | select((.[0] | length) > 2 or (.[1] != [] and .[1] != null))
         | .[0][1]] | unique[]' 2>/dev/null
}
# unsafe_reason <file>: empty when the file is safe for headscale to start on.
unsafe_reason() {
    local o
    [ -f "$1" ] || { echo "no policy file (headscale would start on none)"; return; }
    if ! o="$(owners_seen "$1")"; then echo "does not parse here (headscale may read it, owners unchecked)"; return; fi
    [ -z "${o}" ] || echo "security tag(s) with an owner: $(printf '%s' "${o}" | tr '\n' ' ')"
}

# ── extract the real functions ───────────────────────────────────────────────
extract() { awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "${PROVISION}"; }
SRC="${WORK}/extracted.sh"; : > "${SRC}"
for fn in headscale_policy_owned_security_tags headscale_deny_all_policy headscale_stage_deny_all_policy \
          headscale_policy_unprotected headscale_effective_policy_path headscale_config_gate \
          headscale_refuse_config provision_headscale publish_cp_dns_record; do
    body="$(extract "${fn}")"
    if [ -n "${body}" ]; then printf '%s\n\n' "${body}" >> "${SRC}"
    else bad "${fn}() not found in $(basename "${PROVISION}")"; fi
done
grep -q '^provision_headscale() {' "${SRC}" || cannot "provision_headscale() could not be extracted"
# Rewrite every absolute path into the sandbox ${HSB}, then refuse to run if any
# command line still names one (comments and the policy text are not commands).
sed -i -E 's#(^|[^A-Za-z0-9_}])/(etc/headscale|var/lib/headscale|run/headscale|var/log/headscale|run/hugmesh)#\1${HSB}/\2#g' "${SRC}"
leftover="$(sed 's#/dev/null##g' "${SRC}" | grep -nE '(^|[^A-Za-z0-9_}.])/(etc|var|run|usr|opt|root|home|boot|srv|dev|sys|proc)/' \
    | grep -vE '^[0-9]+:[[:space:]]*(#|//)')"
[ -z "${leftover}" ] || cannot "provision_headscale names a path this suite does not sandbox — refusing to run it:
${leftover}"
ok "extracted provision_headscale + helpers; every path they touch is sandboxed"
# publish_cp_dns_record edits config.yaml from an inline python program, where the
# sandbox variable is not expanded: point that one literal at the sandbox through the
# environment (HSB is exported in the scenarios that run it).
n_py="$(grep -c 'p = "${HSB}/etc/headscale/config.yaml"' "${SRC}")"
[ "${n_py}" = 1 ] || cannot "publish_cp_dns_record's config.yaml literal not found once (found ${n_py}) — its python changed shape"
sed -i 's#p = "${HSB}/etc/headscale/config.yaml"#p = __import__("os").environ["HSB"] + "/etc/headscale/config.yaml"#' "${SRC}"

# ── fixtures ─────────────────────────────────────────────────────────────────
FX="${WORK}/fx"; mkdir -p "${FX}"
cat > "${FX}/clean.hujson" <<'EOF'
{
  // a clean KEYS override (FIXTURE-CLEAN)
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": [] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ]
}
EOF
cat > "${FX}/owned.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"], "tag:dev_abc": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.96.0.0/12:443"] } ]
}
EOF
# headscale reads hujson (trailing commas allowed); jq cannot. Owned on purpose.
cat > "${FX}/unreadable.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"], },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] }, ],
}
EOF
cat > "${FX}/case.hujson" <<'EOF'
{
  "TagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ]
}
EOF
cat > "${FX}/dup.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ],
  "tagOwners": { "tag:hugmesh": ["hugmesh"] }
}
EOF
printf '{\n  "tagOwner\xc5\xbf": { "tag:superadmin": ["hugmesh"] },\n  "acls": []\n}\n' > "${FX}/nonascii.hujson"
sed 's/"tag:superadmin": \[\]/"tag:superadmin": ["hugmesh"]/' "${BOOTSTRAP_SRC}" > "${FX}/bootstrap-owned.hujson"
cmp -s "${BOOTSTRAP_SRC}" "${FX}/bootstrap-owned.hujson" && cannot "could not plant an owner in the bootstrap fixture (shape changed?)"
printf '{"headscale":{"enabled":true}}\n' > "${FX}/provision.json"

# Fixture sanity: the reader above must call every bad fixture unsafe and the clean
# ones safe, or every scenario verdict below means nothing.
for f in owned unreadable case dup nonascii bootstrap-owned; do
    [ -n "$(unsafe_reason "${FX}/${f}.hujson")" ] && ok "reader: fixture ${f} is unsafe" \
        || bad "reader: fixture ${f} reads as safe — the scenario verdicts would be vacuous"
done
for f in "${FX}/clean.hujson" "${BOOTSTRAP_SRC}"; do
    [ -z "$(unsafe_reason "${f}")" ] && ok "reader: $(basename "${f}") is safe" \
        || bad "reader: $(basename "${f}") reads as unsafe ($(unsafe_reason "${f}"))"
done

# ── config.yaml variants and what headscale loads from each ──────────────────
# For the baked config and the keys-template config, one file per row of ${VARIANTS},
# plus "<file>.reads" = "<mode> <path|->" as the pinned headscale reports it (measured
# by the live suite). hs_reads <config.yaml> looks a config up in that table, ignoring
# the server_url / base_domain lines provision_headscale rewrites; rc 1 = unknown.
CFGX="${FX}/cfg"; mkdir -p "${CFGX}"
nvar=0
for base in baked template; do
    case "${base}" in baked) src="${BAKED_CFG}" ;; template) src="${TEMPLATE_CFG}" ;; esac
    # Every variant edits the canonical three-line block; a base without it is a broken fixture.
    [ "$(grep -c -x -e 'policy:' -e '  mode: file' -e '  path: /etc/headscale/policy.hujson' "${src}")" = 3 ] \
        || cannot "$(basename "${src}") does not carry the canonical policy block the variants edit"
    while IFS=$'\t' read -r vname vsed vmode vpath; do
        case "${vname}" in ''|\#*) continue ;; esac
        sed -e "${vsed}" "${src}" > "${CFGX}/${base}-${vname}.yaml" || cannot "variant ${vname}: sed failed"
        printf '%s %s\n' "${vmode}" "${vpath}" > "${CFGX}/${base}-${vname}.yaml.reads"
        if [ "${vname}" = canonical ]; then
            cmp -s "${src}" "${CFGX}/${base}-${vname}.yaml" || cannot "the canonical variant changed $(basename "${src}")"
        else
            cmp -s "${src}" "${CFGX}/${base}-${vname}.yaml" && cannot "variant ${vname} did not change $(basename "${src}") (shape changed?)"
        fi
        nvar=$((nvar + 1))
    done < "${VARIANTS}"
done
[ "${nvar}" -ge 10 ] || cannot "only ${nvar} config variants were built from ${VARIANTS}"
# The CP DNS trap: a stick config whose policy: block sits between the two marker lines
# publish_cp_dns_record deletes between. headscale reads it as canonical (the first gate
# passes); after that rewrite it names no policy.path. Both MEASURED on the pinned
# binary by the live suite (G, "C"). The rewritten form is made by the production
# program itself with this suite's CP name and tailnet IP.
CP_NAME="kube-api.headnet.internal"; CP_IP="100.64.0.1"
{ sed '/^policy:$/,/^  path: /d' "${TEMPLATE_CFG}"
  printf 'cpdns_trap:\n  # >>> hugmesh cp dns (managed)\npolicy:\n  mode: file\n  path: /etc/headscale/policy.hujson\n  # <<< hugmesh cp dns (managed)\n'
} > "${CFGX}/trap-cpdns.yaml"
echo "file /etc/headscale/policy.hujson" > "${CFGX}/trap-cpdns.yaml.reads"
mkdir -p "${WORK}/trapgen/etc/headscale"; cp "${CFGX}/trap-cpdns.yaml" "${WORK}/trapgen/etc/headscale/config.yaml"
awk 'index($0, "python3 - \"$cpname\" \"$tip\" <<") {q=1; next} q && /^PY$/ {exit} q {print}' "${SRC}" > "${WORK}/cpdns.py"
grep -q 'environ\["HSB"\]' "${WORK}/cpdns.py" || cannot "could not cut publish_cp_dns_record's python program out"
HSB="${WORK}/trapgen" python3 -I "${WORK}/cpdns.py" "${CP_NAME}" "${CP_IP}" 2>/dev/null || cannot "publish_cp_dns_record's python program failed on the trap config"
cp "${WORK}/trapgen/etc/headscale/config.yaml" "${CFGX}/trap-cpdns-after.yaml"
echo "file -" > "${CFGX}/trap-cpdns-after.yaml.reads"
grep -q '^policy:$' "${CFGX}/trap-cpdns-after.yaml" && cannot "the CP DNS rewrite kept the trap's policy block — the trap does not model the edit"
# ... and the baked config after the same rewrite (a record under dns:, policy untouched).
cp "${BAKED_CFG}" "${WORK}/trapgen/etc/headscale/config.yaml"
HSB="${WORK}/trapgen" python3 -I "${WORK}/cpdns.py" "${CP_NAME}" "${CP_IP}" 2>/dev/null || cannot "publish_cp_dns_record's python program failed on the baked config"
cp "${WORK}/trapgen/etc/headscale/config.yaml" "${CFGX}/baked-cpdns-after.yaml"
echo "file /etc/headscale/policy.hujson" > "${CFGX}/baked-cpdns-after.yaml.reads"
grep -q "${CP_NAME}" "${CFGX}/baked-cpdns-after.yaml" || cannot "the CP DNS rewrite wrote no record into the baked config"
cfg_norm() { grep -v -e '^server_url:' -e '^[[:space:]]*base_domain:' "$1" 2>/dev/null; }
hs_reads() {
    local f
    [ -f "$1" ] || return 1
    for f in "${CFGX}"/*.yaml; do
        if cmp -s <(cfg_norm "$1") <(cfg_norm "${f}"); then cat "${f}.reads"; return 0; fi
    done
    return 1
}
[ "$(hs_reads "${BAKED_CFG}")" = "file /etc/headscale/policy.hujson" ] && [ "$(hs_reads "${TEMPLATE_CFG}")" = "file /etc/headscale/policy.hujson" ] \
    && ok "variants: the baked and keys-template configs read as file mode on /etc/headscale/policy.hujson" \
    || bad "variants: the shipped configs do not read as canonical ('$(hs_reads "${BAKED_CFG}")', '$(hs_reads "${TEMPLATE_CFG}")')"

# ── scenario runner ──────────────────────────────────────────────────────────
# run_scenario <name> <override fixture|-> <bootstrap fixture|-> [baked policy.hujson|-]
# The image's baked config.yaml (specs/etc/headscale/config.yaml) is in place, as on a
# real image.
# Env: FAIL_MV_RE (mv fails when its source matches), PRE_MARK=1 (a stale mark exists),
#      EXTRA_SRC (shell text evaluated after the functions: negative controls),
#      STICK_CFG=<file> (the KEYS stick's headscale/config.yaml),
#      STICK_EXTRA=<file> (the KEYS stick's headscale/acl.hujson),
#      PRE_DUMP=<file> (a stale config.dump.yaml), PRE_DUMP_DIR=1 (one that cannot be
#      removed), DUMP_FAULT=none (dumpConfig writes nothing, exit 0) | text:<printf %b>
#      (dumpConfig writes exactly that), GATE_ENV=<NAME=value> (exported into
#      keys-provision's own environment), ENDPOINT=<url> (resolve_endpoint's answer),
#      LATER_RESTART=1 (a later `rc-service headscale restart`, as the policy-sync
#      apply leg does), CPDNS=1 (publish_cp_dns_record runs after provision_headscale).
run_scenario() {
    local name="$1" ovr="$2" boot="$3" baked="${4:--}"
    local sb="${WORK}/sb-${name}"
    rm -rf "${sb}"; mkdir -p "${sb}/keys/headscale" "${sb}/etc/headscale"
    [ "${ovr}" = "-" ] || cp "${ovr}" "${sb}/keys/headscale/policy.hujson"
    [ "${boot}" = "-" ] || cp "${boot}" "${sb}/etc/headscale/policy.bootstrap.hujson"
    [ "${baked}" = "-" ] || cp "${baked}" "${sb}/etc/headscale/policy.hujson"
    cp "${BAKED_CFG}" "${sb}/etc/headscale/config.yaml"
    [ -z "${STICK_CFG:-}" ] || cp "${STICK_CFG}" "${sb}/keys/headscale/config.yaml"
    [ -z "${STICK_EXTRA:-}" ] || cp "${STICK_EXTRA}" "${sb}/keys/headscale/acl.hujson"
    [ -z "${PRE_DUMP:-}" ] || cp "${PRE_DUMP}" "${sb}/etc/headscale/config.dump.yaml"
    [ "${PRE_DUMP_DIR:-0}" = 1 ] && mkdir -p "${sb}/etc/headscale/config.dump.yaml/keep"
    if [ "${PRE_MARK:-0}" = 1 ]; then
        mkdir -p "${sb}/run/hugmesh/firewall-health"; echo stale > "${sb}/run/hugmesh/firewall-health/headscale_policy.unprotected"
    fi
    (
        HSB="${sb}"; MANIFEST="${FX}/provision.json"
        # shellcheck disable=SC2034  # read by the extracted provision_headscale
        BASE="${sb}/keys"
        n=0
        log()  { echo "[kp] $*" >> "${HSB}/log"; }
        warn() { log "WARNING: $*"; }
        have() { command -v "$1" >/dev/null 2>&1; }
        jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
        getent() { return 0; }; groupadd() { :; }; useradd() { :; }; sleep() { :; }
        chown() { [ ! -e "${HSB}/etc/headscale/config.dump.yaml" ] || echo "$*" >> "${HSB}/chown-saw-dump"; }
        logger() { echo "$*" >> "${HSB}/syslog"; }
        resolve_endpoint() { [ -z "${ENDPOINT:-}" ] || echo "${ENDPOINT}"; }; resolve_magic_dns_domain() { :; }; resolve_ssh_user() { echo superadmin; }
        approve_mesh_routes_now() { :; }; provision_headscale_derp() { :; }
        mv() { # fault injection: fail when the SOURCE (next-to-last argument) matches
            local mv_src="${*: -2:1}"
            if [ -n "${FAIL_MV_RE:-}" ] && [[ "${mv_src}" =~ ${FAIL_MV_RE} ]]; then return 1; fi
            command mv "$@"
        }
        hs_path() { # a policy.path as headscale resolves it, mapped into the sandbox
            case "$1" in /etc/headscale/*) echo "${HSB}$1" ;; /*) echo "$1" ;; *) echo "${HSB}/etc/headscale/$1" ;; esac
        }
        snap() { # what headscale reads at (re)start: the policy its INSTALLED config names
            local reads mode path f e
            for e in json toml yaml yml properties props prop hcl tfvars dotenv env ini; do
                [ -e "${HSB}/etc/headscale/config.${e}" ] && break
                e=""
            done
            # no config file at all: headscale cannot start (fatal "Config File Not Found")
            [ -n "${e}" ] || { echo "$1 (no config: headscale cannot start)" >> "${HSB}/nostarts"; return 0; }
            n=$((n + 1))
            if ! reads="$(hs_reads "${HSB}/etc/headscale/config.yaml")"; then
                echo "a config.yaml this suite cannot tell the policy of" > "${HSB}/loaded.${n}.unsafe"
            else
                mode="${reads%% *}"; path="${reads#* }"
                if [ "${mode}" != file ]; then echo "policy.mode ${mode}: a policy nobody checked" > "${HSB}/loaded.${n}.unsafe"
                elif [ "${path}" = - ]; then echo "no policy.path: headscale runs allow-all" > "${HSB}/loaded.${n}.unsafe"
                else
                    f="$(hs_path "${path}")"
                    if [ -f "${f}" ]; then cp "${f}" "${HSB}/loaded.${n}"; else : > "${HSB}/loaded.${n}.missing"; fi
                fi
            fi
            cmp -s "${HSB}/etc/headscale/config.yaml" "${HSB}/dumped.cfg" 2>/dev/null || echo "${n}" >> "${HSB}/cfg-changed-after-gate"
            echo "$1 ${n}" >> "${HSB}/starts"
        }
        dump_stub() { # `headscale dumpConfig`: headscale's own reading of the installed config
            local out="${HSB}/etc/headscale/config.dump.yaml" reads mode path
            echo dumpConfig >> "${HSB}/dumps"
            cp "${HSB}/etc/headscale/config.yaml" "${HSB}/dumped.cfg" 2>/dev/null
            case "${DUMP_FAULT:-}" in
                none) return 0 ;;                                        # "Failed to dump config", exit 0
                text:*) printf '%b' "${DUMP_FAULT#text:}" > "${out}"; return 0 ;;
            esac
            reads="$(hs_reads "${HSB}/etc/headscale/config.yaml")" || return 0
            mode="${reads%% *}"; path="${reads#* }"
            # viper's AutomaticEnv: a HEADSCALE_POLICY_PATH in the CALLER's environment wins.
            [ -z "${HEADSCALE_POLICY_PATH:-}" ] || path="${HEADSCALE_POLICY_PATH#"${HSB}"}"
            {
                printf 'database:\n    sqlite:\n        path: /var/lib/headscale/db.sqlite\n    type: sqlite\n'
                printf 'policy:\n    mode: %s\n' "${mode}"
                case "${path}" in -) ;; /*) printf '    path: %s\n' "$(hs_path "${path}")" ;; *) printf '    path: %s\n' "${path}" ;; esac
                printf 'prefixes:\n    allocation: sequential\n    v4: 100.64.0.0/10\n'
            } > "${out}"
        }
        timeout() { shift; "$@"; }
        rc-service() {
            echo "rc-service $*" >> "${HSB}/rc"
            case "$1 $2" in "headscale start"|"headscale restart") snap "$2" ;; esac
            # fault: the policy file is removed underneath the run after headscale started
            [ "${VANISH_AFTER_START:-0}" = 1 ] && [ "$1 $2" = "headscale start" ] && rm -f "${HSB}/etc/headscale/policy.hujson"
            return 0
        }
        rc-update() { echo "rc-update $*" >> "${HSB}/rc"; }
        headscale() {
            case "$1 ${2:-}" in
                "policy set") return 1 ;;   # policy.mode file refuses; provision restarts instead
                "dumpConfig "*) dump_stub ;;
                *) return 0 ;;
            esac
        }
        # shellcheck source=/dev/null
        . "${SRC}"
        [ -n "${EXTRA_SRC:-}" ] && eval "${EXTRA_SRC}"
        resolve_cp_dns_name() { echo "${CP_NAME}"; }
        tailscale() { [ "$1 ${2:-}" = "ip -4" ] && echo "${CP_IP}"; return 0; }
        export HSB
        # shellcheck disable=SC2163  # GATE_ENV is NAME=value
        [ -z "${GATE_ENV:-}" ] || export "${GATE_ENV}"
        provision_headscale; echo "$?" > "${HSB}/rc.exit"
        [ "${CPDNS:-0}" = 1 ] && { echo "--- publish_cp_dns_record" >> "${HSB}/rc"; publish_cp_dns_record; echo "$?" > "${HSB}/cpdns.exit"; }
        [ "${LATER_RESTART:-0}" = 1 ] && rc-service headscale restart
    ) >/dev/null 2>&1
    SB="${sb}"
}
mark()      { echo "${SB}/run/hugmesh/firewall-health/headscale_policy.unprotected"; }
started()   { [ -s "${SB}/starts" ]; }
first_load() { echo "${SB}/loaded.1"; }
# every policy headscale would have read in this scenario is safe
all_loads_safe() {
    local f r out=""
    for f in "${SB}"/loaded.*; do
        [ -e "${f}" ] || continue
        case "${f}" in
            *.missing) out="${out} $(basename "${f}"): no policy file;"; continue ;;
            *.unsafe) out="${out} $(basename "${f}"): $(cat "${f}");"; continue ;;
        esac
        r="$(unsafe_reason "${f}")"; [ -z "${r}" ] || out="${out} $(basename "${f}"): ${r};"
    done
    printf '%s' "${out}"
}
DENYALL="${WORK}/denyall.expected"
( eval "$(extract headscale_deny_all_policy)" && headscale_deny_all_policy ) > "${DENYALL}" 2>/dev/null || : > "${DENYALL}"
is_denyall() { [ -s "${DENYALL}" ] && cmp -s "$1" "${DENYALL}"; }

expect_safe_start() { # <label>
    started || { bad "$1: headscale was never started"; return; }
    local u; u="$(all_loads_safe)"
    [ -z "${u}" ] && ok "$1: every policy headscale would read is safe" || bad "$1: headscale would read an UNSAFE policy:${u}"
}
expect_denyall() { # <label> <reason substring> — deny-all in force, health marked by THAT branch
    expect_safe_start "$1"
    grep -q "^reason=.*$2" "$(mark)" 2>/dev/null && ok "$1: the mark names the branch that failed closed ('$2')" \
        || bad "$1: the mark does not say '$2' (got: $(sed -n 's/^reason=//p' "$(mark)" 2>/dev/null | cut -c1-120))"
    is_denyall "$(first_load)" && ok "$1: the deny-all policy is what headscale starts on" \
        || bad "$1: headscale does not start on the deny-all policy"
    grep -q '^state=deny-all$' "$(mark)" 2>/dev/null && ok "$1: first-boot health marked UNPROTECTED (state=deny-all)" \
        || bad "$1: no UNPROTECTED health mark with state=deny-all"
    grep -q 'ERROR: headscale policy step FAILED CLOSED' "${SB}/log" 2>/dev/null && grep -q 'failed closed' "${SB}/syslog" 2>/dev/null \
        && ok "$1: an ERROR line and a syslog line say it failed closed" || bad "$1: no ERROR/syslog line for the fail-closed fallback"
}
expect_narrowed() { # <label> <source fixture>
    expect_safe_start "$1"
    if ! is_denyall "$(first_load)" && jq -e --slurpfile o <(to_json "$2") '.acls == $o[0].acls' "$(first_load)" >/dev/null 2>&1; then
        ok "$1: narrowed — the policy's own rules are kept, not replaced by deny-all"
    else bad "$1: not the narrowed policy (deny-all or something else is loaded)"; fi
    expect_no_mark "$1"
}
expect_no_mark() { [ ! -e "$(mark)" ] && ok "$1: no health mark (a working policy is in force)" || bad "$1: a health mark was left although a working policy is in force"; }

# ── 0. the deny-all policy itself ────────────────────────────────────────────
echo "== deny-all policy text =="
if [ -s "${DENYALL}" ]; then
    j="$(to_json "${DENYALL}")"
    [ -z "$(unsafe_reason "${DENYALL}")" ] && ok "deny-all: no tag has an owner" || bad "deny-all: $(unsafe_reason "${DENYALL}")"
    printf '%s' "${j}" | jq -e '(.acls == []) and ((.ssh // []) == []) and ((.autoApprovers // {}) == {}) and ((.hosts // {}) == {})' >/dev/null 2>&1 \
        && ok "deny-all: no ACL, no SSH rule, no auto-approver, no host" || bad "deny-all: grants something (acls/ssh/autoApprovers/hosts not empty)"
    printf '%s' "${j}" | jq -e '[.tagOwners[]] | all(. == [])' >/dev/null 2>&1 && printf '%s' "${j}" | jq -e '.tagOwners | has("tag:superadmin")' >/dev/null 2>&1 \
        && ok "deny-all: tag:superadmin listed with an empty owner list, every listed tag ownerless" || bad "deny-all: a listed tag has an owner, or tag:superadmin is not declared"
    printf '%s' "${j}" | jq -e '[.groups[]?] | all(. == [])' >/dev/null 2>&1 \
        && ok "deny-all: its groups have no members" || bad "deny-all: a group has members"
    # headscale 0.23 refuses a policy with no groups, hosts, acls and ssh ("empty policy").
    printf '%s' "${j}" | jq -e '((.groups // {}) | length) + ((.hosts // {}) | length) + ((.acls // []) | length) + ((.ssh // []) | length) > 0' >/dev/null 2>&1 \
        && ok "deny-all: not an 'empty policy' to headscale 0.23 (it would refuse to start)" || bad "deny-all: headscale 0.23 would reject it as an empty policy and not start"
    grep -q '^}' "${DENYALL}" && bad "deny-all: a line starts with '}' — the awk '/^fn\\(\\)/,/^}/' extraction would cut the function short" \
        || ok "deny-all: no line starts with '}' (function extraction stays whole)"
else
    bad "headscale_deny_all_policy produced nothing"
fi

# ── 1. the production check reads the policy the way headscale does ──────────
echo "== headscale_policy_owned_security_tags =="
(
    eval "$(extract headscale_policy_owned_security_tags)"
    # <file> -> its owned security tags, sorted, space-separated; UNREADABLE on rc 1.
    g() { local o; o="$(headscale_policy_owned_security_tags "$1")" || { echo UNREADABLE; return; }; printf '%s\n' "${o}" | sed '/^$/d' | sort | paste -sd' ' -; }
    [ "$(g "${FX}/case.hujson")" = "tag:superadmin" ] && echo "PASS-sub flags owners under a case-variant TagOwners member" || echo "FAIL-sub missed owners under TagOwners (got '$(g "${FX}/case.hujson")')"
    [ "$(g "${FX}/dup.hujson")" = "tag:superadmin" ] && echo "PASS-sub flags owners in the first of two tagOwners members" || echo "FAIL-sub missed owners in a repeated tagOwners member (got '$(g "${FX}/dup.hujson")')"
    [ "$(g "${FX}/nonascii.hujson")" = UNREADABLE ] && echo "PASS-sub a non-ASCII member name makes the policy unreadable" || echo "FAIL-sub a non-ASCII member name was read (got '$(g "${FX}/nonascii.hujson")')"
    printf '' > "${WORK}/empty.json"
    [ "$(g "${WORK}/empty.json")" = UNREADABLE ] && echo "PASS-sub an empty file is unreadable, not clean" || echo "FAIL-sub an empty file reads as clean"
    printf '%s' '{"tagOwners":["hugmesh"]}' > "${WORK}/arr.json"
    [ "$(g "${WORK}/arr.json")" = UNREADABLE ] && echo "PASS-sub a tagOwners that is not an object is unreadable" || echo "FAIL-sub a non-object tagOwners was read (got '$(g "${WORK}/arr.json")')"
    [ "$(g "${FX}/owned.hujson")" = "tag:dev_abc tag:superadmin" ] && echo "PASS-sub flags every owned security tag" || echo "FAIL-sub owned fixture read as '$(g "${FX}/owned.hujson")'"
    [ -z "$(g "${BOOTSTRAP_SRC}")" ] && echo "PASS-sub the shipped bootstrap policy reads clean" || echo "FAIL-sub the shipped bootstrap reads '$(g "${BOOTSTRAP_SRC}")'"
) > "${WORK}/guard.out" 2>&1
while IFS= read -r l; do
    case "${l}" in PASS-sub\ *) ok "guard: ${l#PASS-sub }" ;; FAIL-sub\ *) bad "guard: ${l#FAIL-sub }" ;; esac
done < "${WORK}/guard.out"
grep -q -- '-sub' "${WORK}/guard.out" || bad "guard: the unit checks did not run ($(head -c 200 "${WORK}/guard.out"))"

# ── 2. every branch of provision_headscale ───────────────────────────────────
echo "== provision_headscale branches =="
B="${FX}/bootstrap.hujson"; cp "${BOOTSTRAP_SRC}" "${B}"

run_scenario clean "${FX}/clean.hujson" "${B}"
expect_safe_start "clean override"
cmp -s "$(first_load)" "${FX}/clean.hujson" && ok "clean override: loaded as written" || bad "clean override: not loaded as written"
expect_no_mark "clean override"

PRE_MARK=1 run_scenario stale "${FX}/clean.hujson" "${B}"
expect_no_mark "clean override after a failed earlier run (stale mark)"

run_scenario owned-boot "${FX}/owned.hujson" "${B}"
expect_safe_start "owned override + clean bootstrap"
cmp -s "$(first_load)" "${B}" && ok "owned override + clean bootstrap: the bootstrap is staged instead" || bad "owned override + clean bootstrap: the bootstrap was not staged"
expect_no_mark "owned override + clean bootstrap"

run_scenario owned-narrow "${FX}/owned.hujson" -
expect_safe_start "owned override, no bootstrap (narrowed)"
if jq -e --slurpfile o <(to_json "${FX}/owned.hujson") '.acls == $o[0].acls and .tagOwners["tag:hugmesh"] == ["hugmesh"]' "$(first_load)" >/dev/null 2>&1; then
    ok "owned override, no bootstrap: narrowed — the override's rules and membership owner kept"
else bad "owned override, no bootstrap: not the narrowed override"; fi
expect_no_mark "owned override, no bootstrap (narrowed)"

FAIL_MV_RE='\.narrowed\.' run_scenario narrow-fails "${FX}/owned.hujson" -
expect_denyall "owned override that cannot be narrowed (was: loaded UNSAFE)" "could not be narrowed"

run_scenario unreadable "${FX}/unreadable.hujson" -
expect_denyall "unreadable override, no bootstrap (was: kept and loaded)" "could not be read"

run_scenario unreadable-boot "${FX}/unreadable.hujson" "${B}"
expect_safe_start "unreadable override + clean bootstrap"
cmp -s "$(first_load)" "${B}" && ok "unreadable override + clean bootstrap: the bootstrap is staged instead" || bad "unreadable override + clean bootstrap: the bootstrap was not staged"

run_scenario none - -
expect_denyall "no policy at all (was: headscale started on none)" "no headscale policy"

run_scenario case "${FX}/case.hujson" -
expect_narrowed "case-variant TagOwners override, no bootstrap" "${FX}/case.hujson"

run_scenario case-boot "${FX}/case.hujson" "${B}"
expect_safe_start "case-variant TagOwners override + clean bootstrap"
cmp -s "$(first_load)" "${B}" && ok "case-variant override + clean bootstrap: the bootstrap is staged instead" || bad "case-variant override + clean bootstrap: the override was loaded"

run_scenario dup "${FX}/dup.hujson" -
expect_narrowed "repeated tagOwners override, no bootstrap" "${FX}/dup.hujson"

run_scenario nonascii "${FX}/nonascii.hujson" -
expect_denyall "non-ASCII member name, no bootstrap" "could not be read"

run_scenario bad-bootstrap - "${FX}/bootstrap-owned.hujson"
expect_narrowed "no override, baked bootstrap gives tag:superadmin an owner" "${FX}/bootstrap-owned.hujson"

FAIL_MV_RE='\.(narrowed|deny-all)\.' run_scenario cannot-write "${FX}/owned.hujson" -
if started; then bad "deny-all cannot be written: headscale was STARTED (on $(all_loads_safe || true))"
else ok "deny-all cannot be written: headscale is not started"; fi
grep -q 'rc-update del headscale default' "${SB}/rc" 2>/dev/null && grep -q 'rc-service headscale stop' "${SB}/rc" 2>/dev/null \
    && ok "deny-all cannot be written: headscale is stopped and taken out of the runlevel" || bad "deny-all cannot be written: headscale left in the runlevel or not stopped"
[ ! -e "${SB}/etc/headscale/policy.hujson" ] && ok "deny-all cannot be written: the unsafe policy file is removed" || bad "deny-all cannot be written: the unsafe policy file is still in place"
grep -q '^state=not-started$' "$(mark)" 2>/dev/null && ok "deny-all cannot be written: health marked UNPROTECTED (state=not-started)" || bad "deny-all cannot be written: no UNPROTECTED mark with state=not-started"
[ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 1 ] && ok "deny-all cannot be written: provision_headscale returns 1" || bad "deny-all cannot be written: provision_headscale returned $(cat "${SB}/rc.exit" 2>/dev/null)"
[ ! -e "${SB}/etc/headscale/config.yaml" ] && [ -f "${SB}/etc/headscale/config.yaml.refused" ] \
    && ok "deny-all cannot be written: the configuration is set aside (a later restart has nothing to start on)" \
    || bad "deny-all cannot be written: the configuration is still in place for a later restart"

# The FINAL GATE re-reads the file headscale will start on. A first check that misreads
# (here: says "clean" once, then reads truly) must still not let an owned policy start.
EXTRA_SRC='eval "real_$(declare -f headscale_policy_owned_security_tags)"
    headscale_policy_owned_security_tags() { if [ ! -e "${HSB}/.misread" ]; then : > "${HSB}/.misread"; return 0; fi; real_headscale_policy_owned_security_tags "$@"; }' \
    run_scenario final-gate "${FX}/owned.hujson" -
expect_denyall "first check misreads an owned override as clean (final gate)" "not clean on the final check"

# A narrowing that does not narrow (simulated: jq passes the narrowing program's input
# through) must be caught by the narrowed file's own re-check, not left to the gate.
EXTRA_SRC='jq() { case "$*" in *with_entries*tagowners*) cat ;; *) command jq "$@" ;; esac; }' \
    run_scenario narrow-noop "${FX}/owned.hujson" -
expect_denyall "narrowing that leaves an owner in place" "could not be narrowed"

# A deny-all write that comes out short (disk full) must not be put in place.
EXTRA_SRC='headscale_deny_all_policy() { printf "{\n  \"groups\": {\n"; }' \
    run_scenario short-write - -
if started; then bad "short deny-all write: headscale was STARTED on it"
else ok "short deny-all write: not put in place, headscale is not started"; fi
grep -q '^state=not-started$' "$(mark)" 2>/dev/null && ok "short deny-all write: health marked UNPROTECTED (state=not-started)" \
    || bad "short deny-all write: no not-started mark"

VANISH_AFTER_START=1 run_scenario vanish "${FX}/clean.hujson" -
grep -q 'rc-service headscale stop' "${SB}/rc" 2>/dev/null && grep -q '^state=not-started$' "$(mark)" 2>/dev/null \
    && ok "policy file removed underneath after start: headscale is stopped and health marked" \
    || bad "policy file removed underneath after start: headscale left running on no checked policy"

# ── 2b. the CONFIG GATE: headscale must load the file that was checked ───────
echo "== config gate: what headscale's own config reading says it will load =="
C="${CFGX}"
expect_refused() { # <label> <reason substring> — headscale NOT started, health marked not-started
    if started; then bad "$1: headscale was STARTED ($(all_loads_safe))"
    else ok "$1: headscale is not started"; fi
    [ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 1 ] && ok "$1: provision_headscale returns 1" \
        || bad "$1: provision_headscale returned $(cat "${SB}/rc.exit" 2>/dev/null)"
    grep -q 'rc-update del headscale default' "${SB}/rc" 2>/dev/null && grep -q 'rc-service headscale stop' "${SB}/rc" 2>/dev/null \
        && ok "$1: headscale is stopped and taken out of the runlevel" || bad "$1: headscale left in the runlevel or not stopped"
    grep -q '^state=not-started$' "$(mark)" 2>/dev/null && ok "$1: health marked UNPROTECTED (state=not-started)" \
        || bad "$1: no UNPROTECTED mark with state=not-started"
    grep -q "^reason=.*$2" "$(mark)" 2>/dev/null && ok "$1: the mark says why ('$2')" \
        || bad "$1: the mark does not say '$2' (got: $(sed -n 's/^reason=//p' "$(mark)" 2>/dev/null | cut -c1-160))"
    grep -q 'ERROR: headscale policy step FAILED CLOSED' "${SB}/log" 2>/dev/null && grep -q 'failed closed' "${SB}/syslog" 2>/dev/null \
        && ok "$1: an ERROR line and a syslog line say it failed closed" || bad "$1: no ERROR/syslog line for the refusal"
    [ ! -e "${SB}/etc/headscale/config.dump.yaml" ] || [ "${3:-}" = keep-dump ] \
        && ok "$1: no configuration dump is left behind" || bad "$1: the configuration dump (a copy of the config) was left in /etc/headscale"
    if [ ! -e "${SB}/etc/headscale/config.yaml" ] && [ -f "${SB}/etc/headscale/config.yaml.refused" ]; then
        ok "$1: the refused config.yaml is set aside (config.yaml.refused): a later restart has nothing to start on"
    else bad "$1: the refused configuration is still in place as config.yaml — a later \`rc-service headscale restart\` would start headscale on it"; fi
}
expect_gate_asked() { [ -s "${SB}/dumps" ] && ok "$1: the gate asked headscale (dumpConfig)" || bad "$1: the gate never asked headscale for its config reading"; }

STICK_CFG="${C}/template-canonical.yaml" run_scenario cfg-template "${FX}/clean.hujson" "${B}"
expect_safe_start "stick config = keys-template"
expect_no_mark "stick config = keys-template"
expect_gate_asked "stick config = keys-template"
[ ! -e "${SB}/etc/headscale/config.dump.yaml" ] && ok "stick config = keys-template: the configuration dump is removed" \
    || bad "stick config = keys-template: the configuration dump (a copy of the config) was left in /etc/headscale"
[ ! -e "${SB}/chown-saw-dump" ] && ok "stick config = keys-template: the dump is gone before /etc/headscale is chowned to the daemon" \
    || bad "stick config = keys-template: the dump was still there when /etc/headscale was chowned to the daemon"

# R: the stick config points headscale at a stick acl.hujson that owns tag:superadmin,
# while the checked policy.hujson is the clean bootstrap (the refuted case: rc 0, no mark).
STICK_CFG="${C}/template-redirect.yaml" STICK_EXTRA="${FX}/owned.hujson" run_scenario cfg-redirect - "${B}"
# (Compared with and without the @@TS_SSH_USER@@ substitution, which runs only after a start.)
if cmp -s "${SB}/etc/headscale/policy.hujson" "${B}" \
   || cmp -s "${SB}/etc/headscale/policy.hujson" <(sed 's/@@TS_SSH_USER@@/superadmin/g' "${B}"); then
    ok "redirect: the checked policy.hujson is the clean bootstrap (the policy gate passes)"
else bad "redirect: the setup did not stage the bootstrap — this scenario does not model the bypass"; fi
expect_refused "stick config redirects the policy to acl.hujson" "loads its policy from .*/etc/headscale/acl.hujson"
expect_gate_asked "stick config redirects the policy"

STICK_CFG="${C}/template-nopolicy.yaml" run_scenario cfg-nopolicy "${FX}/clean.hujson" "${B}"
expect_refused "stick config names no policy (allow-all)" "no policy.path"
STICK_CFG="${C}/baked-nopolicy.yaml" run_scenario cfg-nopolicy-baked - "${B}"
expect_refused "stick copy of the baked config with no policy section" "no policy.path"
STICK_CFG="${C}/template-database.yaml" run_scenario cfg-database "${FX}/clean.hujson" "${B}"
expect_refused "stick config selects database mode" "policy.mode is database"
STICK_CFG="${C}/template-relative.yaml" run_scenario cfg-relative "${FX}/clean.hujson" "${B}"
expect_refused "stick config names a relative policy.path" "not a plain absolute path"

DUMP_FAULT=none run_scenario dump-none "${FX}/clean.hujson" "${B}"
expect_refused "dumpConfig writes nothing (and exits 0)" "wrote no configuration dump"
printf 'policy:\n    mode: file\n    path: /etc/headscale/policy.hujson\n' | sed "s#/etc/headscale#${WORK}/sb-dump-stale/etc/headscale#" > "${FX}/stale.dump"
PRE_DUMP="${FX}/stale.dump" DUMP_FAULT=none run_scenario dump-stale "${FX}/clean.hujson" "${B}"
expect_refused "a canonical-looking dump from an earlier run, dumpConfig writes nothing" "wrote no configuration dump"
PRE_DUMP_DIR=1 run_scenario dump-stuck "${FX}/clean.hujson" "${B}"
expect_refused "an old dump that cannot be removed" "could not be removed" keep-dump
[ ! -s "${SB}/dumps" ] && ok "an old dump that cannot be removed: refused before dumpConfig runs" || bad "an old dump that cannot be removed: dumpConfig still ran"

# keys-provision's own environment must not colour headscale's reading: the openrc
# service gets none of it, so a HEADSCALE_POLICY_PATH here would describe a daemon that
# does not exist.
GATE_ENV="HEADSCALE_POLICY_PATH=/etc/headscale/policy.hujson" STICK_CFG="${C}/template-redirect.yaml" STICK_EXTRA="${FX}/owned.hujson" \
    run_scenario gate-env - "${B}"
expect_refused "redirect + a HEADSCALE_POLICY_PATH in keys-provision's environment" "loads its policy from .*/etc/headscale/acl.hujson"

# OpenRC's `restart` STARTS a stopped service, and the policy-sync apply leg restarts
# headscale every time it applies a render: a later restart must not bring headscale up
# on the refused configuration.
LATER_RESTART=1 STICK_CFG="${C}/template-redirect.yaml" STICK_EXTRA="${FX}/owned.hujson" run_scenario later-restart - "${B}"
expect_refused "redirect, then a later rc-service headscale restart" "loads its policy from .*/etc/headscale/acl.hujson"
[ -s "${SB}/nostarts" ] && ok "redirect, then a later restart: that restart finds no configuration and headscale cannot start" \
    || bad "redirect, then a later restart: the later restart was not seen at all — this scenario tests nothing"
# A config.json beside the yaml is set aside too (headscale's search prefers it).
printf '{"policy": {"mode": "file", "path": "/etc/headscale/acl.hujson"}}\n' > "${FX}/config.json"
EXTRA_SRC="cp '${FX}/config.json' \"\${HSB}/etc/headscale/config.json\"" DUMP_FAULT=none LATER_RESTART=1 run_scenario json-aside "${FX}/clean.hujson" "${B}"
[ ! -e "${SB}/etc/headscale/config.json" ] && [ -f "${SB}/etc/headscale/config.json.refused" ] \
    && ok "a config.json beside the yaml is set aside as well" || bad "a config.json beside the yaml was left in place"
started && bad "json-aside: headscale was started" || ok "json-aside: headscale is not started, a later restart included"

# The CP DNS trap: the stick config's policy: block sits between the marker lines
# publish_cp_dns_record deletes between. The first gate passes (headscale reads it as
# canonical); the rewrite then leaves no policy.path, and the restart that follows it
# would run allow-all. The gate runs again before that restart.
CPDNS=1 STICK_CFG="${C}/trap-cpdns.yaml" run_scenario cpdns-trap "${FX}/clean.hujson" "${B}"
[ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 0 ] && ok "CP DNS trap: the first gate passes (headscale reads the stick config as canonical)" \
    || bad "CP DNS trap: provision_headscale already refused (rc $(cat "${SB}/rc.exit" 2>/dev/null)) — the trap does not reach the CP DNS edit"
grep -q '^policy:$' "${SB}/etc/headscale/config.yaml.refused" "${SB}/etc/headscale/config.yaml" 2>/dev/null \
    && bad "CP DNS trap: the rewrite kept the policy block — this scenario does not model the edit" \
    || ok "CP DNS trap: the CP DNS rewrite deleted the stick's policy block"
u="$(all_loads_safe)"
[ -z "${u}" ] && ok "CP DNS trap: headscale is never (re)started on the rewritten, policy-less config" \
    || bad "CP DNS trap: headscale would read an UNSAFE policy:${u}"
cpdns_restarts() { sed -n '/^--- publish_cp_dns_record$/,$p' "${SB}/rc" 2>/dev/null | grep -c 'rc-service headscale restart'; }
grep -q '^--- publish_cp_dns_record$' "${SB}/rc" 2>/dev/null && [ "$(cpdns_restarts)" = 0 ] \
    && ok "CP DNS trap: publish_cp_dns_record does not restart headscale" || bad "CP DNS trap: publish_cp_dns_record restarted headscale (or never ran)"
grep -q '^state=not-started$' "$(mark)" 2>/dev/null && grep -q '^reason=after the CP DNS record was written: .*no policy.path' "$(mark)" 2>/dev/null \
    && ok "CP DNS trap: health marked not-started, naming the CP DNS edit" || bad "CP DNS trap: no not-started mark naming the CP DNS edit ($(sed -n 's/^reason=//p' "$(mark)" 2>/dev/null | cut -c1-140))"
[ ! -e "${SB}/etc/headscale/config.yaml" ] && ok "CP DNS trap: the rewritten config is set aside" || bad "CP DNS trap: the rewritten config is still in place"
CPDNS=1 run_scenario cpdns-ok "${FX}/clean.hujson" "${B}"
[ "$(cpdns_restarts)" = 1 ] && [ ! -e "$(mark)" ] && grep -q "${CP_NAME}" "${SB}/etc/headscale/config.yaml" 2>/dev/null \
    && ok "CP DNS on the baked config: the record is written, the gate passes, headscale is restarted" \
    || bad "CP DNS on the baked config: the record/restart did not happen or a mark was left ($(sed -n 's/^reason=//p' "$(mark)" 2>/dev/null | cut -c1-140))"
expect_safe_start "CP DNS on the baked config"

# The gate examines the config.yaml headscale actually starts with: it runs after the
# server_url rewrite, not before.
ENDPOINT="http://10.9.8.7:8080" run_scenario endpoint "${FX}/clean.hujson" "${B}"
expect_safe_start "server_url rewritten before the start"
grep -q '^server_url: http://10.9.8.7:8080$' "${SB}/etc/headscale/config.yaml" && ok "endpoint: server_url was rewritten" \
    || bad "endpoint: server_url was not rewritten — this scenario does not test the ordering"
[ ! -e "${SB}/cfg-changed-after-gate" ] && ok "endpoint: headscale starts with exactly the config.yaml the gate examined" \
    || bad "endpoint: config.yaml changed between the gate and the start (the gate ran too early)"

# headscale_effective_policy_path on its own, fed dumps of every shape.
UNIT="${WORK}/unit"
unit_eff() { # <printf %b dump text> -> "<rc>|<output>[|LEFT]"
    rm -rf "${UNIT}"; mkdir -p "${UNIT}/etc/headscale"
    (
        HSB="${UNIT}"; UTEXT="$1"
        headscale() { [ "$1" = dumpConfig ] && printf '%b' "${UTEXT}" > "${HSB}/etc/headscale/config.dump.yaml"; return 0; }
        timeout() { shift; "$@"; }
        # shellcheck source=/dev/null
        . "${SRC}"
        out="$(headscale_effective_policy_path)"; rc=$?
        printf '%s|%s' "${rc}" "${out}"
        [ ! -e "${HSB}/etc/headscale/config.dump.yaml" ] || printf '|LEFT'
    ) 2>/dev/null
}
CP="${UNIT}/etc/headscale/policy.hujson"
u_ok() { # <label> <dump>
    local r; r="$(unit_eff "$2")"
    [ "${r}" = "0|${CP}" ] && ok "dump reader: $1 -> ${CP##*/}" || bad "dump reader: $1 -> '${r}' (expected 0|${CP})"
}
u_no() { # <label> <dump> <reason substring>
    local r; r="$(unit_eff "$2")"
    case "${r}" in
        *'|LEFT') bad "dump reader: $1 left the dump in place" ;;
        1\|*"$3"*) ok "dump reader: $1 refused ('$3')" ;;
        *) bad "dump reader: $1 -> '${r}' (expected a refusal saying '$3')" ;;
    esac
}
u_ok "canonical policy block" "policy:\n    mode: file\n    path: ${CP}\n"
u_ok "canonical block between other keys" "noise:\n    private_key_path: /var/lib/headscale/noise_private.key\npolicy:\n    mode: file\n    path: ${CP}\nprefixes:\n    v4: 100.64.0.0/10\n"
u_no "no path" "policy:\n    mode: file\n" "no policy.path"
u_no "database mode" "policy:\n    mode: database\n    path: ${CP}\n" "database"
u_no "mode File" "policy:\n    mode: File\n    path: ${CP}\n" "not file"
u_no "an extra member in the block" "policy:\n    mode: file\n    path: ${CP}\n    extra: x\n" "no single plain policy block"
u_no "two path lines" "policy:\n    mode: file\n    path: ${CP}\n    path: ${CP}\n" "no single plain policy block"
u_no "two policy blocks" "policy:\n    mode: file\n    path: ${CP}\npolicy:\n    mode: file\n    path: ${CP}\n" "no single plain policy block"
u_no "a second policy block with only a mode" "policy:\n    mode: file\n    path: ${CP}\npolicy:\n    mode: file\n" "no single plain policy block"
u_no "a second, case-variant policy key" "policy:\n    mode: file\n    path: ${CP}\nPolicy:\n    path: /x\n" "no single plain policy block"
u_no "policy: null" "policy: null\n" "no single plain policy block"
u_no "a block that is not go-yaml's 4-space shape" "policy:\n  mode: file\n  path: ${CP}\n" "no single plain policy block"
u_no "a quoted path" "policy:\n    mode: file\n    path: \"${CP}\"\n" "not a plain absolute path"
u_no "a path with a space" "policy:\n    mode: file\n    path: ${CP} x\n" "not a plain absolute path"
u_no "a relative path" "policy:\n    mode: file\n    path: policy.hujson\n" "not a plain absolute path"
u_no "an empty dump" "" "wrote no configuration dump"
r="$(unit_eff "policy:\n    mode: file\n    path: /etc/headscale/acl.hujson\n")"
[ "${r}" = "0|/etc/headscale/acl.hujson" ] && ok "dump reader: another plain path is reported as is (the caller compares it)" \
    || bad "dump reader: another plain path -> '${r}'"

# ── 3. NEGATIVE CONTROLS: the verdicts above can see a fail-open ─────────────
echo "== negative controls =="
EXTRA_SRC='headscale_policy_owned_security_tags() { return 0; }' run_scenario nc-noguard "${FX}/owned.hujson" -
[ -n "$(all_loads_safe)" ] && ok "control: with the production check disabled, an owned override is seen loading" \
    || bad "control: the production check was disabled and nothing was seen — the scenario verdicts are vacuous"
EXTRA_SRC='headscale_stage_deny_all_policy() { return 0; }' run_scenario nc-nodenyall - -
[ -n "$(all_loads_safe)" ] && ok "control: with the deny-all writer disabled, a start on no policy is seen" \
    || bad "control: the deny-all writer was disabled and nothing was seen"
EXTRA_SRC='headscale_stage_deny_all_policy() { return 0; }' FAIL_MV_RE='\.narrowed\.' run_scenario nc-unsafe "${FX}/owned.hujson" -
[ -n "$(all_loads_safe)" ] && ok "control: an owned policy left in place by a no-op deny-all writer is seen loading" \
    || bad "control: an owned policy left in place was not seen"
NOGATE='headscale_effective_policy_path() { echo "${HSB}/etc/headscale/policy.hujson"; }'
EXTRA_SRC="${NOGATE}" STICK_CFG="${C}/template-redirect.yaml" STICK_EXTRA="${FX}/owned.hujson" run_scenario nc-nogate-redirect - "${B}"
case "$(all_loads_safe)" in *"security tag(s) with an owner: tag:dev_abc tag:superadmin"*) ok "control: with the config gate disabled, the redirect is seen loading the stick's owned acl.hujson" ;;
    *) bad "control: config gate disabled, redirect — the owned acl.hujson was not seen loading ($(all_loads_safe))" ;; esac
EXTRA_SRC="${NOGATE}" STICK_CFG="${C}/template-nopolicy.yaml" run_scenario nc-nogate-nopolicy "${FX}/clean.hujson" "${B}"
case "$(all_loads_safe)" in *allow-all*) ok "control: with the config gate disabled, a config with no policy is seen starting allow-all" ;;
    *) bad "control: config gate disabled, no policy — the allow-all start was not seen ($(all_loads_safe))" ;; esac
EXTRA_SRC="${NOGATE}" STICK_CFG="${C}/template-database.yaml" run_scenario nc-nogate-database "${FX}/clean.hujson" "${B}"
case "$(all_loads_safe)" in *"policy.mode database"*) ok "control: with the config gate disabled, database mode is seen starting on an unchecked policy" ;;
    *) bad "control: config gate disabled, database — not seen ($(all_loads_safe))" ;; esac
EXTRA_SRC='eval "real_$(declare -f headscale_effective_policy_path)"
    headscale_effective_policy_path() { real_headscale_effective_policy_path; local r=$?; echo "# edited after the gate" >> "${HSB}/etc/headscale/config.yaml"; return $r; }' \
    run_scenario nc-late-edit "${FX}/clean.hujson" "${B}"
[ -e "${SB}/cfg-changed-after-gate" ] && ok "control: a config edit after the gate is seen (the endpoint ordering check can fail)" \
    || bad "control: a config edit after the gate was not seen — the endpoint ordering check is vacuous"
EXTRA_SRC='headscale_refuse_config() { rc-service headscale stop; rc-update del headscale default; headscale_policy_unprotected not-started "$1"; }' \
    LATER_RESTART=1 STICK_CFG="${C}/template-redirect.yaml" STICK_EXTRA="${FX}/owned.hujson" run_scenario nc-noaside - "${B}"
case "$(all_loads_safe)" in *"tag:superadmin"*) ok "control: a refusal that only stops headscale is seen starting on the refused config at the next restart" ;;
    *) bad "control: refusal without set-aside + later restart — the start on the redirect was not seen ($(all_loads_safe))" ;; esac
EXTRA_SRC='eval "first_$(declare -f headscale_config_gate)"
    headscale_config_gate() { if [ -e "${HSB}/.gated" ]; then return 0; fi; : > "${HSB}/.gated"; first_headscale_config_gate; }' \
    CPDNS=1 STICK_CFG="${C}/trap-cpdns.yaml" run_scenario nc-cpdns-nogate "${FX}/clean.hujson" "${B}"
case "$(all_loads_safe)" in *allow-all*) ok "control: without the second gate the CP DNS restart is seen bringing headscale up allow-all" ;;
    *) bad "control: CP DNS trap without the second gate — the allow-all restart was not seen ($(all_loads_safe))" ;; esac

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
