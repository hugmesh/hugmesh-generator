#!/usr/bin/env python3
"""kind_secret_closure.py — every ExternalSecret this tree APPLIES must read a Vault
path the seed WRITES, or say out loud that it does not.

WHY THIS EXISTS (hugmesh-generator#352). On the recovered kind cluster the ArgoCD
Application `external-secrets-config` sits **Degraded**, permanently, with six
ExternalSecrets in `SecretSyncedError` — all of them saying `could not get secret
data from provider`. Four of those six read Vault paths that
`scripts/gen-cluster-secrets.sh` never writes at all:

    hugmesh/akkoma-admin            hugmesh/coturn-shared-secret
    hugmesh/mesh-bff-casdoor-client hugmesh/tuwunel-admin

Not one of them was written down anywhere as expected. So the app is red for
reasons nobody can distinguish from a real secret-sync failure, and the honest
consequence is that everyone stops reading it — which is exactly how the kind
lane sat dead for two days in #349 while every check reported healthy.

THE INVARIANT. Take the ExternalSecret manifests the kustomization actually
applies (uncommented `resources:` entries only). Every Vault path they reference,
through `data[].remoteRef.key` or `dataFrom[].extract.key`, must be written by
`vault kv put`/`patch` in the seed — or be listed in EXEMPT below with a reason.

THE EXEMPTION LIST IS THE POINT, NOT AN ESCAPE HATCH. Some of these tiers really
are deployed by no kind profile and really do ship dark. Writing them down turns
"why is external-secrets-config red?" from folklore into a reviewable list, and
the two ANTI-ROT checks keep it honest: an exemption stops being allowed the
moment its path is no longer referenced (the tier was removed) OR the moment the
seed starts writing it (the gap was closed). Either way the entry must be
deleted, so the list cannot quietly outlive its reasons.

WHAT IS AND IS NOT MODELLED, said plainly:

  * A path the seed writes INSIDE a conditional is counted as written. Every
    `vault kv put` in that script is inside `if VAULT_ADDR is set`, so shell
    nesting carries no signal and was measured to classify all 30 writes as
    "conditional" — a useless axis. The consequence is real and worth naming:
    `hugmesh/velero` IS written, but only when the operator supplies managed
    object-store credentials, so `velero-cloud-credentials` and
    `velero-repo-credentials` fail on a default build and this checker will not
    say so. That pair is documented as shipping dark in the kustomization's own
    comment. Catching it needs a LIVE check — `make kind-doctor` against a
    running cluster — not a static one.
  * Only the external-secrets kustomization is read. An ExternalSecret applied
    from somewhere else is out of scope and would be a separate gap.
  * A file present in the directory but not listed in `resources:`, or listed
    behind a `#`, is NOT applied and is deliberately not checked — that is how
    azure-intune is kept off a default build.

Exit 0 = closed. 1 = a referenced path is unseeded and unexplained, or an
exemption has gone stale. 2 = the checker could not run — never a silent pass.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover — the shell wrapper checks this too
    print("  FAIL PyYAML is required (refusing to skip)", file=sys.stderr)
    raise SystemExit(2)

# "<vault path>" -> why it is referenced by an APPLIED ExternalSecret and
# deliberately never seeded. Delete an entry the moment either half stops being
# true; the anti-rot checks below make that mandatory rather than polite.
EXEMPT: dict[str, str] = {
    "hugmesh/akkoma-admin": (
        "Akkoma/Pleroma admin token for the gated admin-effect seam. akkoma is a "
        "DEFAULT-OFF optional service (optional-services.yaml) and no kind profile "
        "deploys it — measured 0 pods on hugmesh-local. The ESO half ships so a "
        "selected build needs no manifest change; the token is an OPERATOR secret "
        "with no sensible generated default, so the seed cannot mint one."
    ),
    "hugmesh/tuwunel-admin": (
        "Matrix homeserver admin token, same shape and same reason as akkoma-admin: "
        "tuwunel is DEFAULT-OFF, deployed by no kind profile (0 pods measured), and "
        "the token is issued by the homeserver rather than minted by the seed."
    ),
    "hugmesh/coturn-shared-secret": (
        "TURN/STUN long-term-credential shared secret. coturn is DEFAULT-OFF and "
        "deployed by no kind profile (0 pods measured). The kustomization's own "
        "comment states it 'materializes only once that Vault path is populated'. "
        "It is deliberately ESO/Vault-only and never inline, so a default build "
        "leaves it unmaterialized on purpose."
    ),
    "hugmesh/mesh-bff-casdoor-client": (
        "OIDC client credential for the LoRa mesh BFF. The mesh tier (apps/34c, "
        "34d) is in no kind profile — kind_route_closure.py already exempts its "
        "route for the same reason — and the credential is minted by Casdoor when "
        "that tier is provisioned, not by the cluster seed."
    ),
}

PUT_RE = re.compile(
    r'vault kv (?:put|patch)\s+"\$\{VAULT_KV_MOUNT\}/\$\{BASE\}/([A-Za-z0-9._-]+)"'
)
# A `- name.yaml` resource entry that is NOT commented out.
RESOURCE_RE = re.compile(r"^\s*-\s+([A-Za-z0-9._-]+\.yaml)\s*(?:#.*)?$", re.M)


def die(msg: str) -> int:
    print(f"  FAIL {msg}")
    return 2


def applied_resources(kustomization: Path) -> list[str]:
    return RESOURCE_RE.findall(kustomization.read_text(encoding="utf-8", errors="replace"))


def referenced_paths(manifest_dir: Path, resources: list[str]) -> tuple[dict[str, set[str]], list[str]]:
    """{vault path -> {"file:ExternalSecretName", ...}}, plus files that would not parse."""
    refs: dict[str, set[str]] = {}
    broken: list[str] = []
    for rel in resources:
        p = manifest_dir / rel
        if not p.is_file():
            broken.append(f"{rel} is listed in resources: but does not exist")
            continue
        try:
            docs = list(yaml.safe_load_all(p.read_text(encoding="utf-8", errors="replace")))
        except yaml.YAMLError as exc:
            broken.append(f"{rel} is not parseable YAML: {exc}")
            continue
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "ExternalSecret":
                continue
            name = (doc.get("metadata") or {}).get("name") or "<unnamed>"
            spec = doc.get("spec") or {}
            for entry in spec.get("data") or []:
                key = ((entry or {}).get("remoteRef") or {}).get("key")
                if key:
                    refs.setdefault(key, set()).add(f"{rel}:{name}")
            for entry in spec.get("dataFrom") or []:
                key = ((entry or {}).get("extract") or {}).get("key")
                if key:
                    refs.setdefault(key, set()).add(f"{rel}:{name}")
    return refs, broken


def seeded_paths(seed: Path) -> set[str]:
    text = seed.read_text(encoding="utf-8", errors="replace")
    # Strip comments so a `vault kv put ...` quoted in prose cannot count as a write.
    stripped = "\n".join(re.sub(r"#.*", "", line) for line in text.splitlines())
    return {"hugmesh/" + m for m in PUT_RE.findall(stripped)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--manifests", default=None)
    ap.add_argument("--seed", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    repo = Path(args.repo)
    manifest_dir = Path(args.manifests or repo / "specs/cluster/manifests/external-secrets")
    seed = Path(args.seed or repo / "scripts/gen-cluster-secrets.sh")
    kustomization = manifest_dir / "kustomization.yaml"

    for path, what in ((manifest_dir, "manifest directory"), (kustomization, "kustomization"), (seed, "seed script")):
        if not (path.is_dir() if what == "manifest directory" else path.is_file()):
            return die(f"cannot read {what} {path}")

    resources = applied_resources(kustomization)
    if not resources:
        return die(f"{kustomization} lists no resources — refusing to report closure over nothing")

    refs, broken = referenced_paths(manifest_dir, resources)
    if broken:
        for b in broken:
            print(f"  FAIL {b}")
        return 2
    if not refs:
        return die(
            f"parsed {len(resources)} applied resource(s) and found ZERO Vault references — "
            "the extractor is broken, not the tree"
        )

    written = seeded_paths(seed)
    if not written:
        return die(f"found no `vault kv put` in {seed} — the extractor is broken, not the tree")

    failures = 0

    unseeded = sorted(k for k in refs if k not in written and k not in EXEMPT)
    for key in unseeded:
        where = ", ".join(sorted(refs[key]))
        print(f"  FAIL {key} is read by an APPLIED ExternalSecret ({where}) and is never written by {seed.name}")
        print( "       Either seed it, stop applying that ExternalSecret, or add it to EXEMPT with a reason.")
        failures += 1

    # ANTI-ROT 1 — the tier went away, or the file stopped being applied.
    for key in sorted(EXEMPT):
        if key not in refs:
            print(f"  FAIL EXEMPT[{key}] is stale: no applied ExternalSecret references it any more. Delete the entry.")
            failures += 1

    # ANTI-ROT 2 — the gap was closed and the exemption outlived its reason.
    for key in sorted(EXEMPT):
        if key in written:
            print(f"  FAIL EXEMPT[{key}] is stale: {seed.name} now writes it. Delete the entry.")
            failures += 1

    if failures:
        print(f"\n  {failures} closure failure(s).")
        return 1

    if not args.quiet:
        print(
            f"  PASS every Vault path read by the {len(resources)} applied ExternalSecret manifest(s) "
            f"is seeded ({len(refs) - len(EXEMPT)}) or explained ({len(EXEMPT)})"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
