# shellcheck shell=bash
# ════════════════════════════════════════════════════════════════════════════════
# Shared reader for specs/cluster/egress-vpn-secret-contract.env and for the
# contract COPIES carried in the manifests. Sourced by
# tests/egress-vpn/test-secret-contract.sh and
# tests/egress-vpn/test-vpn-secret-projector.sh, so both compare against the same
# parse. Lives under lib/ so the CI job's `for t in tests/egress-vpn/*.sh` glob
# does not try to execute it as a test.
#
# DELIBERATELY DEPENDENCY-FREE: grep + sed only. The projector suite's other half
# needs python3 + PyYAML to lift the loop body out of the DaemonSet and SKIPs
# without it; the contract assertions must NEVER be able to skip, because a
# skipped contract assertion is precisely how two halves of this feature merged
# green while disagreeing.
#
# The manifest reader accepts ONE shape — the canonical single-line
#   - { name: NAME,   value: "VALUE" }
# — and hard-FAILS on anything else (zero matches, two matches, block style).
# That is on purpose: a reader that quietly copes with a reformat is a reader
# that can quietly stop reading.
# ════════════════════════════════════════════════════════════════════════════════

# contract_path <repo-root>  -> absolute path of the contract file
contract_path() { printf '%s\n' "$1/specs/cluster/egress-vpn-secret-contract.env"; }

# contract_get <contract-file> <KEY> -> value on stdout; rc!=0 (with a reason on
# stderr) when the key is absent, empty or declared more than once.
contract_get() {
    local file="$1" key="$2" hits val
    if [ ! -f "${file}" ]; then
        echo "contract file missing: ${file}" >&2; return 2
    fi
    hits="$(grep -cE "^${key}=" "${file}" 2>/dev/null || true)"
    if [ "${hits}" != "1" ]; then
        echo "contract key ${key} declared ${hits} times in ${file} (want exactly 1)" >&2
        return 2
    fi
    val="$(sed -n -E "s/^${key}=(.*)\$/\1/p" "${file}")"
    if [ -z "${val}" ]; then
        echo "contract key ${key} is empty in ${file}" >&2; return 2
    fi
    printf '%s\n' "${val}"
}

# manifest_env <yaml-file> <ENV_NAME> -> the value of the canonical one-line
# `- { name: ENV_NAME, value: "VALUE" }` entry; rc!=0 when it is not present
# exactly once in that exact shape.
manifest_env() {
    local file="$1" name="$2" re hits val
    if [ ! -f "${file}" ]; then
        echo "manifest missing: ${file}" >&2; return 2
    fi
    re="^[[:space:]]*-[[:space:]]*\{[[:space:]]*name:[[:space:]]*${name}[[:space:]]*,[[:space:]]*value:[[:space:]]*\"[^\"]*\"[[:space:]]*\}[[:space:]]*\$"
    hits="$(grep -cE "${re}" "${file}" 2>/dev/null || true)"
    if [ "${hits}" != "1" ]; then
        echo "env ${name} appears ${hits} times in ${file} as a canonical single-line" \
             "\`- { name: ${name}, value: \"...\" }\` entry (want exactly 1)" >&2
        return 2
    fi
    val="$(grep -E "${re}" "${file}" | sed -n -E "s/.*value:[[:space:]]*\"([^\"]*)\".*/\1/p")"
    printf '%s\n' "${val}"
}

# registry_field <optional-services.yaml> <slug> <field> -> the scalar value of
# `<field>:` INSIDE that slug's `- slug: <slug>` block; rc!=0 when the block or
# the field is not present exactly once.
#
# Block-scoped ON PURPOSE. A file-wide `grep secretKey:` would read whichever
# slug happened to declare one first, so a second node slug growing its own
# delivery contract would silently grade egress-vpn's copy — the "each side
# asserts only its own constants" mistake wearing a different hat. Surrounding
# quotes are stripped: `secretKey: "@name"` MUST be quoted in YAML (`@` is a
# reserved indicator and cannot start a plain scalar — YAML 1.2.2 §5.3), and the
# contract file, being an env file, spells the same value bare.
registry_field() {
    local file="$1" slug="$2" field="$3" block hits val
    if [ ! -f "${file}" ]; then
        echo "registry missing: ${file}" >&2; return 2
    fi
    block="$(awk -v s="${slug}" '
        /^[[:space:]]*-[[:space:]]*slug:[[:space:]]*/ {
            v=$0; sub(/^[[:space:]]*-[[:space:]]*slug:[[:space:]]*/,"",v); sub(/[[:space:]]*$/,"",v)
            inblk = (v == s); next
        }
        inblk { print }
    ' "${file}")"
    if [ -z "${block}" ]; then
        echo "registry ${file} has no '- slug: ${slug}' block" >&2; return 2
    fi
    hits="$(printf '%s\n' "${block}" | grep -cE "^[[:space:]]*${field}:[[:space:]]*[^[:space:]]" || true)"
    if [ "${hits}" != "1" ]; then
        echo "field ${field} appears ${hits} times in the ${slug} block of ${file} (want exactly 1)" >&2
        return 2
    fi
    val="$(printf '%s\n' "${block}" | sed -n -E "s/^[[:space:]]*${field}:[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\1/p")"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s\n' "${val}"
}
