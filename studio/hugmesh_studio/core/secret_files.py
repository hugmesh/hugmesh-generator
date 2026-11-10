"""Secret-file vault — browsed key material held IN MEMORY for this Studio session.

OPERATOR ASK (verbatim, 2026-07-29): "instead of just browsing for keys usb or
signing key or cert, once the file is selected its held in memory until the build is
completed, if the build is restarted, a prompt appears to reenter when it is needed".

What that fixes: today the Secure Boot pickers thread bare PATHS to the builder
(``--keys-usb DIR`` / ``--secureboot-key FILE``), so the file must still exist AT
DISPATCH — browse a key on a KEYS USB, unplug the stick, and the build blocks (or,
pre-#465-era, silently signed with a throwaway key). Holding the selected CONTENT in
process memory makes the selection survive an unplug for exactly as long as the
operator asked: until that build COMPLETES.

Scope — which browse targets are vaulted (:data:`VAULT_FIELDS`) and which are not:

* ``secureboot_key`` (--secureboot-key) — VAULTED. It is the Secure Boot signing
  PRIVATE key; the x86 builder itself treats it as 0600 material the moment it takes
  a copy (build-x86-host-stage4.sh:4869 ``cp "${SECUREBOOT_KEY}" "${SBKEY}"; chmod
  600 "${SBKEY}"``).
* ``keys_usb`` (--keys-usb DIR) — VAULTED, as the two well-known members the builder
  actually reads from it: ``Keys/kernel_key.pem`` / ``Keys/kernel_key.der``
  (build-x86-host-stage4.sh:1429-1430 resolves exactly those two files, tolerating
  either alone; nothing else under the dir is consumed by the build). Materializing
  those members under a private tmp ``Keys/`` layout is therefore a faithful
  --keys-usb argument. A browsed dir carrying NEITHER member is refused
  (:meth:`SecretFileVault.hold` raises ValueError) — there is no key material to
  hold, and the builder treats such a dir as "Secure Boot key: <none found>"
  (build-x86-host-stage4.sh:1431), i.e. plain-path semantics lose nothing.
* ``secureboot_cert`` (--secureboot-cert) — NOT vaulted, deliberately. The operator
  said "or cert", but the cert is the PUBLIC half of the signing pair: the builder
  installs it INTO the image rootfs for mokutil enrollment (build-x86-host-stage4.sh
  ``cp "${SBCRT}" "${SYSROOT}${SB_ETC_DIR}/sb.crt"``) and stages it onto boot media.
  Material that is baked into every shipped image is not something that "should not
  linger on disk" — it stays a plain path, and the BuildPage row says so.
* ``keyzip`` (the admin key-zip, gui/pages/keyzip.py) — NOT vaulted. Its import is
  an extract-TO-DISK design by contract: :func:`core.keyzip.extract` unpacks to
  :func:`core.keyzip.staging_dir` (``~/.hugmesh/keyzip``, or under
  ``$HUGMESH_STUDIO_STATE_DIR``) and ``apply_to`` wires STAGING paths into the
  config (branding_dir/egress_vpn/...), which the builder then reads as files.
  Holding the zip bytes in memory would not remove that on-disk footprint, so
  pretending vault coverage there would be dishonest; it is out of scope here.
* the deploy/phone/quest ``keys_dir`` pickers — NOT vaulted: those are enrolment
  key DIRECTORIES consumed live by drivers outside the image-build dispatch (and
  the phone driver re-reads them at flash time); they are not the build-wizard
  key/cert pickers the ask names.

Retention contract (what IS and is NOT persisted):

* CONTENT lives only in this process's memory (:class:`SecretFileVault`) and, for
  the duration of one build run, in a private 0600 tmp copy under a 0700 dir
  (:func:`materialize` — the builder needs a real path). It is NEVER written to a
  saved config, a session record, or any other persisted artifact; the session
  record carries only ``{field, name, sha256}`` (:meth:`HeldSecretFile.record`) so a
  restart can name what must be re-selected — a one-way fingerprint, not material.
* the browsed PATH keeps its existing persistence semantics untouched: config
  save/load round-trips it (pinned by test_pages_build.py
  test_build_secure_boot_key_paths_persist_to_saved_configs) and the --print-specs
  channel keeps carrying it (app.py:203 blanks SECRET_FIELDS only). The vault never
  changes WHICH flags are emitted — only where the path points at dispatch, the
  same rewrite class as build_driver._remap_assets_for_docker. So the headless/CLI
  channels (whose processes never populate a vault) stay byte-identical.

Lifecycle (the operator's own words drive it):

* held from browse until the build that consumed it COMPLETES ("held in memory
  until the build is completed") — ProgressPage drops the consumed fields on a
  ``complete`` outcome only; a failed/stopped run keeps them for the retry;
* a RESTART in a fresh Studio process finds the vault empty; the session record's
  ``held_secret_files`` names exactly what is missing and ProgressPage prompts the
  operator to re-select it BEFORE dispatch ("a prompt appears to reenter when it is
  needed") — declining aborts honestly, never a silent fallback to the stale path;
* Studio exit drops everything (process memory).

Origin pinning: every entry remembers the exact path it was read from
(:attr:`HeldSecretFile.origin`, in-memory only). Consumers honour an entry ONLY
while the config still carries that same path — so a held copy from one config can
never silently sign a different config's build after the operator loads/types
another path (the field edit drops the entry in the GUI; the origin check is the
core-side belt to that brace).

Qt-free by construction (the worklist_driver/build_sessions precedent) — the GUI
pages and BuildDriver consume it; the pure-core tests drive it directly.
"""
from __future__ import annotations

import hashlib
import ntpath
import os
import shutil
import stat
import tempfile
import threading
import time
from dataclasses import dataclass

# The config fields whose browsed selection is held as CONTENT (see the module
# docstring for the per-field reasoning, with builder line citations).
VAULT_FIELDS = ("keys_usb", "secureboot_key")

# Human labels for prompts/rows — flag spelling included so the operator can match
# the prompt to the Review page's command pane.
FIELD_LABELS = {
    "keys_usb": "KEYS USB signing material (--keys-usb)",
    "secureboot_key": "Secure Boot signing key (--secureboot-key)",
}

# WHY each file is needed — the restart prompt must name the reason, not just the field.
FIELD_WHY = {
    "keys_usb": ("the image signs its UKI with the fleet key from this KEYS USB "
                 "(Keys/kernel_key.pem/.der) so it boots under the firmware's "
                 "already-enrolled Secure Boot chain"),
    "secureboot_key": ("the image signs its UKI with this private key so it boots "
                       "under the firmware's already-enrolled Secure Boot chain"),
}

# The ONLY members of a --keys-usb dir the builder reads (build-x86-host-stage4.sh:
# 1429-1430); pem = private key (required-or-der), der = its cert.
KEYS_USB_MEMBERS = ("Keys/kernel_key.pem", "Keys/kernel_key.der")

# Refuse to slurp an absurd selection into RAM: key material is KB-sized; a mis-click
# on an ISO must fail loudly here, not OOM the Studio an hour later. 16 MiB is orders
# of magnitude above any real signing key/cert and far below anything dangerous.
MAX_HELD_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class HeldSecretFile:
    """One held selection: the field it satisfies, its display identity, and the
    member contents. ``sha256`` of a single-file entry equals ``sha256sum <file>``
    on purpose, so an operator can verify the held copy against their own file."""
    field: str
    name: str                                   # display basename (file or dir)
    origin: str                                 # the exact browsed path (in-memory only)
    members: tuple[tuple[str, bytes], ...]      # (relative path, content)
    sha256: str

    @property
    def fingerprint(self) -> str:
        """The short display form (12 hex chars — the git-abbrev idiom)."""
        return self.sha256[:12]

    @property
    def total_bytes(self) -> int:
        return sum(len(data) for _rel, data in self.members)

    def record(self) -> dict:
        """The CONTENT-FREE persistable summary for a session record: enough for a
        restart prompt to name what is missing (and for the operator to verify a
        re-selected file is the same one), never the material or even its path."""
        return {"field": self.field, "name": self.name, "sha256": self.sha256}

    def summary(self) -> str:
        """One line for the GUI row: filename + fingerprint + the retention promise."""
        return (f"{self.name} · sha256 {self.fingerprint} — held in memory for this "
                f"session (survives unplug; dropped when the build completes)")


def _digest(members: tuple[tuple[str, bytes], ...]) -> str:
    """sha256 over the members. Single file -> plain sha256 of its bytes (verifiable
    with ``sha256sum``); multi-member -> relpath-framed so member identity is part of
    the fingerprint."""
    h = hashlib.sha256()
    if len(members) == 1:
        h.update(members[0][1])
    else:
        for rel, data in members:
            h.update(rel.encode())
            h.update(b"\0")
            h.update(str(len(data)).encode())
            h.update(b"\0")
            h.update(data)
    return h.hexdigest()


def _read_capped(path: str) -> bytes:
    size = os.path.getsize(path)
    if size > MAX_HELD_BYTES:
        raise ValueError(
            f"{path} is {size} bytes — larger than the {MAX_HELD_BYTES}-byte ceiling "
            f"for held-in-memory secret files (signing keys/certs are KB-sized; this "
            f"does not look like one)")
    with open(path, "rb") as fh:
        return fh.read()


def _dir_display_name(path: str, osname: str | None = None) -> str:
    """The name a held keys_usb dir is shown and recorded by: its basename. On native
    Windows a KEYS stick is usually a drive's root (``E:\\`` holds ``Keys\\``), whose
    basename is "", so the held row and the restart prompt named nothing; there the
    root itself (``E:\\``, ``\\\\server\\share\\``) is the name. A Linux mount point
    always has a basename. ``osname`` is ``os.name`` unless a test passes another."""
    if (osname or os.name) != "nt":
        return os.path.basename(path.rstrip(os.sep))
    return ntpath.basename(path.rstrip("\\/")) or path


class SecretFileVault:
    """The in-memory store, keyed by config field. Thread-safe: the GUI thread
    holds/drops while the worklist worker thread consumes (build_driver.run)."""

    def __init__(self) -> None:
        self._held: dict[str, HeldSecretFile] = {}
        self._lock = threading.Lock()

    # ---- holding -----------------------------------------------------------
    def hold(self, field: str, path: str) -> HeldSecretFile:
        """Read ``path`` (file, or the keys_usb dir's known members) into memory and
        hold it for ``field``, replacing any prior entry. Raises ValueError for an
        unknown field / an empty keys_usb dir / an oversized file, OSError for an
        unreadable path — callers surface the message, nothing is partially held."""
        if field not in VAULT_FIELDS:
            raise ValueError(f"{field} is not a held-in-memory secret-file field "
                             f"(expected one of {', '.join(VAULT_FIELDS)})")
        path = os.path.abspath(path)
        if field == "keys_usb":
            entry = self._read_keys_usb(path)
        else:
            data = _read_capped(path)
            name = os.path.basename(path)
            members = ((name, data),)
            entry = HeldSecretFile(field=field, name=name, origin=path,
                                   members=members, sha256=_digest(members))
        with self._lock:
            self._held[field] = entry
        return entry

    @staticmethod
    def _read_keys_usb(path: str) -> HeldSecretFile:
        if not os.path.isdir(path):
            raise ValueError(f"--keys-usb expects a directory: {path}")
        members: list[tuple[str, bytes]] = []
        for rel in KEYS_USB_MEMBERS:
            full = os.path.join(path, rel)
            if os.path.isfile(full):
                members.append((rel, _read_capped(full)))
        if not members:
            # No key material to protect: the builder itself would log "Secure Boot
            # key: <none found>" for this dir (build-x86-host-stage4.sh:1431), so
            # plain-path semantics lose nothing — refuse the hold honestly.
            raise ValueError(
                f"{path} carries neither {KEYS_USB_MEMBERS[0]} nor "
                f"{KEYS_USB_MEMBERS[1]} — nothing to hold in memory (the builder "
                f"reads exactly those; it would find no Secure Boot key here)")
        m = tuple(members)
        return HeldSecretFile(field="keys_usb", name=_dir_display_name(path),
                              origin=path, members=m, sha256=_digest(m))

    # ---- queries / lifecycle -------------------------------------------------
    def get(self, field: str) -> HeldSecretFile | None:
        with self._lock:
            return self._held.get(field)

    def has(self, field: str) -> bool:
        return self.get(field) is not None

    def held_fields(self) -> tuple[str, ...]:
        with self._lock:
            return tuple(k for k in VAULT_FIELDS if k in self._held)

    def drop(self, field: str) -> bool:
        """Forget one entry (returns whether it existed). The bytes objects are
        left to the GC — CPython offers no reliable in-place wipe, and pretending
        otherwise (bytearray zeroing of already-copied bytes) would be theater."""
        with self._lock:
            return self._held.pop(field, None) is not None

    def drop_fields(self, fields) -> None:
        for f in fields:
            self.drop(f)

    def clear(self) -> None:
        with self._lock:
            self._held.clear()


# ── the process vault ────────────────────────────────────────────────────────────────
# One per process: the wizard pages hold into it, BuildDriver.run consumes from it,
# ProgressPage drops from it at completion. Tests swap _VAULT for isolation.
_VAULT: SecretFileVault | None = None
_VAULT_GUARD = threading.Lock()


def vault() -> SecretFileVault:
    global _VAULT
    with _VAULT_GUARD:
        if _VAULT is None:
            _VAULT = SecretFileVault()
        return _VAULT


# ── just-in-time materialization (the builder needs a real path) ─────────────────────
class MaterializedSecretFiles:
    """Held entries written to a private tmp tree for ONE build run.

    ``paths`` maps field -> the path to substitute into that field's flag: the 0600
    file itself for a single-file field, the tmp dir (carrying ``Keys/…``) for
    keys_usb. ``cleanup()`` removes the whole tree; callers run it in a ``finally``
    so a failed/cancelled build never leaves key material behind."""

    def __init__(self, root: str, paths: dict[str, str],
                 owner: "PrivateDir | None" = None):
        self._root = root
        self.paths = paths
        self._owner = owner

    def cleanup(self) -> None:
        if self._owner is not None:
            self._owner.remove()
        else:
            shutil.rmtree(self._root, ignore_errors=True)


# ── private temp dirs: an owner lock for their life, and a sweep for the dead ──────
#: Every prefix a private key/password dir is minted under in TMPDIR. A run removes
#: its own dir in a ``finally``; a SIGKILL, a power cut or a hard crash skips that,
#: and before this the plaintext stayed there for good (PR #938 review, finding 4).
PRIVATE_DIR_PREFIXES = ("hugmesh-held-keys-", "hugmesh-domain-ca-", "hugmesh-login-")
#: The lock file inside each dir. Its lock is held by the creating process for the
#: dir's whole life, and the OS drops it when that process dies, however it dies.
OWNER_LOCK = ".owner.lock"
#: A dir younger than this is never swept: it may be one being created right now
#: (between ``mkdtemp`` and its lock), or a pre-lock Studio's that is still in use.
SWEEP_GRACE_SECONDS = 120


def _try_lock(fd: int) -> bool:
    """Take an exclusive, non-blocking lock on ``fd``. False when another open file
    holds it, or when this filesystem cannot lock at all (then nobody can, and the
    sweep reads the dir as live: it never removes a dir it cannot prove dead)."""
    try:
        if os.name == "nt":
            import msvcrt
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def _unlock_close(fd: int) -> None:
    try:
        if os.name == "nt":
            import msvcrt
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    except OSError:
        pass
    finally:
        os.close(fd)


class PrivateDir:
    """A 0700 ``mkdtemp`` dir that holds its owner lock until :meth:`remove`."""

    def __init__(self, prefix: str):
        self.path = tempfile.mkdtemp(prefix=prefix)
        self._fd: int | None = None
        try:
            os.chmod(self.path, 0o700)
            fd = os.open(os.path.join(self.path, OWNER_LOCK),
                         os.O_RDWR | os.O_CREAT | os.O_EXCL
                         | getattr(os, "O_BINARY", 0), 0o600)
            self._fd = fd
            os.write(fd, f"{os.getpid()}\n".encode("ascii"))
            _try_lock(fd)      # (a filesystem without locks: see _try_lock)
        except BaseException:
            self.remove()
            raise

    def remove(self) -> None:
        fd, self._fd = self._fd, None
        if fd is not None:
            _unlock_close(fd)  # first: Windows cannot delete an open file
        shutil.rmtree(self.path, ignore_errors=True)


def _owner_gone(path: str) -> bool:
    """True when ``path``'s owner lock can be taken (its process is gone), or when the
    dir has no lock file at all (a Studio from before the lock)."""
    lock = os.path.join(path, OWNER_LOCK)
    try:
        fd = os.open(lock, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
                     | getattr(os, "O_BINARY", 0))
    except FileNotFoundError:
        return True
    except OSError:
        return False
    try:
        return _try_lock(fd)
    finally:
        _unlock_close(fd)


def sweep_stale_private_dirs(tmp_dir: str | None = None, *, dry_run: bool = False,
                             grace: float = SWEEP_GRACE_SECONDS,
                             now: float | None = None) -> list[str]:
    """Remove the private key/password dirs in ``tmp_dir`` (default: TMPDIR) whose
    owning process is gone, and return their paths (``dry_run``: list, remove
    nothing). A dir is removed only when ALL of these hold: its name has a
    :data:`PRIVATE_DIR_PREFIXES` prefix; it is a real directory (``lstat``: a symlink
    is never followed); it belongs to this user (POSIX); it is older than ``grace``
    seconds; and its owner lock is free, or it has none (pre-lock Studio)."""
    tmp_dir = tmp_dir or tempfile.gettempdir()
    now = time.time() if now is None else now
    getuid = getattr(os, "getuid", None)
    out: list[str] = []
    try:
        names = sorted(os.listdir(tmp_dir))
    except OSError:
        return out
    for name in names:
        if not name.startswith(PRIVATE_DIR_PREFIXES):
            continue
        path = os.path.join(tmp_dir, name)
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode):
            continue
        if getuid is not None and st.st_uid != getuid():
            continue
        if now - st.st_mtime < grace:
            continue
        if not _owner_gone(path):
            continue
        out.append(path)
        if not dry_run:
            shutil.rmtree(path, ignore_errors=True)
    return out


def startup_sweep() -> list[str]:
    """The Studio's startup call (GUI and TUI entry points): sweep TMPDIR, and never
    let a sweep problem stop the Studio from starting."""
    try:
        return sweep_stale_private_dirs()
    except Exception:       # noqa: BLE001 - a cleanup must never block startup
        return []


def _write_0600(path: str, data: bytes) -> None:
    # O_EXCL: the file must not pre-exist — we just minted the private dir, so a
    # pre-existing name would mean something else is writing here; fail loudly.
    # O_BINARY (Windows only): without it the CRT's text mode turns every 0x0A into
    # 0x0D 0x0A, corrupting a DER key and giving a PEM CRLF endings.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                 | getattr(os, "O_BINARY", 0), 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def materialize(entries) -> MaterializedSecretFiles:
    """Write ``entries`` (HeldSecretFile iterable) under a fresh private dir:
    ``mkdtemp`` (0700 by contract, re-asserted) / ``<field>/`` (0700) / members at
    0600. Never under the build workdir — that tree is the artifact output the
    operator browses and archives; key material does not belong in it."""
    owner = PrivateDir("hugmesh-held-keys-")
    root = owner.path
    paths: dict[str, str] = {}
    try:
        for e in entries:
            base = os.path.join(root, e.field)
            for rel, data in e.members:
                full = os.path.join(base, rel)
                os.makedirs(os.path.dirname(full), mode=0o700, exist_ok=True)
                _write_0600(full, data)
            # keys_usb is consumed as a DIRECTORY flag; single-file fields as the file.
            paths[e.field] = base if e.field == "keys_usb" else os.path.join(
                base, e.members[0][0])
    except BaseException:
        owner.remove()
        raise
    return MaterializedSecretFiles(root, paths, owner)


def stage_local_pass(password: str) -> tuple[str, "Callable[[], None]"]:
    """Write the build-time LOGIN password to a private 0600 file for ONE build run
    and return ``(path, cleanup)``; the builder reads it with ``--local-pass-file``.

    Why a file: ``--local-pass PASS`` put the plaintext on the process list for the
    whole build — ``sudo env … bash ./build-*.sh … --local-pass PASS`` natively, and
    ``docker run … bash -c '… --local-pass PASS'`` under docker, where it also sits
    in ``docker inspect`` for the container's lifetime. argv is world-readable in
    /proc/<pid>/cmdline. An env var would move it to /proc/<pid>/environ and the
    container config instead. A 0600 file under a 0700 ``mkdtemp`` dir is readable
    only by its owner and root (the builder runs as root), and the caller's cleanup
    removes it when the run ends — success, failure or cancel alike. Same dir/perm
    contract as :func:`materialize`, never under the build workdir."""
    owner = PrivateDir("hugmesh-login-")
    path = os.path.join(owner.path, "local-pass")
    try:
        _write_0600(path, password.encode("utf-8"))
    except BaseException:
        owner.remove()
        raise
    return path, owner.remove


# ── restart support ──────────────────────────────────────────────────────────────────
def missing_for_restart(held_records, v: SecretFileVault | None = None) -> list[dict]:
    """The subset of a session record's ``held_secret_files`` entries NOT currently in
    the vault — exactly what a restart must re-collect BEFORE dispatch. Malformed rows
    (hand-edited records) are skipped rather than crashing the restart path."""
    v = v or vault()
    out: list[dict] = []
    for rec in held_records or []:
        if not isinstance(rec, dict):
            continue
        field = rec.get("field")
        if field in VAULT_FIELDS and not v.has(field):
            out.append(rec)
    return out
