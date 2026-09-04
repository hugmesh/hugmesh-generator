"""The TUI journey — the GUI wizard's flow, as a face-independent state machine.

Parity lane (issue #51 phase 2, catching up to the GUI features merged after the
#54 scaffold): the WELCOME flow with its three journey entry points (#67), the
journey-ordered mode menu (#67), the create-nodes-for-local-cloud abbreviated
wizard (#65, :mod:`.localcloud`), the whole-mesh emulation screen (#69,
:mod:`.meshemu`), the QEMU device-test screen (:mod:`.qemu` — the TEST lane of
the same emulation plan the mesh screen deploys), the Themes screen (#63,
:mod:`.themes`) and the per-domain Sign-in choice on the domains step (#71,
:mod:`.domains_step`).

PARITY RULES (what the tests pin):

* the page order IS the GUI's — :data:`PAGE_ORDER` is ``config.WIZARD_PAGE_SLUGS``
  itself, never a copy that could drift;
* the welcome/mode choice ids, their JOURNEY order and their routing targets match
  the GUI cards one for one (test_tui_gui_parity.py compares them to the live Qt
  pages where a Qt binding exists);
* committing a mode mirrors ``gui/pages/mode.py::validatePage`` — same transient
  side-flow flags, same config resets — so a config walked through the TUI and one
  walked through the GUI serialize identically for equivalent picks.

Every screen follows one small protocol (``enter/lines/prompt/feed``) so BOTH
faces — the plain numbered prompts and the urwid renderer — drive exactly the
same object and render exactly the same strings (the #54 rule).

Steps the TUI has not ported yet render an HONEST stub ("configure this step in
the GUI; Enter keeps the step's defaults") instead of pretending: a skipped
surface that says so beats a half-faked one, and the flow still walks the
canonical order end to end, finishing with a saveable config.
"""
from __future__ import annotations

from ..core.config import (
    IDP_CHOICES, IDP_LABELS, MODE_DEFAULT_ROLE, MODE_SKIPPED_PAGES, ROLE_CHOICES,
    UNAFFILIATED_ROLE, VAULT_FIELDS, VAULT_KV_MOUNT_DEFAULT, WIZARD_PAGE_SLUGS,
    ImageConfig, enter_mesh_defaults, vault_field_error,
)
from ..core.worklist import WorklistConfig, WorklistEntry

__all__ = [
    "PAGE_ORDER", "SIDE_FLOW_SLUGS", "WELCOME_CHOICES", "WELCOME_TARGET",
    "MODE_CHOICES", "MODE_DEFAULT_CHOICE", "PENDING_NOTE", "Journey",
    "README_GETTING_STARTED", "VAULT_COMMANDS",
]

#: The canonical page order — the GUI's OWN tuple, consumed rather than copied so
#: the two surfaces cannot drift (config.WIZARD_PAGE_SLUGS is the single source).
PAGE_ORDER: tuple[str, ...] = WIZARD_PAGE_SLUGS

#: The non-image side-flow slugs: entered ONLY via their mode-menu card (the GUI
#: skips them via applies_to on every image-mode walk; the TUI walk never visits
#: them positionally). "sessions" is likewise entered only from the welcome screen
#: (GUI: only WelcomePage.nextId routes INTO it).
SIDE_FLOW_SLUGS = ("localmesh", "phone", "quest", "deploy", "e2e", "qemu",
                   "meshemu", "localcloud")

#: The README's getting-started section — the same link the GUI welcome explainer
#: carries (rendered as selectable text here; a terminal has no anchor to click).
README_GETTING_STARTED = "https://github.com/hugmesh/hugmesh-generator#quick-start"

#: The welcome screen's TWO journey entry points (issue #50 item 1 / GUI PR #67):
#: (choice id, title, description) — ids and titles mirror gui/pages/welcome.py's
#: ``choices`` (test_tui_gui_parity pins the match), descriptions are the card
#: blurbs verbatim.
#:
#: The "Start a local mesh" card that used to sit between them is GONE, per the
#: operator's 2026-08-26 report ("standalone menu is asking same questions
#: seemingly multiple times") — DECISION 2(d): the welcome card and the mode
#: menu's "Local Docker mesh" card were two doors onto one flow, so the mode
#: menu keeps it and welcome drops it. gui/pages/welcome.py made the same cut
#: (its ``choices``/``_CHOICE_TARGET``/``_CHOICE_ICONS` all lost the entry); the
#: TUI's own MODE_CHOICES below still carries "localmesh", exactly as ModePage
#: does, so the journey is unreachable from neither front end.
WELCOME_CHOICES: tuple[tuple[str, str, str], ...] = (
    ("build", "Start building",
     "Open the menu of choices — build a mesh node, run a local Docker "
     "mesh, build a desktop image, enroll MDM devices, publish to a cloud, "
     "or run the end-to-end test suite."),
    ("sessions", "Review prior sessions",
     "Previous builds and saved configurations: restart or redo a session, "
     "open its artifacts, read its logs — or load/save a config file."),
)

#: welcome choice id -> the PAGE_ORDER slug it routes to (the GUI's _CHOICE_TARGET).
#: No "localmesh" key: DECISION 2(d) removed that card, and the GUI deliberately
#: leaves no target for a card nobody can pick (welcome.py:51-54 calls it an
#: unreachable branch in nextId()). The local-mesh journey is entered from the
#: MODE screen instead.
WELCOME_TARGET = {"build": "mode", "sessions": "sessions"}

#: The mode menu, in the operator's mesh-building JOURNEY order (issue #50 /
#: GUI PR #67; the #65 localcloud and #69 meshemu cards included): (id, title,
#: description) mirroring gui/pages/mode.py's ``modes`` — ids, order and titles
#: are parity-pinned against the live GUI page.
MODE_CHOICES: tuple[tuple[str, str, str], ...] = (
    ("localmesh", "Local Docker mesh",
     "Run a mesh on THIS machine in Docker — no separate server hardware. "
     "Configure it and launch the dockerized node right here."),
    ("localcloud", "Create nodes for local cloud",
     "Turn the local Docker mesh you already run HERE into real device "
     "images: an abbreviated mesh wizard that reuses its domain and "
     "accounts and offers ONLY the laptop and node image types. The local "
     "k8s (DevOps) stack must stop first — the next screen asks you to "
     "confirm that."),
    ("mesh", "Mesh node",
     "Superadmin: build the server node image(s) — PKI, backend, frontend, GPU, "
     "edge-AI — that run a mesh on dedicated hardware."),
    # MIRROR of gui/pages/mode.py. The "QEMU device tests" card that used to sit here
    # was REMOVED on 2026-08-27 at the operator's request ("remove QEMU device
    # emulation menu item as it does not do anything that cannot be done from the
    # other menu, but add the run e2e tests button") and this took its slot. The QEMU
    # device-test SCREEN survives on both faces and is reached FROM here — removing a
    # menu card must not delete a lane, and that lane is the only Studio door to the
    # Playwright-on-an-emulated-device harness and the SELinux AVC workout.
    # test_tui_gui_parity pins these descriptions word for word, so the two faces are
    # edited together or not at all.
    ("e2e", "Run e2e tests",
     "Run the end-to-end suite against a mesh that is ALREADY RUNNING — the "
     "Docker compose stack, the local DevOps (kind) cluster, or a "
     "QEMU-emulated device. Browse the suite as a tree, check the features "
     "to run, and read exactly why a run is blocked when it is. Starts no "
     "mesh. This is also the door to the emulated-device test lanes."),
    ("meshemu", "Mesh emulation",
     "Emulate the mesh you are readying for deployment: persistent devices, "
     "console, save-back. Boot every image of a prior build session and keep "
     "the guests up — per-device status, ssh logins, the QEMU console, disk "
     "saves, USB provisioning keys and the mesh's web front door."),
    ("deploy", "Cloud deploy",
     "Publish an already-built, cloud-packaged x86 image to a cloud provider "
     "(AWS / Azure / OpenShift / any qcow2 host) — no image build. Plans are "
     "rendered offline; apply is confirmed by the driver."),
    ("phone", "MDM phone",
     "Flash a USB Pixel with VERIFIED GrapheneOS and enroll it in the mesh — "
     "no image build. Runs the same driver right here."),
    ("quest", "MDM Quest headset",
     "Enroll a USB Meta Quest 3/3S as an MDM-managed mesh device (Headwind + "
     "tailnet + XR-chat URL) — no image build, no flash. Same driver, quest "
     "device class."),
    ("cloud", "Mesh desktop client",
     "Build a branded desktop that JOINS an existing mesh (tailnet + SSO). "
     "Load your admin-provided key-zip or configuration link."),
    ("standalone", "Standalone Gentoo desktop",
     "A personal hardened LUKS/SELinux desktop — or a plain UNAFFILIATED Gentoo "
     "desktop with zero HugMesh branding/tooling. No mesh, no SSO."),
)

#: The no-pick default — BY ID, exactly the GUI's rule, so a reorder of the menu
#: can never change which choice a plain Enter exercises.
MODE_DEFAULT_CHOICE = "standalone"

#: The honesty stub for wizard steps not ported to the TUI yet.
PENDING_NOTE = ("this step is not yet ported to the TUI — configure it in the "
                "GUI (python -m hugmesh_studio) if you need it; Enter keeps the "
                "step's defaults and continues.")

#: Side-flow stubs: these run whole drivers the TUI does not host yet. "qemu" left
#: this set once :mod:`.qemu` landed — a real screen over core.emulation, read-only
#: toward the host like :mod:`.meshemu` — so the two emulation lanes (TEST and
#: DEPLOY) are both hosted here and only the MDM/cloud drivers remain stubbed.
#: "e2e" (:mod:`.e2e`) is hosted for the same reason: the GUI grew a real page, so a
#: stub here would be the TUI breaking a promise the menu makes on both faces.
_SIDE_FLOW_STUB = {
    "localmesh": "Local Docker mesh",
    "phone": "MDM phone",
    "quest": "MDM Quest headset",
    "deploy": "Cloud deploy",
}

_PENDING_STEPS = {
    "idp": "Identity provider",
    "hardware": "Hardware",
    "network": "Network",
    "keyzip": "Admin key-zip",
    "system": "System",
    "home": "Home",
    "launch": "Launch",
    "progress": "Progress",
}


def _mode_titles() -> dict[str, str]:
    return {mid: title for mid, title, _ in MODE_CHOICES}


# ── screens ─────────────────────────────────────────────────────────────────────────
class WelcomeScreen:
    """The first screen (#67): explainer + the three journey entry points."""

    slug = "welcome"
    title = "HugMesh Image Studio"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002 — protocol signature
        return None

    def lines(self, j: "Journey") -> list[str]:  # noqa: ARG002
        out = [
            "HugMesh is a self-hosted mesh: a small cluster of nodes (Raspberry "
            "Pi and x86) that serves chat, social, storage and single-sign-on "
            "for your people, plus branded desktop clients that join it. This "
            "studio assembles every piece — from a local trial mesh in Docker "
            "to production node images you flash onto real hardware.",
            f"New here? Read the getting-started guide: {README_GETTING_STARTED}",
            "",
        ]
        for i, (_cid, label, desc) in enumerate(WELCOME_CHOICES, 1):
            out.append(f"  {i}. {label}")
            out.append(f"     {desc}")
        out.append("")
        out.append("(Enter = Start building — the default)")
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "welcome> "

    def feed(self, j: "Journey", line: str) -> None:
        choice = "build" if line == "" else _pick_id(WELCOME_CHOICES, line)
        if choice is None:
            j.status = f"unrecognised choice: {line!r} (a NUMBER picks; q quits)"
            return
        # the GUI welcome page raises the SAME transient flag its localmesh card
        # raises on ModePage — never persisted into cfg (cfg.mode stays an image
        # mode); ModePage re-derives it on its own commit.
        j.flags["localmesh_selected"] = (choice == "localmesh")
        target = WELCOME_TARGET[choice]
        if target == "sessions":
            # the sessions review is owned by the face (plain loop / urwid
            # widget, both already exist) — the journey only asks for it.
            j.effect = "sessions"
            return
        j.goto(target)


class ModeScreen:
    """The journey-ordered menu of choices (#67) — gui/pages/mode.py's twin."""

    slug = "mode"
    title = "What do you want to build?"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:
        out = ["Pick one. Three of these build an image; the rest are side-flows "
               "(no image build)."]
        out.append("")
        for i, (mid, label, desc) in enumerate(MODE_CHOICES, 1):
            marker = "*" if j.cfg.mode == mid else " "
            out.append(f" {marker}{i:2d}. {label}")
            out.append(f"      {desc}")
        out.append("")
        out.append(f"(Enter = {_mode_titles()[MODE_DEFAULT_CHOICE]} — the "
                   "default, by id; * marks the loaded config's mode)")
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "mode> "

    def feed(self, j: "Journey", line: str) -> None:
        mid = MODE_DEFAULT_CHOICE if line == "" else _pick_id(MODE_CHOICES, line)
        if mid is None:
            j.status = f"unrecognised choice: {line!r} (a NUMBER picks; q quits)"
            return
        j.commit_mode(mid)


class PendingSideFlow:
    """A side-flow the TUI does not host yet — honest stub, back to the menu."""

    def __init__(self, slug: str, title: str):
        self.slug = slug
        self.title = title

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:  # noqa: ARG002
        return [f"The {self.title} flow is not yet ported to the TUI — run it "
                "from the GUI (python -m hugmesh_studio).",
                "", "(Enter returns to the menu of choices)"]

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return f"{self.slug}> "

    def feed(self, j: "Journey", line: str) -> None:  # noqa: ARG002
        j.goto("mode")


class PendingStep:
    """A wizard step not ported yet: keeps the config's defaults and continues."""

    def __init__(self, slug: str, title: str):
        self.slug = slug
        self.title = title

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:  # noqa: ARG002
        return [PENDING_NOTE]

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return f"{self.slug} (Enter=continue)> "

    def feed(self, j: "Journey", line: str) -> None:  # noqa: ARG002
        j.advance()


class IdpScreen:
    """The mesh-node identity-provider step — Casdoor is pickable; the external
    providers need issuer/client-id plumbing the TUI has not ported, so they are
    LISTED but refused with the reason (the inert-control rule, not a dead end)."""

    slug = "idp"
    title = "Identity provider (mesh nodes)"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:
        out = ["Which identity provider will this mesh's nodes trust?", ""]
        for i, idp in enumerate(IDP_CHOICES, 1):
            marker = "*" if j.cfg.idp == idp else " "
            out.append(f" {marker}{i}. {IDP_LABELS[idp]}")
        out.append("")
        out.append("External providers (issuer/client-id entry) are not yet "
                   "ported to the TUI — pick them in the GUI. Enter keeps "
                   f"{IDP_LABELS[j.cfg.idp]!r}.")
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "idp> "

    def feed(self, j: "Journey", line: str) -> None:
        if line == "":
            j.advance()
            return
        idx = _index(line, len(IDP_CHOICES))
        if idx is None:
            j.status = f"unrecognised choice: {line!r} (a NUMBER picks; q quits)"
            return
        idp = IDP_CHOICES[idx]
        if idp != "casdoor":
            # honest refusal, state unchanged — never a silently-inert pick
            j.status = (f"{IDP_LABELS[idp]} needs issuer/client-id entry that is "
                        "not yet ported to the TUI — configure it in the GUI "
                        f"(kept: {IDP_LABELS[j.cfg.idp]}).")
            return
        j.cfg.idp = "casdoor"
        j.advance()


#: TUI edit vocabulary for the secrets-store step: command letter -> cfg field.
#: One entry per VAULT_FIELDS member, in order — the GUI/TUI parity test pins the
#: two faces edit exactly the same trio.
VAULT_COMMANDS = {"a": "vault_addr", "m": "vault_kv_mount", "p": "vault_base_path"}
assert tuple(VAULT_COMMANDS.values()) == VAULT_FIELDS


class VaultScreen:
    """The mesh SECRETS-STORE step (issue #224) — the TUI twin of gui/pages/vault.py.

    Edits the SAME ``cfg.vault_*`` trio through the SAME fail-closed predicate
    (``config.vault_field_error``), so what this face accepts is exactly what the
    argv accepts. Every edit is validated BEFORE it is committed and a refusal is an
    inline status line (never a dead end, never a silently-inert command); clearing
    the address clears the two paths with it — the byte-identity rule the GUI's
    validatePage applies. Enter keeps the current values and continues."""

    slug = "vault"
    title = "Secrets store (HashiCorp Vault, mesh nodes)"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:
        cfg = j.cfg
        out = ["Where this mesh's nodes fetch cluster secrets from at first boot.",
               "Empty address = no flag; the builder bakes nothing unless brand.conf "
               "sets VAULT_ADDR (then secrets come off the KEYS stick).",
               ""]
        if cfg.vault_addr:
            out += [f"  address    {cfg.vault_addr}",
                    f"  KV mount   {cfg.vault_kv_mount or VAULT_KV_MOUNT_DEFAULT + ' (builder default)'}",
                    f"  base path  {cfg.vault_base_path or '<brand> (builder default)'}",
                    "",
                    "  Every x86/rpi5 node in the worklist bakes these into "
                    "/etc/hugmesh/vault.conf.", ""]
        else:
            out += ["  address    (none — no flag emitted; brand.conf VAULT_ADDR or "
                    "offline KEYS-stick delivery)", ""]
        out += [
            "commands:",
            "  a URL|-     Vault address (https://…; - clears it and the two paths)",
            "  m NAME|-    KV v2 mount (- = the builder default "
            f"'{VAULT_KV_MOUNT_DEFAULT}')",
            "  p PATH|-    base path under the mount (- = the builder default: the "
            "brand slug)",
            "  Enter       keep these and continue",
            "",
            "The Vault token and unseal key are never entered here: put them on the "
            "KEYS stick (vault/token, vault/unseal-key). A .vault block in the "
            "stick's provision.json overrides this step.",
        ]
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "vault> "

    def feed(self, j: "Journey", line: str) -> None:
        if line == "":
            j.advance()
            return
        cmd, _, arg = line.partition(" ")
        cmd = cmd.strip().lower()
        arg = arg.strip()
        field = VAULT_COMMANDS.get(cmd)
        if field is None:
            j.status = (f"unrecognised command: {line!r} (a/m/p set a value, "
                        "Enter continues, q quits)")
            return
        if not arg:
            j.status = f"{cmd} needs a value (or - to clear)"
            return
        cfg = j.cfg
        new = {f: getattr(cfg, f) for f in VAULT_FIELDS}
        new[field] = "" if arg == "-" else arg
        if field == "vault_addr" and not new["vault_addr"]:
            # clearing the address clears the residue with it (byte-identity)
            new["vault_kv_mount"] = new["vault_base_path"] = ""
        err = vault_field_error(new["vault_addr"], new["vault_kv_mount"],
                                new["vault_base_path"])
        if err:
            # honest refusal, state unchanged — the same sentence the GUI shows
            j.status = f"refused: {err}"
            return
        for f, v in new.items():
            setattr(cfg, f, v)


class RoleScreen:
    """The single-image role picker (standalone/cloud; mesh uses the worklist)."""

    slug = "role"
    title = "Image role"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def _choices(self, j: "Journey"):
        return ROLE_CHOICES[j.cfg.mode]

    def lines(self, j: "Journey") -> list[str]:
        out = ["Pick the image role.", ""]
        for i, (role, _platforms, label) in enumerate(self._choices(j), 1):
            marker = "*" if j.cfg.role == role else " "
            out.append(f" {marker}{i:2d}. {label}")
        out.append("")
        out.append(f"(Enter keeps {j.cfg.role!r})")
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "role> "

    def feed(self, j: "Journey", line: str) -> None:
        choices = self._choices(j)
        if line != "":
            idx = _index(line, len(choices))
            if idx is None:
                j.status = f"unrecognised choice: {line!r} (a NUMBER picks)"
                return
            role, platforms, _label = choices[idx]
            j.cfg.role = role
            j.cfg.platform = platforms[0]
        # the ModePage/RolePage bundle_source rule: standalone bundles the
        # generator source EXCEPT the unaffiliated role (builder hard-conflict).
        if j.cfg.mode == "standalone":
            j.cfg.bundle_source = j.cfg.role != UNAFFILIATED_ROLE
        j.advance()


class WorklistScreen:
    """The mesh worklist: role x platform toggles. Honours the localcloud
    restriction hook (#65): when :attr:`Journey.worklist_role_allow` is set, ONLY
    the allow-set's role rows are offered — and because collection reads the same
    restricted row list, a disallowed row can never be collected either (the
    GUI enforces this in three places because its search filter is
    presentation-only; the TUI's single row source needs exactly one)."""

    slug = "worklist"
    title = "Mesh worklist"

    def __init__(self):
        self._rows: list[tuple[str, str, str]] = []   # (role, platform, label)
        self._checked: set[int] = set()

    def enter(self, j: "Journey") -> None:
        allow = j.worklist_role_allow
        self._rows = [
            (role, platform, label)
            for role, platforms, label in ROLE_CHOICES["mesh"]
            if allow is None or role in allow
            for platform in platforms
        ]
        self._checked = {i for i, (role, _p, _l) in enumerate(self._rows)
                         if j.worklist is not None
                         and any(e.role == role and e.platform == _p
                                 for e in j.worklist.entries)}

    def lines(self, j: "Journey") -> list[str]:
        out = ["Pick every image this mesh build produces (a NUMBER toggles):", ""]
        if j.worklist_role_allow is not None:
            out.insert(0, "Abbreviated flow: only the laptop and cluster-node "
                          "image types are offered (create nodes for local "
                          "cloud).")
        for i, (role, platform, label) in enumerate(self._rows, 1):
            mark = "x" if (i - 1) in self._checked else " "
            out.append(f" [{mark}] {i:2d}. {role}.{platform} — {label}")
        out.append("")
        out.append("(Enter = continue with the checked rows)")
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "worklist> "

    def feed(self, j: "Journey", line: str) -> None:
        if line == "":
            if not self._checked:
                j.status = "pick at least one row first (a NUMBER toggles)"
                return
            entries = [WorklistEntry(role=role, platform=platform)
                       for i, (role, platform, _label) in enumerate(self._rows)
                       if i in self._checked]
            j.worklist = WorklistConfig(base=j.cfg, entries=entries)
            j.advance()
            return
        idx = _index(line, len(self._rows))
        if idx is None:
            j.status = f"no such row: {line!r}"
            return
        if idx in self._checked:
            self._checked.discard(idx)
        else:
            self._checked.add(idx)


class YesNoStep:
    """One of the two ask-19/20 CHOICE screens: a y/N that sets a cfg flag.
    Enter KEEPS the current value (a localcloud import may already have set it)."""

    def __init__(self, slug: str, title: str, question: str, field: str):
        self.slug = slug
        self.title = title
        self.question = question
        self.field = field

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:
        current = "yes" if getattr(j.cfg, self.field) else "no"
        return [self.question, "", f"(Enter keeps the current answer: {current})"]

    def prompt(self, j: "Journey") -> str:
        return f"{self.slug} [y/n]> "

    def feed(self, j: "Journey", line: str) -> None:
        answer = line.strip().lower()
        if answer in ("y", "yes"):
            setattr(j.cfg, self.field, True)
        elif answer in ("n", "no"):
            setattr(j.cfg, self.field, False)
        elif answer != "":
            j.status = "answer y or n (Enter keeps the current answer)"
            return
        j.advance()


class UsersScreen:
    """The users table, read-only for now: the imported/configured accounts are
    VISIBLE (the #65 import lands here) — row editing is honestly deferred."""

    slug = "users"
    title = "User accounts"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:
        from . import model
        out: list[str] = []
        if j.cfg.users:
            # roles: the FULL set (issue #228), primary first — the GUI RoleCell's
            # checked boxes, joined; a one-role account renders exactly as before.
            headers = ["#", "username", "domain", "roles", "registration"]
            rows = [[str(i), u.username, u.domain, ", ".join(u.roles),
                     u.registration or "-"]
                    for i, u in enumerate(j.cfg.users, 1)]
            out += model.format_table(headers, rows)
        else:
            out.append("(no user accounts configured)")
        out.append("")
        out.append("Row editing is not yet ported to the TUI — edit accounts in "
                   "the GUI; these rows are saved with the config as-is.")
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "users (Enter=continue)> "

    def feed(self, j: "Journey", line: str) -> None:  # noqa: ARG002
        j.advance()


class BrandingScreen:
    """Branding assets are pending; the THEMES surface (#63) is real — a screen,
    not a popup (TUI-appropriate), opened with ``t``."""

    slug = "branding"
    title = "Branding & Themes"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:  # noqa: ARG002
        return ["Branding assets (logo/wallpaper/plymouth) are not yet ported "
                "to the TUI — configure them in the GUI if you need them.",
                "",
                "  t. Themes — edit the web login theme (colours, header/footer, "
                "background effect)",
                "", "(Enter continues; t opens the Themes screen)"]

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "branding> "

    def feed(self, j: "Journey", line: str) -> None:
        if line.strip().lower() == "t":
            from .themes import ThemesScreen
            j.open_overlay(ThemesScreen())
            return
        j.advance()


class BuildScreen:
    """The end of the TUI walk: summary + save. The TUI does not RUN builds yet
    (launch/progress are the GUI's), and says so instead of pretending."""

    slug = "build"
    title = "Build"

    def enter(self, j: "Journey") -> None:  # noqa: ARG002
        return None

    def lines(self, j: "Journey") -> list[str]:
        cfg = j.cfg
        out = ["Configured:", f"  mode      {cfg.mode}"]
        if cfg.mode == "mesh" and j.worklist is not None:
            ids = ", ".join(e.id for e in j.worklist.entries)
            out.append(f"  worklist  {len(j.worklist.entries)} image(s): {ids}")
        else:
            out.append(f"  role      {cfg.role} ({cfg.platform})")
        if cfg.mode == "mesh":
            out.append(f"  superdomain  {cfg.effective_superdomain()}")
            if cfg.cluster_domain:
                out.append(f"  apex domain  {cfg.cluster_domain}")
            own = cfg.own_idp_domains()
            out.append(f"  domains   {len(cfg.domains)}"
                       + (f" (own Casdoor: {', '.join(own)})" if own else ""))
            out.append(f"  users     {len(cfg.users)}")
        themed = "customized" if cfg.login_theme_css() else "shipped defaults"
        out.append(f"  themes    {themed}")
        out.append("")
        out.append("The TUI does not run builds yet — save this configuration "
                   "and build it in the GUI (python -m hugmesh_studio) or "
                   "headlessly (python -m hugmesh_studio --print-commands).")
        out.append("")
        out.append("commands: s PATH=save the config · q=finish")
        return out

    def prompt(self, j: "Journey") -> str:  # noqa: ARG002
        return "build> "

    def feed(self, j: "Journey", line: str) -> None:
        verb, _, arg = line.partition(" ")
        if verb.lower() == "s" and arg.strip():
            path = arg.strip()
            try:
                j.cfg.validate_identity()
            except ValueError as exc:
                j.status = f"not saved: {exc}"
                return
            try:
                if j.cfg.mode == "mesh" and j.worklist is not None:
                    warnings = j.worklist.save(path)
                else:
                    warnings = j.cfg.save(path)
            except OSError as exc:
                j.status = f"not saved: {exc}"
                return
            j.status = f"saved to {path}" + ("".join(f"\n! {w}" for w in warnings))
            return
        if line == "" or verb.lower() in ("q", "quit", "exit"):
            j.done = True
            return
        j.status = "commands: s PATH=save the config · q=finish"


# ── the journey itself ──────────────────────────────────────────────────────────────
def _pick_id(choices, line: str) -> str | None:
    idx = _index(line, len(choices))
    return None if idx is None else choices[idx][0]


def _index(line: str, count: int) -> int | None:
    try:
        n = int(line.strip())
    except ValueError:
        return None
    return n - 1 if 1 <= n <= count else None


class Journey:
    """The face-independent journey state machine (see the module docstring)."""

    def __init__(self, generator_dir: str = ".", cfg: ImageConfig | None = None):
        from .domains_step import DomainsScreen
        from .e2e import E2EScreen
        from .localcloud import LocalCloudScreen
        from .meshemu import MeshEmuScreen
        from .qemu import QemuScreen
        self.generator_dir = generator_dir
        self.cfg = cfg or ImageConfig()
        self.worklist: WorklistConfig | None = None
        #: The #65 restriction hook — the TUI twin of ``wiz.worklist_role_allow``:
        #: None = full catalog; an iterable of mesh role ids = only those rows.
        self.worklist_role_allow: tuple[str, ...] | None = None
        #: transient side-flow flags (the GUI's wiz.*_selected) — never persisted.
        self.flags: dict[str, bool] = {}
        self.status = ""            # one-shot inline message (inline, never a modal)
        self.done = False
        self.effect: str | None = None   # "sessions" -> the face runs its review
        self.overlay = None              # e.g. the Themes screen (a screen object)
        screens = [
            WelcomeScreen(), ModeScreen(),
            LocalCloudScreen(), E2EScreen(), QemuScreen(), MeshEmuScreen(),
            IdpScreen(), RoleScreen(), WorklistScreen(),
            YesNoStep("domains_choice", "Domains",
                      "Add more domains beyond the internal Tailscale root "
                      "domain (public go-live domains this mesh serves)?",
                      "additional_domains"),
            DomainsScreen(),
            YesNoStep("users_choice", "User accounts",
                      "Configure user accounts for this mesh now?",
                      "configure_users"),
            UsersScreen(), BrandingScreen(), VaultScreen(), BuildScreen(),
        ]
        self._screens = {s.slug: s for s in screens}
        for slug, title in _SIDE_FLOW_STUB.items():
            self._screens[slug] = PendingSideFlow(slug, title)
        for slug, title in _PENDING_STEPS.items():
            self._screens.setdefault(slug, PendingStep(slug, title))
        # "sessions" never renders as a journey screen (the face owns the review),
        # but the registry must still cover EVERY canonical slug — parity-pinned.
        self._screens.setdefault("sessions", PendingStep("sessions", "Sessions"))
        missing = [s for s in PAGE_ORDER if s not in self._screens]
        assert not missing, f"journey screens missing for slugs: {missing}"
        self.slug = PAGE_ORDER[0]        # a fresh start lands on welcome (#67)
        self.screen().enter(self)

    # ── screen protocol plumbing ────────────────────────────────────────────────
    def screen(self):
        return self.overlay if self.overlay is not None else self._screens[self.slug]

    def screen_for(self, slug: str):
        return self._screens[slug]

    def title(self) -> str:
        return self.screen().title

    def lines(self) -> list[str]:
        out = [self.title(), ""]
        out += self.screen().lines(self)
        if self.status:
            out += ["", *self.status.splitlines()]
        return out

    def prompt(self) -> str:
        return self.screen().prompt(self)

    def feed(self, line: str) -> None:
        """One input line. Global: q quits the journey — EXCEPT on screens that
        declare ``wants_q`` (overlays and sub-state screens, where q means BACK
        and the screen handles it itself)."""
        self.status = ""
        self.effect = None
        line = line.strip()
        screen = self.screen()
        if line.lower() in ("q", "quit", "exit") and not getattr(
                screen, "wants_q", False):
            self.done = True
            return
        screen.feed(self, line)

    def open_overlay(self, screen) -> None:
        self.overlay = screen
        screen.enter(self)

    def close_overlay(self) -> None:
        self.overlay = None

    # ── navigation ──────────────────────────────────────────────────────────────
    def goto(self, slug: str) -> None:
        self.overlay = None
        self.slug = slug
        self._screens[slug].enter(self)

    def advance(self) -> None:
        """The positional walk: the next canonical slug that APPLIES — the TUI
        twin of StudioWizard.nextId's skip rules (kept together for review):

        * "sessions" is only entered from welcome; side-flows only via their card;
        * MODE_SKIPPED_PAGES skips the per-mode inapplicable steps;
        * the domains/users tables show only when their choice screen said yes
          (mesh; a cloud client's tables are unconditional);
        * launch/progress are the GUI's build-runner surfaces — the TUI walk
          terminates at "build" (which says so).
        """
        cfg = self.cfg
        i = PAGE_ORDER.index(self.slug)
        for slug in PAGE_ORDER[i + 1:]:
            if slug == "sessions" or slug in SIDE_FLOW_SLUGS:
                continue
            if slug in MODE_SKIPPED_PAGES.get(cfg.mode, ()):
                continue
            if slug == "domains" and cfg.mode == "mesh" \
                    and not cfg.additional_domains:
                continue
            if slug == "users" and cfg.mode == "mesh" \
                    and not cfg.configure_users:
                continue
            if slug in ("launch", "progress"):
                continue
            self.goto(slug)
            return
        self.done = True

    # ── the mode commit (gui/pages/mode.py::validatePage, mirrored) ─────────────
    def commit_mode(self, mid: str) -> None:
        # "qemu" is in SIDE_FLOW_SLUGS but is no longer a mode-menu id, so this
        # comprehension only ever CLEARS qemu_selected. The single writer that can
        # RAISE it is E2EScreen's device-lane door (the GUI twin: E2EPage._sync_arm).
        # Its MEMBERSHIP is still load-bearing and must not be tidied away with the
        # dead comparison: it is what keeps _advance's positional walk off the qemu
        # screen and what lets goto("qemu") resolve. Pinned by
        # test_tui_journey::test_qemu_stays_a_side_flow_slug_even_though_its_card_went.
        #
        # ModePage's mirror of this line is deliberately CONDITIONAL
        # (``qemu_selected and mid == "e2e"``) rather than a flat clear, because Qt
        # re-runs a visited page's validatePage from collect_all() and that would
        # disarm an arm the operator had just picked. The TUI has no such re-run —
        # commit_mode is reached only from ModeScreen.feed — and E2EScreen.enter()
        # resets its own sub-state on every entry, so an unconditional clear here IS
        # the same visible behaviour, not a second rule.
        self.flags = {f"{slug}_selected": (mid == slug)
                      for slug in SIDE_FLOW_SLUGS}
        if mid != "localcloud":
            # any other committed choice lifts the abbreviated-worklist
            # restriction the localcloud gate installs (#65).
            self.worklist_role_allow = None
        if mid in SIDE_FLOW_SLUGS:
            self.goto(mid)               # side-flows commit NOTHING to cfg.mode
            return
        cfg = self.cfg
        prev = cfg.mode
        cfg.mode = mid
        if cfg.role not in {r for r, _, _ in ROLE_CHOICES[mid]}:
            cfg.role = MODE_DEFAULT_ROLE[mid]
        cfg.bundle_source = (mid == "standalone"
                             and cfg.role != UNAFFILIATED_ROLE)
        if mid == "mesh":
            enter_mesh_defaults(cfg, fresh=(prev != "mesh"))
            if prev != "mesh":
                self.worklist = None     # fresh worklist on transition into mesh
        else:
            if prev == "mesh":
                self.worklist = None     # stranded rows never survive a switch
            if mid == "standalone":
                # standalone skips the admin-plane pages: clear what an earlier
                # cloud/mesh detour parked, so unreachable pages can't strand
                # stale state into save() (mode.py's exact clears).
                cfg.keyzip = ""
                cfg.domains = []
                cfg.users = []
                cfg.additional_domains = False
                cfg.configure_users = False
                cfg.tailscale = False
                cfg.sso = False
        self.advance()
