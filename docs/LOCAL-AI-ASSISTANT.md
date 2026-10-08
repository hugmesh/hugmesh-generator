# Local AI coding assistant — Ollama on your own PC, pointed at the mesh code

Run a coding model on your own machine with the Ollama command line, then point a
code assistant at a copy of the HugMesh repositories. Nothing leaves the PC: the
server listens on loopback, the model weights are files on your disk, and the only
network use is the one-time download of the weights.

This page is for a developer's desktop or laptop. To serve models to the **mesh**
from a GPU node, see [EDGE-AI.md](EDGE-AI.md); section 7 below says how the two meet.

> **Honest limits.** A model that fits a desktop GPU is far weaker than a hosted
> frontier model. Use it to read, explain, triage logs and draft small, file-scoped
> edits that **you review**. Do not let it merge, push or run long unattended jobs.
> Its claim "the tests pass" means nothing until you have seen them pass.

Contents: [1 Hardware](#1-what-this-pc-has-and-what-fits) ·
[2 Install](#2-install-ollama-cli) · [3 Start the server](#3-start-the-server) ·
[4 Pick a model](#4-pick-a-model) · [5 Check it](#5-check-that-it-works) ·
[6 Assistant on the mesh code](#6-run-a-code-assistant-on-the-mesh-code) ·
[7 The mesh's own GPU node](#7-use-the-meshs-own-gpu-node-instead) ·
[8 Safety](#8-safety-rules) · [9 Measure your PC](#9-measure-your-own-pc) ·
[10 Troubleshooting](#10-troubleshooting) ·
[11 Running it all without Claude](#11-running-it-all-without-claude)

---

## 1. What this PC has, and what fits

The figures in this page were measured on the reference development PC:

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 4060, **8 GB** VRAM (about 2 GB of it is held by the desktop, so about 6 GB is free for a model) |
| RAM | 31 GiB |
| OS / Ollama | Linux (Gentoo), Ollama 0.21.2 at `/usr/bin/ollama` |

Three rules decide what runs well:

1. **A model plus its context cache must fit in free VRAM to run at full speed.** The
   cache grows with `num_ctx` (the context you ask for), so a 4.7 GB model at 16k
   context loaded as 6.1 GB here. What does not fit runs on the CPU, and the
   `PROCESSOR` column of `ollama ps` shows the split.
2. **Mixture-of-experts (MoE) models are the exception.** A "30B-A3B" model holds 30B
   parameters but uses about 3B per token, so a 19 GB file can run at a usable speed
   with most of it in system RAM. It needs that RAM free: close the compose stack and
   the kind cluster first (with a few builds running they held about 15 GiB here).
3. **Dense models larger than the GPU crawl.** A dense 24B or 27B model with half of
   it on the CPU reads every parameter for every token. Do not expect agent-speed.

## 2. Install Ollama (CLI)

Pick one. All of them give you the same `ollama` command.

```bash
# a) your distribution's package, if it has one
# b) the vendor installer for Linux (downloads and runs a script: read it first)
curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh && less /tmp/ollama-install.sh && sh /tmp/ollama-install.sh
# c) a container with the GPU passed through, bound to loopback only
docker run -d --gpus=all -v ollama:/root/.ollama -p 127.0.0.1:11434:11434 --name ollama ollama/ollama
```

macOS and Windows use the installer from <https://ollama.com/download>.

Check it:

```bash
ollama --version          # this PC: 0.21.2
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv   # NVIDIA only: how much VRAM is free
```

### Keep Ollama current

A model published after your Ollama was built is **refused at pull time**:

```text
Error: pull model manifest: 412:
The model you are attempting to pull requires a newer version of Ollama.
```

On the reference PC (Ollama 0.21.2; the newest release on 2026-10-07 was 0.40.0, from
<https://github.com/ollama/ollama/releases>) `ornith`, `lfm2.5`, `north-mini-code-1.0`
and `laguna-xs-2.1` were refused this way, while `qwen3:8b`, `qwen2.5-coder`,
`gpt-oss:20b` and `qwen3-coder:30b` pulled. Compare `ollama --version` with the latest
release, and update through the same route you installed by (the package manager, the
vendor installer again, or a new container image). Updating replaces the program and
keeps `~/.ollama`, so the models you already pulled stay.

## 3. Start the server

If your install registered a service, it is already running. Otherwise start it
yourself, **on loopback**:

```bash
OLLAMA_HOST=127.0.0.1:11434 OLLAMA_CONTEXT_LENGTH=32768 OLLAMA_FLASH_ATTENTION=1 \
OLLAMA_KV_CACHE_TYPE=q8_0 setsid ollama serve >~/.cache/ollama-serve.log 2>&1 &
curl -s 127.0.0.1:11434/api/tags | head -c 200     # answers with the pulled models
```

| Variable | What it does | Why this value |
|---|---|---|
| `OLLAMA_HOST` | address the server binds | `127.0.0.1:11434`: never `0.0.0.0` on a laptop; section 8 |
| `OLLAMA_CONTEXT_LENGTH` | default context for tools that do not set their own | 32768 is what an agent harness needs; a plain chat needs less |
| `OLLAMA_FLASH_ATTENTION=1` | cheaper attention, smaller cache | needed for the next line |
| `OLLAMA_KV_CACHE_TYPE=q8_0` | halves the context cache | more context in the same VRAM |
| `OLLAMA_MODELS` | where weights live | point it at a big disk: a model is 5 to 25 GB |
| `OLLAMA_KEEP_ALIVE` | how long an idle model stays loaded (default 5 min) | `30m` for a work session; `0` frees VRAM at once |
| `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL` | concurrency | leave unset (parallelism defaults to 1); set `OLLAMA_MAX_LOADED_MODELS=1` to keep only one model resident on an 8 GB card |

Stop it with `pkill -x ollama` (the weights stay on disk). `ollama stop <model>`
unloads one model and keeps the server up.

## 4. Pick a model

Sizes, context windows and tags below are from the Ollama library pages on
**2026-10-07** (<https://ollama.com/library>). The library changes weekly: before you
pull, look at `https://ollama.com/library?sort=newest` and at the model's page, and
after you pull, read the truth with `ollama show <model>`.

> **Never use a tag ending `-cloud`.** Those run on Ollama's servers, not on your PC.
> The prompt, and the code in it, leaves the machine. `OLLAMA_NO_CLOUD=1` on the
> server turns the cloud models off.

The last two columns are what the benchmark in section 9 recorded on the reference PC
at `num_ctx` 16384. A dash means the model has not been measured here yet: run the
script on your own PC for your own numbers. Speeds move with what else the PC is
doing (the figures marked * were taken while builds were running and the load average was above 20).

### Tier A: fits the GPU (best for an agent that must stay responsive)

| Model | Pull | Weights | Max context | Good for | Loaded size / on GPU | Generation |
|---|---|---|---|---|---|---|
| `qwen3:8b` | `ollama pull qwen3:8b` | 5.2 GB | 40K | general work and **tool use**; this is the model the Claude Code session in section 6 was verified on; has a thinking mode | 6.6 GB / 100%* | about 45 tok/s* |
| `qwen2.5-coder:7b` | `ollama pull qwen2.5-coder:7b` | 4.7 GB | 32K | code edits, tests, conversions in a chat; has `tools` but no thinking mode, and is a weaker agent than `qwen3:8b` | 6.1 GB / 87%* | 19 to 20 tok/s* |
| `ornith:9b` | `ollama pull ornith:9b` | 5.6 GB | 256K | listed as a coding-agent model with tools and thinking | needs a newer Ollama (pull refused, HTTP 412, on 0.21.2) | — |
| `lfm2.5:8b` | `ollama pull lfm2.5:8b` | 5.2 GB | 125K | listed for fast tool calling on consumer hardware | needs a newer Ollama (pull refused, HTTP 412, on 0.21.2) | — |
| `qwen2.5-coder:3b` / `:1.5b` | `ollama pull qwen2.5-coder:3b` | 1.9 GB / 0.99 GB | 32K | editor autocomplete beside a bigger model | — | — |

### Tier B: mixture-of-experts, runs partly on the CPU (needs about 14 to 20 GiB free RAM)

| Model | Pull | Weights | Max context | Good for | Loaded size / on GPU | Generation |
|---|---|---|---|---|---|---|
| `gpt-oss:20b` | `ollama pull gpt-oss:20b` | 14 GB | 128K | reasoning and tool calling; the smallest of this tier | pulls on 0.21.2; not measured yet | — |
| `qwen3-coder:30b` | `ollama pull qwen3-coder:30b` | 19 GB | 256K | 30B total, about 3.3B active: agentic coding | pulls on 0.21.2; not measured yet | — |
| `north-mini-code-1.0` | `ollama pull north-mini-code-1.0` | 19 GB | 488K | 30B MoE, 3B active, "built for agentic software engineering" | needs a newer Ollama (pull refused, HTTP 412, on 0.21.2) | — |
| `laguna-xs-2.1` | `ollama pull laguna-xs-2.1` | 20 GB | 256K | 33B MoE, 3B active, "agentic coding and long-horizon work on a local machine" | needs a newer Ollama (pull refused, HTTP 412, on 0.21.2) | — |
| `ornith:35b` | `ollama pull ornith:35b` | 21 GB | 256K | the larger ornith | needs a newer Ollama (pull refused, HTTP 412, on 0.21.2) | — |

### Tier C: does not suit this PC

| Model | Weights | Why |
|---|---|---|
| `devstral-small-2` (24B) | 15 GB | dense: about half would sit on the CPU, expect a few tokens per second |
| `qwen3.8:27b`, `qwen3.6:27b` | 18 to 19 GB | dense, same reason |
| `qwen3.6:35b`, `nemotron-3.5-lightning:30b` | 23 to 25 GB | leaves too little RAM for anything else |
| `laguna-xs-2.1:q8_0`, `qwen3-coder-next`, `gpt-oss:120b` | 36 to 65 GB | larger than this PC's RAM |

### How to choose

* **Driving an agent** (it reads files and runs commands): start with `qwen3:8b`. Move
  to a Tier B model when one file at a time is too small for the job and you can free
  the RAM.
* **Chat-style edits and test writing**: `qwen2.5-coder:7b`.
* **The mesh stack is running** (compose or kind): stay in Tier A.
* **Quality is not in this table.** Sizes and speeds are measured or published;
  whether a model writes correct code for *your* task is not. Try two models on the
  same small task and read the diffs.

## 5. Check that it works

```bash
ollama pull qwen3:8b
ollama run qwen3:8b --verbose "Write a bash function that retries a command 3 times"   # --verbose prints tokens/s
ollama ps            # PROCESSOR column: "100% GPU" is the goal; "18%/82% CPU/GPU" means a spill
ollama list          # what is on disk
ollama show qwen3:8b # context length, quantization, capabilities (look for "tools")
```

The same server speaks HTTP, which is what assistants use:

```bash
curl -s 127.0.0.1:11434/api/chat -d '{"model":"qwen3:8b","stream":false,"think":false,
  "options":{"num_ctx":16384},"messages":[{"role":"user","content":"one line: what is git worktree?"}]}'
# OpenAI-compatible: base URL http://127.0.0.1:11434/v1 and any non-empty API key
```

`num_ctx` is **per request**. If a prompt is longer, its beginning is silently dropped:
raise `num_ctx` (and watch `ollama ps` for a CPU spill) rather than assuming the model
read all of it.

## 6. Run a code assistant on the mesh code

### 6.1 Give the assistant a copy, never your working checkout

The assistant gets a scratch clone **with no remote**, so nothing it does can be
pushed, and nothing it breaks touches your real checkout.

```bash
# the repos: one folder per app, hugmesh-<name>. Studio's "Download the source" puts them in ./.stack-src;
# "Build from a source tree I already have" points at your own folder. Either works as the origin below.
git clone --no-hardlinks ~/Github/hugmesh-user-bff-api ~/lm-scratch/hugmesh-user-bff-api
cd ~/lm-scratch/hugmesh-user-bff-api
git remote remove origin                 # no remote: git push has nowhere to go
git switch -c lm/try-1
```

Do the `git remote remove origin` **before** the first assistant command: until then
`origin` points at your real checkout. Bring a result back by reading the diff
(`git diff main...`) and applying it yourself (`git format-patch` in the scratch
clone, `git am` in the real one).

This is not a sandbox. Removing the remote removes the convenience of pushing, not the
ability: the assistant can run `git remote add`, and any `gh` login or git credential
helper in your session is reachable by every process you start. The protections that
count are that you approve each command and that the shell you launch it from has no
token (section 8).

### 6.2 Claude Code on the local model (verified)

`ollama launch` starts a coding agent against your local server. This was verified
on the reference PC: the agent ran, the local server logged `POST /v1/messages`, and
nothing went to a hosted service.

```bash
cd ~/lm-scratch/hugmesh-user-bff-api
ollama launch claude --model qwen3:8b                      # interactive session
ollama launch claude --model qwen3:8b -- -p "Reply with the single word OK"   # one headless answer
```

* It needs the `claude` command installed; `ollama launch` tells you if it is missing.
* Run the server with `OLLAMA_CONTEXT_LENGTH=32768`: the agent's own instructions are
  large, and they leave roughly 12k to 15k tokens for the actual task. At that size
  `qwen3:8b` loads as 8.0 GB and, with the desktop holding about 2 GB of VRAM, about
  70% of it ran on the GPU and 30% on the CPU (`ollama ps`); an earlier run with
  less VRAM in use reached 87%. An agent-sized context costs speed on an 8 GB card.
* The first reply takes about 40 s (model load plus the large prompt).
* Warnings that the model "isn't described by this version's model catalog" and that
  some hosted-only features are disabled are expected and harmless.
* Only a model with the **tools** capability can drive an agent (`ollama show <model>`).

### 6.3 Other assistants

`ollama launch` supports (from `ollama launch --help` on 0.21.2): `claude`, `cline`,
`codex`, `copilot`, `droid`, `hermes`, `kimi`, `opencode`, `openclaw`, `pi` and `vscode`.

```bash
ollama launch opencode --model qwen3:8b
ollama launch vscode --model qwen3:8b
ollama launch --help                      # the list for your version
```

Any other tool that can talk to an OpenAI-compatible server works with base URL
`http://127.0.0.1:11434/v1` and any non-empty API key. Do not enable an "auto-approve
tools" or "yolo" mode (for example `ollama run --experimental-yolo`) with a model this
size.

### 6.4 Without an agent

```bash
git diff main... | ollama run qwen3:8b --think=false "Review this diff for bugs. Answer as file:line - problem."
ollama run qwen2.5-coder:7b "$(cat src/main/java/net/hugmesh/Foo.java)

Add a failing JUnit test for the null case. Output only the test class."
./mvnw -B verify 2>&1 | tail -80 | ollama run qwen3:8b --think=false "What failed, and what is the single next command?"
```

### 6.5 Tasks that suit a small model

Good: explain a file or a stack trace, summarise a log, write one test for one
function, rename a field in one file, draft a commit message, convert a script.
Poor: anything across many files, anything needing the whole repository in view,
security decisions, anything where being wrong is silent.

Start a session with a brief that sets the rules. This one has worked:

```text
You are a small local model working in a scratch clone with no remote. A person will
review everything you do. Work only in this directory. Never run: git push, sudo,
docker compose up/down, make stack-* or make kind-*, or anything that deletes
outside this directory. Keep each task to one file or one failing test; read big
files in ranges. End every task with: what you changed, what you ran and its result,
and what you did NOT verify. Do not claim a test passed unless you ran it and saw it
pass. First task: <one sentence>.
```

### 6.6 Check what it did

Run the repo's own tests yourself, in the scratch clone:

| Repo kind | Command (from the repo root) |
|---|---|
| Java service (`*-bff-api`, gateway, federation) | `./mvnw -B verify` (some repos pass `-s settings.xml`; see the repo README) |
| Angular UI (`*-ui`, host shell) | `npm ci && npm run build && npm test -- --watch=false` |
| Studio (in `hugmesh-generator/studio`) | `HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen python -m pytest -q tests/<file>.py` |
| Shell and guards (generator) | `bash tests/scripts/test-<name>.sh` |

See [LOCAL-TESTING.md](LOCAL-TESTING.md) and [RUNNING.md](RUNNING.md) for the full
local setup, and [LOCAL-STACK.md](LOCAL-STACK.md) for running the mesh itself.

## 7. Use the mesh's own GPU node instead

If the mesh has an `edge-ai` node, it already serves an OpenAI-compatible model API
to the mesh at `https://ai.<domain>/v1` (see [EDGE-AI.md](EDGE-AI.md)). An assistant
can use it in place of the loopback server: set the base URL to
`https://ai.<domain>/v1` and send a mesh token. **That token is your gateway session
credential, not a key for the model route alone**: put in an assistant's config it
gives the assistant everything your account can reach. The route sits behind the
gateway's authenticated floor (`ROLE_USER`); EDGE-AI.md describes adding a narrower
role (`ROLE_EDGE_AI`) for it. Do that, and use an identity that holds only that role,
before you hand a token to a tool. That makes bigger models available than a desktop GPU
can hold, at the price of the prompt leaving your PC for a machine you run.

## 8. Safety rules

* **Loopback only.** `OLLAMA_HOST=127.0.0.1:11434`. The Ollama API has no login;
  binding it to `0.0.0.0` hands your GPU, and every model on it, to the network.
* **No push credentials in the assistant's reach.** Do not export a GitHub or registry
  token into the shell you launch it from, and do not launch it from a session where
  `gh` is logged in if you cannot watch every command. The no-remote clone of section
  6.1 helps; it is not a sandbox.
* **No secrets in prompts.** `.e2e-credentials`, vault files and `.env` files stay out
  of what you paste or let it read.
* **Review every diff.** A small model invents function names and reports tests it did
  not run.
* **No auto-approval of tools**, and no `sudo` in a session you cannot watch.
* **Weights are code from the internet.** Pull from the official library
  (`ollama.com/library`), not from an unknown namespace.

## 9. Measure your own PC

The tables above go out of date, and every PC differs. `scripts/local-ai-bench.sh`
pulls each model (removing what it pulled afterwards), loads it at `num_ctx` 16384
and records the loaded size, the share on the GPU, the load time, the generation
speed on a coding prompt, and the prompt-processing speed and token count on a
long prompt (about 10k tokens with the default file):

```bash
# from the repository root:
scripts/local-ai-bench.sh                        # the shortlist above
scripts/local-ai-bench.sh qwen3:8b gpt-oss:20b   # just these
CTX=32768 PRUNE=0 scripts/local-ai-bench.sh qwen3:8b
```

It writes a table to the terminal and a TSV to `~/.cache/hugmesh-local-bench/`. Run it
when the PC is otherwise idle (close the compose stack and the kind cluster): builds
running at the same time change the numbers a lot.

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ollama` says it cannot connect | the server is not running: section 3 |
| very slow; `ollama ps` shows a large CPU share | the model plus its cache is bigger than free VRAM: lower `num_ctx` (`/set parameter num_ctx 8192` inside `ollama run`, `"options":{"num_ctx":8192}` on the API, or a lower `OLLAMA_CONTEXT_LENGTH`), use a smaller tier, close GPU programs (`nvidia-smi` shows who holds VRAM) |
| an answer ignores the start of the file, or starts mid-thought | the prompt was longer than `num_ctx` and was cut: raise it |
| a long reasoning block before every answer | `--think=false` on `ollama run`, `"think": false` on `/api/chat` and `/api/generate`, `"reasoning_effort": "none"` on `/v1/chat/completions` (which ignores `think`); a model without a thinking switch ignores it |
| the agent loops or makes bad tool calls | the model is too small for an agent: use Tier B, or drop the agent and use section 6.4 |
| `ollama pull` stalls | the network path: `curl -sI https://registry.ollama.ai | head -1`; any HTTP status line (even a 404) means the path is up, a timeout or connection error means it is not. The pull resumes |
| the kind cluster or compose stack gets killed while a Tier B model loads | out of RAM: stop one of them first (`make kind-halt`), or use Tier A |
| the disk is filling up | weights live in `~/.ollama/models` (or `OLLAMA_MODELS`; a service install uses the `ollama` user's home): `df ~/.ollama` shows which filesystem |

## 11. Running it all without Claude

Section 6.2 shows one way to use a hosted-assistant program with a local model. This
section is the other way: **everything below needs no Claude program, no account at a
hosted service and no API key.** It ships in this repository, talks only to the Ollama on
your own PC, and works from a terminal, from the Studio window or from the Studio's
text screens.

### 11.1 The command: `scripts/local-ai.sh`

```bash
scripts/local-ai.sh up                       # start the loopback Ollama if it is down (detached)
scripts/local-ai.sh start                    # up + the queue worker, both detached
scripts/local-ai.sh status [--json]          # server, model loaded, queue, drafts, last heartbeat
scripts/local-ai.sh todo 6 --watch           # THE ONE LINE: queue the 6 smallest open issues, then watch them
scripts/local-ai.sh todo [N] [REPO...]       # queue only (default 6 issues of hugmesh-generator)
scripts/local-ai.sh draft [--queue] REPO N   # one draft job now, or queued for the worker
scripts/local-ai.sh queue                    # what is waiting and running
scripts/local-ai.sh worker [--foreground]    # the queue worker (detached by default; no tmux needed)
scripts/local-ai.sh stop [--server]          # stop the worker (and an Ollama this script started)
scripts/local-ai.sh chat                     # a prompt loop with the local model
scripts/local-ai.sh prompt "one question"    # one answer on stdout
scripts/local-ai.sh watch                    # the live dashboard (refreshes every 5 seconds)
```

`status` exits 1 when something needs fixing (Ollama missing, not answering, no model
pulled) and prints the problem, the fix and a link to this page.

**What a draft does.** `todo` asks `gh` (with your own login) for the open issues of
the repository, drops the ones labelled `manual`, `decision`, `roadmap` or `blocked`
and the ones with a long description, and queues the smallest as *draft jobs*. A draft
(`draft.sh`) then:

1. fetches the issue **with its comments** before anything else — the model step never
   calls `gh`;
2. starts the loopback Ollama if it is down;
3. makes a scratch worktree of the repository's `origin/main` under the state
   directory (the checkout it comes from is found in `$HUGMESH_REPOS_ROOT`, by default
   the folder that holds this repository; your own working tree is never touched);
4. runs `draft.py` under `env -i` with only `PATH`, `HOME`, `LANG`, `TERM` and a
   loopback `OLLAMA_HOST`;
5. in the default mode sends the issue and the three files a search of the worktree
   picked to the Ollama HTTP API and asks for a unified diff. The diff is checked with
   `git apply --check` and, if it fits, applied **in the scratch worktree only**.
   **Nothing the model wrote is ever run**, and nothing is pushed.

The result is `drafts/<repo>-<n>/STATUS`, whose first word is one of:

| Word | Meaning |
|---|---|
| `queued`, `running` | waiting for the worker, or being drafted now |
| `applied` | the diff fits the current `origin/main`; `draft.diff` is git's own rendering of it. **Read it before you trust it** — "applies" is not "correct" and nothing was tested |
| `does-not-apply` | the model's diff does not fit (it invented a line, usually); `draft.diff` shows what it wrote |
| `no-diff` | the model gave no diff, or said the issue is not one for it |
| `no-issue`, `no-ollama`, `no-model`, `no-checkout`, `error` | the step could not run; the rest of the line says why |

An issue that already has a `drafts/<repo>-<n>/STATUS` is skipped by `todo`; delete that
directory to have it drafted again.

**After a crash or a restart.** A worker that dies without cleaning up (a kill, a power
cut) leaves its job under `queue/running` and its draft saying `running`. Nothing is
working on it, so the Studio lists it as *stalled*. Run `todo` again, or just start the
worker: a new worker moves every such leftover job back to `queue/pending` (and the
draft back to `queued`) before it takes work, files the result of a draft that had in
fact finished instead of drafting it twice, and leaves alone a draft that is still
running on its own. `todo` itself queues a stranded draft again.

A small local model gets some issues right and many wrong: on the reference PC, two
real drafts against `qwen3:8b` ran to a clean `does-not-apply` (the model wrote a
plausible diff for a line that is not in the file). Treat a draft as a head start for a
person, never as a finished change.

**Agent modes.** `AGENT=plain` is the default and needs nothing but Ollama.
`AGENT=opencode scripts/local-ai.sh draft REPO N` runs `ollama launch opencode` inside
the scratch worktree instead, **only if the `opencode` command is installed** (it is
not on the reference PC, so this path is checked with a stand-in command in
`tests/scripts` and has not run with the real program). An agent does run commands, so
its environment is the same short allowlist plus settings that disable pushing; that
is hardening, not a sandbox (section 8). A third, explicit mode exists for anyone who
chooses to use the hosted assistant program against the local model as in section 6.2:
it is the single file `agent-explicit.sh`, it is reached only when you set `AGENT`
to that program's name yourself, and nothing else in these scripts can start it.

**The queue and the worker.** A job is one file in `queue/pending` holding one line,
`draft REPO ISSUE`. `worker.sh` takes them one at a time, moves the file through
`queue/running` to `queue/done/<name>.result` (exit code, seconds, the line), and
refuses any other line — the queue is not a way to run commands. The worker rewrites
`status.json` every 5 seconds. A worker that stopped answering for 30 seconds is
reported as *stalled* and a worker whose process is gone as *stopped*; neither ever
counts as work in progress. `stop` returns the job in hand to the queue, ends the draft
it was running (the whole process group, and the model step by its own pid) and marks
that draft `queued` again, and signals a process only when its command line really is
the worker (process numbers are reused). `stop --server` ends the Ollama that `up`
started, using the pid `up` recorded for the server process itself.

A draft is listed as *running* only while the `draft.sh` that owns it is alive (it
writes `draft.pid` beside `STATUS` and removes it on the way out). A `STATUS` that says
`running` with no such process behind it is listed as *stalled*, and `todo` queues it
again instead of skipping it as already drafted. The one-line status shown by the
terminal faces reads the worker's `status.json` only while that worker is alive and
beating; otherwise it says `no worker running` and does not claim the server is up or a
model is loaded, because nobody has asked.

**Where the state lives** — one directory, read by the Studio as well:
`$HUGMESH_LOCAL_AI_DIR`, else `$XDG_STATE_HOME/hugmesh/local-ai`, else
`~/.local/state/hugmesh/local-ai`:

```text
queue/{pending,running,done,logs}
drafts/<repo>-<n>/{issue.md,agent.log,draft.diff,STATUS}
scratch/            temporary worktrees, removed after each draft
status.json         the worker's heartbeat: pid, time, Ollama up, model loaded, job in hand
worker.pid  ollama.pid  worker.log  ollama-serve.log
drafts/<repo>-<n>/draft.pid    the draft.sh working on it, present only while it runs
```

Settings: `LOCAL_AI_MODEL` (default `qwen3:8b`), `OLLAMA_HOST` (**loopback only**: any
other value is refused before a connection is tried, and system proxy settings are
ignored), `HUGMESH_REPOS_ROOT`, `LOCAL_AI_ORG` (default `hugmesh`), `TODO_TIMEOUT`
(seconds a draft may take, default 1500), `LOCAL_AI_INTERVAL` (watch refresh).

What is deliberately **not** here: the prototype's limit-watcher (it reads another
program's session files) and the CI-sweep triage. The dashboard shows local work only.

**An older personal copy of these scripts** (a `local-runbook` folder kept outside the
repository, with its queue in `~/.cache/hugmesh-local-queue` and its drafts in
`~/.cache/hugmesh-local-ai`) uses a different layout. `scripts/local-ai.sh` does not
read it: a `watch` started from the repository script shows only work queued with the
repository script, and an old worker keeps running its own jobs unseen by it. Finish or
stop the old queue first, then queue again with `scripts/local-ai.sh todo`.

The helper files are `draft.sh` and `draft.py` (one draft), `worker.sh` (the queue
loop), `issues.py` (reads `gh` output: which issues to pick, how to print one) and
`agent-explicit.sh` (the single explicit-agent door above), all in `scripts/local-ai/`.

### 11.2 The same status in the Studio

* **Window.** Every Studio page has a **Local AI** bar along the bottom: one line of
  status (`Local AI: ready, qwen3:8b loaded, 2 queued, 1 running`), a chevron that
  expands it into a prompt line and an answer area (Enter sends; the answer streams
  in), a **Start local assistant** button (runs `scripts/local-ai.sh start` detached)
  and a **Current work** button that opens a window listing the queue, the drafts with
  their STATUS and a button to open each draft diff, the model loaded and the Studio's
  own running builds. The bar remembers whether you left it open or closed. Nothing
  starts until you press a button; the bar never opens a modal dialog.
* **Text screen.** `python -m hugmesh_studio.tui` shows the same status line as the
  bottom row of every screen (it reads the worker's `status.json` and makes no network
  call, so it costs nothing to redraw). **F2** opens the Local AI screen over the screen
  you are on: a live status, the work list, and a prompt line (anything you type that
  is not `start`, `r`, `clear` or `q` is sent to the local model); `q` returns to
  exactly where you were. The plain-prompt face (no urwid, or `NO_TUI=1`) prints the
  status line above every prompt and opens the same screen when you type `local-ai`
  (the urwid face accepts that too).
* **Command line.** `python -m hugmesh_studio --local-ai-status [--json]` and
  `python -m hugmesh_studio --local-ai-prompt "question"`; both exit non-zero with a
  plain sentence when Ollama is down.

### 11.3 How this is kept honest

`tests/scripts/test-local-ai-no-claude.sh` fails if any file under `scripts/local-ai*`
or any Studio local-AI module names the Claude program, an Anthropic service or an API
key outside `agent-explicit.sh`; it runs the real scripts end to end on a PATH where no
`claude` exists and again with a decoy `claude` first on PATH (the decoy must never
run); it proves the agent environment is the allowlist, that a non-loopback
`OLLAMA_HOST` is refused, and that a stalled or dead worker never reads as running.
The worker, `start`, `stop` and `up` are run on both paths (no claude, and the decoy),
so a Claude call that only they make is caught. The guard also stops a draft in the
middle of reading its issue and in the middle of the model step and requires that no
process is left, the job is back in `queue/pending` and the draft is `queued`; it
starts the server (a stub that records its environment: it must be bound to loopback)
and requires `stop --server` to end that process, and to leave alone an unrelated
process even when `ollama.pid` names it; it leaves a job under `queue/running` after a
crash and requires `todo` to queue it again and a new worker to finish it exactly once;
it asks for a draft a live worker is already running and requires that nothing is queued
twice; and it refuses `../x`, `..`, `.git/` and `..` paths. Each of those checks was
shown failing against a doctored copy (the list of copies, and which ones were not
closed, is in the pull request).

---

*Measured on 2026-10-07 with Ollama 0.21.2. Model data from the Ollama library pages
of the same day; re-check them before relying on a size, a context window or a tag.*
