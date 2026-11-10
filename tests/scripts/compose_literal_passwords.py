#!/usr/bin/env python3
"""compose_literal_passwords.py — find literal password values in compose files.

Used by tests/scripts/test-compose-no-literal-passwords.sh over
tests/stack/compose*.yaml (hugmesh-generator#857). A password in those files must
come from the environment (tests/stack/.env, written by
tests/stack/gen-stack-db-env.sh), never from the file. Python 3 stdlib only, no
PyYAML (the pre-merge job's image has none), so it reads LINES, and it reads every
line, including block-scalar command bodies, so a `PGPASSWORD=x psql ...` inside a
one-shot's command is caught too.

What counts as a password field (case-insensitive name containing PASS, PASSWD or
PWD):
  * a mapping entry, block or flow style:   POSTGRES_PASSWORD: x  /  { DB_PASS: x }
  * a shell / env-list / libpq assignment:  - POSTGRES_PASSWORD=x  /  password=x
  * URL userinfo:                           r2dbc:postgresql://user:x@host
What is allowed as its value: nothing at all, or ONLY compose/shell references with
no literal fallback: ${VAR:?msg}, ${VAR?msg}, ${VAR}, ${VAR:-}, ${VAR-}, ${VAR:+x}
(a set/unset sentinel that never carries the value), $${VAR}, $$VAR, $VAR. A
${VAR:-something} default IS a literal: the file then supplies the password
whenever the variable is unset, which is exactly the defect.

Exit 0 clean, 1 findings (each printed as file:line: field — the VALUE is never
printed), 2 usage. `--count` prints how many password fields were checked, so the
caller can refuse a vacuous pass.
"""
import re
import sys

# Fields whose NAME matches the password pattern but which are not credentials.
# Each entry needs a reason; the caller fails if an entry no longer occurs (so the
# list cannot rot into a blanket exemption).
ALLOW_NAMES = {
    # A feature flag (true/false) for user-bff's anonymous forgot-password flow.
    "CASDOOR_PASSWORD_RESET_ENABLED": "boolean feature flag, not a credential",
}

NAME = r"[A-Za-z0-9_.-]*(?:PASS|PWD)[A-Za-z0-9_.-]*"
REF = re.compile(
    r"\$\$\{[A-Za-z_][A-Za-z0-9_]*\}"            # $${VAR}  (shell, escaped for compose)
    r"|\$\$[A-Za-z_][A-Za-z0-9_]*"               # $$VAR
    r"|\$\{[A-Za-z_][A-Za-z0-9_]*(?::?\?[^}]*|:?\+[^}]*|:?-)?\}"  # ${VAR...} no default
    r"|\$[A-Za-z_][A-Za-z0-9_]*"                 # $VAR (shell inside a command)
)
# A value: a quoted string, or a run of ${...} groups and characters up to a flow
# separator. Used for mapping entries. TOK and the character classes beside it are
# DISJOINT (a `$` is consumed only by TOK), so no input can be split two ways and
# the match stays linear (CodeQL py/redos flagged the overlapping first version).
TOK = r"\$\{[^}]*\}|\$(?!\{)"
MAP_VALUE = r"(\"(?:[^\"\\]|\\.)*\"|'[^']*'|(?:" + TOK + r"|[^,}\s#$])(?:" + TOK + r"|[^,}#$])*)?"
MAP_RE = re.compile(r"(?<![A-Za-z0-9_.$-])[\"']?(" + NAME + r")[\"']?\s*:(?:\s+|$)" + MAP_VALUE, re.I)
ASSIGN_RE = re.compile(r"(?<![A-Za-z0-9_.$-])(" + NAME + r")=(\"(?:[^\"\\]|\\.)*\"|'[^']*'|(?:" + TOK + r"|[^\s\"'$])*)", re.I)
URL_RE = re.compile(r"://([^/\s:@\"']+):((?:" + TOK + r"|[^@\s/\"'$])+)@")


def strip_comment(line):
    """Drop a YAML comment: '#' at line start or after whitespace, outside quotes."""
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


def is_literal(value):
    v = (value or "").strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    rest = REF.sub("", v).strip()
    # A value that is only ${...} references (and the quotes/whitespace around
    # them) carries no literal.
    return rest != ""


def scan(paths):
    findings, checked, allow_seen = [], 0, set()
    for path in paths:
        try:
            lines = open(path, encoding="utf-8").read().splitlines()
        except OSError as e:
            findings.append(f"{path}: unreadable ({e})")
            continue
        for n, raw in enumerate(lines, 1):
            line = strip_comment(raw)
            if not line.strip():
                continue
            hits = []
            for m in MAP_RE.finditer(line):
                hits.append(("mapping", m.group(1), m.group(2) or ""))
            for m in ASSIGN_RE.finditer(line):
                hits.append(("assignment", m.group(1), m.group(2) or ""))
            for m in URL_RE.finditer(line):
                hits.append(("url-userinfo", f"{m.group(1)}:<password>@", m.group(2)))
            for kind, name, value in hits:
                if name.upper() in ALLOW_NAMES:
                    allow_seen.add(name.upper())
                    continue
                checked += 1
                if is_literal(value):
                    findings.append(f"{path}:{n}: literal password in {kind} {name}")
    return findings, checked, allow_seen


def main(argv):
    count = False
    if argv and argv[0] == "--count":
        count, argv = True, argv[1:]
    if not argv:
        print("usage: compose_literal_passwords.py [--count] FILE...", file=sys.stderr)
        return 2
    findings, checked, allow_seen = scan(argv)
    for f in findings:
        print(f)
    stale = sorted(set(ALLOW_NAMES) - allow_seen)
    if count:
        print(f"checked={checked} findings={len(findings)} allow_stale={','.join(stale)}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
