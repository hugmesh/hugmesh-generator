#!/usr/bin/env python3
"""Every LOCAL helper a spec/step file USES must be IMPORTED by that file.

WHY THIS EXISTS (hugmesh-generator#305). specs/15-rbac-per-realm-login.spec.ts
called ``loginPassword()`` in a default parameter but imported ``sharedPassword``
instead. TypeScript is not compiled in the e2e lane — Playwright transpiles each
module per-file and never resolves cross-file names — so the file loaded fine and
died at CALL time with ``ReferenceError: loginPassword is not defined``. Spec 15
had therefore not run a single assertion since 2026-08-27.

Nothing in the suite could see it:

  * ``playwright test --list`` imports every module, but a default parameter is
    evaluated at CALL time, so --list never touches the bad expression. The
    enumeration guard (test-e2e-enumeration-without-credentials.sh) is green on
    the exact tree carrying the bug — measured, see that issue.
  * there is no ``tsconfig.json`` under tests/e2e and no typecheck in CI, so
    ``tsc``'s TS2304 never ran.
  * a grep for the name finds it — in the file that is missing its import.

THE CHECK. Build the universe of names exported by the LOCAL modules under
tests/e2e/{specs,steps} (helpers.ts, rbac-roles.ts, federation.ts, ...). Those
names are distinctive project vocabulary. For every .ts file in that tree, any
bare use of such a name must be satisfied by an import in THAT file or by a
declaration in THAT file. A name that is neither is an undefined reference — the
#305 shape — and is reported as ``file:line: name``.

DELIBERATE SCOPE. This is not a typechecker and does not pretend to be. It
answers one decidable question with no toolchain: is this project symbol bound in
this file at all? It is a floor under the lane, not a replacement for ``tsc``.
Run it with no arguments from the repo root, or pass the e2e root as argv[1].
Exit 0 = clean; exit 1 = offenders printed on stdout; exit 2 = the scan itself
could not run (a vacuous pass is a failure here, not a pass).
"""
from __future__ import annotations

import os
import re
import sys

# Identifiers that are ambient in this runtime or supplied by the test framework,
# and so are never "missing" even when a local module happens to export the name.
AMBIENT = {
    'process', 'console', 'Buffer', 'require', 'module', 'exports', 'global',
    'globalThis', '__dirname', '__filename', 'URL', 'URLSearchParams', 'fetch',
    'test', 'expect', 'request', 'page', 'describe', 'it', 'beforeAll',
    'afterAll', 'beforeEach', 'afterEach',
}

IDENT = re.compile(r'[A-Za-z_$][A-Za-z0-9_$]*')

# `/` after one of these is a REGEX literal, not division. Standard heuristic;
# getting it wrong only mis-blanks a literal, which can add a false positive, so
# the battery in the shell guard re-measures the clean tree every run.
REGEX_PRECEDERS = set('(,=:[!&|?{};+-*%~^<>')
REGEX_KEYWORDS = {'return', 'typeof', 'instanceof', 'in', 'of', 'case', 'do',
                  'else', 'yield', 'await', 'void', 'delete', 'new'}


def blank_noncode(src: str) -> str:
    """Replace comments and string-literal TEXT with spaces, preserving offsets.

    Template-literal ``${...}`` substitutions are CODE and are kept: a use inside
    one is a real use. Newlines are preserved so line numbers stay exact.
    """
    out = list(src)
    n = len(src)
    i = 0
    # Stack of open template literals, so ${ } nesting is tracked correctly.
    tmpl_depth: list[int] = []
    brace_depth = 0

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '

    def prev_significant(idx: int) -> str:
        k = idx - 1
        while k >= 0 and src[k] in ' \t\n\r':
            k -= 1
        return src[k] if k >= 0 else ''

    def prev_word(idx: int) -> str:
        k = idx - 1
        while k >= 0 and src[k] in ' \t\n\r':
            k -= 1
        end = k + 1
        while k >= 0 and (src[k].isalnum() or src[k] in '_$'):
            k -= 1
        return src[k + 1:end]

    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j == -1 else j
            blank(i, j)
            i = j
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j == -1 else j + 2
            blank(i, j)
            i = j
            continue
        if c == '/':
            p = prev_significant(i)
            w = prev_word(i)
            if p in REGEX_PRECEDERS or w in REGEX_KEYWORDS or p == '':
                j = i + 1
                in_class = False
                while j < n:
                    d = src[j]
                    if d == '\\':
                        j += 2
                        continue
                    if d == '\n':
                        break  # unterminated: not a regex after all
                    if d == '[':
                        in_class = True
                    elif d == ']':
                        in_class = False
                    elif d == '/' and not in_class:
                        j += 1
                        break
                    j += 1
                blank(i, j)
                i = j
                continue
        if c in ('"', "'"):
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == c or src[j] == '\n':
                    j += 1
                    break
                j += 1
            blank(i, j)
            i = j
            continue
        if c == '`':
            tmpl_depth.append(brace_depth)
            i += 1
            # Blank literal text up to the next ${ or the closing backtick.
            start = i
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '`':
                    blank(start, i)
                    tmpl_depth.pop()
                    i += 1
                    start = None
                    break
                if src[i] == '$' and i + 1 < n and src[i + 1] == '{':
                    blank(start, i)
                    # Leave ${ ... } as code; walk it with brace counting.
                    depth = 0
                    i += 1  # at '{'
                    while i < n:
                        if src[i] == '{':
                            depth += 1
                        elif src[i] == '}':
                            depth -= 1
                            if depth == 0:
                                i += 1
                                break
                        elif src[i] in ('"', "'", '`'):
                            # Nested literal inside a substitution: recurse the
                            # cheap way by blanking to its close.
                            q = src[i]
                            j = i + 1
                            while j < n and src[j] != q:
                                if src[j] == '\\':
                                    j += 1
                                j += 1
                            blank(i, min(j + 1, n))
                            i = min(j + 1, n)
                            continue
                        i += 1
                    start = i
                    continue
                i += 1
            if start is not None and i >= n:
                blank(start, n)
            continue
        i += 1
    return ''.join(out)


def exported_names(code: str) -> set[str]:
    names: set[str] = set()
    for m in re.finditer(
            r'^\s*export\s+(?:async\s+)?(?:function|const|let|var|class|interface|type|enum)\s+'
            r'([A-Za-z_$][A-Za-z0-9_$]*)', code, re.M):
        names.add(m.group(1))
    # `export { a, b as c };` — the EXPORTED spelling is what importers write.
    for m in re.finditer(r'^\s*export\s*\{([^}]*)\}', code, re.M):
        for part in m.group(1).split(','):
            part = part.strip()
            if not part:
                continue
            bits = re.split(r'\s+as\s+', part)
            leaf = bits[-1].strip()
            if IDENT.fullmatch(leaf):
                names.add(leaf)
    return names


def imported_names(code: str) -> set[str]:
    names: set[str] = set()
    # `export { X } from './y';` re-exports X: the module system binds it, so a
    # later bare mention in the same file is not an undefined reference.
    for m in re.finditer(r'\bexport\s*\{([^}]*)\}\s*from\b', code, re.S):
        for part in m.group(1).split(','):
            leaf = re.split(r'\s+as\s+', part.strip())[-1].strip()
            if IDENT.fullmatch(leaf):
                names.add(leaf)
    for m in re.finditer(r'\bimport\s+(?:type\s+)?([^;]*?)\bfrom\b', code, re.S):
        clause = m.group(1)
        braced = re.search(r'\{(.*)\}', clause, re.S)
        if braced:
            for part in braced.group(1).split(','):
                part = part.strip()
                if not part:
                    continue
                part = re.sub(r'^type\s+', '', part)
                leaf = re.split(r'\s+as\s+', part)[-1].strip()
                if IDENT.fullmatch(leaf):
                    names.add(leaf)
            clause = clause[:braced.start()] + clause[braced.end():]
        for m2 in re.finditer(r'\*\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)', clause):
            names.add(m2.group(1))
        clause = re.sub(r'\*\s+as\s+[A-Za-z_$][A-Za-z0-9_$]*', '', clause)
        for part in clause.split(','):
            part = part.strip()
            if IDENT.fullmatch(part):
                names.add(part)
    return names


def declared_names(code: str) -> set[str]:
    """Names bound anywhere in the file: declarations, params, catch, for-of.

    Deliberately over-broad. A missed binding would be a FALSE POSITIVE, which
    this guard must never produce; an extra binding only narrows what it can see,
    and the #305 shape (a name bound NOWHERE in the file) survives that.
    """
    names: set[str] = set()
    for m in re.finditer(
            r'\b(?:function|class|interface|type|enum|const|let|var)\s+'
            r'([A-Za-z_$][A-Za-z0-9_$]*)', code):
        names.add(m.group(1))
    # Destructuring binds: const { a, b: c } = ... / const [x, y] = ...
    for m in re.finditer(r'\b(?:const|let|var)\s*[\{\[]([^\}\]]*)[\}\]]', code):
        for ident in IDENT.findall(m.group(1)):
            names.add(ident)
    # Every parenthesised group: function params, arrow params, catch(e).
    # Over-broad on purpose (see the docstring): a call's ARGUMENTS also land
    # here, which is exactly why a use must ALSO appear outside every paren to
    # be reportable. The caller handles that; this set is the safety net.
    for m in re.finditer(r'\bcatch\s*\(\s*([A-Za-z_$][A-Za-z0-9_$]*)', code):
        names.add(m.group(1))
    for m in re.finditer(r'\bfor\s*\(\s*(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)', code):
        names.add(m.group(1))
    # Labelled/declared function parameters: `(a, b = 1, { c }: T) =>` and
    # `function f(a: T, b?: U)`. Take the parameter list of declared functions.
    for m in re.finditer(r'\bfunction\s*[A-Za-z0-9_$]*\s*\(([^)]*)\)', code):
        for part in m.group(1).split(','):
            lead = IDENT.match(part.strip().lstrip('{[.'))
            if lead:
                names.add(lead.group(0))
    for m in re.finditer(r'\(([^()]*)\)\s*(?::[^=;{]*)?=>', code):
        for part in m.group(1).split(','):
            lead = IDENT.match(part.strip().lstrip('{[.'))
            if lead:
                names.add(lead.group(0))
    return names


def uses(code: str, vocabulary: set[str]) -> dict[str, int]:
    """First line on which each vocabulary name is used as a bare identifier."""
    found: dict[str, int] = {}
    for m in IDENT.finditer(code):
        name = m.group(0)
        if name not in vocabulary:
            continue
        s, e = m.span()
        before = code[:s].rstrip()
        if before.endswith('.') or before.endswith('?.'):
            continue  # property access
        after = code[e:].lstrip()
        if after.startswith('?'):
            after = after[1:].lstrip()   # `member?: T` in an interface
        if after.startswith(':') and not after.startswith('::'):
            # DECLARATION position, not a use: an object-literal key, or a
            # member of an `interface`/type literal. The separator before it is
            # `{`, `,`, `;` or a bare newline — never the `=`/`(`/operator that
            # precedes a real expression, and never the `=` of the #305 shape
            # (`password = loginPassword()`), so this cannot mask that defect.
            if before == '' or before[-1] in '{,;':
                continue
        if before.endswith('as') and re.search(r'\bas\s*$', before):
            continue  # `import { x as name }` was already stripped, but be safe
        line = code.count('\n', 0, s) + 1
        found.setdefault(name, line)
    return found


def main(argv: list[str]) -> int:
    root = argv[1] if len(argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'e2e')
    root = os.path.abspath(root)
    files: list[str] = []
    for sub in ('specs', 'steps'):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for dirpath, _dirs, names in os.walk(d):
            if 'node_modules' in dirpath:
                continue
            for nm in sorted(names):
                if nm.endswith('.ts') and not nm.endswith('.d.ts'):
                    files.append(os.path.join(dirpath, nm))
    files.sort()
    if len(files) < 20:
        print(f'SCAN-FAILED: only {len(files)} .ts file(s) under {root}/'
              '{specs,steps} — expected 20+; refusing to report a vacuous pass',
              file=sys.stderr)
        return 2

    code: dict[str, str] = {}
    vocabulary: set[str] = set()
    for f in files:
        with open(f, 'r', encoding='utf-8', errors='replace') as fh:
            src = fh.read()
        code[f] = blank_noncode(src)
        vocabulary |= exported_names(code[f])
    vocabulary -= AMBIENT
    if len(vocabulary) < 20:
        print(f'SCAN-FAILED: local export vocabulary is only {len(vocabulary)} '
              'name(s) — the export scan found nothing to check', file=sys.stderr)
        return 2

    offenders: list[str] = []
    for f in files:
        c = code[f]
        bound = imported_names(c) | declared_names(c) | AMBIENT
        for name, line in sorted(uses(c, vocabulary).items(), key=lambda kv: kv[1]):
            if name in bound:
                continue
            rel = os.path.relpath(f, root)
            offenders.append(f'{rel}:{line}: {name} is used but never imported '
                             f'or declared in this file')
    for o in offenders:
        print(o)
    if offenders:
        return 1
    print(f'clean: {len(files)} file(s), {len(vocabulary)} local export name(s) '
          'checked, every use is bound', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
