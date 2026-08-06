#!/usr/bin/env python3
"""exec_argv_property.py — assert a PROPERTY of WORKLOAD_CONSOLE_EXEC_READONLY.

The defect class this exists for is NOT "someone put a banned name on the list".
It is "an allowlisted command has an ARGUMENT that turns it into something the
list's own rule forbids".  `ps eww` (BSD `e` = show the environment) and
`du --files0-from=F` (echoes every unparseable name in F back as
`du: cannot access '<line>'`) are the same bug wearing two different names, and a
guard written as a hand-list of banned names cannot see either of them until a
human has already found it and typed the name in.  Every such guard is exactly
one command behind the attacker.

So nothing here is a list of forbidden commands.  What is asserted is the
property itself:

  P.  For every entry E of the read-only exec allowlist, no argv that the shipped
      consumer licenses for E can be induced to
        (1) print the contents of an arbitrary file,
        (2) print an environment,
        (3) execute another program, or
        (4) modify the filesystem.

  "the argv the consumer licenses" is decided by the shipped matcher, which is a
  FIRST-TOKEN match (WorkloadConsoleProperties.execReadOnlyAllowed ->
  `execReadOnlyCommands.contains(command.get(0))`).  So a BARE NAME on the list
  licenses that command with ARBITRARY arguments and must satisfy P under all of
  them; a PINNED form (`ps -e`) licenses nothing today — its head is not an
  element of the list, so the matcher refuses it outright — and is checked as the
  exact argv it will mean once the whole-argv matcher lands.

P is decided by two INDEPENDENT oracles, neither of which contains a list of
command names.  Either one firing fails the entry.

  ORACLE A — the command's OWN documentation.  `<cmd> --help` is harvested and
  parsed into option blocks.  An option is hazardous when its VALUE is a path
  (placeholder named FILE/F/DATEFILE/PATH/DIR/...), or its own description says it
  reads from a file, dumps an environment, or runs a program; a head is hazardous
  when its own synopsis takes a COMMAND positionally, or when its synopsis takes a
  PATH-shaped OPERAND that the same help documents as a byte source/sink (§ below).
  For a bare name ANY hazardous option disqualifies it, because a bare name
  licenses every option.

  ORACLE B — behaviour, against live canaries.  A throwaway sandbox is built
  containing a file whose CONTENT is a fresh random canary, an executable marker
  that prints a second canary, and a tree snapshot; the child is given a third
  canary in its ENVIRONMENT and is run on a pty (so tty-scoped tools such as
  procps behave as they do for a real operator).  Every option Oracle A harvested
  is then fired at those canaries — alone, POINTED AT THE CANARY FILE AS A PLAIN
  POSITIONAL OPERAND (`<cmd> <file>`, `<cmd> -- <file>`, `<cmd> <file> <out>`), by
  both `--opt path` and `--opt=path`, and pointed at the marker.  If a canary comes
  back in the output, or the marker ran, or the sandbox changed, the entry has
  demonstrably violated P.

  ORACLE B', the DIFFERENTIAL leg — because "prints the file" is not the class.
  A leak does not have to be legible: `base64 F`, `od -c F`, `cksum F`, `xxd F` all
  hand the operator the file's bytes without ever emitting them literally, so a
  guard that searches its output for the canary STRING waves every encoder, hex
  dumper and checksummer through.  What is actually forbidden is that the output be
  a FUNCTION OF THE FILE'S BYTES, in any encoding.  So the same argv is run against
  FOUR sibling files, identical in name-shape, length, mode and mtime, whose
  CONTENTS are X, Y, X, Y.  A token that appears in both X-runs, in neither Y-run,
  AND vice versa is a token the file's bytes decided: that is a leak whatever the
  alphabet.  The X/Y interleaving is what makes it noise-proof — a drifting value
  (df's used blocks, a pid, a clock) is never equal across two non-adjacent runs
  and absent from both of the others, and the two-sided requirement means a
  one-sided coincidence is not enough.  Metadata is deliberately NOT a leak: the
  four files differ in inode and path, so anything derived from identity falls out
  of the intersection and `ls -l`, `stat`, `df` stay green on their own merits.

  § Why Oracle A needs a SEPARATE positional rule.  An option surface says nothing
  about operands: `Usage: base64 [OPTION]... [FILE]` needs no flag at all.  But a
  path-shaped operand alone does not mean the bytes are read — `ls FILE`, `df FILE`
  and `stat FILE` take one and print only metadata.  The discriminator is taken
  from the help itself: a sentence that NAMES the operand and also names STANDARD
  INPUT or STANDARD OUTPUT is the command documenting that operand as a stream of
  bytes it consumes or emits ("With no FILE, or when FILE is -, read standard
  input", "Print selected parts of lines from each FILE to standard output").
  ls/df/stat say no such thing about theirs.

An entry that cannot be probed (binary absent, help unreadable) is a FAILURE, not
a skip: an unprobed entry is an unproven entry, and a mirror that cannot fail is
not a guard.
"""

import os
import re
import sys
import fcntl
import select
import struct
import secrets
import termios
import hashlib
import shutil
import tempfile
import time

# ── vocabulary ────────────────────────────────────────────────────────────────
# These describe the SHAPE OF A VALUE and the MEANING OF A SENTENCE. They are not
# a list of commands: adding a new command to the allowlist does not require
# touching anything here, and no command can be exempted by editing it.

# An option value that names a path — the value the command will then OPEN.
PATH_PLACEHOLDER = re.compile(
    r"^(?:f|file|filename|files?0|datefile|tabfile|conffile|configfile|"
    r"path|dir|directory|folder|script|profile)$"
    r"|file|path|dir(?:ectory)?|fname",
    re.I,
)
# Placeholders that merely LOOK path-ish but are units/enums, kept out explicitly
# because "FIELD_LIST"/"TIME_STYLE"-shaped names must not be read as paths.
NOT_A_PATH = re.compile(r"^(?:field_list|time_style|list|style|format|fmt)$", re.I)

# An option that DUMPS an environment, as its own help describes it. The verb is
# required and a trailing "variable" is excluded on purpose: ls(1) documents
# "(overrides QUOTING_STYLE environment variable)", which names an env var that
# CONFIGURES the option — the opposite of printing one.
DESC_ENV = re.compile(
    r"\b(?:show|shows|print|prints|display|displays|dump|dumps|list|lists|"
    r"output|outputs|report|reports)\b[^.;]{0,40}?\benviron(?:ment)?\b"
    r"(?!\s+variable)",
    re.I,
)
DESC_READS_FILE = re.compile(
    r"\b(?:read|reads|take|takes|obtain|load|loads|specified in|named in)\b"
    r"[^.;]{0,60}?\bfile\b",
    re.I,
)
DESC_RUNS_PROGRAM = re.compile(
    r"\b(?:run|runs|execute|executes|exec|invoke|invokes|spawn)\b"
    r"[^.;]{0,40}?\b(?:command|commands|program|utility|binary)\b",
    re.I,
)
# A synopsis that takes a program positionally: `ionice [options] <command>`,
# `nice [OPTION] [COMMAND [ARG]...]`.
SYNOPSIS_RUNS_PROGRAM = re.compile(r"[\[<]\s*(?:command|program|utility)\b", re.I)

# A sentence that names STANDARD INPUT / STANDARD OUTPUT. Used ONLY together with
# the name of a positional operand: an operand a command documents in the same
# breath as a standard stream is an operand whose BYTES it consumes or emits, which
# is what separates `base64 FILE` from `ls FILE`. Bare "output" is deliberately not
# enough — df's `--output=FIELD_LIST` is a column selector, not a byte sink.
STREAM_SENTENCE = re.compile(r"\bstandard (?:in|out)put\b|\bstdin\b|\bstdout\b", re.I)

# Words a synopsis uses for "the options go here", never an operand.
_NOT_AN_OPERAND = {"option", "options", "opt", "opts", "or", "arg", "args", "argument",
                   "arguments", "usage", "flags", "flag"}

SHELL_META = set(";|&$`<>*?()[]{}!\\\"'\n\t")

CANARY_TIMEOUT_S = 3.0
PTY_COLS = 4000

# argv-template placeholders. A probe argv is built ONCE and materialised against
# each canary variant, so the positional and the flag-valued forms are the same
# battery seen by both behavioural legs.
CANARY = "{CANARY}"
MARKER = "{MARKER}"
SENTINEL = "{SENTINEL}"


# ── help harvesting ───────────────────────────────────────────────────────────
def _run_plain(argv, cwd, timeout=5.0):
    """Run argv with no tty, no canaries. Returns (rc, combined output)."""
    import subprocess

    try:
        p = subprocess.run(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001 - a broken help is a probe failure
        return 127, f"<probe error: {exc}>"


# `-h` is NOT tried: on du/df/ls it is --human-readable, and `du -h` run in a repo
# checkout emits megabytes of directory sizes that would beat the real help on
# length and leave the option surface unparsed — the guard would then fail for
# "unparseable help" instead of for the actual defect. Only forms that are help
# everywhere are used, and they run inside the throwaway sandbox.
HELP_FORMS = (("--help",), ("--help", "all"), ("help",))


def harvest_help(head, cwd):
    """The command's own help text. Longest of the forms it answers to."""
    texts = []
    for form in HELP_FORMS:
        _, out = _run_plain([head, *form], cwd)
        if out and "<probe error" not in out:
            texts.append(out)
    return max(texts, key=len) if texts else ""


_OPTLINE = re.compile(r"^(\s+)(\S.*?)(?:\s{2,}(.*))?$")


def parse_option_blocks(help_text):
    """[(option_part, description)] — the structured pass.

    An option line is an INDENTED line whose first column-group looks like an
    option (`-x`, `--long`, or a bare BSD personality letter). Its description is
    the remainder of that line plus every following line indented deeper. Prose
    paragraphs (column 0) are never option blocks, which is what keeps trailing
    notes such as ls(1)'s "The TIME_STYLE environment variable ..." from being
    read as an option's description.
    """
    blocks = []
    lines = help_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = _OPTLINE.match(line)
        i += 1
        if not m or not line.strip():
            continue
        indent, optpart, rest = m.group(1), m.group(2), (m.group(3) or "")
        first = optpart.split(",")[0].split()[0] if optpart.split() else ""
        if not (first.startswith("-") or re.fullmatch(r"[A-Za-z]", first)):
            continue
        desc = [rest]
        while i < len(lines):
            nxt = lines[i]
            if not nxt.strip():
                break
            nindent = len(nxt) - len(nxt.lstrip())
            if nindent <= len(indent):
                break
            nm = _OPTLINE.match(nxt)
            nfirst = ""
            if nm and nm.group(2).split():
                nfirst = nm.group(2).split(",")[0].split()[0]
            # Stop at the next option line — including procps' UNDASHED BSD
            # personality letters (`  e   show the environment after command`),
            # which are deeper-indented than the `-c` above them and would
            # otherwise be swallowed into the previous option's description and
            # reported against the wrong flag.
            if nfirst.startswith("-") or (re.fullmatch(r"[A-Za-z]", nfirst) and nm.group(3)):
                break
            desc.append(nxt.strip())
            i += 1
        blocks.append((optpart, " ".join(x for x in desc if x)))
    return blocks


_TOKEN = re.compile(r"--?[A-Za-z0-9][A-Za-z0-9_-]*(?:\[[A-Za-z-]+\])?")


def harvest_option_tokens(help_text, blocks):
    """Every option token the help mentions, however it mentions it.

    Deliberately permissive: a token harvested from prose only costs one extra
    probe, while a token MISSED is a hole in the property. Handles the
    `-b[atch]` abbreviation notation iproute2 uses by expanding both forms, and
    the undashed BSD personality letters procps documents.
    """
    toks = set()
    for m in _TOKEN.finditer(help_text):
        t = m.group(0)
        br = re.match(r"^(--?[A-Za-z0-9])\[([A-Za-z-]+)\]$", t)
        if br:
            toks.add(br.group(1))
            toks.add(br.group(1) + br.group(2))
        else:
            toks.add(t)
    for optpart, _ in blocks:
        for piece in re.split(r"[,\s|]+", optpart):
            if re.fullmatch(r"[A-Za-z]", piece):
                toks.add(piece)  # BSD personality letter, e.g. procps `e`
    return sorted(toks)


_PLACEHOLDER = re.compile(
    r"(?:=\[?([A-Za-z_][\w-]*)\]?)"          # --opt=FILE / --opt[=WHEN]
    r"|(?:<([A-Za-z_][\w -]*)>)"              # --opt <class>
    r"|(?:\[([a-z_][\w-]*)\])"                # -b[atch] [filename]
    r"|(?:\s([A-Z][A-Z_0-9]*)\b)"             # -s N / -f DATEFILE
)


def option_placeholders(optpart):
    """[(placeholder, owning_option)] — the option nearest to the LEFT of it.

    iproute2 prints a whole `|`-separated option menu on one line, so the first
    token on the line is usually not the option the placeholder belongs to;
    attributing `[filename]` to `-o[neline]` instead of `-b[atch]` would still be
    a red guard, but it would point the reader at the wrong flag.
    """
    names = [(m.start(), m.group(0)) for m in re.finditer(r"--?[A-Za-z0-9][\w.-]*(?:\[[A-Za-z-]+\])?", optpart)]
    out = []
    for m in _PLACEHOLDER.finditer(optpart):
        val = next((g for g in m.groups() if g), None)
        if not val:
            continue
        owner = ""
        for pos, tok in names:
            if pos <= m.start():
                owner = tok
        out.append((val.strip(), owner))
    return out


def looks_like_path_value(placeholder):
    if NOT_A_PATH.match(placeholder):
        return False
    return bool(PATH_PLACEHOLDER.search(placeholder))


def flags_of(args):
    """The set of flags a pinned argv actually carries, CLUSTERS EXPANDED.

    `du -sh` carries -s and -h; `du -Xh` carries -X (exclude-from=FILE) and the
    letter h as its VALUE. Judging the token `-Xh` as a whole would find no
    documented option by that name and wave it through, so a clustered short-flag
    group is expanded before it is judged.
    """
    out = set()
    for a in args:
        base = a.split("=")[0]
        out.add(base)
        if base.startswith("--") or not base.startswith("-"):
            continue
        for ch in base[1:]:
            out.add("-" + ch)
    return out


def synopsis_lines(head, help_text):
    """The head's own usage lines — including the `Usage:` / `or:` continuations.

    Both layouts in the wild are covered: coreutils puts the head on the `Usage:`
    line itself, util-linux/procps/xxd put a bare `Usage:` and indent the head onto
    the next line.
    """
    out = []
    for ln in help_text.splitlines()[:20]:
        if re.match(r"^\s*(?:usage:|or:)?\s*" + re.escape(head) + r"\b", ln, re.I):
            out.append(ln)
    return out


def synopsis_operands(head, help_text):
    """The POSITIONAL operand placeholders the head's own synopsis declares.

    Everything that is an OPTION token (or an option's `=VALUE`) is removed first,
    so what is left of `od [OPTION]... [FILE] [[+]OFFSET[.][b]]` is FILE/OFFSET/b —
    the words the command will accept as OPERANDS. This is the half of the argv
    surface parse_option_blocks() cannot see, and it is the half `base64 <file>`
    lives in: no flag is involved at all.
    """
    seen, ops = set(), []
    for ln in synopsis_lines(head, help_text):
        tail = re.sub(r"^\s*(?:usage:|or:)?\s*" + re.escape(head) + r"\b", " ", ln, count=1, flags=re.I)
        tail = re.sub(r"--?[A-Za-z0-9][\w.-]*(?:=\S+)?", " ", tail)   # option tokens + their values
        for m in re.finditer(r"[A-Za-z_][\w-]*", tail):
            w = m.group(0)
            if w.lower() in _NOT_AN_OPERAND or w in seen:
                continue
            seen.add(w)
            ops.append(w)
    return ops


def _operand_sentences(help_text, operand):
    """Every sentence of the help that NAMES this operand.

    Case-sensitive when the operand is written in caps, because the placeholder
    FILE and the English word "file" are different things: du's
    `--files0-from=F  ... process those named in file F` is about F, not about du's
    own FILE operand, and attributing it to the operand would point the reader at
    the wrong argument. Plural/`(s)` forms of the placeholder still count.
    """
    flags = 0 if any(c.isupper() for c in operand) else re.I
    pat = re.compile(r"\b" + re.escape(operand) + r"(?:s|\(s\))?\b", flags)
    flat = re.sub(r"\s+", " ", help_text)
    for sent in re.split(r"(?<=[.;])\s+", flat):
        if pat.search(sent):
            yield sent


def positional_doc_hazards(head, help_text):
    """Oracle A, POSITIONAL leg. [(operand, reason)] for every byte-source operand.

    Only reached for a BARE name, because a bare name is what licenses an operand:
    the shipped first-token matcher looks at argv[0] and nothing else, so `base64`
    on the list is `base64 /var/run/secrets/workload-console-read/token` on the list.
    A pinned whole-argv form admits no extra operand and is judged as itself.
    """
    hz = []
    for op in synopsis_operands(head, help_text):
        if not looks_like_path_value(op):
            continue
        for sent in _operand_sentences(help_text, op):
            if STREAM_SENTENCE.search(sent):
                hz.append((("<operand %s>" % op),
                           "takes %s as a PLAIN POSITIONAL operand and its own help "
                           "documents that operand as a standard-stream of BYTES -> "
                           "`%s <any file>` needs no flag at all: %r"
                           % (op, head, sent.strip()[:110])))
                break
    return hz


def doc_hazards(head, help_text, blocks, only_flags=None):
    """Oracle A. Returns [(token, reason)] for every hazardous option.

    only_flags=None  -> a BARE name: every documented option is reachable.
    only_flags={...} -> a PINNED form: only the flags it actually carries.
    """
    hz = []
    synopsis = []
    for ln in help_text.splitlines()[:14]:
        if re.match(r"^\s*(?:usage:)?\s*" + re.escape(head) + r"\b", ln, re.I) or ln.lower().startswith("usage:"):
            synopsis.append(ln)
    for ln in synopsis:
        if SYNOPSIS_RUNS_PROGRAM.search(ln):
            hz.append(("<synopsis>", f"`{head} <any command>` executes that command — its own "
                                     f"synopsis takes a program positionally: {ln.strip()!r}"))
            break

    for optpart, desc in blocks:
        names = [p for p in re.split(r"[,\s|]+", optpart) if p.startswith("-")]
        if only_flags is not None:
            names = [n for n in names if n.split("=")[0] in only_flags]
            if not names:
                continue
        label = names[0] if names else optpart.strip()
        # Membership is decided at BLOCK level, above: a block is retained when any
        # of its ALIASES is in the pinned form. The owner below only labels the
        # message — filtering on it would let `du -Xh` through, because the
        # placeholder's owner is the long alias `--exclude-from` while the pinned
        # token expands to the short one `-X`.
        for ph, owner in option_placeholders(optpart):
            if looks_like_path_value(ph):
                flag = owner or label
                hz.append((flag, f"takes a PATH-valued argument ({ph}) -> "
                                 f"`{head} {flag} <any file>` makes it open that file"))
                break
        if DESC_ENV.search(desc):
            hz.append((label, f"its own description dumps an environment: {desc.strip()[:90]!r}"))
        elif DESC_READS_FILE.search(desc):
            hz.append((label, f"its own description reads from a file: {desc.strip()[:90]!r}"))
        elif DESC_RUNS_PROGRAM.search(desc):
            hz.append((label, f"its own description runs a program: {desc.strip()[:90]!r}"))
    seen, out = set(), []
    for tok, why in hz:
        if tok in seen:
            continue
        seen.add(tok)
        out.append((tok, why))
    return out


# ── the sandbox + the pty runner (Oracle B) ───────────────────────────────────
class Canaries:
    def __init__(self):
        n = secrets.token_hex(8).upper()
        self.file_content = "HUGMESHxFILExCANARYx" + n
        self.env_value = "HUGMESHxENVxCANARYx" + n
        self.exec_value = "HUGMESHxEXECxCANARYx" + n
        self.root = tempfile.mkdtemp(prefix="wc-exec-probe-")
        self.secret_path = os.path.join(self.root, "mounted-token")
        with open(self.secret_path, "w") as fh:
            fh.write(self.file_content + "\n")
        self.marker = os.path.join(self.root, "marker")
        # The exec canary is ASSEMBLED at run time and never appears literally in
        # the marker file. Otherwise a pure file-content READER pointed at the
        # marker (du --files0-from=marker echoes every line it cannot parse) would
        # print the canary and be reported as "executed a program" — the guard
        # would still be red, but for a defect the entry does not have, and a
        # guard that misnames what it caught cannot be trusted about what it
        # missed.
        self._ran_flag = os.path.join(self.root, "MARKER_RAN")
        half = len(self.exec_value) // 2
        with open(self.marker, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                "a=%s\nb=%s\n"
                ": > %s\n"
                'echo "$a$b"\n' % (self.exec_value[:half], self.exec_value[half:], self._ran_flag)
            )
        os.chmod(self.marker, 0o755)
        self.sentinel = os.path.join(self.root, "sentinel")
        with open(self.sentinel, "w") as fh:
            fh.write("do not touch\n")

        # ── the DIFFERENTIAL canaries ────────────────────────────────────────
        # Four sibling files that differ in EXACTLY ONE THING: their bytes. Same
        # basename, same length, same mode, same mtime — so anything an entry
        # prints that is derived from IDENTITY (path, inode, size, timestamps)
        # is identical across the two same-content runs AND present in the other
        # two, and therefore cannot be mistaken for a content leak. The contents
        # are laid out X, Y, X, Y and never adjacent to their own twin, so a value
        # that merely DRIFTS between runs cannot look like a function of content.
        self.diff_a = "HUGMESHxDIFFxAx" + secrets.token_hex(24)
        self.diff_b = "HUGMESHxDIFFxBx" + secrets.token_hex(24)
        assert len(self.diff_a) == len(self.diff_b)
        self.variants = []
        for i, body in enumerate((self.diff_a, self.diff_b, self.diff_a, self.diff_b)):
            d = os.path.join(self.root, "v%d" % i)
            os.mkdir(d)
            self.variants.append({
                "content": body,
                "canary": os.path.join(d, "mounted-token"),
                "sentinel": os.path.join(d, "out"),
            })
        self.reset_variants()

        self.baseline = self.snapshot()

    # The variant tree is REBUILT before every differential probe: an entry that
    # writes (xxd's second positional is an OUTFILE) would otherwise poison the
    # next comparison and turn a real write into a fake content leak.
    def reset_variants(self):
        for v in self.variants:
            with open(v["canary"], "w") as fh:
                fh.write(v["content"] + "\n")
            os.chmod(v["canary"], 0o600)
            os.utime(v["canary"], (1_700_000_000, 1_700_000_000))
            with open(v["sentinel"], "w") as fh:
                fh.write("do not touch\n")
            os.chmod(v["sentinel"], 0o600)
            os.utime(v["sentinel"], (1_700_000_000, 1_700_000_000))

    def snapshot(self):
        h = hashlib.sha256()
        for dirpath, dirnames, filenames in os.walk(self.root):
            # The v0..v3 differential tree is REBUILT between probes by design and
            # has its own oracle; folding it into the write-detector would make
            # every differential probe look like a filesystem modification.
            dirnames[:] = sorted(d for d in dirnames if not re.fullmatch(r"v\d+", d))
            for name in sorted(filenames):
                if name == "MARKER_RAN":
                    continue  # the execution flag has its own, separate oracle
                p = os.path.join(dirpath, name)
                h.update(os.path.relpath(p, self.root).encode())
                try:
                    with open(p, "rb") as fh:
                        h.update(fh.read())
                except OSError:
                    h.update(b"<unreadable>")
        return h.hexdigest()

    def marker_ran(self):
        return os.path.exists(self._ran_flag)

    def clear_marker(self):
        try:
            os.unlink(self._ran_flag)
        except OSError:
            pass

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


def run_on_pty(argv, env, cwd, timeout=CANARY_TIMEOUT_S):
    """Run argv on a real pty, wide enough that nothing is lost to truncation.

    A pty matters: procps ps scopes several of its selections to the controlling
    terminal, so a pipe-only probe would report `ps e` clean for the wrong reason
    and the guard would be green because it looked away, not because the command
    is safe.
    """
    import pty

    pid, fd = pty.fork()
    if pid == 0:  # child
        try:
            os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        except BaseException:
            os._exit(127)
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 200, PTY_COLS, 0, 0))
    except OSError:
        pass
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline and len(buf) < 8 << 20:
        try:
            r, _, _ = select.select([fd], [], [], 0.05)
        except OSError:
            break
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        else:
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                break
            if done:
                break
    for sig in (15, 9):
        try:
            os.kill(pid, sig)
        except OSError:
            break
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    return buf.decode("utf-8", "replace")


def probe_env(can):
    env = dict(os.environ)
    env["WORKLOAD_CONSOLE_PROBE_SECRET"] = can.env_value
    env["HOME"] = can.root
    env["TMPDIR"] = can.root
    env["COLUMNS"] = str(PTY_COLS)
    env["LC_ALL"] = "C"
    env.pop("LANG", None)
    return env


def materialize(tmpl, mapping):
    out = []
    for a in tmpl:
        for k, v in mapping.items():
            a = a.replace(k, v)
        out.append(a)
    return out


def behavioural_violations(tmpls, can, limit=6):
    """Oracle B. Returns [(argv, what_leaked)] for every argv that violates P."""
    env = probe_env(can)
    subst = {CANARY: can.secret_path, MARKER: can.marker, SENTINEL: can.sentinel}
    bad = []
    for tmpl in tmpls:
        argv = materialize(tmpl, subst)
        can.clear_marker()
        out = run_on_pty(argv, env, can.root)
        why = []
        if can.file_content in out:
            why.append("printed the CONTENTS of the file it was pointed at")
        if can.env_value in out:
            why.append("printed an ENVIRONMENT")
        if can.exec_value in out or can.marker_ran():
            why.append("EXECUTED another program")
        if can.snapshot() != can.baseline:
            why.append("MODIFIED the filesystem")
            can.baseline = can.snapshot()
        if why:
            bad.append((argv, "; ".join(why)))
            if len(bad) >= limit:
                break
    return bad


def _tokens(out):
    return set(out.replace("\r", "\n").split())


def content_leaks(tmpls, can, limit=6):
    """Oracle B', the DIFFERENTIAL leg. [(shown_argv, what_leaked)].

    An entry violates P if its output is a FUNCTION OF THE FILE'S BYTES, whatever
    alphabet it chooses to say so in — base64, hex, an octal dump, a checksum, the
    first N characters, the line reversed. Searching the output for the canary
    STRING can only see the identity transform, so instead the same argv is run
    against four sibling files whose contents are X, Y, X, Y and the output is
    tokenised:

        leaked_X = (tok[0] & tok[2]) - tok[1] - tok[3]
        leaked_Y = (tok[1] & tok[3]) - tok[0] - tok[2]

    A token in leaked_X survived both files that hold X and appeared in neither
    that holds Y: nothing but those bytes could have put it there. BOTH sides are
    required, so a single fluctuating value (a clock, a pid, df's used blocks)
    cannot manufacture a verdict — it would have to oscillate in step with the
    layout, and the two X files are never adjacent runs.

    Identity is explicitly NOT content: the four files differ in path and inode, so
    every token derived from them drops out of the intersection. That is why `ls`,
    `ls -l`, `stat` and `df` stay green here on their own merits rather than by
    exemption.
    """
    env = probe_env(can)
    bad = []
    for tmpl in tmpls:
        if not any(CANARY in a for a in tmpl):
            continue
        can.reset_variants()
        toks = []
        for v in can.variants:
            argv = materialize(tmpl, {CANARY: v["canary"], MARKER: can.marker,
                                      SENTINEL: v["sentinel"]})
            toks.append(_tokens(run_on_pty(argv, env, can.root)))
        leaked_x = (toks[0] & toks[2]) - toks[1] - toks[3]
        leaked_y = (toks[1] & toks[3]) - toks[0] - toks[2]
        if leaked_x and leaked_y:
            sample = sorted(leaked_x, key=len, reverse=True)[0]
            shown = materialize(tmpl, {CANARY: "<file>", MARKER: "<prog>",
                                       SENTINEL: "<out>"})
            bad.append((shown,
                        "printed a TRANSFORM of the CONTENTS of the file it was "
                        "pointed at — %d output token(s) changed when, and only "
                        "when, the file's bytes changed (e.g. %r). The canary "
                        "string never appears: an encoding is still the file."
                        % (len(leaked_x), sample[:64])))
            if len(bad) >= limit:
                break
    return bad


def battery_for_bare(head, tokens):
    """Every argv a BARE name licenses that is worth firing at the canaries.

    Templates, not argvs: the canary is a placeholder so the SAME battery can be
    materialised against the single literal canary (Oracle B) and against each of
    the four differential variants (Oracle B'). The first four forms carry no flag
    at all — that is the shape the option-only battery could never reach, and the
    shape `base64 /var/run/secrets/workload-console-read/token` arrives in.
    """
    argvs = [
        [head],
        [head, CANARY],                 # the plain positional operand
        [head, "--", CANARY],           # ... past an end-of-options separator
        [head, CANARY, SENTINEL],       # ... with a second operand (xxd's OUTFILE)
        [head, MARKER],
    ]
    for t in tokens:
        argvs.append([head, t])
        argvs.append([head, t, CANARY])
        if t.startswith("--"):
            argvs.append([head, t + "=" + CANARY])
        argvs.append([head, t, MARKER])
    return argvs


# ── the check ─────────────────────────────────────────────────────────────────
def check_entries(entries, emit):
    """Assert P over a parsed allowlist. Returns (passes, failures)."""
    P = F = 0

    def ok(m):
        nonlocal P
        P += 1
        emit("  PASS " + m)

    def bad(m):
        nonlocal F
        F += 1
        emit("  FAIL " + m)

    if not entries:
        bad("exec allowlist is empty")
        return P, F
    ok("exec allowlist non-empty (%d entries)" % len(entries))

    can = Canaries()
    try:
        bare_heads = {e.split()[0] for e in entries if len(e.split()) == 1}
        for entry in entries:
            argv = entry.split()
            head, args = argv[0], argv[1:]

            if SHELL_META & set(entry):
                bad("entry %r contains a shell metacharacter" % entry)
                continue
            if any("/" in a for a in argv):
                bad("entry %r embeds a path; an allowlist entry names a COMMAND, and a "
                    "pinned path is how `--files0-from=/var/run/secrets/...` would get in"
                    % entry)
                continue
            if args and any(not a.startswith("-") for a in args):
                bad("entry %r carries a non-flag argument — a pinned form is flags only "
                    "(this is what makes `ps eww` unrepresentable: its selectors are "
                    "undashed)" % entry)
                continue
            if args and head in bare_heads:
                bad("entry %r pins arguments for %r while %r also ships BARE — the bare "
                    "name licenses every argv and voids the pin" % (entry, head, head))
                continue

            binary = shutil.which(head)
            if not binary:
                bad("entry %r: %r is not present on this runner, so the property CANNOT "
                    "be proven for it. An unprobed entry is an unproven entry — install "
                    "the package that ships it in the job image, or drop the entry."
                    % (entry, head))
                continue

            help_text = harvest_help(head, can.root)
            if len(help_text.strip()) < 40:
                bad("entry %r: %r produced no usable --help/-h text, so neither oracle "
                    "can judge its arguments" % (entry, head))
                continue
            blocks = parse_option_blocks(help_text)
            if not blocks:
                bad("entry %r: could not parse a single option out of %r's help; the "
                    "argument surface is unknown, so the property is unproven"
                    % (entry, head))
                continue
            tokens = harvest_option_tokens(help_text, blocks)

            # BOTH oracles always run, even once one has already condemned the
            # entry: they are independent evidence, and a guard that stops at the
            # first hit can never show that its second leg still works.
            only = None if not args else flags_of(args)
            hz = doc_hazards(head, help_text, blocks, only_flags=only)
            # The OPERAND half of the argv surface. Only a bare name can be handed
            # one — a pinned whole-argv form admits no extra positional — which is
            # exactly why a bare name has to survive this leg too.
            if only is None:
                hz = hz + positional_doc_hazards(head, help_text)
            argvs = [argv] if args else battery_for_bare(head, tokens)
            viol = behavioural_violations(argvs, can)
            leak = content_leaks(argvs, can)

            if hz or viol or leak:
                for tok, why in hz[:4]:
                    if tok == "<synopsis>":
                        bad("entry %r: [docs] %s" % (entry, why))
                    elif tok.startswith("<operand "):
                        bad("entry %r: [docs/operand] `%s` %s" % (entry, head, why))
                    else:
                        bad("entry %r: [docs] `%s %s` %s" % (entry, head, tok, why))
                for v_argv, why in viol[:4]:
                    bad("entry %r: [behaviour] `%s` %s" % (entry, " ".join(v_argv), why))
                for v_argv, why in leak[:4]:
                    bad("entry %r: [behaviour/differential] `%s` %s"
                        % (entry, " ".join(v_argv), why))
                if not args:
                    bad("entry %r is a BARE name, so the shipped first-token matcher "
                        "licenses EVERY one of those forms. Pin an explicit whole-argv "
                        "form, or drop the entry." % entry)
                continue

            if args:
                ok("entry %r: pinned argv — its flags carry no path-valued, "
                   "environment-dumping or program-running documentation, and the exact "
                   "form leaked no file/env/exec canary on a live pty" % entry)
            else:
                ok("entry %r: bare name holds property P — none of the %d documented "
                   "options takes a path, dumps an environment or runs a program, no "
                   "operand of its synopsis is a documented byte stream, and %d live "
                   "argv probes (positional and flag-valued) leaked no canary, touched "
                   "no file, and produced no output token that changed with the probed "
                   "file's BYTES" % (entry, len(blocks), len(argvs)))
    finally:
        can.cleanup()
    return P, F


def entries_from_patch(path):
    import yaml

    doc = yaml.safe_load(open(path))
    spec = doc["spec"]["template"]["spec"]
    ctr = next(c for c in spec["containers"] if c["name"] == "hugmesh-admin-bff-api")
    env = {e["name"]: e.get("value") for e in ctr.get("env", [])}
    raw = env.get("WORKLOAD_CONSOLE_EXEC_READONLY") or ""
    return [e.strip() for e in raw.split(",") if e.strip()]


def main(argv):
    if len(argv) >= 3 and argv[1] == "--entries":
        entries = [e.strip() for e in argv[2].split(",") if e.strip()]
    elif len(argv) >= 2:
        entries = entries_from_patch(argv[1])
    else:
        print("usage: exec_argv_property.py <patch.yaml> | --entries 'a,b -c'")
        return 2
    P, F = check_entries(entries, print)
    print("__SUB %d %d" % (P, F))
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
