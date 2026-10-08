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
deletes a model it did not make. It also drives the scorer behind `test` against a stub of the
Ollama API (fixed answers, a logged request list) and checks the table, totals, verdict and which
model each column asked, with four planted defects that it must catch.

What it checks about a fact has three levels. Every name (make target, variable, repository, path)
is checked to exist. Every sentence of the primer except three instructions to the model is then
listed in full in `CLAIMS` in the guard (65 sentences, 94 file patterns), each with the repository
file text that backs it: for example `make stack-halt` keeps the data and `make stack-down` deletes
the volumes, the ports 8088 and 8488, the kind order, the 1420 tunnel MTU, which repositories are
Java and which Angular, the test commands, the no-push and no-sudo rules, the warning about node
images, and the scratch clone with no remote. The guard fails when a sentence is not word for word in
the primer, so reversing a rule, moving a repository from the Java list to the Angular list or
changing any number turns it red until a person reads the new sentence against the file; and it fails
when a primer sentence is neither listed nor on the short `UNANCHORED` list, so a new fact cannot be
added unbacked. What this is and is not: a pattern proves the repository file still says what the
primer relied on when a person last read both, not that every clause of the sentence is a correct
reading of that file (a clause no pattern names is protected only by the word-for-word match, which
is a tripwire for a person, not a proof). Each question's expected words must also be in the primer
text itself, not merely somewhere in the repository.

To add a fact: write it in `primer.md`, name the file that backs it in the sources comment, add the
sentence to `CLAIMS` in the guard with the repository file text that backs it (the guard fails on a
primer sentence that is not listed, and on a listed sentence that was reworded), run the guard. To re-count tokens after a large edit:
`scripts/local-ai-agents.sh test --tokens` and update `MEASURED_TOKENS` and `MEASURED_BYTES` at the
top of the guard.

## Measured: prepared against the plain base

Measured 2026-10-07 with Ollama 0.40.0 on the reference PC (RTX 4060, 8 GB), one request at a time:
`scripts/local-ai-agents.sh test`. Same 19 questions, same options for every column
(`temperature` 0, `seed` 0, `num_ctx` 16384, `num_predict` 200, thinking off), no system message
in the first two columns. An answer passes when it contains the words in `eval/questions.tsv`
(a case-insensitive substring check; backticks and asterisks are removed first), so the score is
mechanical and nobody judged an answer.

**The score is a range, not one number.** The same command on the same models was run five times
(the first run, a reviewer's rerun and three later reruns): prepared `hugmesh-agent` scored 18/19
once and 17/19 four times; the plain base scored 0/19 four times and 1/19 once. Four of the five
(17/19 against 0/19 three times, and the reviewer's 17/19 against 1/19) were on the primer as it is
now; the first run (18/19) was made while the primer was still being edited, so treat it as a
nearby sample, not as the same input. Temperature 0 and a fixed seed do not make the GPU output
identical from run to run. The table below is the latest run, on the final primer (17/19 against
0/19); as recorded at the time, the 18/19 run differed from it only in `mock-lane`.

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
| mock-lane | fail | **fail** | fail |
| repo-source | fail | pass | fail |
| hub-repo | fail | pass | fail |
| pullbackoff | fail | pass | fail |
| **total** | **0/19** | **17/19** | **0/19** |

Read this honestly:

* The prepared model answered 17 or 18 of 19 and the plain base none or one, because every question
  asks for a name that exists only in this repository (a make target, a variable, a script). The base
  cannot know those; the score shows the primer reaches the model, not that the model is smarter.
* **The scorer can be fooled by an incidental word.** It only looks for the expected words in the
  answer text. `mock-lane` expects the word "mock": in a reviewer's rerun (not reproduced in the three runs
  made afterwards) the plain base rambled for 200 tokens, happened to write "mock" and scored a pass, while the prepared model answered "No, ... does not
  prove" correctly, never said "mock" and scored a fail. A pass is therefore not proof the answer was
  right, and a fail is not proof it was wrong. Read `scripts/local-ai-agents.sh test --out FILE` and
  the answers in it before quoting a number.
* Two misses on the latest run. `scratch-clone`: asked where an agent should work and what that copy
  must not have, it said "a scratch clone" and then talked about `.stack-src` instead of saying "no
  remote". `mock-lane`: the correct "no", without the reason.
* An earlier run, on the primer as it was before a few wording edits made the guard pass, also
  scored 17/19. The questions were not changed after seeing any run.
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
