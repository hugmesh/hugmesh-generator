#!/usr/bin/env python3
"""shell_published_ports.py — a shell script that starts a container must publish its ports on
loopback only.

The compose scanner (compose_published_ports.py) reads compose files. This reads the OTHER place a
port gets published: `docker|podman run -p HOST:CONTAINER ...` in a shell script. A bare
`-p HOST:CONTAINER` binds 0.0.0.0 (and [::]), so a test that starts a throwaway Casdoor with its upstream
factory admin (tests/casdoor/test-jwt-custom-token.sh did, hugmesh-generator#1033) answers on every
interface of the machine for the length of the run, and for as long as a crash leaves it behind, although
the script itself only ever talks to 127.0.0.1.

RULES (the compose scanner's, reused: judge_host_ip / split_publish are imported from it)
  1. A published port names a host IP: "HOST_IP:HOST:CONTAINER" or "HOST_IP::CONTAINER" (a random host
     port). "HOST:CONTAINER" and a bare "CONTAINER" are findings.
  2. The host IP is loopback BY DEFAULT: a literal 127.x.x.x / [::1], or ${VAR:-<loopback>}.
  3. -P / --publish-all publishes every exposed port on every interface: always a finding.
Only the part of a line AFTER `docker|podman|$RT ... run|create` is read, so `mkdir -p`, `ssh -p` and the
like never count. Continuation lines (backslash-newline) are joined and comments dropped. Python 3 stdlib.

Exit 0 clean, 1 findings (file:line: why), 2 usage. --count appends "published=N findings=F" so the
caller can refuse a vacuous pass.
"""
import importlib.util
import os
import re
import shlex
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("compose_published_ports",
                                               os.path.join(_HERE, "compose_published_ports.py"))
_cpp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cpp)

# The runtime word: docker, podman, or the variable a script keeps it in.
RUN_RE = re.compile(
    r"(?:\bdocker|\bpodman|\$\{?(?:RT|RUNTIME|CONTAINER_RT|CRT|DOCKER|PODMAN)\}?)"
    r"(?:\s+(?:-{1,2}[A-Za-z][\w-]*(?:[= ]\S+)?))*\s+(?:container\s+)?(?:run|create)\b")
# What a -p value looks like (a port spec), as opposed to `mkdir -p dir` handed to the container.
SPEC_RE = re.compile(r"^(?:\[[0-9A-Fa-f:.]*\]|[0-9.]+|\$\{[^}]*\}|[0-9]*)?(?::(?:[0-9]*|\$\{[^}]*\}))*"
                     r"(?:-[0-9]+)?(?:/(?:tcp|udp|sctp))?$")


def logical_lines(text):
    out, buf, start = [], "", 0
    for n, raw in enumerate(text.splitlines(), 1):
        if not buf:
            start = n
        line = raw.rstrip("\n")
        if line.endswith("\\") and not line.endswith("\\\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        out.append((start, buf))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def tokens(segment):
    try:
        return shlex.split(segment, comments=False, posix=True)
    except ValueError:
        # An unbalanced quote (the segment ends inside `CID="$(docker run ... )" || {`): split on blanks
        # and drop the quote characters, so a quoted -p value is still read rather than silently skipped.
        return [t.strip("\"'") for t in segment.split()]


def judge_value(value):
    """'' when the publish names a loopback-default host IP, else why not."""
    parts = _cpp.split_publish(value)
    if parts is None:
        return f"'{value}' cannot be read"
    if len(parts) < 3:
        return f"'{value}' names no host IP (binds every interface)"
    return _cpp.judge_host_ip(parts[0])


def scan_text(text, label):
    findings, published = [], 0
    for lineno, line in logical_lines(text):
        code = _cpp.strip_comment(line)
        m = RUN_RE.search(code)
        if not m:
            continue
        toks = tokens(code[m.end():])
        i = 0
        while i < len(toks):
            t = toks[i]
            value = None
            if t in ("-p", "--publish"):
                value = toks[i + 1] if i + 1 < len(toks) else ""
                i += 1
            elif t.startswith("--publish="):
                value = t.split("=", 1)[1]
            elif t.startswith("-p=") or (t.startswith("-p") and len(t) > 2 and SPEC_RE.match(t[2:])):
                value = t[3:] if t.startswith("-p=") else t[2:]
            elif t in ("-P", "--publish-all"):
                findings.append(f"{label}:{lineno}: {t} publishes every exposed port on every interface")
            if value is not None and SPEC_RE.match(value):
                published += 1
                why = judge_value(value)
                if why:
                    findings.append(f"{label}:{lineno}: -p {value}: {why}")
            i += 1
    return findings, published


def main(argv):
    count = "--count" in argv
    specs = [a for a in argv if a != "--count"]
    if not specs:
        print("usage: shell_published_ports.py [--count] FILE[=LABEL] ...", file=sys.stderr)
        return 2
    findings, published = [], 0
    for spec in specs:
        path, _, label = spec.partition("=")
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as e:
            findings.append(f"{label or path}: unreadable ({e})")
            continue
        f, p = scan_text(text, label or path)
        findings += f
        published += p
    for f in findings:
        print(f)
    if count:
        print(f"published={published} findings={len(findings)}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
