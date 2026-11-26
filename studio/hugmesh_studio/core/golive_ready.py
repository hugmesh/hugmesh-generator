"""'Go live when ready' on the domain step — the ONE implementation both faces use
(hugmesh-generator#1201), Qt-free.

The GUI page (gui/pages/domain_services.py) draws it as a row under the Tor front door —
a provider picker and, for a provider that needs one, a masked API-key field; the TUI
step (tui/domain_services_step.py) as the ``go`` and ``key`` commands. Both read and
write through :func:`get` / :func:`set_provider`, describe it with :func:`state_line`,
and offer it only where :func:`applies` says so, so the two cannot drift.

What it records: ``Domain.go_live`` for a domain row, ``ImageConfig.cluster_domain_go_live``
for the mesh's own (implicit) domain. What it means on the node:
``/usr/sbin/hugmesh-go-live-at-ready`` (docs/GO-LIVE-WHEN-READY.md). The API key never
touches the config: :mod:`core.golive_tokens`.
"""
from __future__ import annotations

from . import config, golive_tokens

__all__ = ["ROW_LABEL", "GO_COMMAND", "KEY_COMMAND", "PROVIDER_LABELS", "applies",
           "get", "set_provider", "state_line", "choices", "parse_provider"]

ROW_LABEL = "Go live when ready"
#: TUI commands: ``go <provider>`` / ``go off``, and ``key`` (the next line is hidden).
GO_COMMAND = "go"
KEY_COMMAND = "key"

#: Plain names for the pickers, in GO_LIVE_AT_READY_PROVIDERS order.
PROVIDER_LABELS = {
    "cloudflare-tunnel": "Cloudflare Tunnel",
    "byo-domain": "Own domain (your DNS)",
    "duckdns": "DuckDNS / dynamic DNS",
    "tailscale-funnel": "Tailscale Funnel",
    "router-portforward": "Router port-forward",
}
#: What must already be true outside the mesh for each provider.
_PREREQ = {
    "cloudflare-tunnel": "the tunnel must already exist in your Cloudflare account",
    "byo-domain": "the domain's DNS must already point at the mesh's public address",
    "duckdns": "the DuckDNS / Cloudflare name must already exist",
    "tailscale-funnel": "Funnel must be allowed for this tailnet",
    "router-portforward": "your router must forward ports 80 and 443 to the public edge node",
}


def choices() -> list[tuple[str, str]]:
    """``[(value, label), ...]`` for a picker: Off first, then each provider."""
    return [("", "Off")] + [(p, PROVIDER_LABELS.get(p, p))
                            for p in config.GO_LIVE_AT_READY_PROVIDERS]


def applies(cfg, route: str = "image") -> bool:
    """Offered only where it can reach a node: an IMAGE build of a mesh (the builders
    bake it), never the local Docker mesh or kind routes, and never a desktop-client
    configuration (mode cloud: no cluster to take public)."""
    if route != "image" or not isinstance(cfg, config.ImageConfig):
        return False
    return (getattr(cfg, "mode", "") or "") != "cloud"


def _row(cfg, name: str):
    for d in getattr(cfg, "domains", None) or []:
        if (getattr(d, "name", "") or "").strip() == name:
            return d
    return None


def get(cfg, name: str) -> str:
    """The provider ``name`` is set to go live through, "" when off."""
    d = _row(cfg, name)
    if d is not None:
        return getattr(d, "go_live", "") or ""
    if name and name == (getattr(cfg, "cluster_domain", "") or "").strip():
        return getattr(cfg, "cluster_domain_go_live", "") or ""
    return ""


def set_provider(cfg, name: str, provider: str) -> None:
    """Record ``provider`` ("" = off) for ``name``. Raises ValueError for a value
    ``config.go_live_problem`` refuses, or a name that is neither a row nor the own
    domain."""
    problem = config.go_live_problem(provider)
    if problem:
        raise ValueError(problem)
    d = _row(cfg, name)
    if d is not None:
        d.go_live = provider or ""
        return
    if name and name == (getattr(cfg, "cluster_domain", "") or "").strip():
        cfg.cluster_domain_go_live = provider or ""
        return
    raise ValueError(f"{name!r} is not a domain of this configuration")


def parse_provider(word: str) -> str:
    """The provider a typed word names ("off" -> ""), or raise ValueError."""
    w = (word or "").strip().lower()
    if w in ("off", "none", "no", ""):
        return ""
    if w in config.GO_LIVE_AT_READY_PROVIDERS:
        return w
    raise ValueError(config.go_live_problem(w) or f"unknown provider {word!r}")


def state_line(name: str, provider: str, st=None) -> str:
    """The one sentence under the control, on both faces."""
    if not provider:
        return (f"Off — {name} goes public only when someone runs Go live for it "
                "(and confirms).")
    st = st or golive_tokens.store()
    label = PROVIDER_LABELS.get(provider, provider)
    out = (f"On — once the mesh's nodes have booted and every pod is ready, the public-"
           f"edge node takes {name} public through {label} on its own, with no "
           f"confirmation: choosing this is the consent. Before that, "
           f"{_PREREQ.get(provider, 'the provider must be set up')}.")
    if golive_tokens.needs_token(provider):
        prompt = config.GO_LIVE_TOKEN_PROMPTS[provider]
        if st.has(name):
            out += (f" {prompt}: entered (held in memory only; written onto the edge "
                    "nodes' KEYS sticks, never into an image or a saved config).")
        else:
            out += (f" Needs a {prompt}: the build refuses until it is entered. It is "
                    "written onto the edge nodes' KEYS sticks only.")
    return out
