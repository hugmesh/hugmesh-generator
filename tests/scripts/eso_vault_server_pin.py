#!/usr/bin/env python3
"""eso_vault_server_pin.py -- the ClusterSecretStore's Vault server is pinned ON PURPOSE.

Issue #531, decision 88 = B on #347: the mesh's Vault is the in-cluster one and an
external Vault is not a supported topology, so
specs/cluster/manifests/external-secrets/secretstore.yaml keeps

    spec.provider.vault.server: "https://vault.vault.svc.cluster.local:8200"

and VAULT_ADDR (which steers only the WRITE side) never reaches it. This checker
fails if any of these stop being true:

  1. the ClusterSecretStore(s) with a vault provider in secretstore.yaml carry
     exactly the pinned server literal (host, port, scheme);
  2. secretstore.yaml still SAYS it is pinned on purpose (the marker
     "eso-vault-server: pinned" and "decision 88", in a COMMENT);
  3. nothing re-points the field at render time: kustomization.yaml and
     apps/04-external-secrets-config.yaml name no spec/provider/vault/server
     path (a `replacements` target or a JSON-6902 op would be the seam #531 asked
     about, and decision 88 = B declined);
  4. every `server: <http(s) URL>` line (also as a `- server:` list item) in a
     *.yaml/*.yml/*.tpl under specs/cluster/manifests, whatever the host is
     called, is the same pinned address, so the pin is not undone one file at a
     time. Scope: single-line block-style fields only; flow style, JSON, a value on
     the next line, and files outside specs/cluster/manifests are not read;
  5. scripts/gen-cluster-secrets.sh's header still says VAULT_ADDR never reaches
     the ClusterSecretStore.

Usage: eso_vault_server_pin.py [REPO_ROOT]   (exit 0 = pinned, 1 = defect)
Stdlib + PyYAML. Importable: check(root) -> list[str] of defects.
"""
import os
import re
import sys

import yaml

PIN = "https://vault.vault.svc.cluster.local:8200"
STORE = "specs/cluster/manifests/external-secrets/secretstore.yaml"
KUSTOMIZATION = "specs/cluster/manifests/external-secrets/kustomization.yaml"
APP = "specs/cluster/apps/04-external-secrets-config.yaml"
WRITER = "scripts/gen-cluster-secrets.sh"
MANIFESTS = "specs/cluster/manifests"

MARKER = "eso-vault-server: pinned"
DECISION = "decision 88"
WRITER_PHRASE = "VAULT_ADDR never reaches the ClusterSecretStore"

# Any `server:` line (or `- server:` list item) whose value is an http(s) URL. Not
# gated on the host name: a generator re-pointed at a host that does not say "vault"
# must fail too. (ArgoCD Applications name the kubernetes API server under
# spec.destination, but those live in specs/cluster/apps, outside MANIFESTS.)
SERVER_LINE = re.compile(r"""^\s*(?:-\s+)?server:\s*["']?(https?://[^"'\s#]+)""")
FIELD_PATH = re.compile(r"provider[/.]vault[/.]server")


def _read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def _comment_text(text):
    return "\n".join(ln for ln in text.splitlines() if ln.lstrip().startswith("#"))


def check(root):
    errs = []

    # 1 + 2: the store itself.
    try:
        text = _read(root, STORE)
    except OSError as exc:
        return [f"{STORE}: unreadable ({exc}) -- the pin cannot be verified"]
    try:
        docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        return [f"{STORE}: not parseable YAML ({exc})"]
    seen = 0
    for d in docs:
        if d.get("kind") not in ("ClusterSecretStore", "SecretStore"):
            continue
        vault = ((d.get("spec") or {}).get("provider") or {}).get("vault")
        if not isinstance(vault, dict):
            continue
        seen += 1
        name = (d.get("metadata") or {}).get("name", "?")
        server = vault.get("server")
        if server != PIN:
            errs.append(
                f"{STORE}: {d['kind']} {name!r} spec.provider.vault.server is "
                f"{server!r}, must stay the pinned {PIN!r} (decision 88 = B)")
    if seen == 0:
        errs.append(f"{STORE}: no ClusterSecretStore with a vault provider found "
                    "(a scan that finds nothing must not pass)")
    comments = _comment_text(text)
    if MARKER not in comments:
        errs.append(f"{STORE}: the comment saying the server is pinned on purpose "
                    f"is gone (expected {MARKER!r} in a # comment)")
    if DECISION not in comments:
        errs.append(f"{STORE}: the pin comment no longer cites {DECISION!r}")

    # 3: no render-time seam onto the field.
    for rel in (KUSTOMIZATION, APP):
        try:
            body = _read(root, rel)
        except OSError as exc:
            errs.append(f"{rel}: unreadable ({exc})")
            continue
        code = "\n".join(ln for ln in body.splitlines() if not ln.lstrip().startswith("#"))
        if FIELD_PATH.search(code):
            errs.append(f"{rel}: targets spec/provider/vault/server -- a render-time "
                        "re-point of the pinned address (decision 88 = B declined it)")

    # 4: every other server URL literal is the same address.
    mdir = os.path.join(root, MANIFESTS)
    literals = 0
    for dirpath, _dirs, files in os.walk(mdir):
        for fn in sorted(files):
            if not fn.endswith((".yaml", ".yml", ".tpl")):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            with open(path, encoding="utf-8", errors="replace") as fh:
                for no, ln in enumerate(fh, 1):
                    m = SERVER_LINE.match(ln)
                    if m:
                        literals += 1
                        if m.group(1) != PIN:
                            errs.append(f"{rel}:{no}: server {m.group(1)!r} is not "
                                        f"the pinned {PIN!r}")
    if literals == 0:
        errs.append(f"{MANIFESTS}: found no `server:` URL literal at all "
                    "(the census is vacuous)")

    # 5: the writer's header.
    try:
        w = _read(root, WRITER)
    except OSError as exc:
        errs.append(f"{WRITER}: unreadable ({exc})")
    else:
        flat = re.sub(r"\s*\n#\s*", " ", w)
        if WRITER_PHRASE.lower() not in flat.lower():
            errs.append(f"{WRITER}: header no longer says: {WRITER_PHRASE}")
    return errs


def main(argv):
    root = os.path.abspath(argv[1]) if len(argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", ".."))
    errs = check(root)
    for e in errs:
        print(f"  FAIL {e}")
    if not errs:
        print(f"  ok   ClusterSecretStore vault server pinned to {PIN}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
