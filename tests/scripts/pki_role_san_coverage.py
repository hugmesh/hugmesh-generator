#!/usr/bin/env python3
"""Vault-PKI issuance simulator: would every requested cert actually be issued?

Usage: pki_role_san_coverage.py <path-to-specs/cluster>
Exit 0 = every check passed. Exit 1 = at least one check failed. Exit 2 = usage.

Driven by tests/scripts/test-pki-role-san-coverage.sh, which re-runs each check
against deliberately-corrupted copies of the tree (negative controls) so a green
run cannot be vacuous.

WHY THIS EXISTS
---------------
manifests/vault-pki/pki-init-configmap.yaml writes the issuing roles.
manifests/**/…-externalsecrets.yaml ask those roles for concrete certs. NOTHING
compared the two sides, and they had silently diverged: the roles allowed
`svc.cluster.local` + allow_subdomains (i.e. *.svc.cluster.local ONLY) while
every ESO generator also asks for the TWO-LABEL `<service>.<namespace>` SAN. On
a live kind cluster ESO logged, for every generic-loop app:

    could not generate [0]: Error making API request.
    URL: PUT https://vault.../v1/pki_int/issue/hugmesh-user-bff-api
    Code: 400. Errors:
    * subject alternate name hugmesh-user-bff-api.hugmesh-backend not allowed by this role

So no app could ever be issued its mTLS cert, no keystore initContainer got
material, and the whole fleet mTLS story was dead on arrival. The existing
[pki-roles] check in cluster_manifest_integrity.py proves the ROLE EXISTS; it
says nothing about whether the role would accept the names asked of it. Two
roles (media-poisoner, harbor) had already been hand-patched around exactly this
failure without anyone fixing the loop — twice hit, twice papered over.

WHAT IT CHECKS
--------------
[pki-san-coverage]   For EVERY VaultDynamicSecret in the tree, every requested
                     common_name and alt_names entry is run through a faithful
                     port of Vault's own name validator against the params its
                     role is actually created with. Any pair that would 400 is
                     reported with the exact Vault error text.
[pki-san-containment] The mirror image, and the reason a "just widen it" repair
                     cannot pass: no role may issue a name belonging to ANOTHER
                     workload. Re-adding a blanket `svc.cluster.local`,
                     `${DOMAIN}` or allow_any_name to make coverage green
                     immediately fails here instead.
[pki-role-posture]   Per-role flag posture that a blanket cannot hide behind:
                     allow_any_name off, allow_localhost off (Vault DEFAULTS it
                     ON), non-empty allowed_domains, and the SAN classes a
                     generator can ask for (ip_sans / uri_sans / other_sans)
                     matched against the flags that would accept them.

THE MATCHER IS A PORT, NOT AN APPROXIMATION
-------------------------------------------
Ported from hashicorp/vault builtin/logical/pki/issuing/issue_common.go
(ValidateNames) as of 2026-08, including the parts that are easy to get wrong:
  * allow_bare_domains  -> strings.EqualFold(name, entry)      exact, case-insens.
  * allow_subdomains    -> strings.HasSuffix(reduced, "."+entry)  ANY prefix depth,
                           and CASE-SENSITIVE (Go uses HasSuffix, not EqualFold)
  * allow_glob_domains  -> only fires when the ENTRY contains '*', then
                           ryanuber/go-glob semantics, where '*' spans dots
  * allow_localhost     -> checked BEFORE allowed_domains, DEFAULT true
  * allow_any_name      -> short-circuits allowed_domains entirely
  * enforce_hostnames   -> Vault's wildHostnameRegex, DEFAULT true
Role parameter defaults are Vault's, not zero values: allow_localhost,
allow_ip_sans, allow_wildcard_certificates, enforce_hostnames and require_cn all
default TRUE when the role does not set them.

Deliberately dependency-light: PyYAML + bash only, so it runs in the
`python:3-slim` CI image with no cluster, no kubectl, no vault and no network.
The role parameters are obtained by EXECUTING the ConfigMap's real init-pki.sh
under a vault stub — a regex cannot tell what `${entry%%:*}` expands to, which is
the same reason the sibling [pki-roles] check executes it too.
"""
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict

import yaml

# Roles a VaultDynamicSecret references that vault-pki-init KNOWINGLY does not
# create yet. Kept in lockstep with PKI_ROLES_KNOWN_UNPROVISIONED in
# cluster_manifest_integrity.py, which is the check that owns "the role must
# exist"; here they are SKIPPED (and counted) because there is no role to
# simulate against — not because their names are approved.
PKI_ROLES_KNOWN_UNPROVISIONED = {
    "meshbridge-client",   # manifests/external-secrets/meshbridge-externalsecrets.yaml
    "cassandra",           # manifests/cassandra-hardening (ships dark, Stage 2)
}

# Names a role may legitimately issue that are NOT its own workload identity.
# Empty on purpose: every shared/foreign name granted here is a cross-issuance
# capability someone has to justify in review. Keyed "<role>:<name>".
CROSS_ISSUANCE_ALLOW = set()

# The minimum shape of the contract. If the tree ever presents fewer than this,
# the gate has stopped seeing the thing it exists to check and must say so
# rather than print a green "0 problems".
MIN_ROLES = 20
MIN_REQUESTS = 20

# ── Vault role parameter defaults (builtin/logical/pki/path_roles.go) ────────
# NOT zero values. A role that omits allow_localhost gets `localhost` issuance
# for free, which is why the simulator must model the real defaults.
ROLE_BOOL_DEFAULTS = {
    "allow_localhost": True,
    "allow_bare_domains": False,
    "allow_subdomains": False,
    "allow_glob_domains": False,
    "allow_any_name": False,
    "allow_ip_sans": True,
    "allow_wildcard_certificates": True,
    "allow_token_displayname": False,
    "enforce_hostnames": True,
    "require_cn": True,
}

# issue_common.go: labelPattern / leftWildLabelPattern / hostnamePattern /
# wildHostnamePattern, transcribed verbatim.
_LABEL = r"([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])"
_LEFT_WILD_LABEL = r"(\*|\*%s|%s\*|%s\*%s)" % (_LABEL, _LABEL, _LABEL, _LABEL)
_HOSTNAME = r"(%s\.)*%s\.?$" % (_LABEL, _LABEL)
WILD_HOSTNAME_RE = re.compile(r"^(%s\.)?%s" % (_LEFT_WILD_LABEL, _HOSTNAME))

failures = []
notes = []


def fail(check, msg):
    failures.append((check, msg))


def ok(check, msg):
    notes.append((check, msg))


# ── go-glob port (github.com/ryanuber/go-glob, the package Vault imports) ────
def go_glob(pattern, subj):
    """`*` matches any run of characters INCLUDING dots — not fnmatch."""
    if pattern == "":
        return subj == pattern
    if pattern == "*":
        return True
    parts = pattern.split("*")
    if len(parts) == 1:
        return subj == pattern
    leading = pattern.startswith("*")
    trailing = pattern.endswith("*")
    end = len(parts) - 1
    for i in range(end):
        idx = subj.find(parts[i])
        if i == 0:
            if not leading and idx != 0:
                return False
        elif idx < 0:
            return False
        if idx < 0:
            return False
        subj = subj[idx + len(parts[i]):]
    return trailing or subj.endswith(parts[end])


def _validate_wildcard_domain(name):
    """Port of ValidateWildcardDomain -> (wildcard_label, reduced) or None."""
    if name.count("*") > 1:
        return None
    split = name.split(".", 1)
    if len(split) != 2 or "*" not in split[0]:
        return None
    return split[0], split[1]


def name_allowed(name, role):
    """Port of issuing.ValidateNames for ONE name. -> (bool, why-not str)."""
    reduced = name
    email_domain = name
    wildcard_label = ""
    is_email = False
    is_wildcard = False

    if "@" in reduced:
        parts = reduced.split("@")
        if len(parts) != 2:
            return False, "malformed email-style name"
        reduced = email_domain = parts[1]
        is_email = True

    if "*" in reduced:
        is_wildcard = True
        if not role["allow_wildcard_certificates"]:
            return False, "contains a wildcard and allow_wildcard_certificates=false"
        split = _validate_wildcard_domain(reduced)
        if split is None:
            return False, "malformed wildcard domain"
        wildcard_label, reduced = split

    if is_email and is_wildcard:
        return False, "wildcard in an email-style name"

    if role["enforce_hostnames"] and reduced:
        converted = (wildcard_label + "." + reduced) if is_wildcard else reduced
        if not WILD_HOSTNAME_RE.match(converted):
            return False, "not a valid hostname and enforce_hostnames=true"

    if role["allow_any_name"]:
        return True, ""

    if role["allow_localhost"]:
        if reduced in ("localhost", "localdomain") or \
           (is_email and email_domain in ("localhost", "localdomain")):
            return True, ""
        if role["allow_subdomains"]:
            if reduced.endswith(".localhost") or (is_wildcard and reduced == "localhost"):
                return True, ""
            if reduced.endswith(".localdomain") or (is_wildcard and reduced == "localdomain"):
                return True, ""

    for entry in role["allowed_domains"]:
        if entry == "":
            continue
        # 1) exact match on the full name (case-insensitive)
        if role["allow_bare_domains"] and (
                name.lower() == entry.lower() or
                (is_email and email_domain.lower() == entry.lower())):
            return True, ""
        # 2) any-depth suffix match (Go uses HasSuffix: CASE-SENSITIVE)
        if role["allow_subdomains"]:
            if reduced.endswith("." + entry) or (is_wildcard and reduced.lower() == entry.lower()):
                return True, ""
        # 3) glob, and ONLY when the entry itself carries a '*'
        if role["allow_glob_domains"] and "*" in entry and \
                go_glob(entry.lower(), name.lower()):
            return True, ""

    return False, "no allowed_domains entry matches under the role's flags"


# ── side 1: the roles vault-pki-init really creates, with their real params ──
VAULT_STUB = r"""
set -u
vault() {
  case "${1:-}" in
    status) return 0 ;;
    secrets) echo '{"pki_int/":{}}' ; return 0 ;;
    read)
      case "$*" in
        *-field=certificate*) echo "STUBCERT" ;;
      esac
      return 0 ;;
    write)
      case "${2:-}" in
        */roles/*)
          printf 'ROLE\t%s\n' "${2##*/roles/}" >> "$ROLE_OUT"
          shift 2
          for kv in "$@"; do printf 'ARG\t%s\n' "$kv" >> "$ROLE_OUT"; done
          ;;
      esac
      return 0 ;;
  esac
  return 0
}
sleep() { return 0; }
export -f vault 2>/dev/null || true
. "$SCRIPT_PATH"
"""


def _as_bool(value, default):
    if value is None:
        return default
    return str(value).strip().lower() in ("1", "t", "true", "y", "yes", "on")


def load_roles(root):
    """-> ({role: params}, error-or-None). Params are Vault-normalised."""
    cm = os.path.join(root, "manifests", "vault-pki", "pki-init-configmap.yaml")
    if not os.path.exists(cm):
        return {}, "missing %s" % cm
    try:
        script = yaml.safe_load(open(cm, encoding="utf-8"))["data"]["init-pki.sh"]
    except Exception as exc:
        return {}, "could not extract init-pki.sh from the ConfigMap: %s" % exc

    with tempfile.TemporaryDirectory() as td:
        sp = os.path.join(td, "init-pki.sh")
        ro = os.path.join(td, "roles.txt")
        open(sp, "w", encoding="utf-8").write(script)
        open(ro, "w").close()
        env = dict(os.environ, SCRIPT_PATH=sp, ROLE_OUT=ro)
        proc = subprocess.run(["bash", "-c", VAULT_STUB], env=env,
                              capture_output=True, text=True, timeout=120)
        lines = open(ro, encoding="utf-8").read().splitlines()

    roles = {}
    current = None
    raw = defaultdict(dict)
    order = []
    for line in lines:
        kind, _, rest = line.partition("\t")
        if kind == "ROLE":
            current = rest.strip()
            order.append(current)
            raw.setdefault(current, {})
        elif kind == "ARG" and current is not None:
            key, _, value = rest.partition("=")
            raw[current][key.strip()] = value
    if not order:
        return {}, ("executing init-pki.sh under a vault stub created ZERO issuing "
                    "roles (stderr: %s)" % proc.stderr.strip()[:300])

    for role in order:
        params = raw[role]
        # allowed_domains is TypeCommaStringSlice: the CLI splits on commas.
        domains = [d.strip() for d in (params.get("allowed_domains") or "").split(",")]
        entry = {"allowed_domains": [d for d in domains if d],
                 "_raw": dict(params)}
        for key, default in ROLE_BOOL_DEFAULTS.items():
            entry[key] = _as_bool(params.get(key), default)
        roles[role] = entry
    return roles, None


# ── side 2: what every VaultDynamicSecret actually asks pki_int to issue ─────
def yaml_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        if os.sep + "charts" + os.sep in dirpath + os.sep and "templates" in dirpath.split(os.sep):
            continue
        for name in sorted(filenames):
            if name.endswith((".yaml", ".yml")):
                yield os.path.join(dirpath, name)


def load_requests(root):
    """-> [ {role, rel, ns, cn, dns[], ip[], uri[], other[]} ] over the whole tree."""
    out = []
    for path in yaml_files(root):
        rel = os.path.relpath(path, root)
        try:
            docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8"))
                    if isinstance(d, dict)]
        except Exception:
            continue        # [yaml-parse] in the sibling gate owns unparseable files
        for d in docs:
            if d.get("kind") != "VaultDynamicSecret":
                continue
            spec = d.get("spec") or {}
            p = str(spec.get("path") or "")
            if not p.startswith("pki_int/issue/"):
                continue
            params = spec.get("parameters") or {}

            def listed(key):
                v = params.get(key)
                if v is None:
                    return []
                if isinstance(v, (list, tuple)):
                    items = [str(x) for x in v]
                else:
                    items = str(v).split(",")
                return [i.strip() for i in items if i.strip()]

            out.append({
                "role": p.split("/", 2)[2],
                "rel": rel,
                "ns": (d.get("metadata") or {}).get("namespace"),
                "name": (d.get("metadata") or {}).get("name"),
                "cn": (str(params["common_name"]).strip()
                       if params.get("common_name") is not None else None),
                "dns": listed("alt_names"),
                "ip": listed("ip_sans"),
                "uri": listed("uri_sans"),
                "other": listed("other_sans"),
            })
    return out


def _flags(role):
    return "allowed_domains=%s bare=%s sub=%s glob=%s any=%s" % (
        role["allowed_domains"], role["allow_bare_domains"], role["allow_subdomains"],
        role["allow_glob_domains"], role["allow_any_name"])


# ── check A: every requested name would actually be issued ──────────────────
def check_coverage(roles, requests):
    checked = skipped = bad = 0
    for req in requests:
        role = roles.get(req["role"])
        if role is None:
            if req["role"] in PKI_ROLES_KNOWN_UNPROVISIONED:
                skipped += 1
                continue
            bad += 1
            fail("[pki-san-coverage]",
                 "%s (ns %s) requests pki_int/issue/%s but vault-pki-init creates no such "
                 "role — nothing to validate its names against, and the Secret can never "
                 "materialize" % (req["rel"], req["ns"], req["role"]))
            continue

        if req["cn"] is None:
            if role["require_cn"]:
                bad += 1
                fail("[pki-san-coverage]",
                     "%s (role %s) sets no common_name and the role keeps require_cn=true — "
                     "Vault rejects the issue call outright"
                     % (req["rel"], req["role"]))
        else:
            checked += 1
            good, why = name_allowed(req["cn"], role)
            if not good:
                bad += 1
                fail("[pki-san-coverage]",
                     "role %s (%s, ns %s) requests common_name %r which the role does NOT "
                     "permit (%s; %s). Vault answers: Code: 400. Errors: * common name %s "
                     "not allowed by this role — ESO never materializes the Secret and the "
                     "keystore initContainer never gets material."
                     % (req["role"], req["rel"], req["ns"], req["cn"], why, _flags(role), req["cn"]))

        for san in req["dns"]:
            checked += 1
            good, why = name_allowed(san, role)
            if not good:
                bad += 1
                fail("[pki-san-coverage]",
                     "role %s (%s, ns %s) requests alt_names entry %r which the role does "
                     "NOT permit (%s; %s). Vault answers: Code: 400. Errors: * subject "
                     "alternate name %s not allowed by this role — ESO never materializes "
                     "the Secret and the keystore initContainer never gets material."
                     % (req["role"], req["rel"], req["ns"], san, why, _flags(role), san))

        for kind, key, flag in (("ip_sans", "ip", "allow_ip_sans"),
                                ("uri_sans", "uri", None),
                                ("other_sans", "other", None)):
            values = req[key]
            if not values:
                continue
            checked += len(values)
            if flag is not None and not role[flag]:
                bad += 1
                fail("[pki-san-coverage]",
                     "role %s (%s) requests %s=%s but the role sets %s=false — Vault "
                     "rejects the issue call" % (req["role"], req["rel"], kind, values, flag))
            if kind == "uri_sans" and not role["_raw"].get("allowed_uri_sans"):
                bad += 1
                fail("[pki-san-coverage]",
                     "role %s (%s) requests uri_sans=%s but the role sets no allowed_uri_sans "
                     "— Vault rejects every URI SAN" % (req["role"], req["rel"], values))
            if kind == "other_sans" and not role["_raw"].get("allowed_other_sans"):
                bad += 1
                fail("[pki-san-coverage]",
                     "role %s (%s) requests other_sans=%s but the role sets no "
                     "allowed_other_sans — Vault rejects every other SAN"
                     % (req["role"], req["rel"], values))

    if checked < MIN_REQUESTS:
        fail("[pki-san-coverage]",
             "only %d requested name(s) were simulated (expected at least %d). The gate has "
             "lost sight of the manifests it exists to check — a green result here would be "
             "vacuous." % (checked, MIN_REQUESTS))
    elif not bad:
        ok("[pki-san-coverage]",
           "all %d requested CN/SAN name(s) across %d VaultDynamicSecret(s) would be issued "
           "by the role they target (%d known-unprovisioned role reference(s) skipped)"
           % (checked, len(requests) - skipped, skipped))


# ── check B: a role may not mint another workload's identity ────────────────
def check_containment(roles, requests):
    identity = defaultdict(set)
    for req in requests:
        for name in ([req["cn"]] if req["cn"] else []) + req["dns"]:
            identity[req["role"]].add(name)
    if len(identity) < 2:
        fail("[pki-san-containment]",
             "fewer than two distinct roles carry requested names (%d) — cross-issuance "
             "cannot be tested and a green result would be vacuous" % len(identity))
        return

    bad = 0
    pairs = 0
    reported = 0
    for role_name, role in sorted(roles.items()):
        own = identity.get(role_name, set())
        foreign = set()
        for other, names in identity.items():
            if other != role_name:
                foreign |= names
        for name in sorted(foreign - own):
            if "%s:%s" % (role_name, name) in CROSS_ISSUANCE_ALLOW:
                continue
            pairs += 1
            good, _why = name_allowed(name, role)
            if not good:
                continue
            bad += 1
            owners = sorted(r for r, n in identity.items() if name in n)
            if reported < 12:
                reported += 1
                fail("[pki-san-containment]",
                     "role %s would happily issue %r — an identity belonging to %s. A cert "
                     "for that name off the SAME cluster CA passes every peer's hostname "
                     "check, so this role can impersonate it. (%s)"
                     % (role_name, name, "/".join(owners), _flags(role)))
    if bad > reported:
        fail("[pki-san-containment]",
             "... and %d further (role, foreign-name) pair(s) not listed. A blanket "
             "allowed_domains entry (`svc.cluster.local`, the cluster domain) or "
             "allow_any_name grants the whole cross-product at once."
             % (bad - reported))
    if not bad:
        ok("[pki-san-containment]",
           "no role can issue any of the %d foreign (role, name) pair(s) tested — each "
           "issuing role is confined to its own workload identity" % pairs)


# ── check C: per-role flag posture ──────────────────────────────────────────
def check_posture(roles):
    bad = 0
    for role_name, role in sorted(roles.items()):
        problems = []
        if role["allow_any_name"]:
            problems.append("allow_any_name=true — allowed_domains is bypassed entirely "
                            "and the role can mint a cert for ANY name off the cluster CA")
        if role["allow_localhost"]:
            problems.append("allow_localhost is on (Vault DEFAULTS it to TRUE, so an "
                            "unset role gets it) — `localhost`/`localdomain` certs are "
                            "issuable independent of allowed_domains")
        if not role["allowed_domains"]:
            problems.append("allowed_domains is empty, which in Vault means the "
                            "allowed_domains gate is SKIPPED, not that nothing matches")
        if role["allow_ip_sans"]:
            problems.append("allow_ip_sans is on (Vault default) — any IP SAN is accepted "
                            "with NO authorization check")
        if problems:
            bad += 1
            fail("[pki-role-posture]",
                 "issuing role %s: %s" % (role_name, "; ".join(problems)))
    if len(roles) < MIN_ROLES:
        fail("[pki-role-posture]",
             "vault-pki-init creates only %d issuing role(s) (expected at least %d) — the "
             "gate is not seeing the real loop and a green result would be vacuous"
             % (len(roles), MIN_ROLES))
    elif not bad:
        ok("[pki-role-posture]",
           "all %d issuing roles keep allow_any_name/allow_localhost/allow_ip_sans off and "
           "carry a non-empty allowed_domains" % len(roles))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    if not os.path.isdir(root):
        print("no such tree: %s" % root)
        return 2

    roles, err = load_roles(root)
    if err:
        fail("[pki-role-load]", err)
        print("  FAIL %-24s %s" % failures[0])
        print()
        print("== 0 checks passed, 1 findings ==")
        return 1
    requests = load_requests(root)

    check_coverage(roles, requests)
    check_containment(roles, requests)
    check_posture(roles)

    for check, msg in notes:
        print("  PASS %-24s %s" % (check, msg))
    for check, msg in failures:
        print("  FAIL %-24s %s" % (check, msg))
    print()
    print("== %d checks passed, %d findings ==" % (len(notes), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
