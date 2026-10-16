#!/usr/bin/env bash
# test-docs-command-coverage.sh — every user-facing command under scripts/ must be
# reachable from docs/ or a README (hugmesh-generator#268, the fourth box of #49
# that a scoped `Closes` left unsatisfied).
#
# WHAT WENT WRONG. #49 ("documentation for every command") was closed on
# 2026-08-20 by a commit that named only its first-run item. 1h27m later PR #78
# merged scripts/publish-images.sh — a user-facing export verb with its own CLI
# grammar, a unit suite wired into both CI files, and NOT ONE LINE of
# documentation anywhere. Nothing noticed, because nothing enforced the rule; a
# census three weeks later found it by hand. A rule with no gate is a wish.
#
# THE RULE, as this file enforces it. A tracked file under scripts/ is a COMMAND
# when it is executable in the git index (mode 100755) or carries a command
# extension (.sh .py .ps1 .js), unless it is an internal library by the repo's
# own naming convention (scripts/**/_*-lib.sh). A command is DOCUMENTED when:
#   (a) its basename appears in the docs corpus — every tracked docs/**/*.md and
#       every tracked README*.md anywhere in the repo; or
#   (b) it has a documented `make` front: a Makefile target whose recipe invokes
#       it, where the TARGET name appears in the corpus as `make <target>` or as
#       a code-span / `|`-alternation token (`kind-doctor`, `make a|b|kind-doctor`)
#       — the way scripts/hugmesh-view.py is documented through `make view`; or
#   (c) it is on the ALLOWLIST below as an internal helper, with a reason. Every
#       allowlist entry is itself checked: the path must be tracked, must NOT be
#       documented (a stale entry is a finding — the list must stay honest), and
#       must be referenced from at least one other tracked non-doc file (an
#       "internal helper" nothing calls is dead code, not internal).
# Anything else is a finding, named with its path, and the suite exits 1.
#
# Both forms of (b) are deliberately narrow: an unqualified word match would let
# the English word "view" document scripts/hugmesh-view.py from any sentence.
#
# EXECUTED AGAINST SYNTHETIC REPOS TOO. The rule is one function taking a repo
# root and an allowlist, and the negative controls at the bottom run it over
# throw-away git repos built to exercise every clause — an undocumented command,
# a documented one, a make-fronted one whose target is / is not documented, an
# allowlisted helper that is honest / stale / unreferenced, a _*-lib.sh, a data
# file, an extensionless 100755. A gate whose clauses have never been seen to
# fire is a gate nobody has tested.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for t in git awk grep sed; do
    command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t is not installed — this suite cannot run (it must not pass vacuously)"; exit 2; }
done

# ── ALLOWLIST: internal helpers with no operator-facing surface ───────────────
# One `path|reason` per line. An entry is a STATEMENT that the file is internal,
# checked three ways above — not permission to skip documentation.
ALLOWLIST_TEXT='
scripts/emit-package-catalog.py|internal: invoked by studio/hugmesh_studio/core/package_catalog.py to regenerate the Studio package catalog; no operator runs it
scripts/patch-portage-file-copy.py|internal: invoked by every build-*-stage4.sh, Dockerfile.build and scripts/_portage-config-lib.sh to patch portage inside the seed; no operator runs it
'

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── the rule ──────────────────────────────────────────────────────────────────
# coverage_findings <repo-root> <allowlist-text> -> one finding per line; empty = clean
coverage_findings() {
    local repo="$1" allow="$2"
    local corpus commands mk entry path reason base targets t documented found_ref
    # docs corpus: tracked docs/**/*.md + tracked README*.md anywhere
    corpus="$(git -C "${repo}" ls-files | grep -E '^docs/.*\.md$|(^|/)README[^/]*\.md$' || true)"
    if [ -z "${corpus}" ]; then echo "docs corpus is EMPTY (no tracked docs/**/*.md or README*.md) — the rule cannot be evaluated"; return; fi
    # commands: tracked under scripts/, mode 100755 or a command extension, not _*-lib.sh
    commands="$(git -C "${repo}" ls-files -s -- scripts | awk '
        { mode=$1; path=$4; n=split(path, seg, "/"); b=seg[n]
          if (b ~ /^_.*-lib\.sh$/) next
          if (mode == "100755" || b ~ /\.(sh|py|ps1|js)$/) print path }' | sort -u)"
    if [ -z "${commands}" ]; then echo "no commands found under scripts/ — the rule cannot be evaluated"; return; fi
    # Makefile: "<target>\t<recipe line>" pairs (a target line is `name(s):` not followed by `=`)
    mk="${TMP}/mk.$$"
    if [ -f "${repo}/Makefile" ]; then
        awk '
            /^[A-Za-z0-9_][A-Za-z0-9_.%\/-]*([[:space:]]+[A-Za-z0-9_][A-Za-z0-9_.%\/-]*)*[[:space:]]*:([^=]|$)/ {
                tg=$0; sub(/:.*$/, "", tg); gsub(/^[[:space:]]+|[[:space:]]+$/, "", tg); cur=tg; next }
            /^\t/ { if (cur != "") { line=$0; sub(/^\t/, "", line); nt=split(cur, ts, /[[:space:]]+/)
                                     for (i=1; i<=nt; i++) print ts[i] "\t" line }; next }
            /^[^\t#]/ { cur="" }
        ' "${repo}/Makefile" > "${mk}"
    else
        : > "${mk}"
    fi
    re_escape() { printf '%s' "$1" | sed 's/[.[\*^$+?(){}|\\]/\\&/g'; }
    in_corpus_fixed() { # <basename> -> 0 when some corpus file names it as a whole name
        # The character before the name must not be a name character: a mention of
        # tests/scripts/test-kind-doctor.sh must NOT document scripts/kind-doctor.sh.
        local f q
        q="$(re_escape "$1")"
        while IFS= read -r f; do
            [ -n "${f}" ] || continue
            grep -E -- "(^|[^[:alnum:]_.-])${q}([^[:alnum:]_.-]|\$)" "${repo}/${f}" >/dev/null 2>&1 && return 0
        done <<< "${corpus}"
        return 1
    }
    target_documented() { # <make-target> -> 0 when the corpus names it as a make front
        local f
        while IFS= read -r f; do
            [ -n "${f}" ] || continue
            grep -E -- "make[[:space:]]+$1([^[:alnum:]_.-]|\$)" "${repo}/${f}" >/dev/null 2>&1 && return 0
            grep -E -- "[|/\`][[:space:]]*$1[[:space:]]*[|/\`]" "${repo}/${f}" >/dev/null 2>&1 && return 0
        done <<< "${corpus}"
        return 1
    }
    # allowlist -> path|reason map; each entry checked
    local allowed_paths=""
    while IFS= read -r entry; do
        entry="$(printf '%s' "${entry}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "${entry}" ] || continue
        path="${entry%%|*}"; reason="${entry#*|}"
        [ "${path}" != "${entry}" ] && [ -n "${reason}" ] || { echo "allowlist entry '${entry}' has no |reason"; continue; }
        if ! git -C "${repo}" ls-files --error-unmatch -- "${path}" >/dev/null 2>&1; then
            echo "allowlist names ${path}, which is not tracked — stale entry"; continue
        fi
        base="${path##*/}"
        if in_corpus_fixed "${base}"; then
            echo "allowlist names ${path} as internal, but ${base} IS documented — stale entry, remove it"
        fi
        found_ref="$(git -C "${repo}" ls-files | grep -vE '^docs/.*\.md$|(^|/)README[^/]*\.md$' | grep -vxF -- "${path}" \
                     | while IFS= read -r f; do grep -lF -- "${base}" "${repo}/${f}" 2>/dev/null; done | head -1)"
        if [ -z "${found_ref}" ]; then
            echo "allowlist names ${path} as internal, but nothing else in the tree references ${base} — dead code is not internal"
        fi
        allowed_paths="${allowed_paths}${path}"$'\n'
    done <<< "${allow}"
    # the rule proper
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        base="${path##*/}"
        if printf '%s' "${allowed_paths}" | grep -xF -- "${path}" >/dev/null; then continue; fi
        if in_corpus_fixed "${base}"; then continue; fi
        documented=""
        targets="$(awk -F'\t' -v b="${base}" 'BEGIN { q=b; gsub(/\./, "\\.", q); re="(^|[ /\t\"'"'"'=])" q "($|[ \t\"'"'"';)])" } $2 ~ re { print $1 }' "${mk}" | sort -u)"
        for t in ${targets}; do
            if target_documented "${t}"; then documented="make ${t}"; break; fi
        done
        [ -n "${documented}" ] && continue
        if [ -n "${targets}" ]; then
            echo "${path} is not documented: no docs/README names ${base}, and its make front(s) [$(printf '%s' "${targets}" | tr '\n' ' ' | sed 's/ $//')] are not documented as \`make <target>\` either"
        else
            echo "${path} is not documented: no docs/**/*.md or README*.md names ${base}, and no make target invokes it"
        fi
    done <<< "${commands}"
}

# ── the Makefile help rule (decision 106 = B on #49) ─────────────────────────
# `make help` is documentation for make targets: a target is DOCUMENTED when its
# rule line carries a `## ` help line that `make help` actually prints. help's own
# grep is  ^[a-zA-Z0-9_.+-]+:.*?##   so the rule here is the same shape: every
# column-0 rule line naming a plain target (letters, digits, _ . + -) must carry
# `## `. Pattern rules (`rpi-%:`), dot-targets (.PHONY, .DEFAULT_GOAL), variable
# assignments (`X := y`, `X ?= y`) and recipe lines are not targets in this sense.
# makefile_help_findings <repo-root> -> one finding per line; empty = clean.
makefile_help_findings() {
    local repo="$1" mf="$1/Makefile" n
    [ -f "${mf}" ] || { echo "Makefile is missing — the help rule cannot be evaluated"; return; }
    n="$(grep -cE '^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*:([^=:]|$)' "${mf}" || true)"
    [ "${n:-0}" -gt 0 ] || { echo "Makefile has no target lines — the help rule cannot be evaluated"; return; }
    awk '/^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*:([^=:]|$)/ && $0 !~ /## / { t=$0; sub(/:.*$/, "", t); printf "Makefile:%d target %s has no `## ` help line, so `make help` does not list it\n", NR, t }' "${mf}"
}

# ── the real repo ─────────────────────────────────────────────────────────────
echo "== docs command coverage: ${GEN} =="
n_cmd="$(git -C "${GEN}" ls-files -s -- scripts | awk '{ n=split($4, s, "/"); b=s[n]; if (b ~ /^_.*-lib\.sh$/) next; if ($1=="100755" || b ~ /\.(sh|py|ps1|js)$/) c++ } END { print c+0 }')"
n_doc="$(git -C "${GEN}" ls-files | grep -cE '^docs/.*\.md$|(^|/)README[^/]*\.md$' || true)"
if [ "${n_cmd}" -gt 0 ] && [ "${n_doc}" -gt 0 ]; then
    ok "census: ${n_cmd} command(s) under scripts/ (100755 or .sh/.py/.ps1/.js, minus _*-lib.sh) against ${n_doc} doc/README file(s)"
else
    bad "census is vacuous: ${n_cmd} command(s), ${n_doc} doc file(s) — is this a git checkout with git ls-files working?"
fi
findings="$(coverage_findings "${GEN}" "${ALLOWLIST_TEXT}")"
if [ -z "${findings}" ]; then
    ok "every command under scripts/ is named in docs/ or a README, or reached through a documented make front, or an honest allowlist entry"
else
    while IFS= read -r line; do bad "${line}"; done <<< "${findings}"
fi

mk_findings="$(makefile_help_findings "${GEN}")"
n_tg="$(grep -cE '^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*:([^=:]|$)' "${GEN}/Makefile" || true)"
if [ -z "${mk_findings}" ]; then
    ok "every plain Makefile target (${n_tg}) carries a '## ' help line that make help lists (decision 106)"
else
    while IFS= read -r line; do bad "${line}"; done <<< "${mk_findings}"
fi

# ── negative controls over synthetic repos ────────────────────────────────────
echo "-- negative controls --"
mkrepo() { # <name> -> path; a fresh git repo with docs/README.md and a Makefile stub
    local r="${TMP}/repo-$1"
    mkdir -p "${r}/docs" "${r}/scripts"
    git -C "${r}" init -q
    printf '# index\n' > "${r}/docs/README.md"
    printf 'help:\n\t@echo help\n' > "${r}/Makefile"
    printf '%s' "${r}"
}
addf() { # <repo> <path> <content> [mode]
    mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"
    # +x on DISK, not only in the index: control() re-adds with `git add -A`, which
    # re-stats the file and would put a 644 back over an index-only chmod.
    if [ "${4:-}" = "x" ]; then chmod +x "$1/$2"; fi
    git -C "$1" add -- "$2"
}
control() { # <label> <repo> <allowlist> <expect: clean|finding-substring>
    local label="$1" repo="$2" allow="$3" want="$4" out
    git -C "${repo}" add -A . >/dev/null 2>&1
    out="$(coverage_findings "${repo}" "${allow}")"
    if [ "${want}" = clean ]; then
        if [ -z "${out}" ]; then ok "${label}: clean, as it should be"; else bad "${label}: unexpected finding: $(printf '%s' "${out}" | tr '\n' '|' | cut -c1-200)"; fi
    else
        if printf '%s\n' "${out}" | grep -F -- "${want}" >/dev/null; then ok "${label}: caught — '$(printf '%s\n' "${out}" | grep -F -- "${want}" | head -1 | cut -c1-100)'"
        else bad "${label}: NOT caught (expected '${want}'): $(printf '%s' "${out}" | tr '\n' '|' | cut -c1-200)"; fi
    fi
}

# (c1) an undocumented command is a finding
R="$(mkrepo c1)"; addf "${R}" scripts/foo.sh '#!/bin/sh' x
control "c1: undocumented scripts/foo.sh" "${R}" "" "scripts/foo.sh is not documented"

# (c2) documented by basename in docs/
R="$(mkrepo c2)"; addf "${R}" scripts/foo.sh '#!/bin/sh' x; addf "${R}" docs/USING.md 'Run `scripts/foo.sh` to foo.'
control "c2: named in docs/USING.md" "${R}" "" clean

# (c2b) documented by basename in a README outside docs/
R="$(mkrepo c2b)"; addf "${R}" scripts/foo.sh '#!/bin/sh' x; addf "${R}" specs/README.md 'foo.sh does the thing'
control "c2b: named in specs/README.md" "${R}" "" clean

# (c3) documented only through a make front that the docs name as `make front`
R="$(mkrepo c3)"; addf "${R}" scripts/bar.py 'print(1)'
printf 'help:\n\t@echo help\nfront: ## run bar\n\tpython3 scripts/bar.py\n' > "${R}/Makefile"; git -C "${R}" add Makefile
addf "${R}" docs/USING.md 'Run `make front` to bar.'
control "c3: make front documented as \`make front\`" "${R}" "" clean

# (c3b) ...or as a code-span / alternation token (README's `kind-up` / `kind-doctor` style)
R="$(mkrepo c3b)"; addf "${R}" scripts/bar.py 'print(1)'
printf 'help:\n\t@echo help\nkind-bar: ## run bar\n\tpython3 scripts/bar.py\n' > "${R}/Makefile"; git -C "${R}" add Makefile
addf "${R}" docs/USING.md 'The kind lane: `kind-up` / `kind-bar` / `kind-down` stand it up.'
control "c3b: make front documented as a \`kind-bar\` code-span token" "${R}" "" clean

# (c4) a make front exists but the docs never name the target -> finding names the target
R="$(mkrepo c4)"; addf "${R}" scripts/bar.py 'print(1)'
printf 'help:\n\t@echo help\nfront: ## run bar\n\tpython3 scripts/bar.py\n' > "${R}/Makefile"; git -C "${R}" add Makefile
addf "${R}" docs/USING.md 'We have a front for viewing things.'
control "c4: make front exists, target never documented" "${R}" "" "make front(s) [front] are not documented"

# (c4b) the English word does not count: "view" in prose must not document `make view`
R="$(mkrepo c4b)"; addf "${R}" scripts/hv.py 'print(1)'
printf 'help:\n\t@echo help\nview: ## serve\n\tpython3 scripts/hv.py up\n' > "${R}/Makefile"; git -C "${R}" add Makefile
addf "${R}" docs/USING.md 'From this view the operator can see the doors.'
control "c4b: the prose word 'view' does not document the make target view" "${R}" "" "scripts/hv.py is not documented"

# (c2c) a mention of tests/scripts/test-foo.sh does NOT document scripts/foo.sh (name boundary)
R="$(mkrepo c2c)"; addf "${R}" scripts/foo.sh '#!/bin/sh' x; addf "${R}" docs/USING.md 'CI runs `tests/scripts/test-foo.sh`.'
printf 'help:\n\t@echo help\nfoo-test: ## gate\n\tbash tests/scripts/test-foo.sh\n' > "${R}/Makefile"; git -C "${R}" add Makefile
addf "${R}" docs/CI.md 'Run `make foo-test` before pushing.'
control "c2c: test-foo.sh in docs and in a documented make target does not document foo.sh" "${R}" "" "scripts/foo.sh is not documented"

# (c5) an honest allowlist entry: internal helper, referenced from another script, not documented
R="$(mkrepo c5)"; addf "${R}" scripts/helper.py 'print(1)'; addf "${R}" scripts/main.sh 'python3 scripts/helper.py' x
addf "${R}" docs/USING.md 'Run `scripts/main.sh`.'
control "c5: honest allowlist entry" "${R}" "scripts/helper.py|internal: called by main.sh" clean

# (c6) a STALE allowlist entry: the helper became documented
R="$(mkrepo c6)"; addf "${R}" scripts/helper.py 'print(1)'; addf "${R}" scripts/main.sh 'python3 scripts/helper.py' x
addf "${R}" docs/USING.md 'Run `scripts/main.sh`; `helper.py` is what it calls.'
control "c6: allowlist entry for a now-documented helper" "${R}" "scripts/helper.py|internal: called by main.sh" "IS documented — stale entry"

# (c7) an allowlisted "internal" helper that nothing references
R="$(mkrepo c7)"; addf "${R}" scripts/helper.py 'print(1)'
control "c7: allowlisted helper nothing references" "${R}" "scripts/helper.py|internal: honest?" "nothing else in the tree references"

# (c7b) an allowlist entry for an untracked path
R="$(mkrepo c7b)"; addf "${R}" scripts/x.sh '#!/bin/sh' x; addf "${R}" docs/USING.md 'x.sh'
control "c7b: allowlist entry for an untracked path" "${R}" "scripts/gone.sh|internal" "not tracked — stale entry"

# (c8) the library convention is exempt
R="$(mkrepo c8)"; addf "${R}" scripts/_thing-lib.sh 'thing() { :; }'; addf "${R}" scripts/ok.sh '#!/bin/sh' x; addf "${R}" docs/USING.md 'Run `scripts/ok.sh`.'
control "c8: scripts/_thing-lib.sh needs no docs (next to a documented command)" "${R}" "" clean

# (c9) a non-executable data file is not a command
R="$(mkrepo c9)"; addf "${R}" scripts/devices.tsv 'a	b'; addf "${R}" scripts/ok.sh '#!/bin/sh' x; addf "${R}" docs/USING.md 'Run `scripts/ok.sh`.'
control "c9: scripts/devices.tsv is data, not a command (next to a documented command)" "${R}" "" clean

# (c10) an extensionless 100755 IS a command
R="$(mkrepo c10)"; addf "${R}" scripts/tool 'echo hi' x
control "c10: extensionless executable scripts/tool" "${R}" "" "scripts/tool is not documented"

# (c11) an empty corpus is a finding, not a pass
R="${TMP}/repo-c11"; mkdir -p "${R}/scripts"; git -C "${R}" init -q; addf "${R}" scripts/foo.sh '#!/bin/sh' x
control "c11: no docs at all is a finding, never a vacuous pass" "${R}" "" "docs corpus is EMPTY"

# (h1..h5) the Makefile help rule
mkhelp() { # <name> <Makefile content> -> path of a repo holding only that Makefile
    local r="${TMP}/repo-$1"; mkdir -p "${r}"; printf '%b' "$2" > "${r}/Makefile"; printf '%s' "${r}"
}
mkcontrol() { # <label> <repo> <expect: clean|finding-substring>
    local out; out="$(makefile_help_findings "$2")"
    if [ "$3" = clean ]; then
        if [ -z "${out}" ]; then ok "$1: clean, as it should be"; else bad "$1: unexpected finding: $(printf '%s' "${out}" | tr '\n' '|' | cut -c1-200)"; fi
    elif printf '%s\n' "${out}" | grep -F -- "$3" >/dev/null; then ok "$1: caught — '$(printf '%s\n' "${out}" | grep -F -- "$3" | head -1 | cut -c1-100)'"
    else bad "$1: NOT caught (expected '$3'): $(printf '%s' "${out}" | tr '\n' '|' | cut -c1-200)"; fi
}
R="$(mkhelp h1 'help: ## list\n\t@echo h\nfoo:\n\t@echo foo\n')"
mkcontrol "h1: a target without a help line" "${R}" "target foo has no"
R="$(mkhelp h2 'help: ## list\n\t@echo h\nfoo: dep ## do foo\n\t@echo foo\nbar-x.y+z: ## do bar\n\t@echo bar\n')"
mkcontrol "h2: targets with prerequisites and a help line" "${R}" clean
R="$(mkhelp h3 '.PHONY: help foo\n.DEFAULT_GOAL := help\nX := a:b\nY ?= c\nZ:=1\nhelp: ## list\n\t@echo "bar: not a target"\n\tcheck: a recipe line that looks like a rule\nrpi-%: ## pattern rule\n\t@echo p\n')"
mkcontrol "h3: .PHONY, assignments, recipe lines and pattern rules are not targets" "${R}" clean
R="$(mkhelp h4 'help: ## list\nfoo:\n\t@echo "## not a help line, a recipe"\n')"
mkcontrol "h4: a '##' inside the recipe does not count as the target's help line" "${R}" "target foo has no"
R="$(mkhelp h4b 'help: ## list\nfoo-bar.baz+x:\n\t@echo x\n')"
mkcontrol "h4b: a target with - . + in its name is still a target" "${R}" "target foo-bar.baz+x has no"
R="${TMP}/repo-h5"; mkdir -p "${R}"
mkcontrol "h5: a missing Makefile is a finding, never a vacuous pass" "${R}" "Makefile is missing"
R="$(mkhelp h6 '# only comments\nX := 1\n')"
mkcontrol "h6: a Makefile with no targets is a finding, never a vacuous pass" "${R}" "no target lines"

echo
echo "== docs command coverage: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
