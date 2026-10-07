# local-ai: models that already know this mesh

Four Ollama models, built from one short, checked description of the mesh, plus three role
files for a coding-agent harness. Commands and the full walk-through are in
[`docs/LOCAL-AI-ASSISTANT.md`](../docs/LOCAL-AI-ASSISTANT.md) section 11; this page says what is
in the folder and what was measured.

```bash
scripts/local-ai-agents.sh create     # build hugmesh-agent, hugmesh-coder, hugmesh-reviewer, hugmesh-triage
scripts/local-ai-agents.sh test       # prepared vs plain base on the questions below
```

## What is here

| Path | What it is |
|---|---|
| `primer.md` | the vetted description of the mesh: repositories, the lanes and their commands, test commands, house rules, documented traps. About 1,470 tokens. Ends with a comment (everything from the line `<!-- SOURCES` on) that names the repository file backing each fact; it is removed before use. |
| `modelfiles/hugmesh-*.Modelfile` | the base model, the parameters and a role paragraph for each model. `scripts/local-ai-agents.sh create` puts the primer in front of the role paragraph, so the primer exists once. |
| `agents/mesh-*.md` | three role files for a coding-agent harness (`mesh-builder`, `mesh-tester`, `mesh-reviewer`): a front matter block (`name`, `description`, `tools`) and a short body. The tester and the reviewer have no editing tool. |
| `eval/questions.tsv` | the 19 mesh questions and the words a correct answer must contain. |

| Model | Base | num_ctx | temperature | Role |
|---|---|---|---|---|
| `hugmesh-agent` | `qwen3:8b` | 32768 | 0.2 | tool-driven work, small steps, says what it did not verify |
| `hugmesh-coder` | `qwen2.5-coder:7b` | 16384 | 0.2 | outputs only the changed code, one file at a time |
| `hugmesh-reviewer` | `qwen3:8b` | 16384 | 0.1 | `file:line - problem`, no praise |
| `hugmesh-triage` | `qwen3:8b` | 16384 | 0.1 | cause, class (ENVIRONMENT, CODE, UNSURE), one next command |

## The guard keeps the primer true

`bash tests/scripts/test-local-ai-primer.sh` (offline, no Ollama) fails when the primer names a
make target that is not in the Makefile, a variable or repository nothing in the tree mentions, a
path that does not exist, or when it is over 10,240 bytes or about 2,500 tokens, holds a
secret-shaped string, a home path, an account name or an attribution line, when a Modelfile does
not parse, when `create --dry-run` prints anything other than the role file plus the primer plus
the role text, or when a role file lacks the front matter. It also drives the script's `create`,
`list` and `remove` against a stand-in `ollama` to prove it never pulls, never overwrites and never
deletes a model it did not make.

To add a fact: write it in `primer.md`, name the file that backs it in the sources comment, run
the guard. To re-count tokens after a large edit:
`scripts/local-ai-agents.sh test --tokens` and update `MEASURED_TOKENS` and `MEASURED_BYTES` at the
top of the guard.

## Measured: prepared against the plain base

Measured 2026-10-07 with Ollama 0.40.0 on the reference PC (RTX 4060, 8 GB), one request at a time:
`scripts/local-ai-agents.sh test`. Same 19 questions, same options for every column
(`temperature` 0, `seed` 0, `num_ctx` 16384, `num_predict` 200, thinking off), no system message
in the first two columns. An answer passes when it contains the words in `eval/questions.tsv`
(a case-insensitive substring check; backticks and asterisks are removed first), so the score is
mechanical and nobody judged an answer.

| question | plain `qwen3:8b` | `hugmesh-agent` | `hugmesh-agent`, caller sends its own system message |
|---|---|---|---|
| kind-one-image | fail | pass | fail |
| kind-order | fail | pass | fail |
| stack-src-vanish | fail | pass | fail |
| mtu-env | fail | pass | fail |
| studio-test-cmd | fail | pass | fail |
| scratch-clone | fail | **fail** | fail |
| compose-signin | fail | pass | fail |
| halt-vs-down | fail | pass | fail |
| compose-one-service | fail | pass | fail |
| maven-eleven-min | fail | pass | fail |
| argocd-token | fail | pass | fail |
| docs-rule | fail | pass | fail |
| no-modals | fail | pass | fail |
| guard-proof | fail | pass | fail |
| kind-pause | fail | pass | fail |
| mock-lane | fail | pass | fail |
| repo-source | fail | pass | fail |
| hub-repo | fail | pass | fail |
| pullbackoff | fail | pass | fail |
| **total** | **0/19** | **18/19** | **0/19** |

Read this honestly:

* The prepared model answered 18 of 19 and the plain base none, because every question asks for a
  name that exists only in this repository (a make target, a variable, a script). The base cannot
  know those; the score shows the primer reaches the model, not that the model is smarter.
* One miss, `scratch-clone`: asked where an agent should work and what that copy must not have, it
  said "a scratch clone" and then talked about `.stack-src` instead of saying "no remote".
* The score moves by a question or two with small changes. An earlier run, on the primer as it was
  before a few wording edits made the guard pass, scored 17/19 (it also missed `mock-lane`: it answered "no"
  correctly but did not give the reason, the word "mock"). The questions were not changed after
  seeing either run.
* **The last column is the finding that matters.** When the caller sends a system message of its
  own (any coding-agent harness does), Ollama uses that instead of the Modelfile's `SYSTEM` text,
  and the prepared model scores the same as the base: 0 of 19. `hugmesh-agent` helps in
  `ollama run`, in chat tools that send no system message, and in plain API calls. For a harness,
  use `scripts/local-ai-agents.sh print primer > CLAUDE.md` in the scratch clone (below).

### A harness session, once

`ollama launch claude --model hugmesh-agent -- -p "..."` in a no-remote scratch folder holding
`CLAUDE.md` (the output of `print primer`) and `.claude/agents/` (the three role files) answered
the make command for one image on kind and the variable for the npm stall correctly from the
primer, in 2 minutes 20 seconds on a loaded machine. The session's own start-up report listed
`mesh-builder`, `mesh-reviewer` and `mesh-tester` among its agents, so the harness reads the role
files as written. That was one session on one model: it shows the path works, not how well an
agent does real edits with it.

### The other three models, one request each

Not scored; a check that each role keeps its output format. `hugmesh-triage` on an npm
`ETIMEDOUT` log answered `Cause`, `Class: ENVIRONMENT` and `Next: export BUILD_NETWORK=host &&
make kind-images`. `hugmesh-reviewer` on a two-line diff flagged `git push --force` as
`file:line - problem` but missed the edit under `.stack-src` and gave the wrong line.
`hugmesh-coder` returned only the changed file.

### Not exercised

Any model other than `qwen3:8b` and `qwen2.5-coder:7b` (so `BASE_AGENT` with a bigger base was
tested only against a stand-in `ollama`, not a real pull); an agent doing real, multi-file work
with `hugmesh-agent`; Windows and macOS.
