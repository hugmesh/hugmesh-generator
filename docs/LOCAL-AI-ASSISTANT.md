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
[10 Troubleshooting](#10-troubleshooting)

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
doing (the figures marked * were taken while builds were running; † is a hand reading of `ollama ps` at 16k context, not a benchmark row).

### Tier A: fits the GPU (best for an agent that must stay responsive)

| Model | Pull | Weights | Max context | Good for | Loaded size / on GPU | Generation |
|---|---|---|---|---|---|---|
| `qwen3:8b` | `ollama pull qwen3:8b` | 5.2 GB | 40K | general work and **tool use**; this is the model the Claude Code session in section 6 was verified on; has a thinking mode | 6.6 GB / 82%† | — |
| `qwen2.5-coder:7b` | `ollama pull qwen2.5-coder:7b` | 4.7 GB | 32K | code edits, tests, conversions in a chat; has `tools` but no thinking mode, and is a weaker agent than `qwen3:8b` | 6.1 GB / 87%* | 19 to 20 tok/s* |
| `ornith:9b` | `ollama pull ornith:9b` | 5.6 GB | 256K | listed as a coding-agent model with tools and thinking | — | — |
| `lfm2.5:8b` | `ollama pull lfm2.5:8b` | 5.2 GB | 125K | listed for fast tool calling on consumer hardware | — | — |
| `qwen2.5-coder:3b` / `:1.5b` | `ollama pull qwen2.5-coder:3b` | 1.9 GB / 0.99 GB | 32K | editor autocomplete beside a bigger model | — | — |

### Tier B: mixture-of-experts, runs partly on the CPU (needs about 14 to 20 GiB free RAM)

| Model | Pull | Weights | Max context | Good for | Loaded size / on GPU | Generation |
|---|---|---|---|---|---|---|
| `gpt-oss:20b` | `ollama pull gpt-oss:20b` | 14 GB | 128K | reasoning and tool calling; the smallest of this tier | — | — |
| `qwen3-coder:30b` | `ollama pull qwen3-coder:30b` | 19 GB | 256K | 30B total, about 3.3B active: agentic coding | — | — |
| `north-mini-code-1.0` | `ollama pull north-mini-code-1.0` | 19 GB | 488K | 30B MoE, 3B active, "built for agentic software engineering" | — | — |
| `laguna-xs-2.1` | `ollama pull laguna-xs-2.1` | 20 GB | 256K | 33B MoE, 3B active, "agentic coding and long-horizon work on a local machine" | — | — |
| `ornith:35b` | `ollama pull ornith:35b` | 21 GB | 256K | the larger ornith | — | — |

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

---

*Measured on 2026-10-07 with Ollama 0.21.2. Model data from the Ollama library pages
of the same day; re-check them before relying on a size, a context window or a tag.*
