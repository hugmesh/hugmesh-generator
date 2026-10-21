#!/usr/bin/env bash
# ============================================================================
# local-ai-bench.sh — measure local coding models on THIS machine (Ollama).
# ============================================================================
#
# docs/LOCAL-AI-ASSISTANT.md ranks models by what they claim and what they weigh.
# This script replaces the claim with a measurement: for each model it records how
# much of the loaded model sits on the GPU, how fast it generates, and how fast it
# reads a long prompt (what a code assistant does all day).
#
#   scripts/local-ai-bench.sh                     # the shortlist from the doc
#   scripts/local-ai-bench.sh qwen3:8b gpt-oss:20b
#   CTX=32768 scripts/local-ai-bench.sh qwen3:8b  # a different num_ctx
#   PRUNE=0 scripts/local-ai-bench.sh ...         # keep what this run pulled
#
# Per model (one row):
#   disk_gb       size of the loaded model INCLUDING its KV cache at CTX (from /api/ps)
#   gpu_pct       share of that size resident in VRAM; the rest runs on the CPU
#   load_s        time to load the model
#   gen_tok_s     generation speed on a short coding prompt
#   prompt_tok_s  prompt-processing speed on a long prompt (about 10k tokens with the default file)
#   long_total_s  wall time of that long request (the prompt in, 120 tokens out)
#   prompt_tokens  how many prompt tokens that request really carried (a shorter LONGFILE gives fewer)
#
# Environment: OLLAMA_HOST (default 127.0.0.1:11434), CTX (num_ctx, default 16384),
# PRUNE (1 = remove models THIS run pulled, the default; 0 = keep), LONGFILE (text
# for the long prompt; default docs/ARCHITECTURE.md next to this script).
# Output: a table on stdout and ~/.cache/hugmesh-local-bench/<timestamp>.tsv.
#
# Everything goes to the loopback Ollama API. The only other network use is
# `ollama pull`, which fetches weights from the Ollama registry. A server that is
# not running is started detached on the loopback address, the way the doc says.
# Numbers depend on what else the machine is doing: run it idle to compare models.
set -u

case "${1:-}" in -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;; esac

HOST=${OLLAMA_HOST:-127.0.0.1:11434}
CTX=${CTX:-16384}
PRUNE=${PRUNE:-1}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LONGFILE=${LONGFILE:-$HERE/../docs/ARCHITECTURE.md}
OUTDIR=${HOME}/.cache/hugmesh-local-bench
TSV=$OUTDIR/$(date +%Y%m%d-%H%M%S).tsv

command -v ollama >/dev/null 2>&1 || { echo "ollama is not installed: see docs/LOCAL-AI-ASSISTANT.md" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required (it parses the API timings)" >&2; exit 2; }
[ -r "$LONGFILE" ] || { echo "LONGFILE $LONGFILE is not readable" >&2; exit 2; }

up() { curl -fsS --max-time 3 "http://$HOST/api/tags" >/dev/null 2>&1; }
if ! up; then
  OLLAMA_HOST=$HOST OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 setsid ollama serve \
    >"${HOME}/.cache/ollama-serve.log" 2>&1 < /dev/null &
  for _ in $(seq 1 30); do up && break; sleep 1; done
  up || { echo "ollama did not answer on $HOST after 30 s (see ~/.cache/ollama-serve.log)" >&2; exit 2; }
fi

if [ $# -gt 0 ]; then MODELS=("$@"); else
  MODELS=(qwen2.5-coder:7b qwen3:8b ornith:9b lfm2.5:8b gpt-oss:20b qwen3-coder:30b north-mini-code-1.0 laguna-xs-2.1)
fi

mkdir -p "$OUTDIR"
# A failing `ollama list` must stop the run: reading it as "nothing installed" would make PRUNE remove a model you had.
ollama list >/dev/null 2>&1 || { echo "ollama list failed: refusing to guess which models you already have" >&2; exit 2; }
have() { ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -Fqx "$1"; }
trap 'echo "interrupted"; ollama stop "${m:-}" >/dev/null 2>&1; exit 130' INT TERM
printf 'model\tdisk_gb\tgpu_pct\tload_s\tgen_tok_s\tprompt_tok_s\tlong_total_s\tprompt_tokens\tnote\n' > "$TSV"

for m in "${MODELS[@]}"; do
  pulled=0
  if ! have "$m" && ! have "${m}:latest"; then
    echo "== pull $m"
    if ! ollama pull "$m" >/dev/null 2>&1; then
      printf '%s\t\t\t\t\t\t\t\tpull-failed\n' "$m" >> "$TSV"; continue
    fi
    pulled=1
  fi
  echo "== measure $m (num_ctx=$CTX)"
  row=$(python3 - "$m" "$HOST" "$CTX" "$LONGFILE" <<'PY'
import json, sys, time, urllib.error, urllib.request

model, host, ctx, longfile = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]


def call(path, body, timeout=900):
    req = urllib.request.Request(f"http://{host}{path}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def gen(prompt, n):
    body = {"model": model, "prompt": prompt, "stream": False, "keep_alive": "60s", "think": False,
            "options": {"num_ctx": ctx, "temperature": 0, "num_predict": n}}
    try:
        return call("/api/generate", body)
    except urllib.error.HTTPError as e:      # a model without a thinking switch refuses think:false
        if e.code == 400:
            body.pop("think")
            return call("/api/generate", body)
        raise


try:
    short = gen("Write a bash function retry N cmd... that retries a command up to N times "
                "with exponential backoff. Code only.", 300)
    ps = json.load(urllib.request.urlopen(f"http://{host}/api/ps", timeout=30))
    names = {model, model + ":latest"}
    me = next((x for x in ps.get("models", []) if x.get("name") in names or x.get("model") in names), None)
    size = me["size"] if me else 0
    vram = me["size_vram"] if me else 0
    gpu = round(100 * vram / size) if size else ""
    gen_rate = round(short["eval_count"] / (short["eval_duration"] / 1e9), 1) if short.get("eval_duration") else ""
    load_s = round(short.get("load_duration", 0) / 1e9, 1)
    words = open(longfile, errors="replace").read().split()
    chunk = " ".join(words[:4500])           # about 10k tokens of Markdown
    t0 = time.time()
    lg = gen(chunk + "\n\nSummarise the text above in three short bullets.", 120)
    total = round(time.time() - t0, 1)
    pr = round(lg["prompt_eval_count"] / (lg["prompt_eval_duration"] / 1e9), 1) if lg.get("prompt_eval_duration") else ""
    ptok = lg.get("prompt_eval_count", 0)
    note = "long prompt hit num_ctx (truncated)" if ptok >= ctx - 200 else ("LONGFILE shorter than the 4500-word test" if len(words) < 4500 else "")
    print("\t".join(str(x) for x in (round(size / 1e9, 1), gpu, load_s, gen_rate, pr, total, ptok, note)))
except Exception as e:                       # noqa: BLE001 - one bad model must not stop the table
    print("\t".join(["", "", "", "", "", "", "", f"error: {type(e).__name__}: {e}"[:120]]))
PY
)
  printf '%s\t%s\n' "$m" "$row" >> "$TSV"
  ollama stop "$m" >/dev/null 2>&1
  if [ "$pulled" = 1 ] && [ "$PRUNE" = 1 ]; then ollama rm "$m" >/dev/null 2>&1 && echo "   (removed $m: PRUNE=1)"; fi
done

echo
column -t -s"$(printf '\t')" "$TSV"
echo
echo "saved: $TSV"
