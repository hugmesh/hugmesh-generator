"""One practical tip for every Studio page, with no model needed (Qt-free, stdlib only).

The bottom strip of every Studio window shows ``Tip: ...`` for the page the person is
on. The tips here are curated (one to three per page, each under 140 characters, in
the plain words the screens use), so they work on a machine with no model at all. When
a model IS running, :func:`model_tip` may ask it for one sentence about the page; the
curated tip is already on screen, and the model's replaces it only when it arrives for
the same page and domain, spells no command the docs do not, and uses no word a brand
screen may not show (core/plain_words.FORBIDDEN_ON_SCREENS).

Keyed by EVERY slug the window and the text UI can stand on: config.WIZARD_PAGE_SLUGS
with the ``localmesh`` slot expanded to its eleven steps, plus the slugs the text UI's
journey and the dock's hosts use (``fleet``, ``golive``, ``local_ai``, ``review``). A
test asserts the coverage and the wording rules.

Hidden tips are a per-viewer setting (``assistant_settings.tips_hidden``).
"""
from __future__ import annotations

import os
from typing import Callable, Optional

from . import assistant_settings
from .assistant_context import Where, render_where

__all__ = ["TIPS", "ALL_SLUGS", "LOCALMESH_SLUGS", "EXTRA_SLUGS", "tip_for", "tips_hidden",
           "set_tips_hidden", "model_tip", "MODEL_TIP_PROMPT", "TIP_MAX_CHARS", "clean_model_tip",
           "TipRotation"]

TIP_MAX_CHARS = 140
MODEL_TIP_MAX_CHARS = 160

LOCALMESH_SLUGS: tuple = (
    "localmesh_choice", "localmesh_join", "localmesh_env", "localmesh_domains",
    "localmesh_domain_services", "localmesh_source", "localmesh_services", "localmesh_idp",
    "localmesh_overlay", "localmesh_review", "localmesh")
EXTRA_SLUGS: tuple = ("fleet", "golive", "local_ai", "review", "themes")

TIPS: dict = {
    "welcome": (
        "The Studio builds HugMesh images or runs a local Docker mesh; nothing starts until you press Build or Generate & start.",
        "Ask the assistant below anything about this page; it answers from the project's own docs, on this machine.",
    ),
    "sessions": (
        "Prior sessions lists every earlier build with its state; View errors shows a failed build's last log lines.",
        "A session can be reopened to restart its build with the same choices.",
    ),
    "mode": (
        "Mesh node, Mesh desktop client, Standalone desktop and Local Docker mesh build or run something; the other cards are tools.",
        "Local Docker mesh needs Docker on this machine; image builds need the builder container.",
    ),
    "localmesh_choice": (
        "Create a new mesh, or join one that is already running; a saved mesh can be loaded from here.",
    ),
    "localmesh_join": (
        "Joining needs the running mesh's address; nothing on this machine is changed until you continue.",
    ),
    "localmesh_env": (
        "test keeps the mesh on this LAN; prod uses public names and the mesh's VPN, which needs an auth key.",
        "The brand box names the mesh's own domain; every other domain starts from its look and sign-in.",
    ),
    "localmesh_domains": (
        "Add one row per domain the mesh serves; each domain gets its own services on the next step.",
    ),
    "localmesh_domain_services": (
        "One domain at a time: tick its services, then the Identity, Look and Ways tabs for its sign-in, colours and Tor.",
        "Next domain moves to the following row; Back returns without losing what you ticked.",
    ),
    "localmesh_source": (
        "Clone fetches the mesh's sources; Existing points at a folder you already have. Code folders per domain live under the state folder.",
    ),
    "localmesh_services": (
        "Mesh-level services (Tor, egress VPN, consoles) are chosen here; per-domain ones are on each domain's page.",
    ),
    "localmesh_idp": (
        "The mesh's own sign-in: the built-in Casdoor, Azure Entra ID, AWS Cognito or another OIDC provider.",
    ),
    "localmesh_overlay": (
        "The overlay step applies to the kind lane only; the Docker mesh ignores it.",
    ),
    "localmesh_review": (
        "Read the plan; nothing is generated until Generate & start on the next step.",
    ),
    "localmesh": (
        "Generate & start writes the compose files and starts the mesh; the Running mesh tab shows its pods and doors.",
        "Stop halts the mesh and keeps its data; the DevOps lane can be halted without deleting the cluster.",
    ),
    "phone": ("MDM phone enrols a phone against a running mesh; it builds no image.",),
    "quest": ("MDM Quest headset enrols a headset against a running mesh; it builds no image.",),
    "deploy": ("Cloud deploy pushes a built image to a provider; build the image first.",),
    "e2e": ("Run e2e tests needs a running local mesh; results land in the evidence folder.",),
    "qemu": ("QEMU device tests boot a built image in an emulator; a saved device can be reopened later.",),
    "meshemu": ("Mesh emulation boots several node images together; it needs built images first.",),
    "localcloud": ("Create nodes for local cloud makes node machines for a cloud deploy on this computer.",),
    "idp": (
        "The mesh's sign-in provider: Casdoor is built in; Entra, Cognito and OIDC need an address and a client id.",
    ),
    "role": (
        "Standalone builds one desktop image; cloud builds a mesh desktop client; mesh builds node images from a list.",
    ),
    "worklist": (
        "Tick one row per image to build: a role on a platform; each row gets its own build log.",
    ),
    "hardware": ("Pick the board and GPU driver for the machine the image will boot on.",),
    "branding": ("Branding sets the desktop image's name, wallpaper and theme; a brand record carries the same.",),
    "network": ("The mesh's domain, its VPN and egress choices for the whole node are set here.",),
    "keyzip": ("Load the admin key-zip (or link) from a running mesh; keys are read, never shown.",),
    "domains_choice": ("Say yes to add domains beyond the mesh's own; each gets its own services and sign-in.",),
    "domains": (
        "One row per domain: name, title, which images carry it and its GitHub organisation for export.",
    ),
    "domain_services": (
        "Tick the services this domain runs; the Identity, Look and Ways tabs hold its sign-in, colours and Tor address.",
        "Ways to reach it: an internal name, a Tor address or a public name; Tor needs Tor on the node.",
        "The Look tab: a preset, a main and second colour, font, style; empty means inherited from the mesh.",
    ),
    "users_choice": ("Say yes to add user accounts now; generated accounts are written to the session folder.",),
    "users": (
        "Superusers and domain users are generated or typed here; the node key folders land under keys-* after the build.",
    ),
    "system": ("System identity: the host name, time zone and the admin account of the image.",),
    "vault": (
        "The Secrets store page may stay empty: an internal store under hugmesh/ is used unless you name one.",
    ),
    "home": ("Home folder, encryption and login choices for a desktop image; encryption needs a passphrase.",),
    "build": (
        "Review shows every choice; Continue commits nothing and the Build page starts the build.",
    ),
    "review": (
        "Review shows every choice; Continue commits nothing and the Build page starts the build.",
    ),
    "launch": ("Build starts the image build; its log streams on the Building page and the Image builds tab.",),
    "progress": (
        "Building streams build.log; a failed build keeps its last lines on Prior sessions under View errors.",
        "You can follow the log in a terminal with tail -F on the session's build.log.",
    ),
    "fleet": ("The fleet window manages several meshes; each row is a saved mesh.",),
    "golive": ("Go live starts the Tor addresses; it opens no public port.",),
    "local_ai": ("Type a question for the local model; docs <question> shows the docs without a model.",),
    "themes": ("Themes preview the look presets; choose one on the domain's Look tab.",),
}

ALL_SLUGS: tuple = tuple(TIPS)

_TAB_TIPS = {
    "identity": "Identity: sign in through the mesh, or give this domain its own Casdoor, Entra, Cognito or OIDC sign-in.",
    "look": "Look: a preset, a main and second colour, font, style, decoration; empty means inherited from the mesh.",
    "services": "Services: tick what this domain runs; each service gets its own address under the domain.",
    "ways": "Ways: an internal name, a Tor address (needs Tor on the node) and the VPN and egress choices.",
}


class TipRotation:
    """A per-session counter so a page visited again shows its next tip."""

    def __init__(self):
        self.visits: dict = {}

    def pick(self, slug: str, count: int) -> int:
        n = self.visits.get(slug, 0)
        self.visits[slug] = n + 1
        return n % max(1, count)


_ROTATION = TipRotation()


def tips_hidden() -> bool:
    return bool(assistant_settings.get("tips_hidden", False))


def set_tips_hidden(hidden: bool) -> bool:
    return assistant_settings.update(tips_hidden=bool(hidden))


def _state_value(where: Where, key: str) -> str:
    for k, v in list(where.state) + list(where.activity):
        if k == key:
            return v
    return ""


def tip_for(where: Where, *, rotation: Optional[TipRotation] = None) -> str:
    """The curated tip for ``where``: a failed build on a build page first, the mesh's
    doors on the bring-up step when it is up, the open tab's line on a domain page,
    else the page's tips rotated by step and visit."""
    slug = (where.slug or "").strip()
    failed = _state_value(where, "last failed build")
    if failed and slug in ("progress", "sessions", "build", "launch", "worklist"):
        image = failed.split("images ")[1].split(";")[0] if "images " in failed else failed.split(";")[0]
        return f"Your last build failed at {image}; the Image builds tab has the log."[:TIP_MAX_CHARS]
    mesh = _state_value(where, "local mesh")
    if slug == "localmesh" and mesh.startswith("up"):
        return ("The mesh is up: " + mesh[len("up"):].strip(" (:)") or "open its doors from the Running mesh tab")[:TIP_MAX_CHARS]
    if slug in ("domain_services", "localmesh_domain_services") and where.tab in _TAB_TIPS:
        return _TAB_TIPS[where.tab]
    tips = TIPS.get(slug) or TIPS.get(slug.split("_")[0], ()) or TIPS["welcome"]
    rot = rotation or _ROTATION
    i = (rot.pick(slug, len(tips)) + max(0, where.step_index)) % len(tips)
    return tips[i]


# ── the optional model tip ───────────────────────────────────────────────────────────
MODEL_TIP_PROMPT = ("In one sentence (max 25 words), give one practical tip for this Studio page. "
                    "Use only the page facts and snippets. No commands unless they appear in the "
                    "snippets.")


def clean_model_tip(text: str, chunks, primer: str = "") -> str:
    """The model's tip, or "" when it is too long, names an unverified command or a
    forbidden screen word."""
    from . import assistant_docs as adocs, plain_words
    tip = " ".join((text or "").split()).strip().strip("\"'")
    if not tip or len(tip) > MODEL_TIP_MAX_CHARS:
        return ""
    if adocs.unverified_commands(tip, chunks, primer):
        return ""
    low = tip.lower()
    if any(w in low for w in plain_words.FORBIDDEN_ON_SCREENS):
        return ""
    return tip


def model_tip(where: Where, env: Optional[dict] = None, *,
              should_stop: Optional[Callable[[], bool]] = None,
              generator_dir: Optional[str] = None) -> str:
    """Ask the running model for one sentence about this page; "" on any error. Small
    on purpose: a short primer, the page facts, ONE snippet for the page title, 60
    tokens of answer, 10 s per piece and 20 s in all."""
    from . import agent_context as actx, assistant_docs as adocs, local_ai_status as lai
    env = dict(os.environ if env is None else env)
    try:
        gen = adocs.generator_dir(generator_dir, env)
        primer = actx.primer_text(gen, "", with_sources=False)
        idx = adocs.load_index(gen)
        chunks = adocs.retrieve(where.title or where.slug, where, index=idx, k=1, budget_tokens=700)
        system = ("# HugMesh primer\n" + primer + "\n\n# Where the person is\n" + render_where(where)
                  + ("\n\n# Snippets\n" + "\n\n".join(f"[doc: {c.label}]\n{c.text}" for c in chunks)
                     if chunks else ""))
        text = lai.send_prompt(MODEL_TIP_PROMPT, env=env, system=system, timeout=10,
                               total_timeout=20, should_stop=should_stop,
                               options={"num_predict": 60})
        if should_stop is not None and should_stop():
            return ""
        return clean_model_tip(text, chunks, primer)
    except Exception:                        # noqa: BLE001 — a tip is never an error
        return ""
