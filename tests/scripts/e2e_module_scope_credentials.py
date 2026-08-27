#!/usr/bin/env python3
"""Find MODULE-SCOPE credential resolution in the e2e specs/steps.

A credential resolved at module scope fires at IMPORT time, which breaks
`playwright test --list` — enumeration starts no browser and contacts nothing,
so it must work with nothing seeded.

Catches two shapes:
  direct       const X = sharedPassword();
  indirection  const r = () => sharedPassword();   // module scope
               const X = r();                      // module scope

Module scope == column 0. An indented call sits inside a function, a getter or a
default parameter, all of which resolve at CALL time, which is exactly what we want.

Prints one offender per line as `path:line:text`; exit 0 always — the caller
decides the verdict, and also enforces the vacuity floor (this file cannot know
how many files SHOULD have been scanned).
"""
import re
import sys

# loginPassword() is the LAZY accessor, but assigning it to a module-scope const
# re-eagerises it, so it belongs here too.
CRED = r'(?:sharedPassword|passwordFor|swarmPassword|loginPassword)'

# const X = <cred>(...)      /  let X = ...  /  export const X = ...
DIRECT = re.compile(r'^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*' + CRED + r'\s*\(')
# const f = (...) => ... <cred>(...)   — a module-scope arrow that resolves one
ARROW = re.compile(r'^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>.*' + CRED + r'\s*\(')
# function f(...) { ... }  — captured by name; body scanned separately
FUNC_OPEN = re.compile(r'^(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(')
CRED_CALL = re.compile(CRED + r'\s*\(')


def resolvers(lines):
    """Module-scope names that, when CALLED, resolve a credential."""
    names = set()
    for i, ln in enumerate(lines):
        m = ARROW.match(ln)
        if m:
            names.add(m.group(1))
            continue
        m = FUNC_OPEN.match(ln)
        if m:
            # scan the body to its closing column-0 brace
            for body in lines[i + 1:]:
                if body.startswith('}'):
                    break
                if CRED_CALL.search(body):
                    names.add(m.group(1))
                    break
    return names


def scan(path):
    try:
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out = []
    known = resolvers(lines)
    indirect = (re.compile(r'^(?:export\s+)?(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=\s*(' +
                           '|'.join(re.escape(n) for n in sorted(known)) + r')\s*\(')
                if known else None)
    for n, ln in enumerate(lines, 1):
        if DIRECT.match(ln):
            out.append((path, n, ln.strip(), 'direct'))
        elif indirect and indirect.match(ln):
            out.append((path, n, ln.strip(), 'via a module-scope resolver'))
    return out


def main(argv):
    hits = []
    for p in argv[1:]:
        hits.extend(scan(p))
    for path, n, text, how in hits:
        print(f"{path}:{n}:{how}:{text}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
