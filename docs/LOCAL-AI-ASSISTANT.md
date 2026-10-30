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

The Studio can run (c) for you instead of using a system Ollama: pick **Ollama in
Docker** in the Assistant tab of its bottom panel. It runs `ollama/ollama:0.40.0` pinned
by digest as the container `hugmesh-studio-ollama`, on `127.0.0.1:11435` (so it never
takes a system Ollama's 11434), keeps models in the volume `hugmesh-studio-ollama-models`
and passes the GPU through only when Docker can provide one. Pull a model into it with
`docker exec hugmesh-studio-ollama ollama pull qwen3:8b`. Everything the assistant does
then talks to that port (`OLLAMA_HOST=127.0.0.1:11435`).

macOS and Windows use the installer from <https://ollama.com/download>.

In the native Windows build of the Studio (the MSI), **Start local assistant** does not
run `scripts/local-ai.sh`: it is a bash script, and `bash` there is the WSL launcher. It
opens the panel on its Assistant tab (also when you pressed it on the collapsed strip)
and says so there, the whole sentence, with two ways on: start Ollama for Windows
yourself (the panel asks it on `127.0.0.1:11434`), or pick **Ollama in Docker**, which
the button still starts and waits for (only the queue worker stays off). For the queue
worker too, run the Studio inside WSL2. Section 3 has the commands.

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

### On native Windows

The Studio's panel only talks to Ollama over HTTP, so in the Windows build (the MSI) any
Ollama that answers on loopback serves it. Pick one:

- **Ollama for Windows.** The installer from <https://ollama.com/download> starts it in
  the tray, already serving on `127.0.0.1:11434`; the panel's **System Ollama** is that
  address. To start it yourself with the settings above, quit the tray app first, then
  in PowerShell:

  ```powershell
  $env:OLLAMA_HOST = "127.0.0.1:11434"; $env:OLLAMA_CONTEXT_LENGTH = "32768"
  $env:OLLAMA_FLASH_ATTENTION = "1"; $env:OLLAMA_KV_CACHE_TYPE = "q8_0"
  ollama serve
  ```

  and check it from a second window with `curl.exe -s http://127.0.0.1:11434/api/tags`.
  Stop it with Ctrl+C there (or quit the tray app).
- **The Studio's own Ollama in Docker.** With Docker Desktop running, choose **Ollama in
  Docker** in the panel and press **Start local assistant**: the Studio starts its
  container (on `127.0.0.1:11435` unless you changed it) and waits until it answers.

Either way the panel answers questions, but `scripts/local-ai.sh` (the queue worker,
`todo`, `chat`) is a bash script and does not run in the Windows build. For it, run the
Studio inside WSL2: in a WSL2 distro (Ubuntu) with Docker Desktop's WSL integration on
for it, clone hugmesh-generator into `~` (not `/mnt/c`), start the Linux build of the
Studio from that checkout, and follow the Linux commands above inside the distro
(`bash scripts/local-ai.sh start` starts the distro's own Ollama, installed there as in
section 2, when none answers).

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

The Studio can do 6.1 and 6.2 for you: the agent launcher in the **Assistant** tab of the Studio panel (the strip along the bottom of every Studio window; it used to be the card *Work on this mesh with a local AI agent* on the local-mesh Bring-up page) makes this copy, writes the brief and a fresh project-context file (`HUGMESH-CONTEXT.md`: the org, the repositories, the Studio and where every local source is) beside it, and opens the terminal ([studio/README.md](../studio/README.md)).

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
  of what you paste or let it read. The Studio's assistant enforces this with a
  deny-list (section 12.6): a file on it is never opened, and every log line it quotes
  is redacted first.
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
pulled) and prints the problem, the fix and a link to this page. A server that is up
but drops the connection mid-reply, or answers something that is not HTTP, counts as
not answering: the same sentence, never a traceback, and the worker keeps beating.

**What the worker runs with.** `start` (the Studio panel's and the text screen's
**Start** run it too) gives the worker two variables: `HUGMESH_REPOS_ROOT`, the folder
that holds your checkouts, and `HUGMESH_AGENT_CONTEXT`, a project-context file
(`HUGMESH-CONTEXT.md` in the state directory: the org, the repositories, the Studio and
where every local source is). The Studio writes that file with the mesh's domains and
their code folders; started from a terminal, `start` writes it without them. `draft.sh`
writes it again right before each agent, so the checkouts it lists are the ones on disk
at that moment. The worker records what it runs with in `worker.env`; when a later
`start` would use another Ollama address (the Studio's system/Docker switch), another
context file or another checkouts folder, it restarts the worker (a job in hand goes
back to the queue) instead of keeping the old one. `todo` never restarts a worker.

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
`LOCAL_AI_CTX` sets the context size, in tokens, that the Studio dock and
`--local-ai-prompt` ask the model for: a whole number greater than 0. Anything else
(`16k`, `0`) is refused with one sentence naming the variable, and nothing is sent.

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

* **Window.** Every Studio page has the Studio panel along the bottom (it also holds
  the local-mesh actions, the running mesh, the run log and the image builds; see
  studio/README.md, "The Studio panel"): one line of
  status (`Local AI: ready, qwen3:8b loaded, 2 queued, 1 running`), a chevron that
  expands it into its tabs, the first of which is a prompt line and an answer area
  beside the assistant's options — which Ollama it uses (system or the Studio's Docker
  one), where your checkouts are, and the local AI agent launcher (Enter sends, and only sends: the
  wizard stays on the page you were on, so a question never presses Next or starts a
  build; Escape only cancels the current input or dialog: with text in the prompt it
  clears the prompt and nothing else, and from any other part of the bar (an empty
  prompt, the chevron, the answer area, the buttons) it does nothing and never closes
  the Studio window; the window's own Cancel button and its close button still close
  it, and Escape in the Current work window closes that window only; with the focus on
  the chevron, Enter shows or hides the prompt (a held key does it once); with the
  focus in the answer area — where you click to copy the model's words — Enter does
  nothing at all, rather than reaching the wizard; on the bar's buttons Enter presses
  that button; Clear while an answer is still arriving frees the prompt at once, so the
  next question is sent without waiting for the old one to stop; a
  server on the Ollama port that answers something other than Ollama's JSON is shown
  as "not answering", never as a crash; the answer streams in, and
  a connection that drops mid-answer is reported in words under the status line rather
  than passed off as a finished answer), a **Start local assistant** button (runs `scripts/local-ai.sh start` detached)
  and a **Current work** button that opens a window listing the queue, the drafts with
  their STATUS and a button to open each draft diff, the model loaded and the Studio's
  own running builds. The bar remembers whether you left it open or closed, and **Pop
  out** moves its tabs into a window of their own. Nothing starts until you press a
  button; the bar never opens a modal dialog.
* **Text screen.** `python -m hugmesh_studio.tui` shows the same status line as the
  bottom row of every screen (it reads the worker's `status.json` and makes no network
  call, so it costs nothing to redraw). **F2** opens the Local AI screen over the screen
  you are on: a live status, the work list, and a prompt line (anything you type that
  is not `start`, `r`, `clear`, `q` or `ollama docker|system` is sent to the local
  model; `ollama docker` and `ollama system` switch the Ollama in use, the same saved
  choice as the Studio panel's); `q` returns to
  exactly where you were. The plain-prompt face (no urwid, or `NO_TUI=1`) prints the
  status line above every prompt and opens the same screen when you type `local-ai`
  (the urwid face accepts that too). The key and the command work on every screen —
  the welcome, each wizard step, the previous-builds list (`q` there returns to the
  list, not to the welcome) — and on the Local AI screen itself they re-read the state
  and say so, never open a second screen, and never send the word `local-ai` to the
  model.
* **Command line.** `python -m hugmesh_studio --local-ai-status [--json]` and
  `python -m hugmesh_studio --local-ai-prompt "question"`; both exit non-zero with a
  plain sentence when Ollama is down.
* **One model.** The window, the text screen and the command line all ask the model
  `LOCAL_AI_MODEL` names (else `qwen3:8b` when it is pulled, else the first pulled
  model), never whatever happens to be loaded, so the same question goes to the same
  model whichever face you type it into.

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
twice; and it refuses `../x`, a bare `..` and `.git/` paths. Each of those checks was
shown failing against a doctored copy of the code it covers.

---

*Measured on 2026-10-07 with Ollama 0.21.2. Model data from the Ollama library pages
of the same day; re-check them before relying on a size, a context window or a tag.*

## 12. What the assistant knows and can do

Since 2026-10-29 the bottom panel of every Studio window, the text UI's Local AI
screen (F2 / `local-ai`) and `scripts/local-ai.sh prompt|chat` are one grounded
assistant. It is still the same local model on the same loopback Ollama; what changed
is what it is told before every question. Everything below is Qt-free code under
`studio/hugmesh_studio/core/assistant_*.py`.

### 12.1 The primer

One text, `core/agent_context.primer_text`, says what HugMesh is, what the Studio
does and where the local sources are. The coding-agent brief (`HUGMESH-CONTEXT.md`)
starts with the same text, so the two never describe the project differently. It is
under 600 tokens by test.

The brief names the checkouts folder and the generator checkout by their paths; the
assistant's primer never does. Asked to "wipe everything", qwen3:8b once answered with
a command that deleted exactly those two folders. So the primer describes them in words, and every
part of what the model is sent (primer, page facts, options, snippets, files, history)
goes through `assistant_prompt.scrub_paths` first: a path under the generator checkout
becomes relative to it (`docs/LOCAL-STACK.md`), one under the checkouts folder relative
to that, one under the home folder starts with `~`, any other `/home`, `/Users` or
`/root` path keeps only its last two parts (`…/w1/build.log`), and the folders themselves
become words ("the generator checkout", "the checkouts folder"). Documented system paths
such as `/etc/wireguard` are left alone.

### 12.2 Where you are

Every question carries the page the person is on (`core/assistant_context.Where`):
the face (window, terminal, command line), the page title and its step number for
the mode, the domain on screen and which of its tabs (Identity, Look, Services, Ways)
is open, the brand, one line per domain (services, sign-in, Tor, VPN and egress
choices), whether the local mesh is up and which verb runs, the running build or the
last failed one with its last error lines (redacted), the model and context size, and
the per-domain code folders. The window reads its page facts on the window thread
(attribute reads only) and collects the file-based facts on the worker, each
collector under a one-second budget; a slow one yields "(unavailable)", never a stall.

### 12.3 The docs it reads

`core/assistant_docs` splits an allowlist of this checkout's Markdown (the Studio
walkthrough and wizard flow, the studio README, the per-feature docs; `README.md` by
its user-facing headings only) on `##`/`###` headings and ranks the sections with
BM25 (stdlib, offline). The index is cached under `<state dir>/assistant/docs-index.json`
and rebuilt only when a file's mtime or size changes. Hand-offs, roadmaps, audits and
machine-written inventories are never indexed. An installed Studio without a `docs/`
folder still works; every answer then ends with
`Sources: none (no docs folder on this machine)`.

### 12.4 Tips along the bottom

`core/assistant_tips` holds one to three short tips for every page (the wizard's
slugs with the local-mesh steps expanded, plus the text UI's screens). The collapsed
bar shows `Tip: ...` with a `×` (Hide tips; a per-viewer setting, `tips_hidden` in
`local-ai-dock.json`, with a `Show tips` button in the panel's options column); the
expanded panel shows the same line above the answer area; the text UI prints it under
the status and `tips on|off` toggles it. A running model may replace the curated tip
with one sentence for the same page (60 tokens, 20 s, never while an answer is in
flight, once per page and domain in ten minutes); a sentence that names a command the
docs do not, or a word the brand screens never show, is dropped.

### 12.5 Answers and their Sources line

The model is asked with: `# HugMesh primer`, `# Rules` (answer from the snippets, the
page facts and the primer only; say "I do not know from the docs I have" otherwise;
never a command that is not in a snippet; never claim to have changed anything; never
invent a shell command, and point to the Studio's own buttons and the documented make
targets rather than spell a command that deletes anything; 12.11 has the details),
`# Where the person is`, `# Options on this page`, `# Snippets` and, on a page with
proposable settings, `# Change format`. Each part has a cap and the whole stays under
the context size minus 6000 tokens for the answer; when it cannot, the options, the
snippets, the page facts and the history are dropped in that order and the answer
says `(page facts left out: the question is long)`. After every answer the face
prints `Sources: STUDIO-WALKTHROUGH.md § Domain services; ...` — made by the code
from what was retrieved, never by the model — and, when the answer spells a command no
snippet contains, `Commands not found in the docs I read: ...`. A command is any `make`
target, `scripts/...`, `./x.sh`, `ollama`, `docker`/`docker-compose`/`podman` with any
subcommand, `kubectl`, `helm`, `kind`, `systemctl`/`rc-service`, `sudo`, `rm`, `dd`,
`mkfs` or `git` verb in the text, plus EVERY line of a fenced shell block (untagged,
`bash`, `sh`, `console`, ...; split at `&&`, `||`, `;` and `|`) and every inline code
span that starts with a program (`assistant_docs.code_commands`). `change`, `diff`,
`json` and other data fences are not commands. With no model running the face shows
`[Local AI is not running. Press Start local assistant.]` and the best snippet.

An answer that spells a command which deletes data gets a warning above it in every
face (12.11).

`scripts/local-ai.sh prompt` and `chat` export `LOCAL_AI_GROUNDED=1`, which makes a
bare `send_prompt` (and so `hugmesh-studio --local-ai-prompt`) grounded the same way;
unset, the command line sends exactly what it sent before. `chat` understands
`/where <page>`. Two model-free commands: `scripts/local-ai.sh docs [--page=SLUG]
<question>` prints the snippets and the Sources line; `scripts/local-ai.sh catalogue
[domain|mesh|image]` prints every option (12.7).

### 12.6 Privacy: the deny-list and redaction

Nothing leaves the machine. Files that hold secrets are never opened by the
assistant — not by the docs index, not by a code edit, not by a state collector
(`core/assistant_context.DENY_PATHS`):

- `<generator>/keys-out/**` — generated node keys
- `<generator>/keys-*/` — generated node keys (any keys-* folder)
- `<generator>/.e2e-credentials` — e2e account credentials
- `<generator>/tests/stack/.env` — the local stack's environment
- `~/.hugmesh/mesh-node/.env` — the mesh node's environment
- `~/.hugmesh/keyzip/**` — admin key-zips
- `~/.config/hugmesh-studio/local-login/roles.json` — local sign-in roles
- `<state>/**/secrets.json` — a build's secrets
- `<workdir>/secrets.json` — a build's secrets
- `<workdir>/report.json` — a build's report (carries seeded credentials)
- `<workdir>/.cli.json` — a build's argv (carries secrets)
- `**/vault/token` — a Vault token
- `**/vault/unseal-key` — a Vault unseal key
- `*.kubeconfig` — a cluster credential
- `$KUBECONFIG` — the cluster credential the shell names
- `**/*.pem` — key or certificate material
- `**/*.key` — key material
- `**/id_*` — SSH keys
- `**/.env` — an environment file
- `~/.local/share/hugmesh-local-only/**` — the operator's local-only folder
- `<secret_files>/**` — a secret-files staging folder
- `<egress_vpn_conf>` — the egress VPN provider file

A question that names one gets "That file holds secrets; I do not read it." Every
value whose key looks secret (password, token, auth_key, api_key, private, unseal,
kubeconfig, luks, client_secret, cookie, session_id) is rendered as
`(set, never shown)`, and every free-text line (error tails, run logs, file texts shown
for a code edit) goes through `redact`, which blanks:

- any key that CONTAINS password, passwd, passphrase, pwd, secret, token, api key, auth
  key, private key, access key, client key, preshared key or credential, however it is
  prefixed, quoted or JSON-escaped: `POSTGRES_PASSWORD=...`, `CASDOOR_CLIENT_SECRET=...`,
  `export GH_TOKEN=...`, `aws_secret_access_key = ...`, `{"admin_password": "..."}`,
  `x-api-key: ...`, WireGuard's `PrivateKey = ...`, a kubeconfig's `client-key-data:`
  (a plural "tokens", such as a context size, is left alone), and any key with `pass`
  or `unseal` as a word of its own: `LUKS_PASS=...`, `local_pass: ...`,
  `VAULT_UNSEAL_KEY=...` (not `passed`, `bypass`, `passthrough` or `unsealed`). A
  QUOTED value is blanked up to its closing quote, spaces and all
  (`{"admin_password": "horse battery staple"}` loses all three words; a backslash
  escapes the next character; an unclosed quote, and a value whose last character
  before the line end is a backslash, run to the end of the line when no other quote
  of that kind follows on it (see the known gaps); bash's `$'..'` counts as quoted).
  JSON inside a string, as a log or `kubectl` prints it (`msg="{\"password\": \"a b\"}"`,
  a logfmt `msg="token=\"..\""`, at any depth), is blanked to its own escaped closing
  quote, also when the value ENDS in a backslash (at depth one that close is five
  backslashes and the quote, and it no longer runs on into the next key). An unquoted
  value is one word: `secret = two words` keeps its second word; inside that word a
  quote and a backslash-escaped space (`printf %q`'s `horse\ battery`) are part of it;
- a YAML block scalar under a secret key (`secret: |` or `>-`): every indented line
  of it;
- command-line flags such as `--password X`, `--admin-password=X`, `--client-secret X`,
  `--luks-pass X` (a quoted value whole, as above), and a `-pX` glued to its value on
  a line that names `mysql`, `mariadb`, `mysqldump` or `mysqladmin`: because the rules
  run until nothing changes, EVERY glued `-pX` after that word on the line is blanked,
  not only the client's own (`mysql -u root -pX && mkdir -pv /x && gcc -pthread a.c`
  becomes `-p[redacted]` three times). A line without one of those words keeps its
  `-pthread` and `mkdir -pv`, and a `-p` with a space after it (`mysql -p`,
  `docker run -p 8080:80`) is never touched;
- SQL a database's init log echoes: `PASSWORD '...'` and `IDENTIFIED BY '...'` (SQL's
  doubled quote `''` and the other quote kind stay inside the value);
- the password in ANY `scheme://user:password@host` URL, and secret query parameters
  (`?access_token=...`, `&password=...`);
- `Authorization: Bearer|Basic ...`, `Cookie:` and `Set-Cookie:` values, Vault's
  `Unseal Key N:` (and its `Unseal Key (will be hidden):` prompt) and
  `Initial Root Token:` lines, and the key in `vault operator unseal KEY`;
- private-key blocks, a bare base64 key-body line, and every base64-only line that runs
  up to an END line however short (a key printed line by line, or a tail that cut its
  BEGIN line off): a build's error tail is redacted as ONE text per
  image before it is cut, so a block that spans lines is caught whole;
- Tailscale and headscale keys, GitHub, AWS, Vault, Slack and `sk-` tokens, JWTs, the
  local-only folder's path, the e2e `user / secret` shape and the retired `e2e-pass`
  literal.

`redact` runs these rules again until a pass changes nothing (at most six passes), so
the file text a code edit shows and the options block, which are redacted once, get
the same result as the Where rows, which are redacted on every hop.

`studio/tests/test_assistant_privacy.py` plants a canary in every denied path and
asserts none reaches any rendered text, runs every shape above through `redact` (and
ordinary log lines that must stay as they are), and plants the shapes in a failed
build's tail and the mesh log and asserts none reaches the system text the model gets.
A seeded fuzz (24,000 cases) puts the canary inside a value in every quote and
backslash spelling (escapes, unclosed quotes, a trailing backslash, `$'..'`, JSON
escaped up to three deep, Python reprs, a quote inside a bare word) after every secret
key and flag spelling, and asserts it never comes out. A second one (8,000 cases)
puts two to four SECRET keys in one object, side by side or with a plain key between,
the earlier values often ending in one to three backslashes, as JSON up to three deep,
a Python repr or logfmt inside an escaped string, with the canary in every secret
value.

Known gaps (not blanked, or only in part):

- an unquoted multi-word value (`secret = horse battery`, a YAML plain scalar with
  spaces) keeps every word after the first;
- a bare value that starts with `-` after a flag (`--password -x`) is read as the
  next flag; a value glued to an empty quote (`password=""x`) is not blanked;
- `vault operator unseal` with a flag that takes a separate argument
  (`-address URL KEY`) blanks the URL, not the key;
- `cryptsetup --key-file=PATH` names a key FILE; the path is not a secret and is left
  as it is (the file itself is never opened);
- an unclosed quote followed later on its line by another quote of the same kind: the
  two pair up, so `password: "abc ... token: "X"` blanks `abc ...` and sends `X`;
- shapes with no secret KEY next to the value: MySQL's `SET PASSWORD FOR u = '..'`,
  Kubernetes env pairs (`- name: DB_PASSWORD` then `value: X`, and the same in JSON),
  argv lists printed as a Python or JSON list (`['--luks-pass', 'X']`), `curl -u
  user:X`, `sshpass -p X`, `docker login -p X`, `htpasswd -b FILE USER X`, `chpasswd`
  input, `vault login TOKEN`, and XML (`<password>X</password>`);
- a key wrapped in terminal colour codes, and a value in curly quotes (`“..”`), which
  is read as a bare word;
- false positives, which fail safe: a bare `pass` or `unseal` as a key now blanks
  ordinary lines such as `PASS: tests/x.sh`, `Tests pass: 12`, `unseal: done` and the
  word after `--pass-through`; and on a line that names `mysql`, `mariadb`,
  `mysqldump` or `mysqladmin`, every later glued `-pX` (`-pthread`, `mkdir -pv`) is
  blanked as if it were the client's password.

### 12.7 The option catalogue (from the code)

`core/assistant_catalogue` builds, at import, one entry per setting the Studio
offers — from `config.Domain`, `LocalMeshBootstrapConfig` and `ImageConfig` and the
`*_CHOICES` tables, the theme presets, modes, styles, decorations and background
effects, the font presets, the reach choices — with its valid values, default, the
page it is edited on (`assistant_catalogue_pages.py`, a generated module so it ships
wherever the package does, written by `scripts/local-ai/catalogue-pages.py` and checked
by a test) and whether the
assistant may propose a change to it. The slice for the page on screen goes into every
prompt as `# Options on this page`. `scripts/local-ai.sh catalogue domain` lists the
domain scope: `services`, `signin` (and `provider`, `issuer`, `client_id`, `jwks`),
`tor`, `tailnet`, `egress`, `look.preset`, `look.mode`, `look.primary`,
`look.secondary`, `look.font`, `look.style`, `look.decor`, `look.bg_effect`,
`github_org` and the rest.

### 12.8 Small changes to a domain, on a press

On a domain's page the model may answer a request such as "turn off the forum for
this domain", "use a darker purple" or "switch this domain to its own Casdoor" with
one sentence and one fenced block:

```
I can turn the forum off for shop.example.
```change
{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}
```
```

The example the model itself is shown is made up on purpose:
`{"domain": "example.invalid", "field": "example.setting", "to": true}`, under
"Example (made up; never copy it):" (that wording is measured: a longer "made up and
always refused" note broke every code-edit diff qwen3:8b wrote). The old one named a real field of the domain on screen (shop.example,
`tor`, `true`), and qwen3:8b copied it word for word into a "turn off the forum" answer:
its card offered an onion front door nobody asked for. `validate` now refuses the
example block, and any block with its `.invalid` domain or its `example.setting` field,
with "That block is the format's made-up example, not a change for this page; nothing
was proposed." A services list that switches on or off a service the request does not
name is refused too ("I don't want phpBB" once came back as `[tuwunel, games]`): "Not
proposed: that list would also switch on games, which you did not ask for. Name each
service to switch on or off." A request that names no service is judged by the card.

(For `services` the value is the whole new list, built from the `current:` list the
model is shown; the card always says `from -> to` before anything is applied.)

`core/assistant_actions.parse_proposal` reads the block; `validate` checks the field
against the catalogue and the page's own validators (`brand_look.check_value`,
`domain_reach`, `config.signin_problems`), reads the current value from the page —
never from the model — and refuses a no-op ("Already set to ..."), any domain but the
one on screen ("I only change the domain on screen (shop.example). To change
blog.example, open its tabs (Next domain) and ask there." — even when the question
names the other domain: the page's readers and writers act on the domain on screen),
or a field this page does not edit ("I can only change these on this page: ... Valid
values for <key>: ..."). Switching sign-in back to the mesh's or to an own Casdoor is
handed to the page's own writer, which drops the external provider's values; an
external provider is checked with exactly the values that writer gets, and without a
sign-in address and client id the card says to type them on the Identity tab first. The
window shows a card `Proposed change — <domain>` with `<label>: <from> -> <to>`,
Apply and Cancel; the text UI prints the same block and takes `apply`, `cancel` and
later `undo`. Apply re-reads the page first (a value that moved since the proposal is
refused: "changed to <x> since I proposed this; ask again"; a card left up after Next
domain is refused: "This change is for shop.example, but the page now shows
blog.example. Go back to shop.example to apply it") and then writes through
the page's own functions — the `BrandView` setters, the look model, the Ways tab's
Tor signal, the Services tab's check boxes — so the visible widgets show the new value
exactly as after a click; Undo puts the page back EXACTLY the same way — the look's
whole record (a preset fills the preset and both colours), the egress mode with its
provider file, the sign-in choice with its provider values — one level per domain, and
only on that domain's tabs. The keys the assistant may propose (`FIELD_ROUTES`): `services`, `tor`,
`signin`, `provider`, `issuer`, `client_id`, `jwks`, `tailnet`, `egress` (`vpn` is
proposed as a mode only — "pick the VPN file on the page"), `look.preset`,
`look.mode`, `look.primary`, `look.secondary`, `look.font`, `look.style`,
`look.decor`, `look.bg_effect`; on the local-mesh steps `env`, `with_tor`, `services`
(the mesh-level list), `web_locales` and `superadmin_username`. Passwords, the auth
key, the egress provider file, paths and every image-route field are refused.

The Options block the model reads carries `current: ...` for each key, read through
the same readers Apply uses (`assistant_actions.current_values`), so "turn the forum
off" starts from the services actually ticked and a colour request knows whether the
main colour is set or inherited. When a question asks to set a password, a key or a
token and the answer proposes nothing, the footer adds, whatever the model said: "I
never set passwords, keys or tokens: you type those on the page itself, and they never
reach me. I can only change these on this page: ...".

### 12.9 Small code edits, on a press

For a domain that has a code folder (the per-domain workspaces the Studio made under
`<state>/domain-code/<mesh>/<app>-<domain>/`), a request that names a file ("change
the footer text in index.html") sends the file's current text and gets back one
sentence and one fenced `diff` block. `core/assistant_code_edits.parse_diff` is a
small unified-diff parser: every context line must match the file exactly, a hunk
header only needs a readable start line (`@@ -3 ...`), and a diff that would change
nothing is refused rather than "applied". The window
shows `Proposed edit — <app>-<domain>` with View diff (the Current work window's
viewer), Apply and Cancel, then Revert. Apply first checks every hunk AGAIN against
the file as it is at that moment — a file edited after the card appeared is refused
("changed since I proposed this edit ... nothing was changed. Ask again for a fresh
diff."), so the diff applied is always the diff on the card — then writes byte copies
of the files to `<state>/assistant-edits/<id>/before/` with a manifest (sha256 before
and after), then the files; Revert restores the copies after checking the file still
has the applied sha. Limits: text files only, at most 3 files and 120 changed lines, 64 KiB per file,
never a secret-shaped name, never through a symlink or outside the folder, never the
build source root. Nothing is committed, pushed or run. Anything bigger ("refactor",
"add a feature", more files) is handed to the coding-agent launcher: "That is more
than a small edit (...). Open a coding session with the Launch button — your request
is in the brief."

### 12.10 Measuring it against a real model: `scripts/local-ai/eval.py`

`scripts/local-ai/eval.py` asks the local model the questions in
`scripts/local-ai/eval-items.json`, one at a time, against a THROWAWAY state (a temp
`HOME` and Studio state folder with a planted brand, two domains, a failed build whose
error tail carries canaries, and a code folder), and scores what the faces would show:
the answer with its Sources line, or for a change request the validated card (or its
refusal). It never starts, stops or pulls a model; Ollama must already be serving on
the loopback address.

```
LOCAL_AI_MODEL=qwen3:8b python3 -I scripts/local-ai/eval.py scripts/local-ai/eval-items.json
```

It prints a table and exits 1 below its thresholds (80 % of the must-mention items,
every must-not item, every change block parsing and validating, no delete command shown
without the warning, no wrong change card). The scores are advisory: a small model's
answers vary from run to run.

Two counts must be 0 whatever the aggregate says. **Unwarned delete commands**: an
answer that looks like it deletes data by eval.py's OWN word list (`DANGER_WORDS`, not
the detector it checks) without `DESTRUCTIVE_WARNING` in what is shown; answers that
carry a delete command are counted as well ("warned"). **Wrong change cards**: a
`Proposed change` card for an item with `card_must_be` (or a JSON must-mention) whose
block is anything else; no card or a refusal is not wrong. `model_mention_any` asks for
one of several phrases in the model's own words; the Studio's warning and Sources lines
never count as the model's. The items that ask how to start over want the documented
button or make target (12.11) and forbid any `/home/` path; the forum-off items accept
only the phpbb-off block.

### 12.11 Delete commands get a warning, always

(Not indexed for the assistant: `EXCLUDED_IN_FILE` in `core/assistant_docs.py` leaves
this section out, so the model is never shown the commands listed here.)

When an answer spells a command that deletes
data (`rm -r`/`rm -f` or `rm` of a path, any `docker`/`podman` prune, `docker rm`/`rmi`,
`docker volume rm`, compose `down -v`/`--volumes`/`--rmi`, `dd of=`, `mkfs`, `wipefs`,
`git clean`, `git reset --hard`, `git push --force`, `kubectl delete`, `helm uninstall`,
`kind delete`, `find -delete`, `DROP DATABASE`; `assistant_docs.destructive_commands`),
every face shows `assistant_prompt.DESTRUCTIVE_WARNING` ABOVE the answer, whether or not
a doc spells the same command. The warning says not to run them and names the documented
ways instead: the Studio's **Stop & clean Docker…** button (it asks first and lists what
it removes; STUDIO-WALKTHROUGH.md), `make stack-down` (LOCAL-STACK.md) and Stop mesh
(`make stack-halt`, keeps the data). The window inserts it in bold warning colour where
the answer starts, the moment the command streams in, keeps the view on it while the
rest of the answer arrives, and repeats it in the note line; the text UI prints it above
the answer and above the conversation (which shows only its last 12 lines); the command
line prints the answer a line (a fenced block) at a time and puts the warning before the
first line that deletes anything. The footer repeats it as its first line.

A wipe, reset, clean or start-fresh question about the mesh or its data
(`assistant_docs.is_reset_question`; "reset the root password", "get rid of the forum"
and "clean up old build sessions" are not) is
searched with the Stop & clean paragraph's own words added, and always gets that
paragraph (STUDIO-WALKTHROUGH.md, Local Docker mesh traps) as its first snippet and
LOCAL-STACK.md's `make stack-down` lines among the others (`RESET_ANCHORS`; a doc edit
that drops either phrase fails `tests/test_assistant_docs.py`).
