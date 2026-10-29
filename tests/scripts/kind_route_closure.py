#!/usr/bin/env python3
"""kind_route_closure.py — a kind profile must DEPLOY every in-cluster Service its
own applied gateway ROUTES point at, or say out loud that it does not.

WHY THIS EXISTS. bootstrap-kind.sh's KIND_PROFILE=sso applies a curated subset of
specs/cluster/apps/. It applied apps/20-gateway-fe.yaml — the whole front door,
route table included — while NOT applying apps/47-user-ui.yaml. The route

    - id: user-ui
      uri: http://hugmesh-user-ui.hugmesh-frontend.svc.cluster.local:80
      path: /user/**

was therefore live and pointed at a Service that nothing created. The result is
the worst kind of failure: the API behind the same surface (/bff/user/**) was
routed AND allowed by the route-access seed, so `curl` said the profile/password
endpoint worked while a browser got 503 from a route into the void, and the host
shell's `user` remote could not fetch its remoteEntry. Nothing reported it,
because a route to nowhere is not a sync error — ArgoCD was Healthy.

THE INVARIANT. For each profile in bootstrap-kind.sh, take the EFFECTIVE applied
set (the always-applied base + that profile's list). Every `uri:` in those
Applications that names an in-cluster `<svc>.<ns>.svc.cluster.local` host must
resolve to a Service some Application in that same set CREATES — or be listed in
EXEMPT below with a reason.

THE EXEMPTION LIST IS THE POINT, NOT AN ESCAPE HATCH. The sso slice is
deliberately partial, so most of the fe-gateway's route table does point at tiers
it does not deploy. Writing them down converts an invisible property ("what does
this profile actually serve?") into a reviewable list, and the ANTI-ROT check
below fails when an exemption stops matching a live routed host — so the moment a
tier IS added to the profile, its exemption must be deleted.

WHAT IS AND IS NOT MODELLED, said plainly:
  * Services created by HELM-CHART Applications are NOT discovered (the templates
    are Go templates, not YAML). No route in this tree targets a chart-created
    Service — the gateways route to kustomize-managed tiers — and a chart tier
    that ever becomes a route TARGET would show up here as an unexplained missing
    host, which is the safe direction to be wrong in.
  * Namespace is part of the identity: `hugmesh-user-ui.hugmesh-frontend` is not
    satisfied by a `hugmesh-user-ui` Service in another namespace.
  * External hosts (anything not ending .svc.cluster.local) are out of scope.

Exit 0 = closed. 1 = a routed Service is undeployed and unexplained (or an
exemption has gone stale). 2 = the checker could not run — never a silent pass.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover — the shell wrapper checks this too
    print("  FAIL PyYAML not available (pip install pyyaml)")
    sys.exit(2)

# ── EXEMPTIONS ──────────────────────────────────────────────────────────────
# "<host>" -> why it is routed but deliberately not deployed by any kind profile.
# Keyed by the full <svc>.<ns> host exactly as the route spells it.
EXEMPT: dict[str, str] = {
    "hugmesh-be-gateway.hugmesh-backend":
        "OUT OF SCOPE for both profiles: the sso slice is the fe front door + native login. "
        "/be/** therefore 503s on kind by design. Adding apps/20-gateway-be.yaml pulls in its "
        "own Cassandra keyspace + route-access role and is a separate decision.",
    "tuwunel-proxy.hugmesh-backend":
        "Matrix homeserver (apps/30-tuwunel.yaml) is not in either profile — /_matrix/** and "
        "/.well-known/matrix/* are dead on kind. The Matrix e2e specs run against the compose lane.",
    "akkoma-proxy.hugmesh-backend":
        "Mastodon/Akkoma (apps/30-akkoma.yaml) is not in either profile — /api/v1/**, /api/v2/** "
        "and /oauth/** are dead on kind, same as Matrix above.",
    "hugmesh-mod-bff-api.hugmesh-backend":
        "moderation tier (apps/32/33) not in the profile; /bff/mod/** 503s on kind.",
    "hugmesh-mod-ui.hugmesh-frontend":
        "moderation UI (apps/46-mod-ui.yaml) not in the profile; /mod/** 503s on kind.",
    "hugmesh-forum-bff-api.hugmesh-backend":
        "forum tier (apps/38/39 + phpBB) not in the profile; /bff/forum/** 503s on kind.",
    "hugmesh-forum-ui.hugmesh-frontend":
        "forum UI (apps/49-forum-ui.yaml) not in the profile; /social/forum/** 503s on kind.",
    "hugmesh-wiki-bff-api.hugmesh-backend":
        "wiki tier (apps/34a/34b) not in the profile; /bff/wiki/** 503s on kind.",
    "hugmesh-mesh-bff-api.hugmesh-backend":
        "LoRa mesh tier (apps/34c/34d) not in the profile; /bff/mesh/** 503s on kind.",
    "hugmesh-character-forge-bff-api.hugmesh-backend":
        "character-forge tier (apps/38b/39b) not in the profile; /bff/character-forge/** 503s on kind.",
    "hugmesh-character-forge-ui.hugmesh-frontend":
        "character-forge UI (apps/49c) not in the profile; /character-forge/** 503s on kind.",
    "hugmesh-character-studio-ui.hugmesh-frontend":
        "character-studio UI (apps/49b) not in the profile; /character-studio/** 503s on kind.",
    "hugmesh-games-ui.hugmesh-frontend":
        "games `games` remote (manifests/games-ui, games slug — no Application syncs it yet, "
        "and the games slug is not in the profile); /games/** 503s on kind.",
    "hugmesh-games.hugmesh-games":
        "games BFF (apps/50-games.yaml, games slug) not in the profile; /games/api/** 503s on kind "
        "(and, once deployed, 401s until the cluster BFF is bridged to the systems issuer — "
        "see apps/20-gateway-fe.yaml games-bff).",
    "hugmesh-api-docs.hugmesh-frontend":
        "api-docs (apps/48-api-docs.yaml) not in the profile; /api-docs/** 503s on kind.",
    "hugmesh-remote-fragment.hugmesh-frontend":
        "remote-fragment sync sidecar (apps/41-remote-fragment.yaml) not in the profile; "
        "/_fragments/** 503s on kind. NOTE: the host shell degrades rather than blanks — "
        "fragments are optional chrome, unlike the /user/** remote this gate was written for.",
}

APP_URI_RE = re.compile(r"uri:\s*https?://([a-z0-9][a-z0-9.-]*)\.svc\.cluster\.local", re.I)
PATH_RE = re.compile(r"path:\s*(specs/cluster/\S+)")


def die(msg: str) -> int:
    print(f"  FAIL {msg}")
    return 2


def profile_arrays(boot_text: str) -> dict[str, list[str]]:
    """Every `<NAME>_APPS=( … )` array in the bootstrap, comments stripped."""
    out: dict[str, list[str]] = {}
    for m in re.finditer(r"^([A-Z0-9_]+_APPS)=\((.*?)^\)", boot_text, re.S | re.M):
        body = re.sub(r"#[^\n]*", "", m.group(2))
        out[m.group(1)] = re.findall(r"[0-9][0-9a-z-]*\.yaml", body)
    return out


def services_created(repo: Path, app_file: Path) -> set[tuple[str, str]]:
    """(service-name, namespace) pairs an Application's kustomize path creates."""
    found: set[tuple[str, str]] = set()
    text = app_file.read_text(encoding="utf-8", errors="ignore")
    default_ns = ""
    m = re.search(r"destination:\s*(?:.|\n)*?namespace:\s*(\S+)", text)
    if m:
        default_ns = m.group(1)
    for rel in PATH_RE.findall(text):
        if "/charts/" in rel:
            continue                      # Go templates — see the module docstring
        d = repo / rel
        if not d.is_dir():
            continue
        kust_ns = ""
        k = d / "kustomization.yaml"
        if k.is_file():
            km = re.search(r"^namespace:\s*(\S+)", k.read_text(encoding="utf-8", errors="ignore"), re.M)
            if km:
                kust_ns = km.group(1)
        for f in sorted(d.rglob("*.yaml")):
            raw = f.read_text(encoding="utf-8", errors="ignore")
            if "{{" in raw:
                continue
            try:
                docs = list(yaml.safe_load_all(raw))
            except yaml.YAMLError:
                continue
            for doc in docs:
                if not isinstance(doc, dict) or doc.get("kind") != "Service":
                    continue
                meta = doc.get("metadata") or {}
                name = meta.get("name")
                if not name:
                    continue
                ns = meta.get("namespace") or kust_ns or default_ns
                found.add((name, ns))
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--bootstrap", default=None)
    ap.add_argument("--apps", default=None)
    ap.add_argument("--base-array", default="CORE_APPS",
                    help="the array applied for EVERY profile, before any profile branch")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    repo = Path(args.repo)
    boot = Path(args.bootstrap or repo / "specs/cluster/bootstrap/kind-local/bootstrap-kind.sh")
    apps = Path(args.apps or repo / "specs/cluster/apps")
    if not boot.is_file():
        return die(f"cannot read {boot}")
    if not apps.is_dir():
        return die(f"cannot read {apps}")

    arrays = profile_arrays(boot.read_text(encoding="utf-8"))
    if not arrays:
        return die(f"no *_APPS arrays found in {boot}")
    base = arrays.get(args.base_array, [])

    violations: list[str] = []
    used_exempt: set[str] = set()
    total_routes = 0
    total_created = 0

    for prof, listed in sorted(arrays.items()):
        if prof == args.base_array:
            continue
        effective = list(dict.fromkeys(base + listed))
        created: set[tuple[str, str]] = set()
        for a in effective:
            f = apps / a
            if f.is_file():
                created |= services_created(repo, f)
        total_created += len(created)
        if not args.quiet:
            print(f"-- {prof}: {len(effective)} application(s), {len(created)} Service(s) created --")

        seen_hosts: set[str] = set()
        for a in effective:
            f = apps / a
            if not f.is_file():
                continue
            for host in APP_URI_RE.findall(f.read_text(encoding="utf-8", errors="ignore")):
                total_routes += 1
                if host in seen_hosts:
                    continue                 # same target, several routes — report once
                seen_hosts.add(host)
                parts = host.split(".")
                svc, ns = parts[0], (parts[1] if len(parts) > 1 else "")
                if (svc, ns) in created:
                    continue
                if host in EXEMPT:
                    used_exempt.add(host)
                    if not args.quiet:
                        print(f"     exempt: {host}")
                        print(f"             {EXEMPT[host]}")
                    continue
                violations.append(
                    f"{prof}: {a} routes to {host}.svc.cluster.local, which NO Application "
                    f"in this profile creates — the route is live and the Service has no endpoints")

    rc = 0
    if violations:
        for v in sorted(set(violations)):
            print(f"     {v}")
        print(f"  FAIL {len(set(violations))} routed-but-undeployed Service(s) above")
        rc = 1
    else:
        print("  PASS every in-cluster route target is deployed by the profile, or exempt with a reason")

    # ── anti-rot: an exemption must still match a live routed host ───────────
    stale = sorted(set(EXEMPT) - used_exempt)
    if stale:
        for s in stale:
            print(f"     stale exemption: {s} (no profile routes there any more, or it is now deployed)")
        print(f"  FAIL {len(stale)} exemption(s) no longer match a routed-but-undeployed host — delete them")
        rc = 1
    else:
        print(f"  PASS anti-rot: no exemption outlives its route ({len(EXEMPT)} declared)")

    # ── vacuity: a run that inspected nothing must not pass ──────────────────
    if total_routes >= 20 and total_created >= 10:
        print(f"  PASS vacuity: {total_routes} in-cluster route target(s) and "
              f"{total_created} created Service(s) really inspected")
    else:
        print(f"  FAIL vacuity: only {total_routes} route target(s) / {total_created} "
              f"created Service(s) seen — the scan has gone blind")
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
