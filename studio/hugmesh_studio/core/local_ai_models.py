"""A model for the local assistant, out of the box: what to offer and how to pull it.

Qt-free, stdlib only. The Studio panel, the text UI's Local AI screen and the command
line (``scripts/local-ai.sh pull``) all go through this module, so the offer, the size
and the words are the same everywhere.

WHY. A fresh Ollama, the system one or the Studio's own Docker one, has no model.
Starting it starts a server and nothing else, and before this module the only answer to
an empty server was a shell command to copy. The Flatpak and the Windows build have no
shell to paste it into, so the assistant could not answer anything out of the box.

THE OFFER. One click (or ``pull`` / ``--yes``) downloads a SMALL model, with the size
and the free space shown before anything is fetched. Never silently: the default was a
5.2 GB model, and an unasked download of that size is not a thing to do to a person on a
metered line. The sizes are a static table (below, and docs/LOCAL-AI-ASSISTANT.md
section 4), because ``/api/pull`` says nothing about size until the manifest is in, and
asking the registry first would be the Studio's first call off this machine.

THE PULL. ``POST /api/pull`` on the same loopback-only opener every other request
uses (no proxy, no redirects, nothing off this machine). It streams one JSON object per
line; an ``{"error": ...}`` line is a failure even under HTTP 200 (a misspelled name
answers exactly that way). Closing the connection cancels the download, and Ollama keeps
the parts it already has, so the next pull resumes. Measured on 2026-11-09 against
ollama/ollama 0.40.0, from inside the Flatpak sandbox too.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional

from . import local_ai_status as lai

__all__ = [
    "Choice", "RECOMMENDED", "TINY", "LARGER", "CHOICES", "HEADROOM", "NoModel",
    "PullProgress", "PullResult", "size_of", "size_words", "is_docker", "where_words",
    "manual_command", "offer_for", "action_words", "fix_words", "free_bytes", "space_problem",
    "consent_line", "pull", "save_choice", "saved_choice", "active_line", "main",
]


@dataclass(frozen=True)
class Choice:
    name: str
    bytes: int
    words: str


#: The model offered first. Measured 2026-11-09 on CPU only (no GPU passed to the
#: container, 28 threads): about 14 s for the first short answer, under 1 s once it is
#: loaded, about 29 s for a fully grounded question. It has the ``tools`` and
#: ``thinking`` capabilities, so the local-agent card can use it too.
RECOMMENDED = Choice("qwen3:1.7b", 1_359_293_444,
                     "small and quick, even without a GPU; can use tools")
#: For a machine short of memory. About 10 s for a first short answer on CPU.
TINY = Choice("qwen3:0.6b", 522_640_096, "the smallest; for a machine short of memory")
#: The model the docs verified an agent on (section 6.2): better answers, needs a GPU
#: or patience. Offered as the next step once a small one works.
LARGER = Choice("qwen3:8b", 5_200_000_000, "better answers; wants a GPU with 8 GB")
CHOICES = (RECOMMENDED, TINY, LARGER)

#: Free space left over after a download, so a pull never fills the disk to the byte.
HEADROOM = 1_000_000_000

#: The command-line spelling of the pull, for sentences the command line prints.
CLI_PULL = "scripts/local-ai.sh pull"


def size_of(name: str) -> Optional[int]:
    return next((c.bytes for c in CHOICES if c.name == name), None)


def size_words(n: Optional[int]) -> str:
    """Bytes as a person reads a download: ``1.4 GB``, ``523 MB`` (decimal, as Ollama
    itself lists sizes)."""
    if n is None:
        return "size unknown"
    if n >= 1_000_000_000:
        return f"{n / 1e9:.1f} GB"
    return f"{max(1, round(n / 1e6))} MB"


# ── which Ollama ─────────────────────────────────────────────────────────────────────
def is_docker(env: Optional[dict] = None) -> bool:
    """True when ``env`` points the assistant at the Studio's own Docker Ollama (its
    loopback port), the same test the not-answering sentences use."""
    from . import ollama_docker as odk
    env = os.environ if env is None else env
    try:
        here = lai._hostport(*lai.ollama_host(env))
    except lai.NotLoopback:
        return False
    return here == odk.endpoint(odk.DOCKER, env)


def where_words(env: Optional[dict] = None) -> str:
    from . import ollama_docker as odk
    if is_docker(env):
        return f"the Studio's Docker Ollama ({odk.CONTAINER})"
    try:
        host = lai._hostport(*lai.ollama_host(env))
    except lai.NotLoopback:
        host = lai.DEFAULT_HOST
    return f"the Ollama on {host}"


def manual_command(model: str, env: Optional[dict] = None) -> str:
    """The by-hand pull for the instance ``env`` names: never ``ollama pull`` when that
    instance is the container (it would fill the SYSTEM store and leave the container
    empty, the contradiction the 2026-11-09 report showed)."""
    from . import ollama_docker as odk
    if is_docker(env):
        return odk.pull_command(model)
    return f"ollama pull {model}"


class NoModel(lai.LocalAIError):
    """The chosen Ollama answers but has no model to answer with (``gone`` = the model
    that was asked for by name is not pulled). ``offer`` says what to download:
    ``{"model", "bytes", "docker"}``; every face shows it with its own button or word."""

    def __init__(self, model: str = "", env: Optional[dict] = None, *, gone: bool = False):
        name = model or RECOMMENDED.name
        self.model = name
        self.gone = gone
        self.offer = {"model": name, "bytes": size_of(name), "docker": is_docker(env)}
        where = where_words(env)
        lead = (f"The model {name} is not pulled into {where}." if gone else
                f"No model is pulled into {where} yet, so it cannot answer.")
        super().__init__(f"{lead} By hand: {manual_command(name, env)}")


def offer_for(env: Optional[dict] = None) -> dict:
    """The offer for an instance with no model: the recommended one."""
    return {"model": RECOMMENDED.name, "bytes": RECOMMENDED.bytes, "docker": is_docker(env)}


#: How each face says "press the thing": the panel has a button, the text screen a word,
#: the command line the script.
_FACE_ACTION = {
    "gui": "Press Download below to fetch {model} ({size})",
    "tui": "Type pull to download {model} ({size})",
    "cli": "Download {model} ({size}) with: " + CLI_PULL,
}


def action_words(offer: dict, face: str = "cli") -> str:
    """``Press Download below to fetch qwen3:1.7b (1.4 GB).``: what to do in ``face``
    (``gui``, ``tui`` or ``cli``), the line each face puts after a :class:`NoModel`."""
    model = str(offer.get("model") or RECOMMENDED.name)
    return _FACE_ACTION.get(face, _FACE_ACTION["cli"]).format(
        model=model, size=size_words(offer.get("bytes"))) + "."


def fix_words(offer: dict, face: str = "cli", env: Optional[dict] = None) -> str:
    """The fix line for a no-model snapshot, in ``face``'s words, with the by-hand
    command for the right instance after it."""
    model = str(offer.get("model") or RECOMMENDED.name)
    return f"{action_words(offer, face)[:-1]}; by hand: {manual_command(model, env)}."


# ── free space ───────────────────────────────────────────────────────────────────────
def _models_dir_candidates(env: dict) -> list:
    home = env.get("HOME") or os.path.expanduser("~")
    out = []
    if env.get("OLLAMA_MODELS"):
        out.append(env["OLLAMA_MODELS"])
    out += [os.path.join(home, ".ollama", "models"), "/usr/share/ollama/.ollama/models",
            "/var/lib/ollama", os.path.join(home, ".ollama"), home]
    return out


def free_bytes(env: Optional[dict] = None, *, runner=None, container: str = "",
               disk_usage=shutil.disk_usage) -> Optional[int]:
    """Free bytes where the models of the instance ``env`` names are stored, or None
    when that cannot be read (the pull is then not refused; the screen says so).

    Docker: ``df`` inside the container (the models volume), run through the host
    bridge so a Flatpak Studio can ask too. System: the folder Ollama keeps its models
    in, or the nearest one that exists."""
    from . import ollama_docker as odk
    env = os.environ if env is None else env
    if is_docker(env):
        run = runner or odk._run
        rc, out = run(["docker", "exec", container or odk.CONTAINER, "df", "-B1",
                       "--output=avail", "/root/.ollama"], 20.0)
        if rc != 0:
            return None
        nums = [w for w in out.split() if w.isdigit()]
        return int(nums[-1]) if nums else None
    for path in _models_dir_candidates(env):
        if path and os.path.isdir(path):
            try:
                return int(disk_usage(path).free)
            except OSError:
                continue
    return None


def space_problem(size: Optional[int], free: Optional[int]) -> str:
    """A sentence when ``free`` is too little for ``size`` plus the headroom, else ""."""
    if size is None or free is None:
        return ""
    if free < size + HEADROOM:
        return (f"Not enough free space: the download is {size_words(size)} and only "
                f"{size_words(free)} is free (keep {size_words(HEADROOM)} spare). Free some "
                "space, or pick a smaller model.")
    return ""


def consent_line(model: str, free: Optional[int]) -> str:
    """``Download qwen3:1.7b (1.4 GB; 120.3 GB free)?`` — what is asked before a pull."""
    tail = f"{size_words(free)} free" if free is not None else "free space unknown"
    return f"Download {model} ({size_words(size_of(model))}; {tail})?"


# ── the pull ─────────────────────────────────────────────────────────────────────────
@dataclass
class PullProgress:
    status: str = ""
    completed: int = 0
    total: int = 0

    @property
    def fraction(self) -> Optional[float]:
        return (min(1.0, self.completed / self.total)) if self.total > 0 else None

    def words(self, model: str = "") -> str:
        """``pulling 37% (512/1359 MB)``; the server's own status before bytes move."""
        f = self.fraction
        if f is None:
            return self.status or "starting"
        return (f"pulling {int(f * 100)}% ({self.completed // 1_000_000}/"
                f"{self.total // 1_000_000} MB)")


@dataclass
class PullResult:
    ok: bool
    model: str
    message: str
    cancelled: bool = False


_ACTIVE_LOCK = threading.Lock()
_ACTIVE: dict = {}                 # model -> the latest progress line (this process)
_LAST: list = []                   # [(when, sentence)] of the last pull that ended
#: How long the line under a terminal screen keeps saying how the last download ended.
LAST_SHOWN_S = 120.0


def active_line(now: Optional[float] = None) -> str:
    """The pull running in this process as one line (``downloading qwen3:1.7b: pulling
    37% (512/1359 MB)``), else how the last one ended for a short while, else ""."""
    now = time.monotonic() if now is None else now
    with _ACTIVE_LOCK:
        if _ACTIVE:
            model, words = next(iter(_ACTIVE.items()))
            return f"downloading {model}: {words}"
        if _LAST and now - _LAST[0][0] <= LAST_SHOWN_S:
            return _LAST[0][1]
    return ""


def _ended(res: "PullResult") -> "PullResult":
    with _ACTIVE_LOCK:
        _LAST[:] = [(time.monotonic(), res.message)]
    return res


def pull(model: str, env: Optional[dict] = None, **kw) -> PullResult:
    """Download ``model``; see :func:`_pull`. The result is also kept for
    :func:`active_line`, so a terminal's status line can say how it ended."""
    return _ended(_pull(model, env, **kw))


def _pull(model: str, env: Optional[dict] = None, *,
         on_progress: Optional[Callable[[PullProgress], None]] = None,
         should_stop: Optional[Callable[[], bool]] = None,
         timeout: float = 120.0, save: bool = True) -> PullResult:
    """Download ``model`` into the Ollama ``env`` names. Blocking: call it off the
    window thread. Never raises; the result says what happened in a sentence.

    ``on_progress`` gets a :class:`PullProgress` per line (the bytes summed over every
    layer, against the table's size when that is larger, so the bar never runs back).
    ``should_stop`` is polled between lines; when it turns true the connection is closed
    and the download stops (Ollama keeps what it has; the next pull resumes).
    ``timeout`` is the longest silence tolerated: fetching the manifest can be quiet for
    several seconds. ``save`` remembers the model as the assistant's choice on success."""
    env = os.environ if env is None else env
    model = (model or "").strip()
    if not model:
        return PullResult(False, model, "No model named.")
    try:
        url = lai.base_url(env) + "/api/pull"
    except lai.NotLoopback as exc:
        return PullResult(False, model, str(exc))
    body = json.dumps({"model": model, "name": model, "stream": True}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
    layers: dict = {}
    known = size_of(model) or 0
    prog = PullProgress()
    succeeded = False
    with _ACTIVE_LOCK:
        _ACTIVE[model] = "starting"
    try:
        with lai._opener().open(req, timeout=timeout) as resp:
            for raw in resp:
                if should_stop is not None and should_stop():
                    return PullResult(False, model, f"Stopped downloading {model}. What "
                                      "arrived is kept; the next download resumes.", True)
                if not raw.strip():
                    continue
                try:
                    line = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(line, dict):
                    continue
                if line.get("error"):
                    return PullResult(False, model, _error_sentence(model, str(line["error"])))
                status = str(line.get("status") or "")
                digest = line.get("digest")
                if digest and isinstance(line.get("total"), int):
                    layers[digest] = (int(line.get("completed") or 0), int(line["total"]))
                done = sum(c for c, _t in layers.values())
                total = max(sum(t for _c, t in layers.values()), known if layers else 0)
                prog = PullProgress(status, done, total)
                with _ACTIVE_LOCK:
                    _ACTIVE[model] = prog.words(model)
                if on_progress is not None:
                    on_progress(prog)
                if status == "success":
                    succeeded = True
                    break
    except urllib.error.HTTPError as exc:
        return PullResult(False, model, f"Ollama refused the download (HTTP {exc.code}). "
                          + ("This Ollama is too old for that model; update it."
                             if exc.code == 412 else ""))
    except TimeoutError:
        return PullResult(False, model, f"Nothing arrived for {int(timeout)} seconds; the "
                          "download stopped. Check the network and try again (it resumes).")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        if "timed out" in str(exc):
            return PullResult(False, model, f"Nothing arrived for {int(timeout)} seconds; "
                              "the download stopped. Check the network and try again "
                              "(it resumes).")
        return PullResult(False, model, f"Ollama is not answering on "
                          f"{lai._hostport(*lai.ollama_host(env))}; start it first.")
    except Exception as exc:            # noqa: BLE001 — a cut stream (IncompleteRead)
        return PullResult(False, model, f"The download was cut off ({exc.__class__.__name__}). "
                          "Try again; it resumes where it stopped.")
    finally:
        with _ACTIVE_LOCK:
            _ACTIVE.pop(model, None)
    if not succeeded:
        return PullResult(False, model, f"The download of {model} ended before Ollama said "
                          "it was complete. Try again; it resumes where it stopped.")
    if save:
        save_choice(model)
    return PullResult(True, model, f"{model} is downloaded and ready.")


def _error_sentence(model: str, said: str) -> str:
    low = said.lower()
    if "file does not exist" in low or "not found" in low:
        return (f"There is no model called {model} in the Ollama library (Ollama said: "
                f"{said}). Check the spelling.")
    if "newer version" in low or "412" in low:
        return f"This Ollama is too old for {model} (Ollama said: {said}). Update it."
    if "no space" in low:
        return f"The disk is full (Ollama said: {said}). Free some space and try again."
    return f"Ollama could not download {model}: {said}"


# ── the remembered choice ────────────────────────────────────────────────────────────
def save_choice(model: str) -> bool:
    from . import assistant_settings
    return assistant_settings.update(model=model)


def saved_choice() -> str:
    from . import assistant_settings
    try:
        value = assistant_settings.get("model", "")
    except Exception:                    # noqa: BLE001 — a convenience, never a crash
        return ""
    return value.strip() if isinstance(value, str) else ""


# ── python -m hugmesh_studio.core.local_ai_status pull [MODEL] [--yes] ───────────────
def main(args: list, *, out=None, err=None, inp=None, env: Optional[dict] = None,
         free=None) -> int:
    """``pull [MODEL] [--yes]``: ask, then download with a progress line. 0 = ready."""
    out = out or sys.stdout
    err = err or sys.stderr
    inp = inp or sys.stdin
    env = os.environ if env is None else env
    yes = any(a in ("--yes", "-y") for a in args)
    names = [a for a in args if not a.startswith("-")]
    model = names[0] if names else RECOMMENDED.name
    try:
        lai._get_json(env, "/api/tags", 5)
    except lai.NotLoopback as exc:
        print(str(exc), file=err)
        return 2
    except lai._NOT_ANSWERING:
        print(f"Ollama is not answering on {lai._hostport(*lai.ollama_host(env))}. Start it "
              "first (scripts/local-ai.sh up, or the Studio's Start local assistant).", file=err)
        return 1
    room = (free or free_bytes)(env)
    problem = space_problem(size_of(model), room)
    if problem:
        print(problem, file=err)
        return 1
    question = consent_line(model, room) + f"  Into {where_words(env)}."
    if not yes:
        out.write(question + " [y/N] ")
        out.flush()
        if inp.readline().strip().lower() not in ("y", "yes"):
            print("Nothing downloaded.", file=out)
            return 1
    else:
        print(question.rstrip("?") + ": yes (--yes).", file=out)
    last = [0.0]

    def show(p: PullProgress) -> None:
        now = time.monotonic()
        if now - last[0] >= 0.5 or p.status == "success":
            last[0] = now
            out.write("\r" + p.words(model).ljust(40))
            out.flush()

    res = pull(model, env, on_progress=show)
    out.write("\n")
    print(res.message, file=out if res.ok else err)
    return 0 if res.ok else 1
