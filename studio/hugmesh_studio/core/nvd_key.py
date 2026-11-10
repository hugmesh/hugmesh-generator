"""The NVD API key OWASP Dependency-Check needs (Qt-free, stdlib only).

WHY THIS EXISTS. The SCA step of the pen-test harness (and every repository's CI
``sca`` / ``pentest:sca`` job) runs OWASP Dependency-Check, which downloads the NVD
CVE feed. Without an NVD API key that download is throttled to 5 requests per 30
seconds against about 420,000 records, and in practice the job dies with exit 13
("[ERROR] Unable to continue dependency-check analysis."). Nothing in the Studio
said a key was needed, and a NEW key is refused by NVD ("Invalid API Key") until
its owner clicks the activation link in NVD's email. See docs/NVD-API-KEY.md.

What this module owns, so the GUI, the TUI and the CLI say the same words and keep
the key the same way:

* the COPY (``NEED_LINE``, ``REQUEST_URL``, ``ACTIVATION_WARNING``, ...);
* the shape check: an NVD key is a UUID; whitespace is stripped, an empty or
  malformed value is refused before anything is stored or sent;
* the STORE: ``<state_dir>/secrets/nvd_api_key``, dir 0700, file 0600, written to a
  private temporary file and renamed into place (``mesh_token._write_private``), with
  a sidecar ``nvd_api_key.meta.json`` holding only a 12-hex PBKDF2 fingerprint, when it was saved
  and the last Verify verdict. The key itself is never in a FleetConfig/ImageConfig
  JSON, a session record, a log, argv, the command preview or the assistant context;
* VERIFY: one GET to NVD's CVE API with the key in the ``apiKey`` header, run only
  on an explicit click, no redirects followed, classified by the responses measured
  on 2026-11-10 (see :func:`classify`);
* the per-run COPY a fleet run hands to ``run-sca.sh`` as ``NVD_API_KEY_FILE``
  (a path is safe on argv; the key is not);
* the optional ``gh secret set NVD_API_KEY --org ORG`` push, value on stdin only;
* :func:`redact`, which blanks the stored key and Dependency-Check's own
  ``XXXXX-*****-XXXXX`` echo of it from a log line;
* the CLI: ``python -m hugmesh_studio.core.nvd_key {status,set,verify,forget,
  push-org-secret}``. There is no flag that takes the key on the command line.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import functools
import getpass
import hashlib
import http.client
import json
import os
import re
import socket
import ssl
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional

from .state_paths import state_dir

__all__ = [
    "NEED_LINE", "REQUEST_URL", "ACTIVATION_WARNING", "EMPTY_REFUSED", "VERIFY_CONSENT",
    "MALFORMED_REFUSED", "GUIDE_URL", "GUIDE_DOC", "SECRET_NAME", "FILE_ENV",
    "DOCKER_SECRET_PATH", "VERIFY_URL", "ORG_SECRET_LABEL", "PREFLIGHT_NO_KEY",
    "OK", "NOT_ACCEPTED", "RATE_LIMITED", "NVD_UNAVAILABLE", "OFFLINE", "MISSING",
    "MALFORMED", "VERDICT_LABELS", "VERDICTS", "NvdKeyError", "VerifyResult",
    "KeyStatus", "PushResult", "push_refusal", "normalise", "check", "key_path", "meta_path", "save",
    "load", "forget", "status", "status_line", "verify", "classify", "record_verdict",
    "materialize_for_run", "export_line", "info_lines", "redact", "make_redactor", "push_org_secret", "main",
]

# ── the words every face shows (GUI widget, TUI ``nvd``, CLI) ─────────────────────────
NEED_LINE = "OWASP Dependency-Check (the SCA step) needs a free NVD API key."
REQUEST_URL = "https://nvd.nist.gov/developers/request-an-api-key"
ACTIVATION_WARNING = ("A new key does not work until you click the activation link in "
                      "NVD's email (allow a few minutes after).")
EMPTY_REFUSED = "An empty value is refused."
MALFORMED_REFUSED = ("That is not an NVD API key: a key is 8-4-4-4-12 hexadecimal "
                     "digits (a UUID). Nothing was stored or sent.")
VERIFY_CONSENT = ("Verify sends the key once to services.nvd.nist.gov (the only outside "
                  "call this makes).")
#: The published guide (hugmesh.net docs site, section operations) and its source.
GUIDE_URL = "https://hugmesh.net/operations/nvd-api-key"
GUIDE_DOC = "docs/NVD-API-KEY.md"
#: The org secret / CI variable name every CI template reads.
SECRET_NAME = "NVD_API_KEY"
#: The POINTER env a fleet run passes to run-sca.sh: a path, never the key.
FILE_ENV = "NVD_API_KEY_FILE"
#: Where the per-run copy is mounted (read-only) inside the docker builder.
DOCKER_SECRET_PATH = "/run/secrets/nvd_api_key"
VERIFY_URL = "https://services.nvd.nist.gov/rest/json/cves/2.0?resultsPerPage=1"
VERIFY_HOST = "services.nvd.nist.gov"
ORG_SECRET_LABEL = f"Also set as GitHub org secret {SECRET_NAME}"
PREFLIGHT_NO_KEY = ("SCA will fail without an NVD API key — set one in Pen-test harness "
                    f"(request one at {REQUEST_URL}).")
ADMIN_ORG_HINT = "needs admin:org: run gh auth refresh -s admin:org"

# ── verdicts ──────────────────────────────────────────────────────────────────────────
OK = "OK"
NOT_ACCEPTED = "NOT_ACCEPTED"
RATE_LIMITED = "RATE_LIMITED"
NVD_UNAVAILABLE = "NVD_UNAVAILABLE"
OFFLINE = "OFFLINE"
MISSING = "MISSING"
MALFORMED = "MALFORMED"
VERDICTS = (OK, NOT_ACCEPTED, RATE_LIMITED, NVD_UNAVAILABLE, OFFLINE, MISSING, MALFORMED)
#: The short label each face puts before the sentence.
VERDICT_LABELS = {
    OK: "accepted",
    NOT_ACCEPTED: "not accepted yet",
    RATE_LIMITED: "rate-limited",
    NVD_UNAVAILABLE: "NVD unavailable",
    OFFLINE: "offline",
    MISSING: "empty",
    MALFORMED: "not a key",
}
#: (after the "not accepted yet: " label every face puts in front of it)
NOT_ACCEPTED_SENTENCE = ("If you just requested it, click the activation link in NVD's "
                         "email and retry in a few minutes; if it has been longer, request "
                         "a new key.")
OFFLINE_SENTENCE = (f"Could not reach {VERIFY_HOST} — check the network/VPN; the key was "
                    "not tested.")
#: CLI exit codes for ``verify``.
EXIT_CODES = {OK: 0, NOT_ACCEPTED: 3, OFFLINE: 4, NVD_UNAVAILABLE: 4, RATE_LIMITED: 5,
              MISSING: 2, MALFORMED: 2}

_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}"
                      r"-[0-9a-fA-F]{12}$")
#: Dependency-Check prints the key's first and last five characters
#: ("Invalid API Key: 33333-*****-77777"): blanked from every Studio log line.
_DC_ECHO_RE = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{5}-\*{5}-[0-9a-fA-F]{5}(?![0-9A-Za-z])")
_ORG_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
_REDACTED = "[NVD key redacted]"


class NvdKeyError(ValueError):
    """A refused key or action. ``verdict`` is MISSING / MALFORMED (or a push
    refusal); ``str()`` is the sentence a face shows inline. Never carries the key."""

    def __init__(self, verdict: str, sentence: str):
        super().__init__(sentence)
        self.verdict = verdict
        self.sentence = sentence


# ── shape ─────────────────────────────────────────────────────────────────────────────
def normalise(raw) -> str:
    """The key as stored and sent: surrounding whitespace (a pasted newline, a trailing
    space — NVD refuses a key with one) stripped. Internal whitespace is NOT removed:
    that is a malformed paste and :func:`check` refuses it."""
    return str(raw or "").strip()


def check(raw) -> str:
    """The normalised key, or :class:`NvdKeyError` (MISSING / MALFORMED). NVD itself
    answers a malformed key exactly like an unknown one, so the shape is checked HERE,
    before anything is stored or sent."""
    key = normalise(raw)
    if not key:
        raise NvdKeyError(MISSING, f"{EMPTY_REFUSED} Paste the key from NVD's email.")
    if not _UUID_RE.match(key):
        raise NvdKeyError(MALFORMED, MALFORMED_REFUSED)
    return key


@functools.lru_cache(maxsize=8)
def _fingerprint(key: str) -> str:
    """A 12-hex id for "is this the same key" (the sidecar's match, the push's
    verified check), shown and stored instead of the key. A slow KDF, not a bare
    hash: the key is a credential, and a plain sha256 of one is what a scanner
    rightly flags (CodeQL py/weak-sensitive-data-hashing). Cached per key."""
    return hashlib.pbkdf2_hmac("sha256", key.encode("utf-8"),
                               b"hugmesh-studio nvd-api-key fingerprint", 50_000).hex()[:12]


# ── store ─────────────────────────────────────────────────────────────────────────────
def key_path() -> str:
    return os.path.join(state_dir(), "secrets", "nvd_api_key")


def meta_path() -> str:
    return key_path() + ".meta.json"


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_meta() -> dict:
    try:
        with open(meta_path(), encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_meta(d: dict) -> None:
    from .mesh_token import _write_private
    _write_private(meta_path(), json.dumps(d, indent=1, sort_keys=True) + "\n")


def save(raw) -> "KeyStatus":
    """Store the key (refusing empty/malformed with :class:`NvdKeyError`). Replaces any
    earlier key; the last verdict is reset, because it was about the old key."""
    from .mesh_token import _makedirs_private, _write_private
    key = check(raw)
    path = key_path()
    _makedirs_private(os.path.dirname(path))
    _write_private(path, key)                 # 0600 temp file + os.replace, no newline
    if os.name != "nt":
        os.chmod(path, 0o600)
    _write_meta({"fingerprint": _fingerprint(key), "saved_at": _now(),
                 "last_verdict": "", "verified_at": ""})
    return status()


def load() -> str:
    """The stored key, or "" when none is stored (or it is unreadable/damaged)."""
    try:
        with open(key_path(), encoding="utf-8") as fh:
            key = normalise(fh.read(4096))
    except (OSError, UnicodeDecodeError):
        return ""
    return key if _UUID_RE.match(key) else ""


def forget() -> bool:
    """Remove the stored key and its sidecar. True when a key was there."""
    had = False
    for p in (key_path(), meta_path()):
        try:
            os.remove(p)
            had = had or p == key_path()
        except FileNotFoundError:
            pass
    return had


@dataclass(frozen=True)
class KeyStatus:
    stored: bool
    fingerprint: str = ""
    saved_at: str = ""
    last_verdict: str = ""
    verified_at: str = ""

    @property
    def verified(self) -> bool:
        return self.stored and self.last_verdict == OK


def status() -> KeyStatus:
    key = load()
    if not key:
        return KeyStatus(False)
    m = _read_meta()
    fp = _fingerprint(key)
    # a sidecar about a different key (replaced by hand) says nothing about this one
    if m.get("fingerprint") != fp:
        m = {}
    return KeyStatus(True, fp, str(m.get("saved_at") or ""),
                     str(m.get("last_verdict") or ""), str(m.get("verified_at") or ""))


def status_line(st: Optional[KeyStatus] = None) -> str:
    """The one-line state every face shows next to the box."""
    st = st or status()
    if not st.stored:
        return "no key stored"
    if st.last_verdict == OK:
        return f"stored, verified {st.verified_at[:10] or 'earlier'}"
    if st.last_verdict == NOT_ACCEPTED:
        return f"stored — {VERDICT_LABELS[NOT_ACCEPTED]}: {NOT_ACCEPTED_SENTENCE}"
    return "stored (not verified)"


def record_verdict(result: "VerifyResult") -> None:
    """Remember the last Verify verdict for the stored key (only when the verified
    key IS the stored one — Verify on an unsaved box changes nothing on disk)."""
    st = status()
    if not st.stored or result.fingerprint != st.fingerprint:
        return
    m = _read_meta()
    m.update({"fingerprint": st.fingerprint, "last_verdict": result.verdict})
    m.setdefault("saved_at", st.saved_at)
    if result.verdict == OK:
        m["verified_at"] = _now()
    _write_meta(m)


# ── verify ────────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class VerifyResult:
    """A Verify outcome. Holds no key (only its 12-hex fingerprint)."""
    verdict: str
    sentence: str
    http_status: Optional[int] = None
    records: Optional[int] = None
    fingerprint: str = ""

    @property
    def label(self) -> str:
        return VERDICT_LABELS[self.verdict]

    @property
    def ok(self) -> bool:
        return self.verdict == OK

    def line(self) -> str:
        return f"{self.label}: {self.sentence}"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the apiKey header to wherever it points: never follow."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


def _connect_v4_first(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT,  # noqa: SLF001
                      source_address=None, **_kw):
    """socket.create_connection, trying IPv4 addresses before IPv6 ones, each attempt
    capped at 5 s. Measured on the operator's host 2026-11-10: NVD publishes four
    AAAA records that black-hole there while IPv4 answers in 80 ms, and the default
    order made one Verify take 4 x the timeout before it even tried IPv4."""
    host, port = address
    infos = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
    infos.sort(key=lambda i: 0 if i[0] == socket.AF_INET else 1)
    per = 5.0
    if isinstance(timeout, (int, float)):
        per = min(per, float(timeout))
    err: Optional[BaseException] = None
    for family, stype, proto, _canon, sa in infos:
        sock = socket.socket(family, stype, proto)
        try:
            sock.settimeout(per)
            if source_address:
                sock.bind(source_address)
            sock.connect(sa)
            if isinstance(timeout, (int, float)):
                sock.settimeout(timeout)
            return sock
        except OSError as e:          # timeout, refused, unreachable: next address
            err = e
            sock.close()
    raise err or OSError(f"no address for {host}")


class _V4FirstHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self._create_connection = _connect_v4_first


class _V4FirstHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_V4FirstHTTPSConnection, req, context=self._context)


def _default_opener():
    return urllib.request.build_opener(_NoRedirect(), _V4FirstHTTPSHandler())


def classify(http_status: Optional[int], headers=None, body: bytes = b"",
             error: Optional[BaseException] = None, fingerprint: str = "") -> VerifyResult:
    """Map one NVD answer to a verdict — the responses measured 2026-11-10 with fake
    keys (docs/NVD-API-KEY.md, section 'What NVD answers'):

    * 200 + JSON with an int ``totalResults`` -> OK;
    * 404 + a ``message: Invalid apiKey.`` header -> NOT_ACCEPTED. An unknown key,
      a malformed one and a real key not yet ACTIVATED all get exactly this, so the
      sentence names activation first;
    * 403 / 429 -> RATE_LIMITED (unmeasured: keyed on the status code only);
    * 5xx, a 404 without that header (a wrong path answers with an HTML page), a
      redirect, or a 200 that is not the CVE JSON -> NVD_UNAVAILABLE (an endpoint
      problem, not a key verdict);
    * no answer at all (DNS, timeout, refused, reset, TLS) -> OFFLINE."""
    fp = fingerprint
    if error is not None and http_status is None:
        return VerifyResult(OFFLINE, OFFLINE_SENTENCE, None, None, fp)
    msg = ""
    if headers is not None:
        try:
            msg = headers.get("message") or ""
        except AttributeError:
            msg = ""
    if http_status == 200:
        try:
            data = json.loads(body.decode("utf-8"))
            n = data.get("totalResults") if isinstance(data, dict) else None
        except (ValueError, UnicodeDecodeError):
            n = None
        if isinstance(n, int) and not isinstance(n, bool):
            return VerifyResult(OK, f"NVD accepted the key (NVD API has {n:,} records).",
                                200, n, fp)
        return VerifyResult(NVD_UNAVAILABLE, "NVD answered 200 but not with its CVE data; "
                            "that is an NVD-side problem, not a verdict on the key. Retry "
                            "later.", 200, None, fp)
    if http_status == 404 and re.search(r"(?i)api\s*key", msg):
        return VerifyResult(NOT_ACCEPTED, NOT_ACCEPTED_SENTENCE, 404, None, fp)
    if http_status in (403, 429):
        return VerifyResult(RATE_LIMITED, f"NVD is rate-limiting (HTTP {http_status}); "
                            "retry in 30 seconds. The key was not judged.",
                            http_status, None, fp)
    return VerifyResult(NVD_UNAVAILABLE, f"NVD's API gave no key verdict (HTTP "
                        f"{http_status}); that is an NVD-side problem, not your key. Retry "
                        "later.", http_status, None, fp)


def verify(raw, opener=None, timeout: float = 15.0) -> VerifyResult:
    """Ask NVD once whether it accepts ``raw``. Empty/malformed input is refused
    WITHOUT a request (MISSING / MALFORMED). Blocking: the GUI runs it on a worker.
    ``opener`` is injectable (tests); the default follows no redirect, honours the
    environment's proxies, and tries IPv4 first. Nothing here logs the key, and no
    exception text that could carry it is passed on."""
    try:
        key = check(raw)
    except NvdKeyError as e:
        return VerifyResult(e.verdict, e.sentence)
    fp = _fingerprint(key)
    req = urllib.request.Request(VERIFY_URL, method="GET", headers={
        "apiKey": key, "User-Agent": "hugmesh-studio-nvd-verify",
        "Accept": "application/json"})
    opener = opener or _default_opener()
    try:
        resp = opener.open(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        try:
            body = e.read(65536) if e.fp is not None else b""
        except Exception:  # noqa: BLE001 - the body is only a hint
            body = b""
        return classify(e.code, e.headers, body, fingerprint=fp)
    except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError,
            ssl.SSLError, http.client.HTTPException, OSError) as e:
        return classify(None, error=e, fingerprint=fp)
    try:
        status_code = getattr(resp, "status", None) or resp.getcode()
        body = resp.read(4 * 1024 * 1024)
        headers = resp.headers
    except (OSError, http.client.HTTPException) as e:
        return classify(None, error=e, fingerprint=fp)
    finally:
        try:
            resp.close()
        except Exception:  # noqa: BLE001
            pass
    return classify(status_code, headers, body, fingerprint=fp)


# ── the per-run copy run-sca.sh reads ─────────────────────────────────────────────────
def materialize_for_run() -> tuple[Optional[str], Callable[[], None]]:
    """A private 0600 copy of the stored key for ONE run (0700 mkdtemp dir, removed by
    the returned cleanup), or ``(None, noop)`` when no key is stored. The path goes on
    argv/env as ``NVD_API_KEY_FILE``; the key never does."""
    key = load()
    if not key:
        return None, (lambda: None)
    from .secret_files import stage_secret_file
    return stage_secret_file("nvd_api_key", key.encode("utf-8"), prefix="hugmesh-nvd-")


# ── redaction ─────────────────────────────────────────────────────────────────────────
def redact(text: str, key: str = "") -> str:
    """``text`` with Dependency-Check's ``XXXXX-*****-XXXXX`` echo and every occurrence
    of ``key`` (any case) blanked."""
    if not text:
        return text or ""
    out = _DC_ECHO_RE.sub(_REDACTED, text)
    if key:
        out = re.sub(re.escape(key), _REDACTED, out, flags=re.IGNORECASE)
    return out


def make_redactor() -> Callable[[str], str]:
    """A one-argument redactor bound to the key stored NOW (read once)."""
    key = load()
    return lambda line: redact(line, key)


# ── the org secret ────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class PushResult:
    ok: bool
    sentence: str
    updated_at: str = ""
    visibility: str = ""


def _scrub(text: str, key: str) -> str:
    return redact((text or "").strip(), key)[:400]


def push_refusal(org: str, raw=None, *, set_anyway: bool = False,
                 st: Optional[KeyStatus] = None) -> str:
    """Why a push must not start ("" when it may): an empty or malformed key (gh would
    store an empty stdin as an EMPTY secret without a word — that happened twice), a
    bad org name, and — unless ``set_anyway`` — a key whose last Verify was not OK,
    because a key that was never activated fails every CI job it reaches."""
    key = load() if raw is None else raw
    try:
        key = check(key)
    except NvdKeyError as e:
        return e.sentence
    if not _ORG_RE.match((org or "").strip()):
        return f"{(org or '').strip()!r} is not a GitHub organisation name."
    if not set_anyway:
        st = st or status()
        # the last verdict is about the STORED key; a different key typed into a box
        # was never verified
        if not (st.verified and st.fingerprint == _fingerprint(key)):
            return "Verify the key first (or tick 'set anyway'). " + ACTIVATION_WARNING
    return ""


def push_org_secret(org: str, raw=None, runner=None, *, set_anyway: bool = False,
                    st: Optional[KeyStatus] = None) -> PushResult:
    """``gh secret set NVD_API_KEY --org ORG --visibility all``, the value on STDIN
    only (bytes, no trailing newline), then read back ``updated_at``/``visibility``.
    Everything :func:`push_refusal` names is refused before anything is spawned. The
    read-back proves the write happened, not that the value is non-empty: the
    refusal is the guard for that."""
    refusal = push_refusal(org, raw, set_anyway=set_anyway, st=st)
    if refusal:
        return PushResult(False, refusal)
    key = check(load() if raw is None else raw)
    org = org.strip()
    if runner is None:
        from .org_export import SubprocessRunner
        runner = SubprocessRunner()
    r = runner.run(["gh", "secret", "set", SECRET_NAME, "--org", org,
                    "--visibility", "all"], input=key.encode("utf-8"), timeout=120)
    if r.returncode != 0:
        err = _scrub(r.err, key)
        if re.search(r"(?i)\b403\b|admin:org|forbidden|scope", err):
            return PushResult(False, f"gh refused ({ADMIN_ORG_HINT}). {err}".strip())
        return PushResult(False, f"gh secret set failed (exit {r.returncode}): {err}")
    rb = runner.run(["gh", "api", f"/orgs/{org}/actions/secrets/{SECRET_NAME}",
                     "--jq", ".updated_at,.visibility"], timeout=60)
    if rb.returncode != 0:
        return PushResult(True, f"gh reported the secret set, but reading it back failed: "
                          f"{_scrub(rb.err, key)}")
    parts = [p.strip() for p in rb.text.splitlines() if p.strip()]
    updated = parts[0] if parts else ""
    vis = parts[1] if len(parts) > 1 else ""
    return PushResult(True, f"{SECRET_NAME} set on {org} at {updated or '?'}, visibility "
                      f"{vis or '?'}.", updated, vis)


# ── CLI ───────────────────────────────────────────────────────────────────────────────
def info_lines() -> list[str]:
    """The fixed block every face prints with the status."""
    return [NEED_LINE, f"Request a key: {REQUEST_URL}", f"Setup guide: {GUIDE_URL}",
            ACTIVATION_WARNING, EMPTY_REFUSED]


def export_line(org: str = "") -> str:
    """The Go-Live org-export step's line (GUI and TUI): the exported repositories
    carry the SCA jobs, so the new org needs the secret too."""
    where = org or "the org"
    return (f"The exported repos run OWASP Dependency-Check: set {SECRET_NAME} on {where} "
            f"(see {GUIDE_URL}).")


def _read_key_source(path: str, stdin=None, prompt=getpass.getpass) -> str:
    stdin = stdin or sys.stdin
    if path == "-":
        return stdin.read()
    if path:
        with open(path, encoding="utf-8") as fh:
            return fh.read(4096)
    if not stdin.isatty():
        raise NvdKeyError(MISSING, "refusing: no key source (use --key-file PATH, '-' "
                          "for stdin, or run in a terminal to be prompted)")
    return prompt("NVD API key (not echoed): ")


def main(argv=None, *, stdin=None, prompt=getpass.getpass, opener=None, runner=None) -> int:
    # allow_abbrev=False everywhere: argparse would otherwise read `--key UUID` as an
    # abbreviation of --key-file and take the key off the command line as a path
    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.nvd_key", allow_abbrev=False,
        description=NEED_LINE + " The key is read from a file, stdin or a prompt — "
        "never from the command line.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="say whether a key is stored and verified",
                   allow_abbrev=False)
    s = sub.add_parser("set", help="store a key (0600, under the Studio state dir)",
                       allow_abbrev=False)
    s.add_argument("--key-file", default="", help="file holding the key ('-' = stdin); "
                   "default: a hidden prompt (terminal only)")
    v = sub.add_parser("verify", help="ask NVD once whether it accepts the key",
                       allow_abbrev=False)
    v.add_argument("--key-file", default="", help="verify this file's key instead of the "
                   "stored one ('-' = stdin)")
    sub.add_parser("forget", help="delete the stored key", allow_abbrev=False)
    o = sub.add_parser("push-org-secret", help=f"gh secret set {SECRET_NAME} --org ORG "
                       "(value on stdin)", allow_abbrev=False)
    o.add_argument("--org", required=True)
    o.add_argument("--yes", action="store_true", help="set it even though the last "
                   "Verify was not OK (set anyway)")
    args = p.parse_args(argv)
    out = sys.stdout
    try:
        if args.cmd == "status":
            st = status()
            print(f"NVD API key: {status_line(st)}"
                  + (f" (fingerprint {st.fingerprint})" if st.stored else ""), file=out)
            for ln in info_lines():
                print(ln, file=out)
            return 0
        if args.cmd == "set":
            raw = _read_key_source(args.key_file, stdin, prompt)
            st = save(raw)
            print(f"NVD API key: {status_line(st)} (fingerprint {st.fingerprint})", file=out)
            print(ACTIVATION_WARNING, file=out)
            return 0
        if args.cmd == "verify":
            raw = _read_key_source(args.key_file, stdin, prompt) if args.key_file else load()
            if not args.key_file and not raw:
                print(f"{VERDICT_LABELS[MISSING]}: no key stored. {NEED_LINE} "
                      f"Request one at {REQUEST_URL}", file=out)
                return EXIT_CODES[MISSING]
            print(VERIFY_CONSENT, file=sys.stderr)
            res = verify(raw, opener=opener)
            if not args.key_file:
                record_verdict(res)
            print(f"{res.verdict} {res.line()}", file=out)
            return EXIT_CODES[res.verdict]
        if args.cmd == "forget":
            print("forgotten" if forget() else "no key was stored", file=out)
            return 0
        res = push_org_secret(args.org, runner=runner, set_anyway=args.yes)
        print(res.sentence, file=out if res.ok else sys.stderr)
        return 0 if res.ok else 1
    except NvdKeyError as e:
        print(e.sentence, file=sys.stderr)
        return 2
    except OSError as e:
        print(f"nvd-key: {e.strerror or e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
