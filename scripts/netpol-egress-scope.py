#!/usr/bin/env python3
"""netpol-egress-scope.py - carve ONE namespace's egress policies out of tier-egress.yaml.

WHY THIS EXISTS. specs/cluster/manifests/networkpolicy-egress/kustomization.yaml
used to say "uncomment `- ../networkpolicy/tier-egress.yaml`". That line cannot
render: kustomize's default load restrictor refuses a file outside the
kustomization's own directory, so the manual-sync Application fails with

    security; file '.../networkpolicy/tier-egress.yaml' is not in or below
    '.../networkpolicy-egress'

(reproduced with `kubectl kustomize`; nothing in this tree sets ArgoCD's
kustomize.buildOptions to lift it). It would also have been wrong even if it
rendered, because the file carries all five tiers at once and the cutover must be
ONE namespace at a time, `devops` last. Both problems have one fix: a scoped copy
of the namespace's policies INSIDE the overlay directory, which this script makes.

It is READ-ONLY with respect to the tree except for the file(s) it writes into
--out, and it never edits kustomization.yaml: listing the file under `resources:`
is the deliberate act an operator performs (docs/DB-HARDENING-RUNBOOK.md, part C).

USAGE
  scripts/netpol-egress-scope.py --list
  scripts/netpol-egress-scope.py NAMESPACE [--with-db-egress] [--out DIR] [--src DIR]

  --list             print every namespace that has a policy in tier-egress.yaml
  NAMESPACE          hugmesh-games | hugmesh-frontend | hugmesh-backend |
                     hugmesh-pki | devops  (whatever --list prints)
  --with-db-egress   also carve the DNS-only per-DB-pod locks for that namespace
                     out of db-egress.yaml (backend: five, pki: one; others: none)
  --out DIR          default specs/cluster/manifests/networkpolicy-egress
  --src DIR          default specs/cluster/manifests/networkpolicy

EXIT 0 ok, 2 usage / unknown namespace / source not as expected.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_SRC = os.path.join(REPO, "specs", "cluster", "manifests", "networkpolicy")
DEFAULT_OUT = os.path.join(REPO, "specs", "cluster", "manifests", "networkpolicy-egress")


def split_docs(text):
    """Split on `---` separator lines, keeping each document's own comments."""
    docs, cur = [], []
    for line in text.splitlines():
        if re.match(r"^---\s*$", line):
            docs.append("\n".join(cur))
            cur = []
        else:
            cur.append(line)
    docs.append("\n".join(cur))
    return docs


def identity(doc):
    """(kind, name, namespace) read from the non-comment lines of one document."""
    live = [l for l in doc.splitlines() if not l.lstrip().startswith("#")]
    body = "\n".join(live)
    kind = re.search(r"^kind:\s*(\S+)", body, re.M)
    meta = re.search(r"^metadata:\s*\n((?:[ \t]+.*\n?)+)", body, re.M)
    name = ns = None
    if meta:
        n = re.search(r"^[ ]{2}name:\s*(\S+)", meta.group(1), re.M)
        s = re.search(r"^[ ]{2}namespace:\s*(\S+)", meta.group(1), re.M)
        name = n.group(1) if n else None
        ns = s.group(1) if s else None
    return (kind.group(1) if kind else None, name, ns)


def load(path):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        sys.stderr.write("cannot read %s: %s\n" % (path, e))
        sys.exit(2)
    out = []
    for d in split_docs(text):
        k, n, s = identity(d)
        if k is None:
            continue  # a comment-only tail
        if k != "NetworkPolicy" or not n or not s:
            sys.stderr.write("%s: a document is not a namespaced NetworkPolicy (%r, %r, %r)\n" % (path, k, n, s))
            sys.exit(2)
        out.append((n, s, d))
    return out


def main(argv):
    src, out = DEFAULT_SRC, DEFAULT_OUT
    with_db, want, listing = False, None, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(__doc__)
            return 0
        if a == "--list":
            listing = True
        elif a == "--with-db-egress":
            with_db = True
        elif a in ("--out", "--src"):
            if i + 1 >= len(argv):
                sys.stderr.write("%s needs a directory\n" % a)
                return 2
            if a == "--out":
                out = argv[i + 1]
            else:
                src = argv[i + 1]
            i += 1
        elif a.startswith("-"):
            sys.stderr.write("unknown argument: %s\n" % a)
            return 2
        elif want is None:
            want = a
        else:
            sys.stderr.write("one NAMESPACE only (the cutover is one namespace at a time)\n")
            return 2
        i += 1

    tier = load(os.path.join(src, "tier-egress.yaml"))
    known = []
    for _, s, _ in tier:
        if s not in known:
            known.append(s)
    if not known:
        sys.stderr.write("tier-egress.yaml carries no NetworkPolicy: refusing to guess\n")
        return 2
    if listing:
        for s in known:
            print(s)
        return 0
    if want is None:
        sys.stderr.write("NAMESPACE required (known: %s)\n" % ", ".join(known))
        return 2
    if want not in known:
        sys.stderr.write("unknown namespace %r (known: %s)\n" % (want, ", ".join(known)))
        return 2

    os.makedirs(out, exist_ok=True)
    written = []

    def emit(fname, header, triples):
        body = header + "\n---\n".join(d.strip("\n") + "\n" for _, _, d in triples)
        path = os.path.join(out, fname)
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
        written.append(fname)
        print("wrote %s  (%s)" % (path, ", ".join(n for n, _, _ in triples)))

    sel = [(n, s, d) for n, s, d in tier if s == want]
    emit("tier-egress-%s.yaml" % want,
         "# GENERATED by scripts/netpol-egress-scope.py %s - do not edit; regenerate.\n"
         "# Source: specs/cluster/manifests/networkpolicy/tier-egress.yaml, the policies whose\n"
         "# metadata.namespace is %s and nothing else. MANUAL sync only\n"
         "# (apps/08a-networkpolicy-egress.yaml). Part C of docs/DB-HARDENING-RUNBOOK.md.\n"
         % (want, want),
         sel)

    if with_db:
        dbdocs = [(n, s, d) for n, s, d in load(os.path.join(src, "db-egress.yaml")) if s == want]
        if dbdocs:
            emit("db-egress-%s.yaml" % want,
                 "# GENERATED by scripts/netpol-egress-scope.py %s --with-db-egress - do not edit.\n"
                 "# Source: specs/cluster/manifests/networkpolicy/db-egress.yaml, namespace %s only.\n"
                 % (want, want),
                 dbdocs)
        else:
            print("db-egress.yaml has no per-DB-pod lock in %s (nothing written)" % want)

    print("")
    print("Next (deliberate, by hand): list under `resources:` in")
    print("  %s" % os.path.join(out, "kustomization.yaml"))
    for fname in written:
        print("  - %s" % fname)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
