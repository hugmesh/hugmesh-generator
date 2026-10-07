#!/usr/bin/env python3
"""draft.py — let the local model draft a fix for one issue, inside a scratch worktree.

Run by draft.sh, under `env -i` with only PATH, HOME, LANG, TERM and a loopback
OLLAMA_HOST. The issue text is already in OUT/issue.md: it was fetched before this
step, with the person's own gh login, and nothing here calls gh. Nothing is pushed.

AGENT modes (--agent):
  plain     the default. Only the Ollama HTTP API: send the issue plus the few files a
            search of the worktree picks, ask for a unified diff, check it with
            `git apply --check` and apply it to the scratch worktree. Nothing the model
            wrote is ever RUN: it is text until a person reads the diff.
  opencode  `ollama launch opencode`, a coding agent that does run commands in the
            scratch worktree. Only when that command exists.
  other     handed to agent-explicit.sh, which accepts one explicit name.

The result is OUT/STATUS (first word = state), OUT/draft.diff and OUT/agent.log:
  applied         the diff applies cleanly; draft.diff is git's own rendering of it
  does-not-apply  the model's diff does not apply; draft.diff is what it wrote
  no-diff         the model gave no diff (or said the issue is not for it)
  no-ollama / no-model / no-issue / error   the step could not run
"""
import argparse
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "studio"))

from hugmesh_studio.core import local_ai_status as lai  # noqa: E402

MAX_FILES = 3
MAX_FILE_CHARS = 12000
MAX_ISSUE_CHARS = 6000
PATH_RE = re.compile(
    r"[\w./-]+\.(?:sh|py|java|ts|tsx|js|md|yml|yaml|json|html|scss|css|xml|properties|toml|cfg|conf)\b"
    r"|\b(?:Makefile|Dockerfile[\w.-]*)\b")
# Any path with a directory in it, whatever its ending: the issues name files such as
# specs/usr/sbin/hugmesh-firewall-reconcile (no extension) and specs/selinux/hugmesh_tor.te.
SLASH_RE = re.compile(r"(?<![\w/.:-])[\w.-]+(?:/[\w.-]+)+")
TICK_RE = re.compile(r"`([^`\n]{3,60})`")
IDENT_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]{4,}(?:[-.][A-Za-z0-9_]+)*\b")

SYSTEM = (
    "You are a careful software engineer. You can only read the text you are given; you "
    "cannot run anything. Reply with ONE unified diff against the files shown and nothing "
    "else: no explanation before or after it. Use the paths exactly as shown (--- a/PATH, "
    "+++ b/PATH), keep every context line exactly as it appears, and change as little as "
    "possible (one or two files). If the issue needs a live system, a secret, a decision "
    "from a person or more than two files, reply with exactly one line: NO CHANGE: <reason>.")

BRIEF = (
    "You are a small local model in a scratch git worktree of a repository. A person will "
    "review everything. Rules: work only in this directory; never run git push, gh, sudo, "
    "docker, make stack-* or make kind-*; keep the change as small as possible (one or two "
    "files); do not claim a test passed unless you ran it and saw it pass; end with what "
    "you changed, what you ran, and what you did NOT verify. TASK: attempt the smallest "
    "correct fix for the issue below. If it needs a live mesh, a secret, or more than two "
    "files, change nothing and say why.\n\n")


def say(msg):
    print(f"[{time.strftime('%T')}] {msg}", flush=True)


def git(work, *args, stdin=None, check=False):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    return subprocess.run(["git", "-C", work, *args], input=stdin, capture_output=True,
                          text=True, env=env, check=check)


def set_status(out, line):
    with open(os.path.join(out, "STATUS"), "w", encoding="utf-8") as fh:
        fh.write(line.strip() + "\n")


# ── choosing the files the model sees ────────────────────────────────────────────────
def tokens(issue):
    """Search terms: backticked words, and identifiers that are not plain English."""
    seen, out = set(), []
    cands = [m.group(1).strip() for m in TICK_RE.finditer(issue)]
    for m in IDENT_RE.finditer(issue):
        w = m.group(0)
        if any(c in w for c in "_-.") or (w != w.lower() and w != w.capitalize()) \
                or any(c.isdigit() for c in w):
            cands.append(w)
    for w in cands:
        k = w.lower()
        if len(w) >= 4 and k not in seen and "\n" not in w:
            seen.add(k)
            out.append(w)
    return out[:15]


def pick_files(work, issue):
    tracked = git(work, "ls-files").stdout.splitlines()
    score = {}
    named = [m.group(0) for m in PATH_RE.finditer(issue)]
    named += [m.group(0).rstrip(".") for m in SLASH_RE.finditer(issue)]
    for want in dict.fromkeys(w.lstrip("./") for w in named):
        if not want:
            continue
        for f in tracked:
            if f == want or f.endswith("/" + want):
                score[f] = score.get(f, 0.0) + 10.0
    for tok in tokens(issue):
        hit = git(work, "grep", "-I", "-l", "-F", "-i", "-e", tok).stdout.split()
        if not hit or len(hit) > 40:
            continue
        for f in hit:
            score[f] = score.get(f, 0.0) + 1.0 / len(hit)
    ranked = sorted(score.items(), key=lambda kv: (-kv[1], kv[0]))
    return [f for f, _ in ranked[:MAX_FILES]]


def read_file(work, rel, issue):
    """The whole file when small, else the stretch around the best match."""
    try:
        with open(os.path.join(work, rel), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    if len(text) <= MAX_FILE_CHARS:
        return text
    lines = text.splitlines()
    best = 0
    for tok in tokens(issue):
        for i, ln in enumerate(lines):
            if tok.lower() in ln.lower():
                best = i
                break
        if best:
            break
    lo = max(0, best - 60)
    hi = lo
    size = 0
    while hi < len(lines) and size < MAX_FILE_CHARS:
        size += len(lines[hi]) + 1
        hi += 1
    return f"(lines {lo + 1}-{hi} of {len(lines)} shown)\n" + "\n".join(lines[lo:hi])


# ── the model's answer -> a diff ─────────────────────────────────────────────────────
def extract_diff(answer):
    """The unified diff inside a model reply, or '' when there is none."""
    text = answer.replace("\r\n", "\n")
    for m in re.finditer(r"```[a-zA-Z]*\n(.*?)```", text, re.S):
        body = m.group(1)
        if re.search(r"^--- ", body, re.M) and re.search(r"^\+\+\+ ", body, re.M):
            text = body
            break
    lines = text.split("\n")
    start = next((i for i, ln in enumerate(lines)
                  if ln.startswith("diff --git ") or ln.startswith("--- ")), None)
    if start is None:
        return ""
    body = lines[start:]
    while body and body[-1].strip() in ("", "```"):
        body.pop()
    diff = "\n".join(body) + "\n"
    return diff if re.search(r"^\+\+\+ ", diff, re.M) else ""


def unsafe_path(diff):
    """A path the diff must not touch: outside the tree, or inside .git."""
    for ln in diff.split("\n"):
        if ln.startswith(("--- ", "+++ ")):
            path = ln[4:].split("\t")[0].strip()
            if path == "/dev/null":
                continue
            path = re.sub(r"^[ab]/", "", path)
            parts = path.split("/")
            if path.startswith("/") or ".." in parts or parts[0] == ".git":
                return path
    return ""


def worktree_diff(work):
    git(work, "add", "-N", "-A")
    return git(work, "diff").stdout


# ── the three modes ──────────────────────────────────────────────────────────────────
def run_plain(a, issue):
    try:
        base = lai.base_url()
    except lai.NotLoopback as exc:
        set_status(a.out, f"no-ollama {exc}")
        return 2
    try:
        models = [m.get("name") for m in lai._get_json(None, "/api/tags", 5).get("models", [])]
    except Exception:
        set_status(a.out, f"no-ollama nothing answers on {base}; run scripts/local-ai.sh up")
        return 2
    if a.model not in models:
        set_status(a.out, f"no-model {a.model} is not pulled; run: ollama pull {a.model}")
        return 2
    files = pick_files(a.work, issue)
    say(f"model {a.model}; files chosen from the issue text: {', '.join(files) or '(none)'}")
    blocks = []
    for rel in files:
        text = read_file(a.work, rel, issue)
        if text is not None:
            blocks.append(f"### {rel}\n```\n{text}\n```")
    prompt = ("ISSUE\n" + issue[:MAX_ISSUE_CHARS] + "\n\nFILES (the current contents)\n"
              + ("\n\n".join(blocks) if blocks else "(no file was found by searching the issue's words)"))
    t0 = time.time()
    try:
        answer = lai.send_prompt(prompt, a.model, system=SYSTEM, timeout=600,
                                 total_timeout=a.timeout,
                                 options={"num_ctx": a.ctx, "num_predict": a.predict,
                                          "temperature": 0.1})
    except lai.LocalAIError as exc:
        set_status(a.out, f"error {exc}")
        return 1
    say(f"answer received in {time.time() - t0:.0f}s ({len(answer)} characters)")
    print("----- model answer -----\n" + answer + "\n----- end -----", flush=True)
    diff = extract_diff(answer)
    if not diff:
        why = answer.strip().splitlines()[0][:160] if answer.strip() else "empty answer"
        set_status(a.out, f"no-diff {why}")
        return 0
    open(os.path.join(a.out, "draft.diff"), "w", encoding="utf-8").write(diff)
    bad = unsafe_path(diff)
    if bad:
        set_status(a.out, f"does-not-apply refused: the diff touches {bad}")
        return 0
    check = git(a.work, "apply", "--check", "--recount", "--whitespace=nowarn", stdin=diff)
    if check.returncode != 0:
        first = (check.stderr.strip().splitlines() or ["git apply --check failed"])[0]
        set_status(a.out, f"does-not-apply {first[:160]}")
        return 0
    git(a.work, "apply", "--recount", "--whitespace=nowarn", stdin=diff, check=True)
    final = worktree_diff(a.work)
    open(os.path.join(a.out, "draft.diff"), "w", encoding="utf-8").write(final)
    n_files = len(re.findall(r"^diff --git ", final, re.M))
    set_status(a.out, f"applied files={n_files} diff_lines={len(final.splitlines())} model={a.model}")
    return 0


def agent_env(out):
    """The allowlist plus the few settings that stop an agent pushing by accident. This
    is hardening, not a sandbox: the agent still has the person's home directory."""
    no_gh = os.path.join(out, ".no-gh")          # an empty gh config: no login to find
    os.makedirs(no_gh, exist_ok=True)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", ""),
           "LANG": os.environ.get("LANG", "C.UTF-8"), "TERM": "dumb",
           "OLLAMA_HOST": os.environ.get("OLLAMA_HOST", lai.DEFAULT_HOST)}
    env.update({"GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_COUNT": "2",
                "GIT_CONFIG_KEY_0": "remote.origin.pushurl", "GIT_CONFIG_VALUE_0": "no-push-from-a-draft",
                "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "",
                "GH_CONFIG_DIR": no_gh})
    return env


def run_agent(a, issue, cmd):
    say("running: " + " ".join(cmd[:6]) + " ...")
    try:
        done = subprocess.run(cmd, cwd=a.work, env=agent_env(a.out), text=True,
                              capture_output=True, timeout=a.timeout)
        print(done.stdout + done.stderr, flush=True)
        rc = done.returncode
    except subprocess.TimeoutExpired:
        set_status(a.out, f"error the agent did not finish in {a.timeout} seconds")
        return 1
    final = worktree_diff(a.work)
    open(os.path.join(a.out, "draft.diff"), "w", encoding="utf-8").write(final)
    if not final.strip():
        set_status(a.out, f"no-diff the agent changed nothing (exit {rc})")
        return 0
    n_files = len(re.findall(r"^diff --git ", final, re.M))
    set_status(a.out, f"applied files={n_files} diff_lines={len(final.splitlines())} "
                      f"agent={a.agent} exit={rc}")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--issue", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--model", default=lai.DEFAULT_MODEL)
    ap.add_argument("--agent", default="plain")
    ap.add_argument("--ctx", type=int, default=16384)
    ap.add_argument("--predict", type=int, default=2048)
    ap.add_argument("--timeout", type=int, default=1500)
    a = ap.parse_args(argv)
    try:
        with open(os.path.join(a.out, "issue.md"), encoding="utf-8") as fh:
            issue = fh.read()
    except OSError:
        set_status(a.out, "no-issue issue.md is missing")
        return 1
    say(f"draft {a.repo}#{a.issue} agent={a.agent}")
    # names only, never values: the log shows what this step was handed
    say("environment names: " + " ".join(sorted(os.environ)))
    if a.agent == "plain":
        return run_plain(a, issue)
    if a.agent == "opencode":
        if not any(os.access(os.path.join(p, "opencode"), os.X_OK)
                   for p in os.environ.get("PATH", "").split(os.pathsep)):
            set_status(a.out, "error AGENT=opencode needs the opencode command; "
                              "unset AGENT to use the plain mode, which needs nothing extra")
            return 1
        return run_agent(a, issue, ["ollama", "launch", "opencode", "--model", a.model,
                                    "--", "run", BRIEF + issue[:MAX_ISSUE_CHARS]])
    return run_agent(a, issue, ["bash", os.path.join(HERE, "agent-explicit.sh"), a.agent,
                                a.model, BRIEF + issue[:MAX_ISSUE_CHARS]])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
