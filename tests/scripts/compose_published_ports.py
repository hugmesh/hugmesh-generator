#!/usr/bin/env python3
"""compose_published_ports.py — every host port the local stack publishes must name a
host IP, and an identity provider or homeserver may only default to loopback.

Used by tests/scripts/test-stack-idp-exposure.sh over tests/stack/compose*.yaml plus the
Studio's generated own-Casdoor overlay (NEW-15). Until 2026-11-11 the local mesh
published Casdoor (:8000), tuwunel (:8008) and Mastodon (:3000/:4000) on EVERY host
interface while Casdoor's built-in admin kept the upstream factory-default password, so
any machine on the LAN could sign in to the mesh's identity provider as its admin. A
short-syntax publish with no host IP binds 0.0.0.0 (and [::]).

RULES
  1. DEFAULT DENY. Every published port names a host IP: "HOST_IP:HOST:CONTAINER".
     The only exceptions are the platform's own front doors in DOORS below, each with
     its reason; a DOORS entry that no longer publishes a bare port fails as stale, so
     the list cannot rot into a blanket exemption.
  2. The host IP is loopback BY DEFAULT: a literal 127.x.x.x / [::1], or
     ${VAR:-<loopback>} (an explicit opt-in such as STACK_BIND_ADDR=0.0.0.0 is the
     operator's choice; a FILE default of 0.0.0.0 or ${VAR} with no default is not).
  3. An identity provider or homeserver (IDP_IMAGE / IDP_SERVICE below) may never be a
     DOORS exception.
  4. FAIL CLOSED on a shape this line reader cannot judge (long-syntax ports, an entry
     it cannot split), never skip it.
Python 3 stdlib only, no PyYAML (the pre-merge job's image has none): it reads lines.

Exit 0 clean, 1 findings (file:line: service: why), 2 usage. --count prints a summary
line "published=N idp=K findings=F doors_stale=..." so the caller can refuse a vacuous
pass.
"""
import re
import sys

# (compose file basename, service) -> why this door may listen on every interface.
DOORS = {
    ("compose.local.yaml", "hugmesh-fe-gateway"):
        "the platform's front door (PUBLIC_HOST_PORT): the only HTTP entry the LAN is meant to use",
    ("compose.local.yaml", "hugmesh-https-front"):
        "the front door's TLS twin (PUBLIC_HTTPS_PORT), proxying to the same fe-gateway",
    ("compose.local.yaml", "hugmesh-anubis"):
        "the proof-of-work gate in front of the same front door (ANUBIS=1)",
}

# Images and service names that are an identity provider or a homeserver/fediverse
# server: an admin API behind them is a takeover of the mesh, so never a DOORS entry.
IDP_IMAGE = re.compile(
    r"(casbin/casdoor|tuwunel|conduwuit|conduit|synapse|dendrite|mastodon|akkoma|pleroma"
    r"|keycloak|authentik|zitadel|dexidp|ory/(kratos|hydra))", re.I)
IDP_SERVICE = re.compile(r"^(casdoor[a-z0-9-]*|tuwunel|mastodon-[a-z]+|akkoma|phpbb)$", re.I)

LOOPBACK_LITERAL = re.compile(r"^(127(\.\d{1,3}){3}|\[::1\]|::1)$")
VAR_DEFAULT = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-)([^}]*)\}$")
VAR_ANY = re.compile(r"\$\{[^}]*\}")
SERVICE_RE = re.compile(r"^  ([A-Za-z0-9._-]+):\s*(#.*)?$")
IMAGE_RE = re.compile(r"^    image:\s*[\"']?([^\"'\s#]+)")
PORTS_RE = re.compile(r"^    ports:\s*(?:!\w+\s*)?(.*)$")


def strip_comment(line):
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def split_flow(s):
    """Items of a one-line flow list "[a, "b", 'c']" (no nesting in a ports list)."""
    s = s.strip()
    if not (s.startswith("[") and s.endswith("]")):
        return None
    body = s[1:-1]
    items, cur, q, depth = [], "", None, 0
    for ch in body:
        if q:
            cur += ch
            if ch == q:
                q = None
            continue
        if ch in "\"'":
            q = ch
            cur += ch
        elif ch == "{":
            depth += 1
            cur += ch
        elif ch == "}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


def split_publish(entry):
    """'IP:HOST:CTR' -> parts, honouring ${...} and [v6] (both may hold ':')."""
    parts, cur, i = [], "", 0
    while i < len(entry):
        if entry.startswith("${", i):
            j = entry.find("}", i)
            if j < 0:
                return None
            cur += entry[i:j + 1]
            i = j + 1
            continue
        if entry[i] == "[":
            j = entry.find("]", i)
            if j < 0:
                return None
            cur += entry[i:j + 1]
            i = j + 1
            continue
        if entry[i] == ":":
            parts.append(cur)
            cur = ""
        else:
            cur += entry[i]
        i += 1
    parts.append(cur)
    return parts


def judge_host_ip(ip):
    """'' when the host IP defaults to loopback, else why it does not."""
    if LOOPBACK_LITERAL.match(ip):
        return ""
    m = VAR_DEFAULT.match(ip)
    if m:
        default = m.group(3)
        if LOOPBACK_LITERAL.match(default):
            return ""
        if default == "":
            return f"host IP {ip} has an EMPTY default (compose then binds every interface)"
        return f"host IP {ip} defaults to {default}, not loopback"
    if VAR_ANY.fullmatch(ip):
        return f"host IP {ip} has no loopback default (unset, compose binds every interface)"
    return f"host IP {ip} is not loopback"


def scan_file(path, label):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        return [f"{label}: unreadable ({e})"], [], 0, 0
    findings, door_hits, published, idp = [], [], 0, 0
    svc, svc_image, in_services = None, "", False
    # collect (lineno, service, entry) first; the image may follow the ports block
    entries = []
    images = {}
    ports_open, ports_indent = False, 0
    for n, raw in enumerate(lines, 1):
        line = strip_comment(raw).rstrip()
        if not line.strip():
            continue
        if re.match(r"^\S", line):
            in_services = line.startswith("services:")
            svc, ports_open = None, False
            continue
        if not in_services:
            continue
        m = SERVICE_RE.match(line)
        if m:
            svc, ports_open = m.group(1), False
            continue
        if svc is None:
            continue
        m = IMAGE_RE.match(line)
        if m:
            images[svc] = m.group(1)
        indent = len(line) - len(line.lstrip(" "))
        if ports_open:
            if indent <= ports_indent:
                ports_open = False
            else:
                item = line.strip()
                if item.startswith("- "):
                    val = item[2:].strip()
                    if re.match(r"^[A-Za-z_]+\s*:", val):
                        findings.append(f"{label}:{n}: {svc}: long-syntax port entry; "
                                        "this guard reads the short form only — write "
                                        "\"HOST_IP:HOST:CONTAINER\"")
                        continue
                    entries.append((n, svc, unquote(val)))
                elif re.match(r"^[A-Za-z_]+\s*:", item):
                    continue  # a key of a long-syntax mapping already reported
                else:
                    findings.append(f"{label}:{n}: {svc}: unrecognised line inside ports:")
                continue
        m = PORTS_RE.match(line)
        if m and indent == 4:
            rest = m.group(1).strip()
            if rest:
                items = split_flow(rest)
                if items is None:
                    findings.append(f"{label}:{n}: {svc}: ports: value is not a one-line list")
                    continue
                for it in items:
                    entries.append((n, svc, unquote(it)))
            else:
                ports_open, ports_indent = True, 4
    for n, s, entry in entries:
        published += 1
        image = images.get(s, "")
        is_idp = bool(IDP_IMAGE.search(image) or IDP_SERVICE.match(s))
        if is_idp:
            idp += 1
        parts = split_publish(entry)
        if parts is None or not 1 <= len(parts) <= 3:
            findings.append(f"{label}:{n}: {s}: cannot split port entry {entry!r}")
            continue
        door = (label.rsplit("/", 1)[-1], s)
        if len(parts) < 3:
            if door in DOORS and not is_idp:
                door_hits.append(door)
                continue
            why = "an identity provider, homeserver or social server: " if is_idp else ""
            findings.append(f"{label}:{n}: {s}: {why}port {entry!r} names no host IP "
                            "(compose binds every interface); write "
                            "\"${STACK_BIND_ADDR:-127.0.0.1}:HOST:CONTAINER\"")
            continue
        why = judge_host_ip(parts[0])
        if why:
            findings.append(f"{label}:{n}: {s}: port {entry!r}: {why}")
    return findings, door_hits, published, idp


def main(argv):
    count = False
    if argv and argv[0] == "--count":
        count, argv = True, argv[1:]
    if not argv:
        print("usage: compose_published_ports.py [--count] FILE[=LABEL]...", file=sys.stderr)
        return 2
    findings, hits, published, idp = [], set(), 0, 0
    for a in argv:
        path, _, label = a.partition("=")
        f, d, p, k = scan_file(path, label or path)
        findings += f
        hits.update(d)
        published += p
        idp += k
    for f in findings:
        print(f)
    stale = sorted(f"{a}:{b}" for (a, b) in set(DOORS) - hits)
    if count:
        print(f"published={published} idp={idp} findings={len(findings)} "
              f"doors_stale={','.join(stale)}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
