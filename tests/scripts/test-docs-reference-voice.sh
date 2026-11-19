#!/usr/bin/env bash
# test-docs-reference-voice.sh — reference pages say what the product does NOW.
#
# A reference page is read by someone using the product today. History (when a thing
# changed, who asked for it, which ticket did it) belongs in git and the issues; on the
# page it reads as noise at best and goes stale at worst (hugmesh-generator#1038 found
# a section that described a behaviour the code had stopped having). So on the pages
# listed in PAGES this suite fails on:
#
#   date     a calendar date (YYYY-MM-DD or YYYY-MM)
#   ticket   a ticket reference: #123, repo#123, or an .../issues/123 or .../pull/123 URL
#   quote    an operator's words: "Operator ask", "the operator asked/said", or an
#            italic quotation (*"…"*) on a line that names the operator
#
# Link TARGETS are not prose and are skipped (`](…)`: a heading anchor may carry a
# date that the linked page owns). Fenced code blocks are skipped too: a command or a
# log line may legitimately contain any of these. A quoted UI string is fine: only an
# italic quotation that sits beside the word "operator" counts as a quote.
#
# To add a page, add it to PAGES. Negative controls at the bottom run the same rule over
# synthetic pages, so every clause is seen to fire (and to stay quiet on look-alikes).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAGES=(
  docs/RUNNING.md
  docs/STUDIO-WALKTHROUGH.md
  docs/STUDIO-INSTALLERS.md
)

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

# voice_findings <file> — prints "<line>:<rule>: <excerpt>" per finding; rc 0 always.
voice_findings() {
  python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1]
date = re.compile(r"(?<![\w/.-])(19|20)\d{2}-(0[1-9]|1[0-2])(-(0[1-9]|[12]\d|3[01]))?(?![\w-])")
ticket = re.compile(r"(?:(?<![\w&/#`-])#\d{2,5}\b)|(?:\b[a-z0-9]+(?:[-/.][a-z0-9]+)+#\d{1,5}\b)|(?:/(?:issues|pull)/\d+)")
quote_words = re.compile(r"\b[Oo]perator (ask|asked|asks|request|requested|said|decision)\b|\bat the operator'?s request\b")
italic_quote = re.compile(r'\*["“][^*]{3,}["”]\*')
in_fence = False
with open(path, encoding="utf-8") as fh:
    for n, line in enumerate(fh, 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        text = re.sub(r"\]\([^)]*\)", "]()", line)          # link targets are not prose
        text = re.sub(r"`[^`]*`", "``", text)               # nor code spans
        for rule, rx in (("date", date), ("ticket", ticket), ("quote", quote_words)):
            m = rx.search(text)
            if m:
                print(f"{n}:{rule}: {m.group(0)}")
        if italic_quote.search(text) and re.search(r"\boperator\b", text, re.I):
            print(f"{n}:quote: italic quotation beside 'operator'")
PY
}

echo "== reference pages"
for p in "${PAGES[@]}"; do
  if [ ! -f "${ROOT}/${p}" ]; then bad "${p}: listed in PAGES but missing"; continue; fi
  out="$(voice_findings "${ROOT}/${p}")"
  if [ -z "${out}" ]; then ok "${p}: no dates, ticket numbers or operator quotes"
  else bad "${p}: history on a reference page (move it to git or the issue):"
       printf '%s\n' "${out}" | sed "s|^|         ${p}:|"; fi
done

echo "== negative controls (each rule must fire; look-alikes must not)"
T="$(mktemp -d "${TMPDIR:-/tmp}/docs-voice.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
fires() { # <name> <rule> <line>
  printf '%s\n' "$3" > "${T}/p.md"
  if voice_findings "${T}/p.md" | grep ":$2:" >/dev/null; then ok "fires: $1"
  else bad "did not fire: $1 ($3)"; fi
}
quiet() { # <name> <text>
  printf '%s\n' "$2" > "${T}/p.md"
  local o; o="$(voice_findings "${T}/p.md")"
  if [ -z "${o}" ]; then ok "quiet: $1"; else bad "fired on a look-alike: $1 -> ${o}"; fi
}
fires "an ISO date"                date   "The pick was retired on 2026-10-21."
fires "a year-month"               date   "Measured in 2026-09, the list held six."
fires "a bare ticket"              ticket "The cell is read-only since #495."
fires "a repo ticket"              ticket "re-extracts the tree — hugmesh-generator#659)."
fires "an issues URL"              ticket "Not included yet ([see](https://x/y/issues/977) and https://github.com/a/b/issues/977)."
fires "an operator ask"            quote  "Operator ask, the domain config needs keys."
fires "the operator said"          quote  "The page exists because the operator asked for it."
fires "italic quote of the operator" quote 'The operator: *"the theme selection should be there"*.'
quiet "a link anchor with a date"  "See [Free-space guard](../README.md#free-space-guard-2026-11-10-full-disk-incident)."
quiet "a code span"                'Run `git log --since=2026-10-01` and `gh issue view #12`.'
quiet "a quoted UI string"         'Then it asks: *"I understand: k8s will stop to proceed."*'
quiet "an HTML entity"             "Press the &#9654; button."
quiet "a version and a hash"       "Verified at cbf5d9a6 for 0.4.4-beta.1 on x86_64."
quiet "a format name"            "Export the key as a PKCS#12 bundle."
quiet "the word operator alone"    "The operator workstation needs no root."
printf '%s\n' '```' 'echo 2026-10-21 #123' '```' > "${T}/p.md"
if [ -z "$(voice_findings "${T}/p.md")" ]; then ok "quiet: inside a fenced block"
else bad "fired inside a fenced block"; fi

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
