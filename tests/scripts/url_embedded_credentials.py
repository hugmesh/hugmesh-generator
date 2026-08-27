#!/usr/bin/env python3
"""Resolve every credential that gets EMBEDDED IN A URL, back to the line that mints it.

The chain, all four hops:

    <scheme>://user:$(ENV_VAR)@host        a Deployment/App manifest
      -> env ENV_VAR: secretKeyRef {name: S, key: K}
      -> ExternalSecret S: data[secretKey=K].remoteRef.property = P
      -> scripts/gen-cluster-secrets.sh:  P="${GEN_VAR}"
      -> GEN_VAR="$(<generator> N)"

Emits one TSV row per site:

    site<TAB>env<TAB>secret/key<TAB>property<TAB>genvar<TAB>generator<TAB>status

`status` is OK, or UNRESOLVED:<hop> naming the hop that broke. An unresolved hop is a
FAILURE for the caller, never a skip: a chain this guard cannot follow is a chain it
cannot vouch for, and silently dropping it is how a new URL-embedded credential would
slip in unchecked.
"""
import os
import re
import sys

# user:$(VAR)@  or  user:${VAR}@ inside a URL with a scheme
URL_CRED = re.compile(
    r'(?P<scheme>[a-z][a-z0-9+.-]*):(?://|[a-z]+://)?[^\s"\']*?'
    r'//(?P<user>[A-Za-z_][A-Za-z0-9_]*):\$[{(](?P<var>[A-Za-z_][A-Za-z0-9_]*)[})]@')

SECRET_REF = re.compile(
    r'-\s*name:\s*(?P<env>[A-Za-z_][A-Za-z0-9_]*)\s*\n'
    r'\s*valueFrom:\s*\n'
    r'\s*secretKeyRef:\s*\n'
    r'(?:\s*name:\s*(?P<name>\S+)\s*\n\s*key:\s*(?P<key>\S+)|'
    r'\s*key:\s*(?P<key2>\S+)\s*\n\s*name:\s*(?P<name2>\S+))')

# remoteRef appears in BOTH spellings in this tree — flow ({ key: .., property: .. })
# and block (key:/property: on their own lines). A resolver that knows only one
# reports the other as unresolvable.
REMOTE_REF = re.compile(
    r'-\s*secretKey:\s*(?P<sk>\S+)\s*\n'
    r'\s*remoteRef:\s*(?:'
    r'\{[^}]*?key:\s*(?P<vp>[A-Za-z0-9_./-]+)[^}]*?property:\s*(?P<prop>[A-Za-z0-9_.-]+)'
    r'|\n(?:\s*key:\s*(?P<vp2>[A-Za-z0-9_./-]+)\s*\n)?\s*property:\s*(?P<prop2>[A-Za-z0-9_.-]+)'
    r')')

# The SAME reference written in YAML flow style, all on one line:
#   - { name: X, valueFrom: { secretKeyRef: { name: S, key: K } } }
# Both spellings are in use in this tree, and a resolver that knows only the block
# form silently reports the flow-form sites as unresolvable — which, if the caller
# treated unresolved as "skip", would hide exactly the credentials it exists to check.
SECRET_REF_FLOW = re.compile(
    r'-\s*\{\s*name:\s*(?P<env>[A-Za-z_][A-Za-z0-9_]*)\s*,\s*valueFrom:\s*\{\s*'
    r'secretKeyRef:\s*\{\s*(?:name:\s*(?P<name>[^,}\s]+)\s*,\s*key:\s*(?P<key>[^,}\s]+)'
    r'|key:\s*(?P<key2>[^,}\s]+)\s*,\s*name:\s*(?P<name2>[^,}\s]+))')

GEN_ASSIGN = re.compile(r'(?m)^\s*(?P<var>[A-Z_][A-Z0-9_]*)="\$\((?P<fn>[a-z_]+)\s')


def walk(root, *rels):
    for rel in rels:
        base = os.path.join(root, rel)
        for dirpath, _dirs, files in os.walk(base):
            for fn in files:
                if fn.endswith(('.yaml', '.yml')):
                    yield os.path.join(dirpath, fn)


def main(root):
    gen_path = os.path.join(root, 'scripts', 'gen-cluster-secrets.sh')
    try:
        gen = open(gen_path, encoding='utf-8').read()
    except OSError as e:
        print(f"FATAL\tcannot read scripts/gen-cluster-secrets.sh ({e})", file=sys.stderr)
        return 2

    # property -> GEN_VAR, from `prop="${GEN_VAR}"` (shell) and `"prop": os.environ[...]`
    # PATH-QUALIFIED first: `vault kv put "<mount>/<base>/<path>"` followed by
    # `prop="${VAR}"` continuation lines. Property names like `password` repeat across
    # vault paths, so the path is what makes the mapping unique. Only where the path
    # cannot be determined do we fall back to the name-only map below, and that map
    # REFUSES to answer when a name has more than one candidate.
    pathprop_to_var = {}
    for blk in re.finditer(r'vault kv put "[^"]*/(?P<path>[A-Za-z0-9_.-]+)"((?:\s*\\\s*\n\s*[a-z0-9_]+="\$\{[A-Z_][A-Z0-9_]*\}")+)',
                           gen):
        for pm in re.finditer(r'([a-z0-9_]+)="\$\{([A-Z_][A-Z0-9_]*)\}"', blk.group(2)):
            pathprop_to_var[(blk.group('path'), pm.group(1))] = pm.group(2)

    prop_candidates = {}
    for m in re.finditer(r'(?m)^\s*([a-z0-9_]+)="\$\{([A-Z_][A-Z0-9_]*)\}"', gen):
        prop_candidates.setdefault(m.group(1), set()).add(m.group(2))
    for m in re.finditer(r'"([a-z0-9_]+)"\s*:\s*os\.environ\["([A-Z_][A-Z0-9_]*)"\]', gen):
        prop_candidates.setdefault(m.group(1), set()).add(m.group(2))
    prop_to_var = {k: next(iter(v)) for k, v in prop_candidates.items() if len(v) == 1}
    ambiguous = {k for k, v in prop_candidates.items() if len(v) > 1}

    # GEN_VAR -> generator function
    var_to_fn = {m.group('var'): m.group('fn') for m in GEN_ASSIGN.finditer(gen)}

    # every ExternalSecret's (name, secretKey) -> vault property
    es_prop = {}
    for path in walk(root, os.path.join('specs', 'cluster')):
        try:
            text = open(path, encoding='utf-8').read()
        except OSError:
            continue
        for doc in text.split('\n---'):
            if 'kind: ExternalSecret' not in doc:
                continue
            tm = re.search(r'target:\s*\n\s*name:\s*(\S+)', doc)
            nm = re.search(r'(?m)^metadata:\s*\n(?:\s+.*\n)*?\s*name:\s*(\S+)', doc)
            names = {n.group(1) for n in (tm, nm) if n}
            for rm in REMOTE_REF.finditer(doc):
                for n in names:
                    es_prop[(n, rm.group('sk'))] = ((rm.group('vp') or rm.group('vp2') or '').rsplit('/', 1)[-1],
                                                   rm.group('prop') or rm.group('prop2'))

    rows = []
    for path in walk(root, os.path.join('specs', 'cluster')):
        try:
            text = open(path, encoding='utf-8').read()
        except OSError:
            continue
        refs = {}
        for rx in (SECRET_REF, SECRET_REF_FLOW):
            for m in rx.finditer(text):
                refs[m.group('env')] = (m.group('name') or m.group('name2'),
                                        m.group('key') or m.group('key2'))
        for m in URL_CRED.finditer(text):
            line = text[:m.start()].count('\n') + 1
            site = f"{os.path.relpath(path, root)}:{line}"
            var = m.group('var')
            ref = refs.get(var)
            if not ref:
                rows.append((site, var, '-', '-', '-', '-', 'UNRESOLVED:secretKeyRef'))
                continue
            prop = es_prop.get(ref)
            if not prop:
                rows.append((site, var, '/'.join(ref), '-', '-', '-', 'UNRESOLVED:ExternalSecret'))
                continue
            vpath, prop = prop
            gvar = pathprop_to_var.get((vpath, prop)) or prop_to_var.get(prop)
            if not gvar:
                why = ('UNRESOLVED:ambiguous-property' if prop in ambiguous
                       else 'UNRESOLVED:generator-var')
                rows.append((site, var, '/'.join(ref), prop, '-', '-', why))
                continue
            fn = var_to_fn.get(gvar)
            if not fn:
                rows.append((site, var, '/'.join(ref), prop, gvar, '-', 'UNRESOLVED:generator-call'))
                continue
            rows.append((site, var, '/'.join(ref), prop, gvar, fn, 'OK'))

    for r in sorted(set(rows)):
        print('\t'.join(r))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else '.'))
