#!/usr/bin/env bash
# test-brand-words.sh — B-WORDS: the seven words of the brand model are written once
# (hugmesh-generator#654, decision D1).
#
# WHAT IT CHECKS
#   1. The word table the screens read (studio/hugmesh_studio/core/plain_words.py:
#      WORDS, as (term, meaning) rows) EQUALS the table in docs/BRAND-MODEL.md
#      ("## The seven words"), row for row, in order.
#   2. No window page or text screen (studio/hugmesh_studio/gui, tui) spells one of
#      the distinctive terms itself without reading the table: a module whose text
#      says "superbrand", "internal root name", "ways to reach" or "Open public ports
#      80 and 443" must import plain_words. (The three short words brand, sign-in and
#      Go live are too common to guard by grep; the table and the document carry
#      them.) The seven house words D1 bans on brand screens (tenant, issuer, slug,
#      epoch, generation, residency, capability) are NOT grepped over today's screens:
#      screens this check does not own still say some of them, and a guard that is
#      red on main teaches everyone to ignore it. They are exported for the screen
#      lanes as plain_words.FORBIDDEN_ON_SCREENS.
#   3. SELF-CHECK, every run: the same comparison against a copy of the document with
#      one meaning changed must FAIL, so a comparison that cannot go red is caught
#      here and not months later.
#
# A wording check, not an end-to-end test (the design's G1). Plain bash + python3,
# no Qt, no network, no mesh. Exit 0 = every check passed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUDIO="${REPO}/studio"
DOC="${REPO}/docs/BRAND-MODEL.md"
PY="${PYTHON:-python3}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
W="$(mktemp -d)"; trap 'rm -rf "${W}" 2>/dev/null' EXIT

for f in "${DOC}" "${STUDIO}/hugmesh_studio/core/plain_words.py"; do
  [ -r "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
done

echo "== B-WORDS: the word table against the document =="

# compare_words DOC -> exit 0 when the table equals the document's rows
compare_words() {
  ( cd "${STUDIO}" && "${PY}" - "$1" <<'PY'
import re, sys
from hugmesh_studio.core import plain_words
doc = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^## The seven words\n(.*?)(?=^## )", doc, re.S | re.M)
if not m:
    print("the document has no '## The seven words' section"); sys.exit(1)
rows = []
for line in m.group(1).splitlines():
    if not line.startswith("|") or set(line.replace("|", "").strip()) <= {"-"}:
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if cells[:2] == ["Word", "Meaning"]:
        continue
    rows.append((cells[0], cells[1]))
table = [(t, meaning) for _k, t, meaning in plain_words.WORDS]
if rows != table:
    print("the document's rows and plain_words.WORDS differ:")
    for i in range(max(len(rows), len(table))):
        d = rows[i] if i < len(rows) else None
        t = table[i] if i < len(table) else None
        if d != t:
            print(f"  row {i + 1}: document={d!r}\n         table={t!r}")
    sys.exit(1)
print(f"{len(rows)} rows agree")
PY
  )
}

if out="$(compare_words "${DOC}" 2>&1)"; then
  ok "plain_words.WORDS equals docs/BRAND-MODEL.md (${out})"
else
  bad "plain_words.WORDS differs from docs/BRAND-MODEL.md:"; echo "${out}" | sed 's/^/        /'
fi

# ── 2. no screen module spells a distinctive term without reading the table ──
TERMS=("superbrand" "internal root name" "ways to reach" "Open public ports 80 and 443")
offenders=()
while IFS= read -r file; do
  [ -n "${file}" ] || continue
  if ! grep -q 'plain_words' "${file}"; then offenders+=("${file}"); fi
done < <(for t in "${TERMS[@]}"; do
           grep -rl -i -- "${t}" "${STUDIO}/hugmesh_studio/gui" "${STUDIO}/hugmesh_studio/tui" 2>/dev/null
         done | sort -u)
if [ "${#offenders[@]}" -eq 0 ]; then
  ok "every screen module that says one of the distinctive terms reads plain_words"
else
  bad "screen modules that spell a term without reading plain_words:"
  printf '        %s\n' "${offenders[@]}"
fi

# ── 3. self-check: a changed meaning must FAIL the comparison ──
sed 's/start the Tor addresses; it opens no public port/start the Tor addresses and open the public ports/' \
  "${DOC}" > "${W}/mutated.md"
if cmp -s "${DOC}" "${W}/mutated.md"; then
  bad "self-check: the mutation changed nothing (the Go live row moved?)"
elif compare_words "${W}/mutated.md" >/dev/null 2>&1; then
  bad "self-check: the comparison stayed GREEN on a document with one meaning changed"
else
  ok "self-check: one changed meaning turns the comparison red"
fi

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
