#!/usr/bin/env bash
# =============================================================================
# test-selected-services-only.sh — THE WHOLE selected-services chain, pinned.
# =============================================================================
# THE REQUIREMENT (operator, verbatim): "make sure images with services selected
# also only start with those services selected until a superadmin enables others
# in the devops superadmin controls."
#
# That is ONE sentence and FOUR independent legs, each of which has been broken
# here at least once while every existing suite stayed green:
#
#   A  BUILD TIME   the Studio/CLI selection must be RENDERED into the baked
#                   sysroot's install-state artefacts, fail-CLOSED, by every
#                   builder that bakes a cluster tree.
#   B  BOOT         those rendered artefacts must actually REACH the cluster, and
#                   nothing the cluster pulls from git may deploy an optional
#                   service unconditionally.
#   C  RUNTIME      a superadmin must be able to turn a service ON afterwards —
#                   which needs the 13a selector, the ignoreDifferences seam, the
#                   reconciler switched on, an authorised write path, a slug set
#                   every registry agrees on, and an endpoint that exists.
#
# ── V2 (2026-08-26). WHAT CHANGED AND WHY ───────────────────────────────────
# V1 of this file read the two stage4 builder FILES directly:
#     _extract_fn() { awk -v n="$2" 'index($0, n "() {")==1 ...' "$1"; }
# The gate has since MOVED into scripts/_optional-services-lib.sh, which both
# builders `source`. Against today's main V1 therefore reported
#     FAIL A1 build-rpi5-stage4.sh: could not derive the renderer's slug loop
#     FAIL A3 DERIVATION YIELDED ZERO ROWS
# — 0 passed, 5 failed, for a reason that has NOTHING to do with the defects it
# exists to catch. Note that it behaved CORRECTLY: it refused to assert over an
# empty set and said so by name. That property is preserved absolutely below.
#
# V2 resolves gate functions THE WAY BASH DOES, through tests/lib/opt-gate-source.sh
# (libs the builder sources, in source order; the builder LAST; last definition
# wins; all bash spellings of a definition). A builder-local override still wins,
# which is the point — that is how a re-introduced x86-only copy of a renderer
# goes RED here instead of hiding behind a name that is present in both files.
# The single-file awk survives as a FALLBACK for trees that predate the library.
#
# ── AND THE TREE MOVED UNDER IT. RE-MEASURED, LEG BY LEG, 2026-08-26 ────────
# PR #183 (the keystone): specs/cluster/bootstrap/bootstrap.sh no longer applies
# the repo-recursing root app-of-apps. It applies the BAKED apps/ tree file by
# file (apply_baked_app, repoURL/targetRevision substitution, bounded retry, a
# skip for the repo-recursing waved root, and a post-condition against the
# zero-iteration no-op). V1's B1/B2/B3 all rested on the premise that NOTHING at
# boot reads the baked tree. That premise is now FALSE for apps/, and still TRUE
# for manifests/. The B leg is re-authored around the measurement, not the memory:
#   B1  is now the boot TOPOLOGY assertion (the default path applies the baked
#       tree; the repo-recursing root is behind a default-off switch) — GREEN,
#       and NC-B1 proves it bites.
#   B4  is NEW and EXECUTED: the real gate, resolved through the real chain, run
#       against a real baked tree, must actually DELETE each deselected slug's
#       registry-declared Applications — and keep them when selected.
#   B2  survives, narrowed by measurement: apps/13a-optional-services.yaml IS
#       applied from the baked tree now; the installed-services ConfigMap and the
#       seed OptionalService CRs are NOT — they are synced from GIT by
#       apps/16-reserved-prefixes-policy.yaml and apps/13d-optional-services-
#       operator.yaml, so the builder's render of those two is still written to a
#       file nothing reads. STILL RED, and still the operator's complaint.
#   B3  survives unchanged and still RED, for the same reason B2 is: those two
#       artefacts come from git, and git ships akkoma/tuwunel/phpbb ON.
# PR #186 (the lever): APP_OPTIONAL_SERVICES_RECONCILE_ENABLED is now DECLARED in
# the admin-bff Deployment, apps/16's ignoreDifferences pointer list is derived
# from the slug set, and the meshbridge CRD-enum gap is closed. So:
#   C3  MOVED to GREEN (14 of 14 writable keys covered; was 12 of 14).
#   C4  MOVED to GREEN (all five in-tree sources agree on 14 slugs).
#   C5  SPLIT. The old check said "set NOWHERE — the reconciler ships dark", and
#       that premise is now FALSE: the lever exists. C5 asserts the lever exists
#       (GREEN). C5b asserts it is actually ON, which it is not — deliberately,
#       pending the hardcoded-app cut-over — so the enable path is still inert.
# PR #182 + the C2 library extraction: the renderers and the _opt_* namespace live
# in scripts/_optional-services-lib.sh; tests/lib/opt-gate-source.sh is the resolver.
#   A3  MOVED to GREEN, and for a STRUCTURAL reason: both builders resolve the
#       same library, so they cannot disagree about what they render unless one
#       of them re-introduces a local override. NC9 is re-authored to plant
#       exactly that override (plus prose, so prose cannot rescue it).
#   A2  MOVED. _opt_render_appset_flag now REFUSES to flip a 13a element to
#       "true" while a hardcoded apps/30-*/50-* Application still owns the same
#       manifest directory (double management: two prune+selfHeal Applications on
#       one path). "Select everything and every 13a flag must be true" is no
#       longer the truth; the truth is per-slug and DERIVED from the tree.
#   C8  is the SIBLING leg: the /bff/superadmin/optional-services surface that C6's
#       route_access rows and gateway route point AT must exist in the service.
#       Absent checkout => UNVERIFIED and a NON-ZERO exit (rc 3), never a silent
#       skip; the in-repo precedent is tests/scripts/test-federation-module-slugs.sh.
#       The Java OptionalServiceRegistry's slug parity is NOT re-checked here —
#       tests/scripts/test-optional-service-slug-closure.sh already owns it, and
#       two guards asserting one thing is how one of them rots unnoticed.
#
# ── V3 (2026-08-27). FOUR CHECKS WERE READING NAMES, NOT MEASUREMENTS ───────
# Two independent adversarial reviews ran against V2. Each finding below was
# demonstrated by a mutation that left the named check GREEN; each mutation is now
# a control that requires it to go RED.
#   B1  was DECORATIVE. It inspected lines containing the literal string
#       "app-of-apps.yaml" that also had "kubectl apply" within ±3 lines, so any
#       indirection walked past it: a helper that binds the path to a local
#       variable and applies it six lines later, called unconditionally, left B1
#       PASS. B1 now reads bootstrap.sh through a shell reader that expands
#       variables and computes reachability through call sites, derives the
#       recursing-root SET from source.path instead of a filename, and checks the
#       glob apply that sweeps up the second root. (NC12d, NC12e.) Two more escapes
#       were found by a mutation battery when this was carried onto main the same
#       day and are closed here: a target bound through `X="${X:-…}"` expanded
#       into noise, and a DIRECT directory apply (`-f "${CLUSTER_DIR}/apps"`, no
#       loop) covered the waved root unseen. (NC12f, NC12g.) NOT closed, on
#       purpose: an `[ … ] && kubectl apply …` one-liner guard is not modelled and
#       reads as unguarded — a false RED, the reader's documented safe direction.
#   A4  was a bare line-anchored NAME scan. On this very tree x86's usage() heredoc
#       satisfied it, so deleting x86's real gate call kept A4 green; and a gate
#       call inside a function nothing invokes turned it fully green. A4 now
#       requires the gate to be RESOLVED, --optional-services to be PARSED, the
#       call to be REACHABLE, and to run AFTER the copy under the same guard stack.
#       (NC10b, NC10c, NC10d; NC10e plants the fix and requires green.)
#   C1  keyed on "some generator carries the selector". ArgoCD applies `selector`
#       PER GENERATOR, so a second selector-less list generator deployed its whole
#       element list unconditionally and C1 still said PASS. Now: every generator.
#       (NC1b.)
#   C3  compared only the LAST PATH SEGMENT of each ignoreDifferences jsonPointer,
#       so /spec/bogus/akkoma "covered" the akkoma key. It now resolves each
#       pointer against the ConfigMap the way its sibling C2 already did. (NC6b.)
#   C4  asserted parity in one direction only. A slug present in the registry, the
#       ConfigMap AND the seed CRs but in neither the CRD enum nor 13a passed
#       unnoticed; the reverse legs are now asserted. (NC7b.)
#   C8  was MISCLASSIFIED. hugmesh-admin-bff-api PR #43 merged 2026-08-27 07:04
#       UTC and OptionalServiceSuperadminController is on that repo's main, so
#       "declares no handler" was stale. The mechanism that hid it: C8 read a
#       WORKING TREE, and the checkout on this box was 9 commits behind its own
#       origin/main. C8 is a SOURCE check, so it now measures the remote-tracking
#       default branch when the tree is behind it (offline, from objects the
#       checkout already has), names WHICH source it measured in every verdict
#       line, and reports UNVERIFIED rather than a false red when it cannot
#       materialise that ref. (NC24, NC25.)
#       KEEP THIS APART FROM DEPLOYMENT LAG. Whether the running admin-bff IMAGE
#       carries the handler is a different question with a different answer — the
#       jar deployed on kind-hugmesh-local was built at 06:19 UTC, 45 minutes
#       before the endpoint merged, so it does not. NOTHING here measures that.
#
# ── THIS GUARD IS STILL RED, AND STILL ON PURPOSE ───────────────────────────
# A4 B2 B3 C5b C7 name defects that are LIVE on this tree (C8 went green when its
# sibling's PR #43 merged). It is therefore NOT wired into the pre-merge
# pull_request gate — a red suite there blocks every PR in the repo — but recorded
# in PREMERGE_UNGATED with that reason and gated in .gitlab-ci.yml, exactly as
# tests/scripts/test-optional-service-slug-closure.sh and
# tests/stack/test-gateway-auth-flag-parity.sh are. Do not "fix" a red check by
# relaxing it — fix the tree. EVERY ONE of the five has a control that plants the
# FIX and requires the check to go GREEN: A4 NC10e, B2 NC21, B3 NC22, C5b NC23,
# C7 NC14. (V2's .gitlab-ci.yml claimed that of six; it was true of two.)
#
# ── HOUSE FAILURE MODES THIS FILE IS BUILT AGAINST ──────────────────────────
#  * EMPTY DERIVATION. Every list below is derived, and every derivation ABORTS
#    the run with a V-* failure if it yields zero rows. An assertion over an empty
#    set is the vacuous pass this repo keeps shipping.
#  * COMMENT-TOKEN INVERSION, IN BOTH DIRECTIONS. Prose naming a token has flipped
#    assertions here repeatedly, and a prose CITATION has also invented an edge
#    that did not exist (apps/16-reserved-prefixes-policy.yaml, cited by name in a
#    comment, created an unsatisfied dependency in another suite this same week).
#    Every shell/SQL scan strips FULL-LINE comments and anchors at line start;
#    every YAML source is parsed, not grepped.
#  * `| grep -q` UNDER pipefail. Not used. Output is written to a file and read
#    with `grep ... >/dev/null` so a found match cannot SIGPIPE into a false red.
#  * A REGISTRY ROW NOTHING READS. Every derived set below is consumed by a check
#    that can fail; V-* rows that feed nothing are not printed.
#  * A TEST SATISFIED BY ITS OWN VOCABULARY. The negative controls at the bottom
#    plant a defect — or, for the checks that are red today, plant the FIX — in a
#    sandbox copy of the real tree and require the NAMED check to flip. A check
#    that is stuck red is as useless as one that is stuck green, so both
#    directions are controlled, for EVERY red check (see NC10e/NC21/NC22/NC23/
#    NC14/NC18).
#  * A CHECK THAT READS A NAME INSTEAD OF A MEASUREMENT. Four checks here were
#    defeated by adversarial review after V2 shipped, each with a mutation that
#    left the check GREEN, and each of those mutations is now a control:
#    B1 (NC12d, NC12e, NC12f, NC12g), A4 (NC10b, NC10c, NC10d), C1 (NC1b), C3 (NC6b),
#    C4 (NC7b).
#
# ── HOW TO READ THE OUTPUT ──────────────────────────────────────────────────
#   V-*   a derivation. FAIL means a source could not be derived at all.
#   A1 A2 EXECUTED. The real renderer functions, resolved through the real source
#         chain and run against a sandbox sysroot seeded from the real committed
#         artefacts. A1 = deselect-all must be fail-closed; A2 = select-all must
#         actually WRITE (an anchor that silently no-ops at rc 0 passes A1 and
#         fails A2), with the 13a expectation DERIVED per slug from the tree.
#   A3 A4 builder parity / coverage.
#   B1 B2 B3 B4 does the selection reach a running cluster.
#   C1-C8 can a superadmin turn something on afterwards.
#   NC*   negative controls over a sandbox copy.
#
# ENV:
#   SELSVC_ROOT           analyse this tree instead of the repo (used by the controls)
#   SELSVC_NO_NC=1        skip the negative controls (they are the slow half)
#   SELSVC_ADMIN_BFF_ROOT where to find the hugmesh-admin-bff-api checkout
#
# Exit: 0 all green · 1 a check failed · 3 only UNVERIFIED legs.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${SELSVC_ROOT:-${REPO}}"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "  FAIL awk not available"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "${W}" 2>/dev/null' EXIT

# ── THE SOURCE-CHAIN RESOLVER ────────────────────────────────────────────────
# Prefer the copy inside the tree under analysis (so a sandbox that carries one
# is analysed with its own), then the repo's. If NEITHER exists we are looking at
# a tree that predates the library extraction, and the single-file awk below is
# the correct reading of THAT tree — not a degraded one.
SELSVC_RESOLVER=0
for _r in "${ROOT}/tests/lib/opt-gate-source.sh" "${REPO}/tests/lib/opt-gate-source.sh"; do
  if [ -f "${_r}" ]; then
    # shellcheck source=/dev/null
    . "${_r}" && SELSVC_RESOLVER=1 && break
  fi
done
unset _r

# ── the files this guard reads, in ONE place: the sandbox copier and the
#    analysers must agree, or a control would silently analyse a hole. ────────
# scripts/_optional-services-lib.sh and tests/lib/opt-gate-source.sh are here
# because the gate LIVES in the first and is RESOLVED by the second: a sandbox
# without them is not a copy of this tree's gate at all, and every A/B result
# taken from it would be noise. NC0 is what proves that copy is faithful.
SELSVC_PATHS=(
  specs/cluster/optional-services.yaml
  specs/cluster/app-of-apps.yaml
  specs/cluster/apps
  specs/cluster/bootstrap
  specs/cluster/manifests/policy
  specs/cluster/manifests/optional-services-operator
  specs/cluster/manifests/admin-bff-api
  specs/cluster/manifests/route-access
  specs/cluster/manifests/external-secrets
  specs/cluster/manifests/casdoor
  specs/etc/keys-provision
  scripts/_optional-services-lib.sh
  tests/lib/opt-gate-source.sh
)

# sandbox_root <dest> — a minimal but REAL tree: the actual committed files, not
# fixtures. Controls mutate this copy so production is never touched by the suite.
sandbox_root() {
  local d="$1" p
  rm -rf "${d}"; mkdir -p "${d}"
  for p in "${SELSVC_PATHS[@]}"; do
    [ -e "${ROOT}/${p}" ] || continue
    mkdir -p "${d}/$(dirname "${p}")"
    cp -r "${ROOT}/${p}" "${d}/${p}"
  done
  for p in "${ROOT}"/build-*-stage4.sh; do
    [ -f "${p}" ] && cp "${p}" "${d}/"
  done
  return 0
}

# ── comment stripping ────────────────────────────────────────────────────────
# FULL-LINE comments only, and every shell assertion below is anchored at the
# start of the stripped line (`^[[:space:]]*<token>`). That combination is what
# makes prose unable to satisfy a check: a documentation block is a full-line
# comment (stripped), and a trailing `cmd  # token` comment cannot match a
# start-of-line anchor. It also stops prose CREATING a false edge, which is the
# other half of the same failure — a citation of a filename in a comment invented
# an unsatisfied dependency in test-kind-profile-app-closure.sh this week.
strip_sh_comments() { sed 's/^[[:space:]]*#.*$//' "$1"; }

# _extract_fn <builder> <name> — the definition of <name> AS THAT BUILDER
# RESOLVES IT. Through tests/lib/opt-gate-source.sh when present: every
# scripts/*-lib.sh the builder sources, in source order, then the builder itself
# LAST, last definition winning — which is what bash does, and therefore the only
# reading of "what would run". The awk is the pre-library fallback and is
# deliberately the OLD one, so an old tree is measured the way it actually was.
_extract_fn() {
  if [ "${SELSVC_RESOLVER}" = "1" ]; then
    opt_gate_extract_fn "$1" "$2"
  else
    awk -v n="$2" 'index($0, n "() {")==1 {p=1} p{print} /^\}/{if(p){exit}}' "$1"
  fi
}
# _has_fn <builder> <name>
_has_fn() { [ -n "$(_extract_fn "$1" "$2")" ]; }
# _covered_slugs <builder> <fn> — the `for slug in …; do` list inside <fn>, as
# resolved. No early awk exit: an `exit` here would SIGPIPE the upstream stage
# and, under pipefail, a FOUND list would report failure. (The house trap.)
_covered_slugs() {
  _extract_fn "$1" "$2" | awk '
    /^[[:space:]]*for slug in / { if (!got) { sub(/^[[:space:]]*for slug in /, ""); sub(/;[[:space:]]*do[[:space:]]*$/, ""); s=$0; got=1 } }
    END { if (got) print s }'
}

# emit_resolved_gate <builder> <outfile> — every gate function the builder
# RESOLVES, each preceded by a `### <name>` marker. The static analyser reads
# THIS instead of re-implementing the resolver in python: one resolver, so the
# executed leg and the static leg cannot drift apart about what a builder runs.
emit_resolved_gate() {
  local b="$1" out="$2" fn
  : > "${out}"
  if [ "${SELSVC_RESOLVER}" = "1" ]; then
    while IFS= read -r fn; do
      [ -n "${fn}" ] || continue
      printf '### %s\n' "${fn}" >> "${out}"
      opt_gate_extract_fn "${b}" "${fn}" >> "${out}"
      printf '\n' >> "${out}"
    done < <(opt_gate_fn_names "${b}")
  else
    while IFS= read -r fn; do
      [ -n "${fn}" ] || continue
      printf '### %s\n' "${fn}" >> "${out}"
      _extract_fn "${b}" "${fn}" >> "${out}"
      printf '\n' >> "${out}"
    done < <(sed -e 's/#.*$//' "${b}" \
             | grep -oE '^[[:space:]]*(gate_optional_services|_opt_[a-z_]+)\(\)' \
             | grep -oE '(gate_optional_services|_opt_[a-z_]+)' | sort -u)
  fi
}

# =============================================================================
# STATIC ANALYSIS — checks A3, A4, B1-B3, C1-C7 and every V-* derivation.
# Everything here is parsed (YAML) or scanned on comment-stripped text; nothing
# is asserted from prose. Prints "  PASS|FAIL|UNVERIFIED <ID> <msg>" lines.
# =============================================================================
analyse_static() {  # $1 = root
  local root="$1" b
  local gd="${W}/gates.$$.${RANDOM}"; rm -rf "${gd}"; mkdir -p "${gd}"
  for b in "${root}"/build-*-stage4.sh; do
    [ -f "${b}" ] || continue
    emit_resolved_gate "${b}" "${gd}/$(basename "${b}").gate"
  done
  local so="${W}/static.$$.${RANDOM}"
  SELSVC_ANALYSE_ROOT="${root}" SELSVC_GATE_DIR="${gd}" python3 - >"${so}" 2>&1 <<'PY'
import os, re, sys, glob, fnmatch
import yaml

root = os.environ["SELSVC_ANALYSE_ROOT"]
GATE_DIR = os.environ["SELSVC_GATE_DIR"]
F = [0]

def ok(i, m):  print("  PASS %s %s" % (i, m))
def bad(i, m): print("  FAIL %s %s" % (i, m)); F[0] += 1
def unv(i, m): print("  UNVERIFIED %s %s" % (i, m))
def die(i, m):
    # A derivation came back EMPTY. Every check downstream of it would be an
    # assertion over an empty set — the vacuous pass this repo keeps shipping —
    # so stop here loudly instead of continuing green.
    print("  FAIL %s DERIVATION YIELDED ZERO ROWS: %s" % (i, m))
    print("       every check downstream of this derivation is UNRUN, not passed")
    print("-- static analysis stopped deliberately at a zero-row derivation --")
    sys.exit(2)

def P(*a): return os.path.join(root, *a)
def rd(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()
def ydocs(p):
    try:
        return [d for d in yaml.safe_load_all(rd(p)) if isinstance(d, dict)]
    except Exception:
        return []
def y1(p):
    d = ydocs(p)
    return d[0] if d else {}
def strip_sh(t):   return "\n".join("" if l.lstrip().startswith("#")  else l for l in t.split("\n"))
def strip_sql(t):  return "\n".join("" if l.lstrip().startswith("--") else l for l in t.split("\n"))

# ── THE SHELL READER — how B1, A4 and V10 read a script ────────────────────
# A filename literal near a `kubectl apply`, and a function NAME anywhere in a
# builder, are not measurements of what RUNS. Both were satisfiable by pure
# indirection, and both were measured green against planted defects on this very
# tree (see the notes on B1 and A4 below). This reader answers the two questions
# those checks actually need:
#   RESOLVE  what path does this statement act on, after variable expansion?
#   REACH    is it on the DEFAULT execution path — counting the guards around it
#            AND the guards around every call site of the function it lives in?
# Heredoc bodies and comments are removed before anything is read (so usage text
# cannot be evidence, and cannot invent an edge either), backslash continuations
# and multi-line `$( … )` are joined, and `${VAR}` is expanded from the
# assignments in the file — but never from a command substitution, so
# `${CLUSTER_DIR}` stays recognisable to norm_target instead of becoming noise.
# It is conservative in the RED direction: a script whose block structure it
# cannot parse is REPORTED by B1/A4, never assumed safe. Verified to parse both
# boot appliers and all three builders on this tree.
_HD = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
_ASSIGN = re.compile(r"^\s*(?:local\s+|export\s+|declare\s+(?:-\w+\s+)?|typeset\s+)?"
                     r"([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
_VARREF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)")
_DEFEQ = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]*)\}\"?\s*(=|==|!=)\s*\"?([^\"\s\]]+)")

_OPS3 = (";;&",)
_OPS2 = (";;", "&&", "||", ";&")
_OPS1 = (";", "|", "&", "(", ")")
_RESET = set([";", ";;", "&&", "||", "|", "&", "(", ")", "{", "}", ";&", ";;&",
              "then", "else", "elif", "do", "!", "time"])


def _first_word(rhs):
    out, q, i = [], None, 0
    while i < len(rhs):
        c = rhs[i]
        if q:
            if c == q:
                q = None
            else:
                out.append(c)
        elif c in "\"'":
            q = c
        elif c.isspace():
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def lex(t):
    """Shell words + operator tokens. $( ), ${ }, ` ` and quotes are opaque."""
    toks, buf, i, n = [], "", 0, len(t)
    def flush():
        nonlocal buf
        if buf:
            toks.append(buf); buf = ""
    while i < n:
        c = t[i]
        if c in "\"'":
            q = c; buf += c; i += 1
            while i < n:
                buf += t[i]
                if t[i] == q and (q == "'" or t[i - 1] != "\\"):
                    i += 1; break
                i += 1
            continue
        if c == "\\" and i + 1 < n:
            buf += t[i:i + 2]; i += 2; continue
        if c == "$" and i + 1 < n and t[i + 1] in "({":
            close = ")" if t[i + 1] == "(" else "}"
            open_ = t[i + 1]
            d = 0; buf += t[i:i + 2]; i += 2; d = 1
            while i < n and d:
                if t[i] == open_: d += 1
                elif t[i] == close: d -= 1
                buf += t[i]; i += 1
            continue
        if c == "`":
            buf += c; i += 1
            while i < n and t[i] != "`":
                buf += t[i]; i += 1
            if i < n:
                buf += t[i]; i += 1
            continue
        if c == "#" and not buf:
            break                      # a `#` in WORD position starts a comment
        if c.isspace():
            flush(); i += 1; continue
        hit = None
        for grp in (_OPS3, _OPS2, _OPS1):
            for op in grp:
                if t.startswith(op, i):
                    hit = op; break
            if hit: break
        if hit:
            flush(); toks.append(hit); i += len(hit); continue
        buf += c; i += 1
    flush()
    return toks



def _scan_state(t, st):
    """Carry quote / $( ) / backtick state across physical lines."""
    q, depth, bt = st
    i, n = 0, len(t)
    prev = " "
    while i < n:
        c = t[i]
        if q:
            if c == "\\" and q == '"' and i + 1 < n:
                i += 2; prev = " "; continue
            if c == q:
                q = None
            i += 1; prev = c; continue
        if bt:
            if c == "`":
                bt = False
            i += 1; prev = c; continue
        if c == "\\" and i + 1 < n:
            i += 2; prev = " "; continue
        if c in "\"'":
            q = c; i += 1; prev = c; continue
        if c == "`":
            bt = True; i += 1; prev = c; continue
        if c == "$" and i + 1 < n and t[i + 1] == "(":
            depth += 1; i += 2; prev = "("; continue
        if depth and c == "(":
            depth += 1; i += 1; prev = c; continue
        if depth and c == ")":
            depth -= 1; i += 1; prev = c; continue
        if c == "#" and (prev.isspace() or prev in ";|&(") and depth == 0:
            break
        i += 1; prev = c
    return (q, depth, bt)


class ShellFile(object):
    def __init__(self, text):
        self.balanced = True
        self.unbalanced = ""
        self.lls = self._logical(text)
        self.assigns = self._collect_assigns()
        self.ctx, self.funcs, self.loops = self._walk()

    def _logical(self, text):
        lines = text.split("\n")
        clean, term = [], None
        for l in lines:
            if term is not None:
                if l.strip() == term:
                    term = None
                clean.append("")
                continue
            if l.lstrip().startswith("#"):
                clean.append("")
                continue
            m = _HD.search(l)
            if m:
                term = m.group(2)
                clean.append(l[:m.start()])
                continue
            clean.append(l)
        if term is not None:
            self.balanced = False
            self.unbalanced = "unterminated heredoc <<%s" % term
        # Join what bash joins: backslash continuations AND any line that ends
        # with an open quote, `$( … )` or backtick. A `while … done` inside a
        # multi-line command substitution is ONE statement; reading it as three
        # lines made the block structure unbalanced and this reader blind.
        out, buf, start, st = [], None, None, (None, 0, False)
        for n, l in enumerate(clean, 1):
            if buf is None:
                start, buf, st = n, l, _scan_state(l, (None, 0, False))
            else:
                buf = buf + " " + l.strip()
                st = _scan_state(l.strip(), st)
            if buf.rstrip().endswith("\\"):
                buf = buf.rstrip()[:-1]
                continue
            if st[0] or st[1] or st[2]:
                continue
            out.append((start, buf)); buf = None; st = (None, 0, False)
        if buf is not None:
            out.append((start, buf))
        return out

    def _collect_assigns(self):
        a = {}
        for _n, t in self.lls:
            m = _ASSIGN.match(t)
            if not m:
                continue
            rhs = _first_word(m.group(2))
            if "$(" in rhs or "`" in rhs:
                continue
            # `X="${X:-default}"` (or :=) is bash's "unless the caller set it"
            # idiom, and bootstrap.sh uses it eight times. Read it as bash does
            # on that line: X IS the default. Left as the literal `${X:-…}`,
            # expanding `${X}` re-inserts the self-reference, and when the default
            # nests another `${VAR}` the text GROWS for eight rounds instead of
            # resolving — so a root apply whose target was bound this way expanded
            # to garbage, matched no leaf, and left B1 green. Measured while
            # carrying V3 onto main (mutation M5 of the battery); NC12f.
            sm = re.match(r"^\$\{%s:[-=](.*)\}$" % re.escape(m.group(1)), rhs)
            if sm:
                rhs = sm.group(1)
            a.setdefault(m.group(1), rhs)
        return a

    def expand(self, text, rounds=8):
        for _ in range(rounds):
            def rep(m):
                name = m.group(1) or m.group(3)
                if name in self.assigns:
                    return self.assigns[name]
                if m.group(2) is not None:
                    return m.group(2)
                return m.group(0)
            new = _VARREF.sub(rep, text)
            if new == text:
                break
            text = new
        return text

    def _fail(self, n, msg):
        if self.balanced:
            self.balanced = False
            self.unbalanced = "line %d: %s" % (n, msg)

    def _walk(self):
        stack, ctx, funcs, loops = [], [], {}, {}
        pend = None          # accumulating an if/elif condition until `then`
        for i, (n, raw) in enumerate(self.lls):
            cur_func = None
            for e in stack:
                if e[0] == "func":
                    cur_func = e[1]
            ctx.append((cur_func, [e for e in stack if e[0] in ("if", "casearm")]))
            toks = lex(raw)
            cmdpos = True
            j = 0
            while j < len(toks):
                w = toks[j]
                if pend is not None and w != "then":
                    pend.append(w); j += 1; continue
                if w == "then":
                    if pend is not None:
                        for k in range(len(stack) - 1, -1, -1):
                            if stack[k][0] == "if":
                                stack[k] = ("if", " ".join(pend), stack[k][2]); break
                        pend = None
                    cmdpos = True; j += 1; continue
                if not cmdpos:
                    if w in _RESET:
                        cmdpos = True
                    j += 1
                    continue
                top0 = stack[-1][0] if stack else ""
                if top0 == "casearm" and w in (";;", ";;&", ";&"):
                    stack.pop(); j += 1; cmdpos = True; continue
                if w in (";", ";;", ";&", ";;&", "&&", "||", "|", "&", "!", "time"):
                    j += 1; cmdpos = True; continue
                if w == "if":
                    stack.append(("if", "", "if")); pend = []; j += 1; continue
                if w == "elif":
                    for k in range(len(stack) - 1, -1, -1):
                        if stack[k][0] == "if":
                            stack[k] = ("if", stack[k][1], "elif"); break
                    else:
                        self._fail(n, "`elif` with no open `if`")
                    pend = []; j += 1; continue
                if w == "else":
                    for k in range(len(stack) - 1, -1, -1):
                        if stack[k][0] == "if":
                            stack[k] = ("if", stack[k][1], "else"); break
                    else:
                        self._fail(n, "`else` with no open `if`")
                    j += 1; cmdpos = True; continue
                if w == "fi":
                    if stack and stack[-1][0] == "if":
                        stack.pop()
                    else:
                        self._fail(n, "`fi` with no open `if`")
                    j += 1; cmdpos = True; continue
                if w in ("for", "while", "until", "select"):
                    stack.append(("loop", i)); j += 1; cmdpos = False; continue
                if w == "do":
                    j += 1; cmdpos = True; continue
                if w == "done":
                    if stack and stack[-1][0] == "loop":
                        loops[stack[-1][1]] = i
                        stack.pop()
                    else:
                        self._fail(n, "`done` with no open loop")
                    j += 1; cmdpos = True; continue
                if w == "case":
                    stack.append(("case",)); j += 1; cmdpos = False; continue
                if w == "esac":
                    if stack and stack[-1][0] == "casearm":
                        stack.pop()
                    if stack and stack[-1][0] == "case":
                        stack.pop()
                    else:
                        self._fail(n, "`esac` with no open case")
                    j += 1; cmdpos = True; continue
                if w == "{":
                    stack.append(("brace",)); j += 1; continue
                if w == "}":
                    if stack and stack[-1][0] in ("brace", "func"):
                        e = stack.pop()
                        if e[0] == "func":
                            funcs[e[1]][1] = i
                    else:
                        self._fail(n, "`}` with no open block")
                    j += 1; cmdpos = True; continue
                # a case ARM pattern:  pat|pat)   — only while a case is open and
                # no arm body is running.
                top = stack[-1] if stack else ("", )
                if top[0] == "case":
                    k = j
                    while k < len(toks) and toks[k] != ")":
                        if toks[k] in (";;", ";;&", ";&"):
                            break
                        k += 1
                    if k < len(toks) and toks[k] == ")":
                        stack.append(("casearm", " ".join(toks[j:k]), "case"))
                        j = k + 1; cmdpos = True; continue
                if top[0] == "casearm" and w in (";;", ";;&", ";&"):
                    stack.pop(); j += 1; cmdpos = True; continue
                # function definition:  NAME ( )  {      or  function NAME {
                if w == "function" and j + 1 < len(toks):
                    name = toks[j + 1]
                    stack.append(("func", name, i)); funcs.setdefault(name, [i, len(self.lls) - 1])
                    ctx[-1] = (name, ctx[-1][1])
                    j += 2
                    if j < len(toks) and toks[j] == "{":
                        j += 1
                    cmdpos = True; continue
                if (j + 2 < len(toks) and toks[j + 1] == "(" and toks[j + 2] == ")"
                        and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", w)):
                    stack.append(("func", w, i)); funcs.setdefault(w, [i, len(self.lls) - 1])
                    ctx[-1] = (w, ctx[-1][1])
                    j += 3
                    if j < len(toks) and toks[j] == "{":
                        j += 1
                    elif j < len(toks) and toks[j] == "(":
                        stack[-1] = ("func", w, i)   # subshell body; treat `)` as its close
                        j += 1
                    cmdpos = True; continue
                cmdpos = False
                j += 1
            # a `;;` that ends an arm may sit alone; handled above
        if stack:
            self._fail(self.lls[-1][0] if self.lls else 0, "unclosed %s at EOF" % stack[-1][0])
        return ctx, funcs, loops

    def guard_verdict(self, g):
        if g[0] == "casearm":
            return "unknown"
        cond, branch = g[1], g[2]
        m = _DEFEQ.search(cond)
        if not m or branch == "elif":
            return "unknown"
        eq = (m.group(2).strip() == m.group(4).strip())
        if m.group(3) == "!=":
            eq = not eq
        if branch == "if":
            return "taken" if eq else "not-taken"
        return "not-taken" if eq else "taken"

    def _stack_verdict(self, guards):
        vs = [self.guard_verdict(g) for g in guards]
        if any(v == "not-taken" for v in vs):
            return "not-taken"
        if all(v == "taken" for v in vs):
            return "taken"
        return "unknown"

    def call_sites(self, name):
        rng = self.funcs.get(name)
        out = []
        for i, (_n, t) in enumerate(self.lls):
            if rng and rng[0] <= i <= rng[1]:
                continue
            toks = lex(t)
            for j, w in enumerate(toks):
                if w != name:
                    continue
                if j + 2 < len(toks) and toks[j + 1] == "(" and toks[j + 2] == ")":
                    continue
                out.append(i); break
        return out

    def reachability(self, idx, _seen=None):
        if _seen is None:
            _seen = frozenset()
        func, guards = self.ctx[idx]
        here = self._stack_verdict(guards)
        if func is None:
            return here, ["line %d" % self.lls[idx][0]]
        if func in _seen:
            return "unknown", ["%s() at line %d (recursive)" % (func, self.lls[idx][0])]
        _seen = _seen | {func}
        sites = self.call_sites(func)
        if not sites:
            return "unreferenced", ["%s() at line %d" % (func, self.lls[idx][0])]
        best, why = "not-taken", []
        for s in sites:
            v, w = self.reachability(s, _seen)
            chain = ["%s() at line %d, called from line %d" % (func, self.lls[idx][0], self.lls[s][0])] + w
            if here == "not-taken" or v in ("not-taken", "unreferenced"):
                comb = "not-taken"
            elif here == "taken" and v == "taken":
                comb = "taken"
            else:
                comb = "unknown"
            if comb == "taken":
                return "taken", chain
            if comb == "unknown" and best != "taken":
                best, why = "unknown", chain
        return best, (why or ["%s() at line %d" % (func, self.lls[idx][0])])

# gate_sections(builder_basename) -> {fn_name: comment-stripped body}
# Read from what BASH would resolve (emit_resolved_gate), never re-derived here.
def gate_sections(bn):
    p = os.path.join(GATE_DIR, bn + ".gate")
    out = {}
    if not os.path.exists(p):
        return out
    cur = None
    for line in rd(p).split("\n"):
        if line.startswith("### "):
            cur = line[4:].strip(); out.setdefault(cur, [])
            continue
        if cur is not None:
            out[cur].append(line)
    return {k: strip_sh("\n".join(v)) for k, v in out.items()}

# ─────────────────────────── DERIVATIONS ────────────────────────────────────
print("-- derivations (each ABORTS the run if it yields zero rows) --")

# V1 registry
reg_p = P("specs", "cluster", "optional-services.yaml")
reg = y1(reg_p)
services = [s for s in ((reg.get("spec") or {}).get("services") or []) if s.get("slug")]
if not services:
    die("V1", "specs/cluster/optional-services.yaml spec.services[].slug")
reg_slugs = [s["slug"] for s in services]
print("         V1 registry services                     : %d" % len(reg_slugs))

# V2 install-state artefacts, discovered STRUCTURALLY: a file qualifies because of
# what it IS (the installed-services ConfigMap / an OptionalService CR / an
# ApplicationSet whose list elements carry an `installed` flag), never because it is
# named here. A fourth artefact added tomorrow is picked up without editing this file.
arte = {"configmap": [], "optionalservice-seed": [], "appset": []}
for base in ("specs/cluster/apps", "specs/cluster/manifests"):
    for dp, _, fns in os.walk(P(base)):
        for fn in sorted(fns):
            if not fn.endswith((".yaml", ".yml")):
                continue
            p = os.path.join(dp, fn); rel = os.path.relpath(p, root)
            for doc in ydocs(p):
                k = doc.get("kind"); md = doc.get("metadata") or {}
                if k == "ConfigMap" and md.get("name") == "installed-services":
                    arte["configmap"].append(rel)
                elif k == "OptionalService":
                    if rel not in arte["optionalservice-seed"]:
                        arte["optionalservice-seed"].append(rel)
                elif k == "ApplicationSet":
                    # Keyed on the ELEMENTS carrying an `installed` flag, NOT on the
                    # selector: keying on the selector would make deleting the selector
                    # (exactly the defect C1 exists to catch) blind this derivation
                    # instead of failing that check. NC1 proves the difference.
                    for g in ((doc.get("spec") or {}).get("generators") or []):
                        els = ((g or {}).get("list") or {}).get("elements") or []
                        if any(isinstance(e, dict) and "installed" in e for e in els):
                            if rel not in arte["appset"]:
                                arte["appset"].append(rel)
for k in ("configmap", "optionalservice-seed", "appset"):
    if not arte[k]:
        die("V2", "no install-state artefact of kind '%s' found under specs/cluster" % k)
print("         V2 install-state artefacts                : cm=%d seed=%d appset=%d"
      % (len(arte["configmap"]), len(arte["optionalservice-seed"]), len(arte["appset"])))

# V5 CRD slug enum (the set a superadmin can address as an OptionalService CR)
crd_enum = []
crd_p = None
for dp, _, fns in os.walk(P("specs/cluster/manifests")):
    for fn in fns:
        if not fn.endswith((".yaml", ".yml")):
            continue
        p = os.path.join(dp, fn)
        for doc in ydocs(p):
            if doc.get("kind") != "CustomResourceDefinition":
                continue
            if (doc.get("spec") or {}).get("names", {}).get("kind") != "OptionalService":
                continue
            crd_p = os.path.relpath(p, root)
            for v in ((doc.get("spec") or {}).get("versions") or []):
                sch = (((v.get("schema") or {}).get("openAPIV3Schema") or {}).get("properties") or {})
                e = (((sch.get("spec") or {}).get("properties") or {}).get("slug") or {}).get("enum")
                if e:
                    crd_enum = list(e)
if not crd_enum:
    die("V5", "OptionalService CRD spec.slug enum")
print("         V5 CRD slug enum                          : %d (%s)" % (len(crd_enum), crd_p))

# V3 the TARGET ApplicationSet: the discovered install-state appset whose element
# slugs cover the CRD enum. Structural, so deleting the ignoreDifferences seam
# (a defect C2 must REPORT) cannot silently remove the target.
target_appset = None; target_elems = []; target_doc = None
for rel in arte["appset"]:
    for doc in ydocs(P(rel)):
        if doc.get("kind") != "ApplicationSet":
            continue
        els = []
        for g in ((doc.get("spec") or {}).get("generators") or []):
            els += list(((g or {}).get("list") or {}).get("elements") or [])
        slugs = {e.get("slug") for e in els if isinstance(e, dict)}
        if slugs and set(crd_enum) & slugs == set(crd_enum):
            target_appset, target_elems, target_doc = rel, els, doc
if not target_elems:
    die("V3", "no install-state ApplicationSet whose elements cover the CRD slug enum")
elem_slugs = [e["slug"] for e in target_elems if isinstance(e, dict) and e.get("slug")]
elem_by_slug = {e["slug"]: e for e in target_elems if isinstance(e, dict) and e.get("slug")}
print("         V3 target ApplicationSet elements         : %d (%s)" % (len(elem_slugs), target_appset))

# V4 installed-services ConfigMap boolean keys
cm_rel = arte["configmap"][0]
cm_doc = None
for doc in ydocs(P(cm_rel)):
    if doc.get("kind") == "ConfigMap":
        cm_doc = doc
cm_bools = {k: v for k, v in ((cm_doc or {}).get("data") or {}).items() if v in ("true", "false")}
if not cm_bools:
    die("V4", "installed-services ConfigMap boolean data keys")
print("         V4 ConfigMap install-state booleans       : %d" % len(cm_bools))

# V6 seed OptionalService CRs
seed_rel = arte["optionalservice-seed"][0]
seed_crs = {}
for doc in ydocs(P(seed_rel)):
    if doc.get("kind") == "OptionalService":
        sp = doc.get("spec") or {}
        if sp.get("slug"):
            seed_crs[sp["slug"]] = bool(sp.get("enabled"))
if not seed_crs:
    die("V6", "seed OptionalService CRs")
print("         V6 seed OptionalService CRs               : %d" % len(seed_crs))

# V8/V9 builders
builders = sorted(glob.glob(P("build-*-stage4.sh")))
if not builders:
    die("V8", "build-*-stage4.sh")
sel_builders = [b for b in builders
                if re.search(r"(?m)^[ \t]*--optional-services\)", strip_sh(rd(b)))]
if not sel_builders:
    die("V9", "builders that parse --optional-services")
print("         V8 builders / V9 selection-aware          : %d / %d (%s)"
      % (len(builders), len(sel_builders), ", ".join(os.path.basename(b) for b in sel_builders)))

# ── V10 what the DEVICE applies at boot ─────────────────────────────────────
# Read through the ShellFile reader above, so this derivation sees what BASH
# sees: heredoc bodies and comments gone, continuations and multi-line command
# substitutions joined, variables EXPANDED, and every apply carrying the
# reachability verdict of the statement it lives on. V1 scanned raw lines for a
# literal `kubectl apply -f <path>`; V2 added the indirect for-loop form. Both
# still read the TEXT of a target rather than its VALUE, so `local f=…; kubectl
# apply -f "${f}"` resolved to the string `${f}` and landed in this set as a
# path that does not exist.
BOOT_CANDIDATES = [P("specs/cluster/bootstrap/bootstrap.sh")] + \
    sorted(glob.glob(P("specs/cluster/bootstrap/*.sh"))) + \
    sorted(glob.glob(P("specs/etc/**/*.sh"), recursive=True)) + \
    sorted(glob.glob(P("specs/etc/**/*.start*"), recursive=True))
applier_files, SF = [], {}
for cand in BOOT_CANDIDATES:
    if not os.path.isfile(cand) or cand in applier_files:
        continue
    sf = ShellFile(rd(cand))
    if any("kubectl" in t and "apply" in t for _n, t in sf.lls):
        applier_files.append(cand); SF[cand] = sf
if not applier_files:
    die("V10", "boot scripts that run `kubectl apply`")

def norm_target(t):
    # Quotes come off LAST. `"${CLUSTER_DIR}"/apps/*.yaml` is one shell word with a
    # quote in the MIDDLE; stripping the outer quotes first (what this did) left a
    # leading `"` welded to the path, and every downstream comparison then missed —
    # B1 went red against the very fix it was re-authored to recognise.
    t = t.strip()
    t = t.replace("${CLUSTER_DIR}", "").replace("$CLUSTER_DIR", "")
    t = t.replace('"', "").replace("'", "")
    if "var/lib/hugmesh/cluster/" in t:
        t = t.split("var/lib/hugmesh/cluster/", 1)[1]
    return t.strip("/")

def applier_fns(sf):
    """Function names whose own body runs `kubectl apply`."""
    out = set()
    for name, (a, b) in sf.funcs.items():
        body = "\n".join(t for _n, t in sf.lls[a:b + 1])
        if "kubectl" in body and "apply" in body:
            out.add(name)
    return out

# A statement behind a proven default-OFF switch is NOT what a device applies, and
# a statement inside a function nothing calls is not applied at all. Both are
# excluded here and REPORTED by B1 instead — this set is "what a default boot
# does", which is the only thing B2 may reason from.
LIVE = ("taken", "unknown")
tgt_re = re.compile(r"-([fk])\s+(\S+)")
applied, apply_stmts = set(), []
for af in applier_files:
    sf = SF[af]
    fns = applier_fns(sf)
    forre = re.compile(r"^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+?);\s*do\b")
    for i, (n, t) in enumerate(sf.lls):
        exp = sf.expand(t)
        # (a) the DIRECT form: kubectl apply -f/-k <target>
        if "kubectl" in t and "apply" in t:
            reach = sf.reachability(i)[0]
            apply_stmts.append((af, i, n, exp, reach))
            if reach in LIVE:
                for _flag, tgt in tgt_re.findall(exp):
                    tt = norm_target(tgt)
                    if tt and tt != "-" and "$" not in tt:
                        applied.add(tt)
        # (b) the INDIRECT form: for VAR in <CLUSTER_DIR-rooted glob>; do … fn "${VAR}" … done
        m = forre.match(t)
        if not m:
            continue
        var, words = m.group(1), m.group(2)
        cands = [w for w in words.split()
                 if "CLUSTER_DIR" in w or "var/lib/hugmesh/cluster" in w]
        if not cands or i not in sf.loops:
            continue
        btxt = "\n".join(x for _y, x in sf.lls[i + 1:sf.loops[i] + 1])
        used = any(re.search(r"(^|\s|\()%s\s+\"?\$\{?%s\}?\"?" % (re.escape(fn), re.escape(var)), btxt)
                   for fn in fns) or ("kubectl" in btxt and "apply" in btxt)
        if not used or sf.reachability(i)[0] not in LIVE:
            continue
        for w in cands:
            tt = norm_target(w)
            if tt and tt != "-":
                applied.add(tt)
if not applied:
    die("V10", "kubectl apply targets inside the boot scripts")
print("         V10 boot-applied targets                  : %d (%s)"
      % (len(applied), ", ".join(sorted(applied))))

# V13 the repo-recursing ROOTS: every file in the baked tree that carries an
# Application which re-imports the repo's own apps/ directory. DERIVED (source.path
# == the root app's own path), never a filename literal — B1 used to key on the
# string "app-of-apps.yaml", so renaming the file, or reaching it through a
# variable, walked straight past the check.
root_app = y1(P("specs", "cluster", "app-of-apps.yaml"))
rsrc = (root_app.get("spec") or {}).get("source") or {}
root_app_files = []
for p in [P("specs/cluster/app-of-apps.yaml")] + sorted(glob.glob(P("specs/cluster/apps/*.yaml"))):
    for doc in ydocs(p):
        if doc.get("kind") == "Application" and \
           ((doc.get("spec") or {}).get("source") or {}).get("path") == rsrc.get("path"):
            root_app_files.append((os.path.relpath(p, root), doc))
if not root_app_files:
    die("V13", "Applications whose source.path re-imports the repo's own apps/ directory")
recursing_leaves = sorted({rel.split("specs/cluster/", 1)[-1] for rel, _d in root_app_files})
print("         V13 repo-recursing root manifests         : %d (%s)"
      % (len(recursing_leaves), ", ".join(recursing_leaves)))

# V11 the Applications each optional service OWNS, per the registry
owned = []   # (slug, repo-relative path)
for s in services:
    for a in (s.get("apps") or []):
        owned.append((s["slug"], os.path.join("specs", "cluster", a)))
if not owned:
    die("V11", "registry spec.services[].apps[]")
print("         V11 registry-owned Applications           : %d across %d slug(s)"
      % (len(owned), len({s for s, _ in owned})))

# V7 apps/16 ignoreDifferences /data pointers over the ConfigMap
cm_name = ((cm_doc or {}).get("metadata") or {}).get("name")
cm_ign_ptrs, cm_ign_app = [], None
for p in sorted(glob.glob(P("specs/cluster/apps/*.yaml"))):
    for doc in ydocs(p):
        if doc.get("kind") != "Application":
            continue
        for ig in ((doc.get("spec") or {}).get("ignoreDifferences") or []):
            if ig.get("kind") == "ConfigMap" and ig.get("name") == cm_name:
                cm_ign_ptrs += list(ig.get("jsonPointers") or [])
                cm_ign_app = os.path.relpath(p, root)
if not cm_ign_ptrs:
    die("V7", "ignoreDifferences jsonPointers over the installed-services ConfigMap")
print("         V7 ConfigMap ignoreDifferences pointers   : %d (%s)" % (len(cm_ign_ptrs), cm_ign_app))

# V12 the build-time-gated slug set, DECLARED by the registry (buildGate[]), and
# the Applications each such slug owns. This is what B4 executes against.
gated_owned = {}
for s in services:
    if s.get("buildGate") and s.get("apps"):
        gated_owned[s["slug"]] = list(s["apps"])
if not gated_owned:
    die("V12", "registry services with a non-empty buildGate[] AND apps[]")
print("         V12 build-gated slugs owning Applications : %d (%d file(s))"
      % (len(gated_owned), sum(len(v) for v in gated_owned.values())))
print()
# ───────────────── A) BUILD TIME (static half; A1/A2 are EXECUTED) ──────────
print("-- A) build time: the selection is rendered into the baked tree --")

# A3 — the selection-aware builders must render the SAME install-state artefacts.
# Membership is decided by the SYSROOT path literals inside each builder's
# RESOLVED _opt_render_* / _opt_set_* function bodies, never by a text scan of the
# file. Today both builders resolve scripts/_optional-services-lib.sh, so parity is
# STRUCTURAL — which is the fix, not the absence of a check: re-add a builder-local
# override that renders less and the override is what bash runs, what this reads,
# and what goes red. NC9 plants exactly that, with prose on top.
def rendered_artefacts(bpath):
    secs = gate_sections(os.path.basename(bpath))
    body = "\n".join(v for k, v in secs.items()
                     if re.match(r"^_opt_(render|set)_[a-z_]+$", k))
    hits = set()
    for kind, rels in arte.items():
        for rel in rels:
            leaf = rel.split("specs/cluster/", 1)[-1]
            if leaf in body:
                hits.add(leaf)
    return hits

rend = {os.path.basename(b): rendered_artefacts(b) for b in sel_builders}
union = set()
for v in rend.values():
    union |= v
if not union:
    die("A3", "no builder renders ANY discovered install-state artefact "
              "(resolved through %s)" % ("tests/lib/opt-gate-source.sh"
                                         if os.path.exists(P("tests/lib/opt-gate-source.sh"))
                                         else "the single-file fallback"))
gaps = {b: sorted(union - v) for b, v in rend.items() if union - v}
if gaps:
    bad("A3", "selection-aware builders disagree on which install-state artefacts they render:")
    for b in sorted(rend):
        print("         %-28s renders %s" % (b, ", ".join(sorted(rend[b])) or "NOTHING"))
    for b, g in sorted(gaps.items()):
        print("         %s never writes: %s" % (b, ", ".join(g)))
    print("         => an image from that builder ships the artefact at its GIT baseline,")
    print("            so the operator's selection is absent from that half of the channel.")
else:
    ok("A3", "all %d selection-aware builder(s) resolve the same %d install-state "
             "artefact renderer(s): %s" % (len(rend), len(union), ", ".join(sorted(union))))

# A4 — every builder that BAKES the cluster tree must gate it, REACHABLY and in
# ORDER. A builder that copies specs/cluster into the sysroot without actually
# running gate_optional_services ships every optional service's Application
# unpruned, whatever the operator selected — and since PR #183 that baked tree is
# EXACTLY what the device applies, so an ungated baker is not a latent gap, it is
# the deployed set.
#
# ── WHY THIS IS NO LONGER A NAME SCAN (V3, 2026-08-27) ──────────────────────
# V2 asked one question: does a line-anchored `gate_optional_services` appear
# anywhere in the file? That is satisfiable by a builder that gates NOTHING, and
# on this very tree it already was — TWICE, measured:
#   * build-x86-host-stage4.sh names the gate at line 635, inside `usage()`'s
#     `cat <<EOF` help text. Delete the REAL call at line 4075 and A4 stayed
#     GREEN for x86, satisfied by usage prose.
#   * dropping this into build-jetson-stage4.sh turned A4 fully green:
#         _selected_services_note() {
#             gate_optional_services
#         }
#     — a function nothing calls, naming the gate at the start of a line.
# So A4 now requires four things of every baker, all read through the ShellFile
# reader (heredocs and comments removed, so help text is not evidence):
#   1. it RESOLVES gate_optional_services through the real source chain
#      (tests/lib/opt-gate-source.sh), i.e. bash would find a definition;
#   2. it PARSES --optional-services, or the gate can never be told what to keep;
#   3. the CALL is REACHABLE — top level, or inside a function that is called;
#   4. the call is ORDERED with the bake: same enclosing function, same guard
#      stack, and AFTER the copy — the gate prunes ${SYSROOT}/var/lib/hugmesh/
#      cluster, so a call before the copy prunes a directory that does not exist
#      yet and a call under a different condition does not run when the bake does.
def _has_gate_fn(bn):
    """Does bash resolve a gate_optional_services BODY for this builder?"""
    return bool((gate_sections(bn) or {}).get("gate_optional_services", "").strip())

BAKE_CMDS = ("cp", "rsync", "install", "mv", "tar", "cpio")
bakers, a4 = [], []
for b in builders:
    bn = os.path.basename(b)
    raw = rd(b)
    # Cheap pre-filter: a builder that never names the baked cluster path cannot be
    # a baker, and parsing ten stage4 scripts to find that out costs seconds. The
    # filter is a SUPERSET (a comment naming the path still gets parsed), so it can
    # only add work, never hide a baker.
    if "var/lib/hugmesh/cluster" not in raw:
        continue
    sf = ShellFile(raw)
    bakes = []
    for i, (n, t) in enumerate(sf.lls):
        toks = lex(t)
        if toks and toks[0] in BAKE_CMDS and "var/lib/hugmesh/cluster" in sf.expand(t):
            bakes.append((i, n))
    if not bakes:
        continue
    bakers.append(bn)
    if not sf.balanced:
        a4.append("%s: this guard cannot parse the builder's block structure (%s), so it "
                  "cannot prove the gate runs — an unreadable baker is not a gated one"
                  % (bn, sf.unbalanced))
        continue
    if not _has_gate_fn(bn):
        a4.append("%s bakes the cluster tree but RESOLVES no gate_optional_services at all "
                  "(source chain: %s) — there is no gate for it to call"
                  % (bn, "tests/lib/opt-gate-source.sh"
                     if os.path.exists(P("tests/lib/opt-gate-source.sh")) else "the single-file fallback"))
        continue
    if not re.search(r"(?m)^[ \t]*--optional-services\)", "\n".join(t for _n, t in sf.lls)):
        a4.append("%s bakes the cluster tree and resolves the gate, but parses no "
                  "--optional-services argument — the gate can never be told what to keep"
                  % bn)
        continue
    calls = []
    for i, (n, t) in enumerate(sf.lls):
        toks = lex(t)
        if toks and toks[0] == "gate_optional_services":
            calls.append((i, n, sf.reachability(i)))
    if not calls:
        a4.append("%s bakes the cluster tree with NO gate_optional_services call "
                  "(the name appears in the file only inside comments or heredocs, "
                  "which this guard removes before reading)" % bn)
        continue
    live = [(i, n, v) for i, n, (v, _w) in calls if v in LIVE]
    if not live:
        a4.append("%s names gate_optional_services at line(s) %s but NONE of those calls is "
                  "reachable (%s) — a call inside a function nothing invokes, or behind a "
                  "switch that is off by default, gates nothing"
                  % (bn, ", ".join(str(n) for _i, n, _v in calls),
                     ", ".join(sorted({v for _i, _n, (v, _w) in calls}))))
        continue
    ordered = []
    for bi, bl in bakes:
        for ci, cl, _v in live:
            if sf.ctx[ci][0] == sf.ctx[bi][0] and sf.ctx[ci][1] == sf.ctx[bi][1] and ci > bi:
                ordered.append((bl, cl)); break
    if len(ordered) != len(bakes):
        got = {b for b, _c in ordered}
        a4.append("%s bakes the cluster tree at line(s) %s and the reachable gate call(s) at "
                  "%s do not run after it on the same path (same enclosing function, same "
                  "guard stack, later line) — %s left ungated"
                  % (bn, ", ".join(str(n) for _i, n in bakes),
                     ", ".join(str(n) for _i, n, _v in live),
                     ", ".join(str(n) for _i, n in bakes if n not in got)))
if not bakers:
    die("A4", "builders that bake ${SYSROOT}/var/lib/hugmesh/cluster")
if a4:
    bad("A4", "%d builder(s) bake the cluster GitOps tree without a gate that RUNS:" % len(a4))
    for m in a4:
        print("         %s" % m)
    print("         (bakers: %s)" % ", ".join(bakers))
    print("         => every optional service's Application/manifests are baked in full,")
    print("            and bootstrap.sh applies that baked tree verbatim, so the image")
    print("            DEPLOYS every optional service whatever the operator selected.")
    print("         GREEN WHEN: the builder sources scripts/_optional-services-lib.sh,")
    print("            parses --optional-services, and CALLS gate_optional_services on a")
    print("            reachable path, after the copy and under the same condition.")
else:
    ok("A4", "all %d builder(s) that bake the cluster tree resolve the gate, parse "
             "--optional-services, and call gate_optional_services reachably after the "
             "copy: %s" % (len(bakers), ", ".join(bakers)))
print()

# ───────────────── B) BOOT: does the selection reach the cluster ────────────
print("-- B) boot: does the build-time selection reach a running cluster --")

# B1 — THE BOOT TOPOLOGY.
#   (i)   some boot script applies the baked apps/ tree, and
#   (ii)  every apply of a repo-recursing root is behind a switch this guard can
#         PROVE is default-off, and
#   (iii) a glob/directory apply that COVERS a recursing root counts as applying
#         it unless the loop demonstrably skips it by name.
#
# ── WHY IT WAS RE-AUTHORED AGAIN (V3, 2026-08-27) ───────────────────────────
# V2's (ii) was DECORATIVE. It looked only at lines containing the literal string
# "app-of-apps.yaml" that ALSO had "kubectl apply" within ±3 lines, and then
# searched BACKWARDS up to 60 lines for an `if`. Every part of that is defeated by
# ordinary shell. Measured, on a sandbox copy of this tree:
#
#     apply_root_app_of_apps() {
#         local f="${CLUSTER_DIR}/app-of-apps.yaml"     <- the literal lives HERE
#         [ -f "${f}" ] || return 0
#         log …; log …; local tries=0
#         kubectl apply -f "${f}" || return 1           <- 6 lines later: outside ±3
#     }
#     apply_root_app_of_apps                            <- no switch, no guard
#
# — B1 reported PASS. The check that exists to catch precisely "a device syncs
# apps/ from git and every build-time prune is bypassed" could not see an
# UNCONDITIONAL apply of the repo-recursing root.
#
# It now reads through the ShellFile reader: the target is EXPANDED (so a variable
# is followed to its value), the statement's reachability counts the guards around
# it AND the guards around every call site of the function it lives in (so an
# unconditional call of a guarded-looking helper is `taken`), and the root set is
# DERIVED from source.path (so renaming the file changes nothing). Anything the
# reader cannot prove default-off is REPORTED, never assumed safe — including a
# boot script whose block structure it cannot parse at all.
b1 = []
apps_applied = sorted(t for t in applied if t == "apps" or t.startswith("apps/"))
if not apps_applied:
    b1.append("no boot script applies ${CLUSTER_DIR}/apps — the baked, gated "
              "Application tree is never read (boot appliers scanned: %s)"
              % ", ".join(os.path.relpath(a, root) for a in applier_files))

def leaf_in(text, leaf):
    return re.search(r"(^|[/\"'\s=])%s(\s|\"|'|$|\))" % re.escape(leaf), text) is not None

for af in applier_files:
    sf, rel = SF[af], os.path.relpath(af, root)
    if not sf.balanced:
        b1.append("%s: this guard cannot parse the script's block structure (%s), so it "
                  "cannot prove any apply is default-off — an unreadable boot script is "
                  "not a passing one" % (rel, sf.unbalanced))
        continue
    # (ii) a direct/indirect apply naming a recursing root
    for _af, i, n, exp, reach in [s for s in apply_stmts if s[0] == af]:
        hits = [L for L in recursing_leaves if leaf_in(exp, os.path.basename(L)) or leaf_in(exp, L)]
        if not hits:
            continue
        why = sf.reachability(i)[1]
        if reach == "not-taken":
            continue
        g = [x for x in sf.ctx[i][1]]
        if reach == "taken":
            if g:
                b1.append("%s:%d applies %s (a repo-recursing root) under %s — the DEFAULT "
                          "takes that branch, so a device syncs the repo's own apps/ tree "
                          "and every build-time prune is bypassed [%s]"
                          % (rel, n, ", ".join(hits), g[-1][1].strip(), "; ".join(why)))
            else:
                b1.append("%s:%d applies %s (a repo-recursing root) with NO enclosing "
                          "condition at all — every build-time prune is bypassed [%s]"
                          % (rel, n, ", ".join(hits), "; ".join(why)))
        elif reach == "unreferenced":
            b1.append("%s:%d applies %s (a repo-recursing root) inside a function with no "
                      "call site this guard can find [%s] — an unreferenced applier is "
                      "either dead code (delete it) or invoked indirectly (make the call "
                      "visible)" % (rel, n, ", ".join(hits), "; ".join(why)))
        else:
            b1.append("%s:%d applies %s (a repo-recursing root) under a condition this "
                      "guard cannot prove is default-off: %s [%s]"
                      % (rel, n, ", ".join(hits),
                         g[-1][1].strip() if g else "(no condition)", "; ".join(why)))
    # (iii) a glob apply that SWEEPS UP a recursing root
    fns = applier_fns(sf)
    forre = re.compile(r"^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+?);\s*do\b")
    for i, (n, t) in enumerate(sf.lls):
        m = forre.match(t)
        if not m or i not in sf.loops:
            continue
        var, words = m.group(1), m.group(2)
        body = sf.lls[i + 1:sf.loops[i] + 1]
        btxt = "\n".join(x for _y, x in body)
        used = any(re.search(r"(^|\s|\()%s\s+\"?\$\{?%s\}?\"?" % (re.escape(fn), re.escape(var)), btxt)
                   for fn in fns) or ("kubectl" in btxt and "apply" in btxt)
        if not used or sf.reachability(i)[0] not in LIVE:
            continue
        for w in words.split():
            pat = norm_target(w)
            if not pat or "$" in pat:
                continue
            for L in recursing_leaves:
                if not (fnmatch.fnmatch(L, pat) or L == pat or L.startswith(pat.rstrip("/") + "/")):
                    continue
                base = os.path.basename(L)
                skipped = False
                for k, (_bn, bt) in enumerate(body):
                    s = bt.strip()
                    if not re.match(r"^[^\s()]*%s[^\s()]*\)" % re.escape(base), s):
                        continue
                    arm = "\n".join(x for _y, x in body[k:k + 8])
                    arm = arm.split(";;", 1)[0]
                    if re.search(r"(^|[\s;&|])continue(\s|$|;)", arm):
                        skipped = True
                    break
                if not skipped:
                    b1.append("%s:%d applies the glob %s, which SWEEPS UP the repo-recursing "
                              "root %s, and the loop body has no `%s)` arm that `continue`s "
                              "past it — the baked apply re-imports the whole unpruned repo tree"
                              % (rel, n, w, L, base))
    # (iv) a DIRECT apply whose -f target is a DIRECTORY or a glob that covers a
    # recursing root. `kubectl apply -f "${CLUSTER_DIR}/apps"` applies every file
    # in that directory, apps/00-app-of-apps-waved.yaml included, and there is no
    # loop body in which to `continue` past it. (iii) read only the loop form, so
    # that one statement left B1 green — measured while carrying V3 onto main
    # (battery mutation M6); NC12g plants it. Semantics as kubectl's: a directory
    # applies its OWN files, and its subdirectories only under -R/--recursive; a
    # `-k` target is a kustomize root that applies whatever its kustomization
    # lists, which is not readable here and is left to (ii)/(iii).
    for _af, i, n, exp, reach in [s for s in apply_stmts if s[0] == af]:
        if reach not in LIVE:
            continue
        words = lex(exp)
        recursive = any(w in ("-R", "--recursive") or w.startswith("--recursive=") for w in words)
        for flag, tgt in tgt_re.findall(exp):
            if flag != "f":
                continue
            on_cluster = ("CLUSTER_DIR" in tgt) or ("var/lib/hugmesh/cluster" in tgt)
            d = norm_target(tgt)
            if "$" in d or d == "-" or (not d and not on_cluster):
                continue
            dd = d.rstrip("/")
            for L in recursing_leaves:
                if L == dd or leaf_in(exp, os.path.basename(L)):
                    continue                     # the literal-root case is (ii)'s
                if any(c in dd for c in "*?["):
                    hit = fnmatch.fnmatch(L, dd)
                else:
                    hit = (os.path.dirname(L) == dd) or \
                          (recursive and (not dd or L.startswith(dd + "/")))
                if hit:
                    b1.append("%s:%d applies %s directly, which COVERS the repo-recursing root %s "
                              "(a directory%s apply has no loop body in which to skip it) — the "
                              "baked apply re-imports the whole unpruned repo tree"
                              % (rel, n, tgt.replace('"', ""), L, " -R" if recursive else ""))
if b1:
    bad("B1", "the boot path does not deploy this image's own Application set (%d problem(s)):"
        % len(b1))
    for m in b1:
        print("         %s" % m)
    print("         GREEN WHEN: the baked ${CLUSTER_DIR}/apps tree is what the default")
    print("            path applies, and every repo-recursing root (%s) is reachable only"
          % ", ".join(recursing_leaves))
    print("            through a switch whose DEFAULT does not take that branch.")
else:
    ok("B1", "boot applies the BAKED %s and all %d repo-recursing root(s) (%s) are "
             "unreachable on the default path"
       % (", ".join(apps_applied), len(recursing_leaves), ", ".join(recursing_leaves)))

# B2 — the artefacts the builders RENDER must be applied at boot from the BAKED
# tree, otherwise the render is written to a file nothing reads. A target may be a
# glob (apps/*.yaml), so match by fnmatch as well as by prefix.
def boot_covers(leaf):
    for t in applied:
        if t == leaf or leaf.startswith(t.rstrip("/") + "/") or fnmatch.fnmatch(leaf, t):
            return True
    return False
missing_apply = sorted(leaf for leaf in union if not boot_covers(leaf))
if missing_apply:
    bad("B2", "%d selection-rendered artefact(s) are applied by NOTHING at boot: %s"
        % (len(missing_apply), ", ".join(missing_apply)))
    print("         boot appliers scanned: %s"
          % ", ".join(os.path.relpath(a, root) for a in applier_files))
    print("         they apply only: %s" % ", ".join(sorted(applied)))
    # Name the Application that DOES own each missing leaf, and where it sources it
    # from — that is the whole mechanism, and it is what makes the render inert.
    for leaf in missing_apply:
        d = os.path.dirname(leaf)
        for p in sorted(glob.glob(P("specs/cluster/apps/*.yaml"))):
            for doc in ydocs(p):
                if doc.get("kind") != "Application":
                    continue
                src = ((doc.get("spec") or {}).get("source") or {})
                if src.get("path") == os.path.join("specs/cluster", d):
                    print("         %s is owned by %s -> repoURL=%s path=%s"
                          % (leaf, os.path.basename(p), src.get("repoURL"), src.get("path")))
    print("         => the builders write the operator's selection into")
    print("            ${SYSROOT}/var/lib/hugmesh/cluster/... and the Application that")
    print("            owns that directory syncs it FROM GIT, so the render is inert.")
    print("         GREEN WHEN: bootstrap.sh applies those baked files directly (the")
    print("            way it already applies apps/), or their owning Applications stop")
    print("            sourcing them from the repo.")
else:
    ok("B2", "every selection-rendered artefact (%d) is applied at boot from the baked tree"
       % len(union))

# B3 — while the artefacts are SOURCED FROM GIT, the git baseline is what lands on
# every device. It must therefore be fail-CLOSED: nothing on. The default-ON policy
# belongs in the builder's default OPTIONAL_SERVICES, not in the committed baseline
# — the ConfigMap's own comments state exactly this rule for games/owncast/tube.
forced = []
for k, v in sorted(cm_bools.items()):
    if v == "true":
        forced.append("%s: ConfigMap %s = \"true\"" % (k, cm_rel.split("/")[-1]))
for k, v in sorted(seed_crs.items()):
    if v:
        forced.append("%s: seed OptionalService enabled: true" % k)
for e in target_elems:
    if isinstance(e, dict) and str(e.get("installed")) == "true":
        forced.append("%s: %s element installed: \"true\"" % (e.get("slug"), target_appset.split("/")[-1]))
if forced:
    bad("B3", "%d git-baseline install-state value(s) are ON, so they land on EVERY "
              "device regardless of what the image selected:" % len(forced))
    for f in forced:
        print("         %s" % f)
    print("         => a build that DESELECTS one of these still boots with it marked")
    print("            installed, because B2's artefacts are synced from git.")
    print("         GREEN WHEN: the committed baseline is all-off and the default-ON")
    print("            policy lives only in the builder's default OPTIONAL_SERVICES.")
else:
    ok("B3", "the committed install-state baseline is fail-closed "
             "(%d ConfigMap keys, %d CRs, %d elements — all off)"
       % (len(cm_bools), len(seed_crs), len(target_elems)))
print()
# ───────── C) RUNTIME: can a superadmin turn one ON afterwards ──────────────
print("-- C) runtime: the superadmin enable path --")

# C1 — the ApplicationSet's generator-level selector is what makes an element's
# `installed` flag mean anything. Without it EVERY element generates, installed or
# not (proved upstream: argo-cd generator_spec_processor.go filters on it).
#
# ── EVERY GENERATOR, NOT "SOME GENERATOR" (V3, 2026-08-27) ──────────────────
# ArgoCD applies `selector` PER GENERATOR. V2 scanned the generator list and set a
# flag the first time it found one carrying the selector, so a SECOND, selector-
# less list generator on the same ApplicationSet made every slug in it generate an
# Application unconditionally — the exact fail-open C1 exists to catch — and C1
# reported PASS ("selector … on generator 0, all 16 elements carry the flag").
# Measured on a sandbox copy of this tree. Every generator must carry it; a
# matrix/merge may carry it once for its whole nest, otherwise each nested
# generator must.
tspec = (target_doc or {}).get("spec") or {}
gens = tspec.get("generators") or []
if not gens:
    die("C1", "generators on %s" % target_appset)
LEAFGEN = ("list", "git", "clusters", "scmProvider", "pullRequest",
           "clusterDecisionResource", "plugin")

def _sel_ok(g):
    return (((g or {}).get("selector") or {}).get("matchLabels") or {}).get("installed") == "true"

def _gen_kinds(g):
    return ",".join(sorted(k for k in (g or {}) if k != "selector")) or "(empty)"

def _check_gen(g, where, out):
    if _sel_ok(g):
        return
    for combo in ("matrix", "merge"):
        if combo in (g or {}):
            nested = ((g.get(combo) or {}).get("generators") or [])
            if not nested:
                out.append("%s: a %s generator with no nested generators" % (where, combo))
                return
            for k, ng in enumerate(nested):
                _check_gen(ng, "%s.%s[%d]" % (where, combo, k), out)
            return
    n_el = len(((g or {}).get("list") or {}).get("elements") or [])
    out.append("%s: a %s generator with NO selector matchLabels installed:\"true\"%s — every "
               "param set it emits generates an Application whether installed or not"
               % (where, _gen_kinds(g), (" (%d element(s))" % n_el) if n_el else ""))

c1 = []
for i, g in enumerate(gens):
    _check_gen(g, "generators[%d]" % i, c1)
noflag = [e.get("slug") for e in target_elems
          if isinstance(e, dict) and "installed" not in e]
if noflag:
    c1.append("%d element(s) carry no `installed` key at all: %s"
              % (len(noflag), ", ".join(map(str, noflag))))
if c1:
    bad("C1", "%s: the installed flag does not gate membership (%d problem(s)):"
        % (target_appset, len(c1)))
    for m in c1:
        print("         %s" % m)
    print("         => ArgoCD applies `selector` PER GENERATOR, so one uncovered generator")
    print("            deploys its whole element list regardless of the install-state.")
    print("         GREEN WHEN: every generator on this ApplicationSet carries")
    print("            selector.matchLabels.installed: \"true\" (or its enclosing")
    print("            matrix/merge does) and every element carries the flag.")
else:
    ok("C1", "%s: all %d generator(s) carry selector matchLabels installed:\"true\", all %d "
             "elements carry the flag" % (target_appset, len(gens), len(target_elems)))

# C2 — the ignoreDifferences seam. It is the ONLY thing that lets the element list
# diverge from git without selfHeal reverting it, so a pointer aimed at the wrong
# generator index silently disarms the whole runtime toggle. Resolve each pointer
# against the real document instead of eyeballing the index, and require the seam
# in EVERY file that carries the root Application (they must stay in lockstep).
# RFC 6901 escaping: ~1 is "/" and ~0 is "~". No slug uses either today, and a
# pointer that silently mis-resolved because of one would report "protects
# nothing" — a FALSE red, the other half of the same failure.
def _unesc(tok):
    return tok.replace("~1", "/").replace("~0", "~")
def resolve_ptr(doc, ptr):
    cur = doc
    for part in (_unesc(x) for x in ptr.strip("/").split("/")):
        if isinstance(cur, list):
            if not re.fullmatch(r"\d+", part) or int(part) >= len(cur):
                return None
            cur = cur[int(part)]
        elif isinstance(cur, dict):
            if part not in cur:
                return None
            cur = cur[part]
        else:
            return None
    return cur

tname = ((target_doc or {}).get("metadata") or {}).get("name")
# root_app_files is DERIVED once, at V13, and shared with B1 — two separate lists
# of "the files carrying a repo-recursing root" could drift, and B1 is the check
# that would then quietly stop looking at one of them.
c2_problems = []
for rel, doc in root_app_files:
    sp = doc.get("spec") or {}
    so = ((sp.get("syncPolicy") or {}).get("syncOptions") or [])
    ptrs = []
    for ig in (sp.get("ignoreDifferences") or []):
        if ig.get("kind") == "ApplicationSet" and ig.get("name") == tname:
            ptrs += list(ig.get("jsonPointers") or [])
    if not ptrs:
        c2_problems.append("%s: no ignoreDifferences on ApplicationSet/%s — selfHeal "
                           "reverts every runtime write of the element list" % (rel, tname))
        continue
    if "RespectIgnoreDifferences=true" not in so:
        c2_problems.append("%s: ignoreDifferences present but syncOptions lacks "
                           "RespectIgnoreDifferences=true — selfHeal ignores it" % rel)
    for ptr in ptrs:
        if resolve_ptr(target_doc, ptr) is None:
            c2_problems.append("%s: jsonPointer %s does not resolve in %s (generators=%d) "
                               "— it protects nothing" % (rel, ptr, target_appset, len(gens)))
if c2_problems:
    bad("C2", "the ignoreDifferences seam is not intact in %d place(s):" % len(c2_problems))
    for m in c2_problems:
        print("         %s" % m)
else:
    ok("C2", "the ignoreDifferences seam resolves in all %d root-Application file(s)"
       % len(root_app_files))

# C3 — the same seam for the ConfigMap: every key the reconciler may write must be
# covered, or ArgoCD reverts the write on the next sync (controller writes, GitOps
# reverts, net no-op).
#
# ── RESOLVED, NOT SUFFIXED (V3, 2026-08-27) ────────────────────────────────
# V2 compared only the LAST PATH SEGMENT of each jsonPointer, so a pointer that
# protects NOTHING counted as covering the key: rewriting `/data/akkoma` to
# `/spec/bogus/akkoma` left C3 reporting "covers all 14 reconciler-writable
# ConfigMap keys" (measured). Its sibling C2 already resolves its pointers against
# the real document; C3 now does the same, and also names any pointer in the list
# that resolves to nothing at all.
writable = sorted(set(crd_enum) & set(cm_bools))
if not writable:
    die("C3", "reconciler-writable ConfigMap keys (CRD enum ∩ ConfigMap booleans)")
covered, dead = set(), []
for ptr in cm_ign_ptrs:
    parts = [_unesc(x) for x in ptr.strip("/").split("/")] if ptr.strip("/") else []
    if resolve_ptr(cm_doc, ptr) is None:
        dead.append(ptr)
        continue
    if len(parts) == 2 and parts[0] == "data":
        covered.add(parts[1])
gap = [k for k in writable if k not in covered]
if gap or dead:
    bad("C3", "%s's ignoreDifferences does not protect the reconciler's writes:" % cm_ign_app)
    if gap:
        print("         %d reconciler-writable ConfigMap key(s) have no pointer that resolves "
              "to their /data node: %s" % (len(gap), ", ".join(gap)))
    for p in dead:
        print("         jsonPointer %s does not resolve in %s — it protects nothing"
              % (p, cm_rel))
    print("         covered: %d of %d writable keys" % (len(writable) - len(gap), len(writable)))
    print("         => flipping one of those on at runtime is reverted on the next sync.")
    print("         GREEN WHEN: each writable key has an ignoreDifferences jsonPointer")
    print("            that RESOLVES to its own /data/<slug> node in %s." % cm_rel)
else:
    ok("C3", "%s covers all %d reconciler-writable ConfigMap keys, and all %d pointers "
             "resolve" % (cm_ign_app, len(writable), len(cm_ign_ptrs)))

# C4 — slug parity, in BOTH directions. An element with no CR cannot be addressed
# by a superadmin; a CRD slug with no element toggles nothing; an element outside
# the registry has no declared owner. (The Java OptionalServiceRegistry is the
# FIFTH surface and is owned by tests/scripts/test-optional-service-slug-closure.sh
# — not re-asserted here.)
#
# ── THE REVERSE LEGS (V3, 2026-08-27) ──────────────────────────────────────
# V2 asserted elements ⊆ {registry, ConfigMap, CRD enum, seed} and CRD enum ⊆
# elements, and nothing else — so a slug present in the registry, the ConfigMap AND
# the seed CRs but absent from the CRD enum AND the 13a elements passed unnoticed
# (measured: `ghostsvc` planted in three sources, C4 green). The reverse legs below
# close it WITHOUT inventing an exemption list: the ConfigMap legitimately carries
# BUILD-time booleans that are not runtime-togglable (workloadConsole, headwind,
# attestation-server today), which is why the reverse leg for the ConfigMap is
# "must be a registered service", while the seam that actually decides
# togglability — the seed CRs and the CRD enum — must match the element set
# EXACTLY in both directions.
sources = {
    "registry(optional-services.yaml)": set(reg_slugs),
    "ConfigMap(installed-services)": set(cm_bools),
    "CRD(slug enum)": set(crd_enum),
    "seed(OptionalService CRs)": set(seed_crs),
}
for n, s in sources.items():
    if not s:
        die("V-parity", "source '%s' derived to the empty set" % n)
c4 = []
for n, s in sources.items():
    miss = sorted(set(elem_slugs) - s)
    if miss:
        c4.append("%d element slug(s) absent from %s: %s" % (len(miss), n, ", ".join(miss)))
orphan = sorted(set(crd_enum) - set(elem_slugs))
if orphan:
    c4.append("%d CRD enum slug(s) with no %s element: %s"
              % (len(orphan), target_appset.split("/")[-1], ", ".join(orphan)))
seed_orphan = sorted(set(seed_crs) - set(elem_slugs))
if seed_orphan:
    c4.append("%d seed OptionalService CR(s) with no %s element: %s — flipping one "
              "actuates nothing" % (len(seed_orphan), target_appset.split("/")[-1],
                                    ", ".join(seed_orphan)))
seed_unenum = sorted(set(seed_crs) - set(crd_enum))
if seed_unenum:
    c4.append("%d seed OptionalService CR(s) outside the CRD slug enum: %s — the API "
              "server rejects them at admission" % (len(seed_unenum), ", ".join(seed_unenum)))
cm_unreg = sorted(set(cm_bools) - set(reg_slugs))
if cm_unreg:
    c4.append("%d installed-services ConfigMap boolean(s) name no registered service: %s"
              % (len(cm_unreg), ", ".join(cm_unreg)))
if c4:
    bad("C4", "the togglable slug set is not consistent across the 4 in-tree sources:")
    for m in c4:
        print("         %s" % m)
    print("         => a superadmin can create a CR the controller drops, or flip a flag")
    print("            that addresses nothing. Both fail silently.")
else:
    ok("C4", "all %d element slugs are present in the registry, the ConfigMap, the CRD "
             "enum and the seed CRs; the CRD enum and the seed CRs carry NOTHING that "
             "13a does not, and every ConfigMap boolean names a registered service "
             "(%d build-time-only: %s)"
       % (len(elem_slugs), len(set(cm_bools) - set(elem_slugs)),
          ", ".join(sorted(set(cm_bools) - set(elem_slugs))) or "none"))

# ── C5 / C5b — the reconciler master switch ─────────────────────────────────
# V1 asserted "APP_OPTIONAL_SERVICES_RECONCILE_ENABLED is set NOWHERE — the
# reconciler ships dark". PR #186 made that premise FALSE: the key is declared in
# the deployed Deployment, which is the only place it CAN be set (a `kubectl set
# env` is reverted by apps/31-admin-bff-api.yaml's selfHeal). So the check splits:
#   C5  the LEVER exists — a GitOps-enforced declaration. GREEN.
#   C5b the lever is ON. RED, deliberately and documentedly: lighting it while a
#       hardcoded apps/30-* Application still owns a slug's manifest directory puts
#       two prune+selfHeal Applications on one path. C5b therefore reports the
#       PRECONDITION alongside the value, so "why is it off" is answerable from the
#       output instead of from a comment.
# Select the admin-bff Deployment BY NAME, not "the last Deployment in the file".
# That file holds one today; the day it holds two, a positional read would start
# reporting the other one's env and its ServiceAccount without saying so.
dep_p = P("specs/cluster/manifests/admin-bff-api/deployment.yaml")
dep_doc = None
if os.path.exists(dep_p):
    for doc in ydocs(dep_p):
        if doc.get("kind") == "Deployment" and \
           "admin-bff" in ((doc.get("metadata") or {}).get("name") or ""):
            dep_doc = doc
env_pairs = {}
if dep_doc is not None:
    for c in (((dep_doc.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []:
        for e in (c.get("env") or []):
            if isinstance(e, dict) and "name" in e:
                env_pairs[e["name"]] = e.get("value")
elif os.path.exists(dep_p):
    die("V-adminbff", "a Deployment named *admin-bff* in %s" % os.path.relpath(dep_p, root))
RK = "APP_OPTIONAL_SERVICES_RECONCILE_ENABLED"
sibling = [k for k in env_pairs if k.startswith("APP_OPTIONAL_SERVICES_RECONCILE_")]
if RK not in env_pairs:
    bad("C5", "%s is declared NOWHERE in the deployed manifest — there is no reachable "
              "lever at all (a `kubectl set env` is reverted by the Application's "
              "selfHeal), so the reconciler can never be switched on" % RK)
    print("         %s env: %d key(s); optional-services siblings present: %s"
          % (os.path.relpath(dep_p, root), len(env_pairs), ", ".join(sorted(sibling)) or "none"))
else:
    ok("C5", "%s is declared in %s — the master switch is a GitOps-enforced lever"
       % (RK, os.path.relpath(dep_p, root)))

    # The cut-over precondition, DERIVED: a slug is blocked while some apps/*.yaml
    # other than the target ApplicationSet declares `path: <the element's path>`.
    # This is the same rule _opt_appset_cutover_done() enforces at build time,
    # recomputed independently from the tree so the two cannot agree by accident.
    blocked = []
    for slug, e in sorted(elem_by_slug.items()):
        ep = e.get("path")
        if not ep:
            continue
        for p in sorted(glob.glob(P("specs/cluster/apps/*.yaml"))):
            if os.path.basename(p) == os.path.basename(target_appset):
                continue
            txt = strip_sh(rd(p))
            if re.search(r"(?m)^[ \t]*path:[ \t]*%s[ \t]*$" % re.escape(ep), txt):
                blocked.append((slug, os.path.basename(p)))
                break
    val = str(env_pairs[RK]).strip('"').lower()
    if val != "true":
        bad("C5b", "%s = %r — the reconciler is OFF, so an OptionalService CR a "
                   "superadmin writes is accepted, stored, and never actuated: no "
                   "element flip, no ConfigMap key, no status" % (RK, env_pairs[RK]))
        if blocked:
            print("         precondition still open: %d slug(s) whose manifest directory is "
                  "still owned by a hardcoded Application (the cut-over):" % len(blocked))
            for slug, f in blocked:
                print("           %-18s still owned by apps/%s" % (slug, f))
            print("         => lighting the switch before those are cut over would put TWO")
            print("            prune+selfHeal Applications on one manifest directory.")
        print("         GREEN WHEN: the %d hardcoded Application(s) above are deleted in "
              "favour of their 13a elements and this value is flipped to \"true\"."
              % len(blocked))
    elif blocked:
        bad("C5b", "%s = \"true\" but %d slug(s) have NOT been cut over — the first lit "
                   "tick double-manages their manifest directories: %s"
            % (RK, len(blocked), ", ".join("%s(apps/%s)" % b for b in blocked)))
    else:
        ok("C5b", "%s = \"true\" and every 13a element's manifest directory is owned by "
                  "13a alone — the enable path is live" % RK)

# C6 — the enable path itself: a superadmin request must be able to REACH the
# writer, and the writer's pod identity must be allowed to write all three targets.
c6 = []
TARGET_EP = "/bff/superadmin/optional-services/"
sql_p = P("specs/cluster/manifests/route-access/initdb/20-schema.sql")
rows = []
if os.path.exists(sql_p):
    rows = re.findall(r"\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*(true|false)\s*\)",
                      strip_sql(rd(sql_p)))
if not rows:
    die("V-routeaccess", "route_access rows in manifests/route-access/initdb/20-schema.sql")
def covers(pat, target):
    if pat.endswith("/**"):
        return target.startswith(pat[:-3] + "/") or target == pat[:-3]
    return pat == target
# A blanket row (e.g. the pki-gateway '/**' floor) is NOT the superadmin console
# surface: require the pattern to live under /bff/superadmin, so deleting that
# surface is visible instead of being absorbed by a catch-all.
grants = [r for r in rows if r[2] == "ROLE_SUPERADMIN" and r[3] == "true"
          and r[1].startswith("/bff/superadmin") and covers(r[1], TARGET_EP)]
if not grants:
    c6.append("no enabled ROLE_SUPERADMIN route_access row under /bff/superadmin covers %s "
              "(scanned %d rows)" % (TARGET_EP, len(rows)))
gw_ok = []
for p in sorted(glob.glob(P("specs/cluster/apps/*gateway*.yaml"))):
    txt = rd(p)
    for m in re.finditer(r"(?m)^\s*-\s*id:\s*(\S+)\s*$\n\s*uri:\s*(\S+)\s*$\n\s*path:\s*(\S+)\s*$",
                         strip_sh(txt)):
        if m.group(3).startswith("/bff/superadmin") and covers(m.group(3), TARGET_EP) \
           and "admin-bff" in m.group(2):
            gw_ok.append("%s:%s" % (os.path.basename(p), m.group(1)))
if not gw_ok:
    c6.append("no gateway route forwards %s to the admin-bff" % TARGET_EP)
rbac_dir = P("specs/cluster/manifests/optional-services-operator")
subjects, grantmap = set(), {}
for p in sorted(glob.glob(os.path.join(rbac_dir, "*.yaml"))):
    for doc in ydocs(p):
        if doc.get("kind") in ("RoleBinding", "ClusterRoleBinding"):
            for s in (doc.get("subjects") or []):
                subjects.add((s.get("kind"), s.get("name"), s.get("namespace")))
        if doc.get("kind") in ("Role", "ClusterRole"):
            for r in (doc.get("rules") or []):
                for g in (r.get("apiGroups") or []):
                    for res in (r.get("resources") or []):
                        grantmap.setdefault((g, res), set()).update(r.get("verbs") or [])
need = [("platform.hugmesh.net", "optionalservices"), ("argoproj.io", "applicationsets"), ("", "configmaps")]
for g, res in need:
    verbs = grantmap.get((g, res), set())
    if not ({"patch", "update"} & verbs):
        c6.append("the operator RBAC grants no patch/update on %s/%s" % (g or "core", res))
sa = None
if dep_doc is not None:
    sa = (((dep_doc.get("spec") or {}).get("template") or {}).get("spec") or {}).get("serviceAccountName")
sa_names = {n for k, n, _ in subjects if k == "ServiceAccount"}
if not sa_names:
    die("V-rbac", "RoleBinding ServiceAccount subjects under manifests/optional-services-operator")
if sa and sa not in sa_names:
    c6.append("the admin-bff runs as ServiceAccount %r but the operator RoleBindings bind %s"
              % (sa, ", ".join(sorted(sa_names))))
if c6:
    bad("C6", "the superadmin enable path is not wired end to end (%d gap(s)):" % len(c6))
    for m in c6:
        print("         %s" % m)
else:
    ok("C6", "superadmin -> admin-bff route (%s) + SA %s bound with patch on "
             "optionalservices/applicationsets/configmaps" % (", ".join(gw_ok), sa))

# C7 — the REVERSE direction. Flipping a slug off makes the ApplicationSet DELETE
# the generated Application; without the ArgoCD resources-finalizer the API server
# removes the Application outright and the app-controller's cascade (gated on
# app.CascadedDeletion()) never runs, so every Deployment/Service/PVC keeps running
# unmanaged. "Only the selected services" has to hold after a disable too.
FIN = "resources-finalizer.argocd.argoproj.io"
tmeta = ((tspec.get("template") or {}).get("metadata") or {})
fins = list(tmeta.get("finalizers") or [])
if FIN not in fins:
    bad("C7", "%s template carries no %s — turning a service OFF deletes the "
              "Application and ORPHANS its running workloads" % (target_appset, FIN))
    print("         template.metadata keys: %s" % (", ".join(sorted(tmeta)) or "(none)"))
    print("         GREEN WHEN: the template's metadata carries that finalizer, so the")
    print("            app-controller cascade-deletes the slug's workloads on disable.")
else:
    ok("C7", "%s template carries %s — a disabled slug's workloads are cascade-deleted"
       % (target_appset, FIN))

print("-- static analysis ran to completion: %d check(s) failed --" % F[0])
sys.exit(1 if F[0] else 0)
PY
  local rc=$?
  cat "${so}"
  # THE EXIT CODE IS NOT ENOUGH. An uncaught Python exception exits 1 — exactly
  # what "a check FAILED and printed its line" exits — so a crash halfway through
  # is indistinguishable from a verdict by rc alone. Measured while building V3: a
  # NameError planted just before C3 printed a traceback to stderr and a headline
  # of "13 passed, 3 failed", with C3 through C7 simply missing and nobody the
  # wiser. The analyser therefore ANNOUNCES that it reached an end — either
  # completion or a deliberate die() — and this requires the announcement.
  if ! grep -E '^-- static analysis (ran to completion|stopped deliberately)' "${so}" >/dev/null 2>&1; then
    echo "  FAIL V-analyser the static analyser did not reach its end marker (exit ${rc}) — the checks after the last line above are UNRUN, not passed"
    rm -f "${so}"
    return 1
  fi
  rm -f "${so}"
  case "${rc}" in
    0|1|2) return "${rc}" ;;
    *) echo "  FAIL V-analyser the static analyser exited ${rc} (neither a verdict nor a derivation abort)"
       return 1 ;;
  esac
}

# =============================================================================
# EXECUTED LEG — A1/A2. The REAL renderer functions, RESOLVED through the real
# source chain (library + any builder-local override, last definition winning)
# and run against a sandbox sysroot seeded from the REAL committed artefacts.
# Nothing here is a reimplementation of the builder.
#
# WHY TWO DIRECTIONS. A renderer whose sed/awk anchor stops matching returns 0,
# prints its success INFO line and writes nothing (that shipped once: the
# `headwind` key was missing from the ConfigMap and the loop no-opped for months).
# Asserting only "deselected slugs end up false" cannot see it whenever the
# baseline is already false. So each run FORCES the pre-state to the OPPOSITE of
# what it expects and requires the renderer to move every covered value:
#   A1  pre-state ALL TRUE  -> render with an EMPTY selection  -> all must be false
#   A2  pre-state ALL FALSE -> render with EVERY covered slug  -> all must be true
# A no-op fails both. The pre-state write is verified by an independent YAML parse
# before the builder runs, so a broken pre-seeder cannot fake either direction.
#
# ── A2's 13a EXPECTATION IS NOW DERIVED, NOT ASSUMED (2026-08-26) ───────────
# _opt_render_appset_flag() refuses to flip a 13a element to "true" while a
# hardcoded apps/30-*/50-* Application still declares the same manifest `path:`
# (two prune+selfHeal Applications on one directory). So "select everything and
# every 13a flag is true" is FALSE BY DESIGN today. The expectation is computed
# per slug from the sandbox tree — is any OTHER apps/*.yaml claiming this
# element's path — which means A2 goes red BOTH ways: if the guard breaks and a
# non-cut-over slug flips true, and if a cut-over slug fails to flip. The
# ConfigMap and CR halves keep the flat expectation; the guard is 13a-only.
#
# The covered slug list is DERIVED from the `for slug in …; do` line inside each
# builder's own RESOLVED function body — not restated here, so a slug added to the
# gate is asserted the day it lands.
# =============================================================================
CM_LEAF="manifests/policy/installed-services-configmap.yaml"
SEED_LEAF="manifests/optional-services-operator/seed-optionalservices.yaml"
APPSET_LEAF="apps/13a-optional-services.yaml"

# selsvc_state <mode:dump|set> <treedir> [<value> <slug>...]
selsvc_state() {
  SS_MODE="$1" SS_TREE="$2" SS_VAL="${3:-}" SS_SLUGS="${*:4}" \
  SS_CM="${CM_LEAF}" SS_SEED="${SEED_LEAF}" SS_APPSET="${APPSET_LEAF}" python3 - <<'PY'
import os, re, sys, yaml
mode = os.environ["SS_MODE"]; tree = os.environ["SS_TREE"]
val = os.environ.get("SS_VAL", ""); slugs = os.environ.get("SS_SLUGS", "").split()
cm = os.path.join(tree, os.environ["SS_CM"])
seed = os.path.join(tree, os.environ["SS_SEED"])
apps = os.path.join(tree, os.environ["SS_APPSET"])

def rl(p):
    return open(p, encoding="utf-8").read().split("\n") if os.path.exists(p) else None
def wl(p, lines):
    open(p, "w", encoding="utf-8").write("\n".join(lines))

if mode == "set":
    L = rl(cm)
    if L is not None:
        for i, l in enumerate(L):
            m = re.match(r'^(\s*)([A-Za-z0-9_-]+):\s*"(?:true|false)"\s*$', l)
            if m and m.group(2) in slugs:
                L[i] = '%s%s: "%s"' % (m.group(1), m.group(2), val)
        wl(cm, L)
    L = rl(seed)
    if L is not None:
        cur = None
        for i, l in enumerate(L):
            m = re.match(r"^\s*slug:\s*(\S+)\s*$", l)
            if m:
                cur = m.group(1).strip("\"'")
                continue
            m = re.match(r"^(\s*)enabled:\s*(?:true|false)\s*$", l)
            if m and cur in slugs:
                L[i] = "%senabled: %s" % (m.group(1), val); cur = None
        wl(seed, L)
    L = rl(apps)
    if L is not None:
        for i, l in enumerate(L):
            m = re.search(r"\{\s*slug:\s*([A-Za-z0-9_-]+)\s*,", l)
            if m and m.group(1) in slugs and re.search(r'installed:\s*"(?:true|false)"', l):
                L[i] = re.sub(r'installed:\s*"(?:true|false)"', 'installed: "%s"' % val, l)
        wl(apps, L)
    sys.exit(0)

# dump — INDEPENDENT of the writer above: parse the YAML, do not re-read the regex.
if os.path.exists(cm):
    for doc in yaml.safe_load_all(open(cm, encoding="utf-8")):
        if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
            for k, v in (doc.get("data") or {}).items():
                if v in ("true", "false"):
                    print("cm %s %s" % (k, v))
if os.path.exists(seed):
    for doc in yaml.safe_load_all(open(seed, encoding="utf-8")):
        if isinstance(doc, dict) and doc.get("kind") == "OptionalService":
            sp = doc.get("spec") or {}
            print("cr %s %s" % (sp.get("slug"), "true" if sp.get("enabled") else "false"))
if os.path.exists(apps):
    for doc in yaml.safe_load_all(open(apps, encoding="utf-8")):
        if isinstance(doc, dict) and doc.get("kind") == "ApplicationSet":
            for g in ((doc.get("spec") or {}).get("generators") or []):
                for e in (((g or {}).get("list") or {}).get("elements") or []):
                    if isinstance(e, dict) and e.get("slug"):
                        print("appset %s %s" % (e["slug"], e.get("installed")))
PY
}

# selsvc_cutover_blocked <appsdir> <appset-file> — print, one slug per line, every
# 13a element whose `path:` is ALSO declared by another apps/*.yaml (so the
# builder's double-management guard will hold its flag at "false"). Derived from
# the tree, comment-stripped, anchored at line start; NOT read back from the
# builder, so builder and expectation cannot agree by accident.
selsvc_cutover_blocked() {
  SC_APPS="$1" SC_APPSET="$2" python3 - <<'PY'
import os, re, sys
apps = os.environ["SC_APPS"]; appset = os.environ["SC_APPSET"]
if not os.path.exists(appset):
    sys.exit(0)
def strip_sh(t):
    return "\n".join("" if l.lstrip().startswith("#") else l for l in t.split("\n"))
txt = open(appset, encoding="utf-8", errors="replace").read()
elems = re.findall(r"\{\s*slug:\s*([A-Za-z0-9_-]+)\s*,[^}]*?\bpath:\s*([^,\s}]+)", txt)
others = []
for fn in sorted(os.listdir(apps)):
    if not fn.endswith(".yaml") or fn == os.path.basename(appset):
        continue
    others.append(strip_sh(open(os.path.join(apps, fn), encoding="utf-8", errors="replace").read()))
for slug, p in elems:
    for t in others:
        if re.search(r"(?m)^[ \t]*path:[ \t]*%s[ \t]*$" % re.escape(p), t):
            print(slug); break
PY
}

# run_render <builder> <sysroot> — the builder's OWN functions, as bash resolves
# them. opt_gate_load_all DERIVES the function set from the chain; a hand-written
# list is only right until the gate grows a leaf, and this one has grown two
# (_opt_appset_cutover_done, _opt_render_federation_modules) since V1 was written.
run_render() (
  local b="$1" sysroot="$2" sel="$3" fn
  info() { :; }; warn() { :; }; err() { :; }; note() { :; }
  SYSROOT="${sysroot}"; OPTIONAL_SERVICES="${sel}"; EXCLUDE_SERVICES=""; ENV="test"
  export SYSROOT OPTIONAL_SERVICES EXCLUDE_SERVICES ENV
  if [ "${SELSVC_RESOLVER}" = "1" ]; then
    opt_gate_load_all "${b}" || return 90
  else
    for fn in _opt_selected _opt_explicitly_deselected _opt_anubis_installed \
              _opt_appset_element_path _opt_appset_cutover_done \
              _opt_render_appset_flag _opt_wire_anubis_ingress \
              _opt_render_installed_services _opt_set_cr_enabled \
              _opt_render_optionalservice_cr; do
      _has_fn "${b}" "${fn}" || continue
      eval "$(_extract_fn "${b}" "${fn}")" || return 90
    done
  fi
  _opt_render_installed_services  || return 91
  _opt_render_optionalservice_cr  || return 92
  return 0
)

# assert_direction <label> <root> <builder> <want> <selection>
# Seeds a sysroot, forces every covered value to the OPPOSITE of <want>, verifies
# that pre-state by parse, runs the builder's renderers, and requires every
# covered value to be <want> — except the 13a flags, whose expectation is derived
# per slug by selsvc_cutover_blocked.
assert_direction() {
  local id="$1" root="$2" b="$3" want="$4" sel="$5"
  local bn; bn="$(basename "${b}")"
  local d="${W}/x-${id}-${bn}"; rm -rf "${d}"
  local tree="${d}/var/lib/hugmesh/cluster"
  mkdir -p "${tree}/$(dirname "${CM_LEAF}")" "${tree}/$(dirname "${SEED_LEAF}")" "${tree}/apps"
  cp "${root}/specs/cluster/${CM_LEAF}"   "${tree}/${CM_LEAF}"
  cp "${root}/specs/cluster/${SEED_LEAF}" "${tree}/${SEED_LEAF}"
  cp -r "${root}/specs/cluster/apps/." "${tree}/apps/"

  local cov_cm cov_cr opp all
  cov_cm="$(_covered_slugs "${b}" _opt_render_installed_services)"
  cov_cr="$(_covered_slugs "${b}" _opt_render_optionalservice_cr)"
  if [ -z "${cov_cm}" ] || [ -z "${cov_cr}" ]; then
    echo "  FAIL ${id} ${bn}: could not derive the renderer's slug loop (cm='${cov_cm}' cr='${cov_cr}') — the check would assert over an empty set"
    return 1
  fi
  all="${cov_cm} ${cov_cr}"
  [ "${want}" = "true" ] && opp="false" || opp="true"

  selsvc_state set "${tree}" "${opp}" ${all}
  # Verify the pre-state by an independent parse: a pre-seeder that silently
  # missed would otherwise make the direction below meaningless.
  local pre; pre="${d}/pre.txt"; selsvc_state dump "${tree}" > "${pre}"
  local s bad_pre=""
  for s in ${cov_cm}; do
    awk -v s="${s}" -v v="${opp}" '$1=="cm" && $2==s { if ($3!=v) print "cm:" s } ' "${pre}" >> "${d}/prebad" 2>/dev/null
  done
  for s in ${cov_cr}; do
    awk -v s="${s}" -v v="${opp}" '$1=="cr" && $2==s { if ($3!=v) print "cr:" s } ' "${pre}" >> "${d}/prebad" 2>/dev/null
  done
  bad_pre="$(cat "${d}/prebad" 2>/dev/null)"
  if [ -n "${bad_pre}" ]; then
    echo "  FAIL ${id} ${bn}: could not force the pre-state to ${opp} for: ${bad_pre//$'\n'/ }"
    return 1
  fi

  # The per-slug 13a expectation, derived from THIS tree before the render runs.
  local blocked; blocked="$(selsvc_cutover_blocked "${tree}/apps" "${tree}/${APPSET_LEAF}")"

  run_render "${b}" "${d}" "${sel}"; local rc=$?
  if [ "${rc}" -ne 0 ]; then
    echo "  FAIL ${id} ${bn}: the builder's renderers exited ${rc}"
    return 1
  fi
  local post; post="${d}/post.txt"; selsvc_state dump "${tree}" > "${post}"
  : > "${d}/wrong"
  for s in ${cov_cm}; do
    awk -v s="${s}" -v v="${want}" '$1=="cm" && $2==s && $3!=v { print "ConfigMap/" s "=" $3 }' "${post}" >> "${d}/wrong"
  done
  for s in ${cov_cr}; do
    awk -v s="${s}" -v v="${want}" '$1=="cr" && $2==s && $3!=v { print "OptionalService/" s "=" $3 }' "${post}" >> "${d}/wrong"
  done
  local n_block=0
  # Membership by `case`, not `printf ... | grep -Fxq`. Under `set -o pipefail` a -q
  # match closes the pipe, the upstream printf dies of SIGPIPE, and a FOUND slug
  # reports FAILURE — the exact trap this file's header claims it avoids, planted
  # in it by hand. tests/scripts/test-guard-integrity.sh check 8 caught it.
  local blocked_sp=" ${blocked//$'\n'/ } "
  if _has_fn "${b}" _opt_render_appset_flag; then
    for s in ${cov_cm}; do
      local exp="${want}"
      if [ "${want}" = "true" ]; then
        case "${blocked_sp}" in *" ${s} "*) exp="false"; n_block=$((n_block+1)) ;; esac
      fi
      awk -v s="${s}" -v v="${exp}" '$1=="appset" && $2==s && $3!=v { print "13a/" s "=" $3 " (expected " v ")" }' "${post}" >> "${d}/wrong"
    done
  fi
  local wrong; wrong="$(cat "${d}/wrong")"
  if [ -n "${wrong}" ]; then
    echo "  FAIL ${id} ${bn}: pre-state ${opp}, selection '${sel:-<none>}', but these did NOT reach the expected value:"
    sed 's/^/         /' "${d}/wrong"
    echo "         => the renderer returned 0 without writing (a dead sed/awk anchor is silent),"
    echo "            or the 13a double-management guard fired for a slug that IS cut over."
    return 1
  fi
  echo "  PASS ${id} ${bn}: pre-state ${opp} -> selection '${sel:-<none>}' -> every covered value is ${want} ($(printf '%s\n' ${cov_cm} | wc -l) CM, $(printf '%s\n' ${cov_cr} | wc -l) CR$(_has_fn "${b}" _opt_render_appset_flag && echo ", +13a with ${n_block} slug(s) held false by the cut-over guard"))"
  return 0
}

# ── B4 — EXECUTED: the gate must actually PRUNE what the operator deselected ──
# The registry DECLARES, per service, which Applications the slug owns (apps[])
# and which builders gate it (buildGate[]). Run the real gate_optional_services
# against a real baked tree with an EMPTY selection: every declared file must be
# GONE. Then run it with the full selection: every declared file must SURVIVE.
# Both directions, because a gate that deletes unconditionally passes the first.
#
# The pre-state is asserted: a file that was never in the sandbox would satisfy
# "absent after the gate" vacuously, so a missing pre-image ABORTS the check
# rather than counting as a pass.
assert_prune() {
  local id="$1" root="$2" b="$3" sel="$4" want="$5"   # want=absent|present
  local bn; bn="$(basename "${b}")"
  local d="${W}/p-${id}-${bn}"; rm -rf "${d}"
  local tree="${d}/var/lib/hugmesh/cluster"
  mkdir -p "${d}/var/lib/hugmesh"
  cp -r "${root}/specs/cluster" "${tree}"

  local decl; decl="$(SC_REG="${root}/specs/cluster/optional-services.yaml" python3 - <<'PY'
import os, yaml
reg = yaml.safe_load(open(os.environ["SC_REG"], encoding="utf-8"))
for s in (reg.get("spec") or {}).get("services") or []:
    if s.get("buildGate") and s.get("apps"):
        for a in s["apps"]:
            print("%s %s" % (s["slug"], a))
PY
)"
  if [ -z "${decl}" ]; then
    echo "  FAIL ${id} ${bn}: DERIVATION YIELDED ZERO ROWS: registry services with buildGate[] AND apps[]"
    return 1
  fi
  # pre-state: every declared file must EXIST before the gate runs.
  local missing="" slug rel
  while read -r slug rel; do
    [ -n "${rel}" ] || continue
    [ -f "${tree}/${rel}" ] || missing="${missing} ${slug}:${rel}"
  done <<< "${decl}"
  if [ -n "${missing}" ]; then
    echo "  FAIL ${id} ${bn}: pre-state missing declared Application file(s) —${missing}"
    echo "         (asserting their ABSENCE afterwards would be vacuous)"
    return 1
  fi

  ( info() { :; }; warn() { :; }; err() { :; }; note() { :; }
    SYSROOT="${d}"; OPTIONAL_SERVICES="${sel}"; EXCLUDE_SERVICES=""; ENV="test"
    export SYSROOT OPTIONAL_SERVICES EXCLUDE_SERVICES ENV
    if [ "${SELSVC_RESOLVER}" = "1" ]; then opt_gate_load_all "${b}" || exit 90
    else eval "$(_extract_fn "${b}" gate_optional_services)" || exit 90; fi
    gate_optional_services ) || {
      echo "  FAIL ${id} ${bn}: gate_optional_services exited non-zero"; return 1; }

  local wrong=""
  while read -r slug rel; do
    [ -n "${rel}" ] || continue
    if [ "${want}" = "absent" ]; then
      [ -e "${tree}/${rel}" ] && wrong="${wrong}
         ${slug} STILL PRESENT: ${rel}"
    else
      [ -e "${tree}/${rel}" ] || wrong="${wrong}
         ${slug} WRONGLY PRUNED: ${rel}"
    fi
  done <<< "${decl}"
  if [ -n "${wrong}" ]; then
    echo "  FAIL ${id} ${bn}: selection '${sel:-<none>}' — declared Application(s) not ${want}:${wrong}"
    echo "         => bootstrap.sh applies this baked apps/ tree verbatim, so a file left"
    echo "            here is a service the device DEPLOYS regardless of the selection."
    return 1
  fi
  echo "  PASS ${id} ${bn}: selection '${sel:-<none>}' -> all $(printf '%s\n' "${decl}" | grep -c . ) registry-declared Application file(s) ${want}"
  return 0
}

analyse_executed() {  # $1 = root
  local root="$1" b sel_b=()
  for b in "${root}"/build-*-stage4.sh; do
    [ -f "${b}" ] || continue
    strip_sh_comments "${b}" | grep -E '^[[:space:]]*--optional-services\)' >/dev/null 2>&1 && sel_b+=("${b}")
  done
  if [ "${#sel_b[@]}" -eq 0 ]; then
    echo "  FAIL V9x DERIVATION YIELDED ZERO ROWS: builders that parse --optional-services"
    return 1
  fi
  echo "-- A) build time, EXECUTED: the real renderers against the real artefacts --"
  echo "   (resolved through $([ "${SELSVC_RESOLVER}" = 1 ] && echo 'tests/lib/opt-gate-source.sh' || echo 'the single-file fallback'); this leg derives its own"
  echo "    slug lists from the gate's own \`for slug in\` loops, so it is independent"
  echo "    of the V-* derivations printed below)"
  for b in "${sel_b[@]}"; do
    assert_direction A1 "${root}" "${b}" false ""
    local cov; cov="$(printf '%s\n' $(_covered_slugs "${b}" _opt_render_installed_services) $(_covered_slugs "${b}" _opt_render_optionalservice_cr) | sort -u | tr '\n' ' ')"
    assert_direction A2 "${root}" "${b}" true "${cov}"
  done
  echo
  echo "-- B) boot, EXECUTED: the gate prunes what the operator deselected --"
  for b in "${sel_b[@]}"; do
    assert_prune B4 "${root}" "${b}" "" absent
    local allsel; allsel="$(SC_REG="${root}/specs/cluster/optional-services.yaml" python3 -c '
import os, yaml
reg = yaml.safe_load(open(os.environ["SC_REG"], encoding="utf-8"))
print(" ".join(s["slug"] for s in (reg.get("spec") or {}).get("services") or []
                if s.get("buildGate") and s.get("apps")))')"
    assert_prune B4 "${root}" "${b}" "${allsel}" present
  done
  echo
}

# ── C8 — the SIBLING half: the endpoint C6's route points at must exist ──────
# hugmesh-admin-bff-api owns the superadmin optional-services control. The
# route_access row and the gateway route are in THIS repo; the handler is not. A
# row that forwards to a 404 is exactly the "registry row nothing reads" shape.
# NO CHECKOUT => UNVERIFIED and a NON-ZERO exit, never a silent skip: the leg that
# matters most is the one this repo cannot see. (Precedent: leg A of
# tests/scripts/test-federation-module-slugs.sh.)
# The Java OptionalServiceRegistry's slug parity is deliberately NOT re-asserted
# here — tests/scripts/test-optional-service-slug-closure.sh owns that surface.
analyse_sibling() {
  local rel="src/main/java/net/hugmesh/adminbff" real="" cand
  # A git WORKTREE lives wherever it was created (/var/tmp/... here), and its
  # siblings do not. The MAIN checkout's parent is where they are, and
  # `rev-parse --git-common-dir` is what points at it from inside a worktree.
  local famroot=""
  local gcd; gcd="$(git -C "${REPO}" rev-parse --git-common-dir 2>/dev/null)"
  if [ -n "${gcd}" ]; then
    [ "${gcd#/}" = "${gcd}" ] && gcd="${REPO}/${gcd}"
    famroot="$(cd "$(dirname "$(dirname "${gcd}")")" 2>/dev/null && pwd)"
  fi
  # An EXPLICIT root is authoritative: if the caller named one and it is not a
  # checkout, that is reported, not silently papered over by finding some other
  # copy on the box. (It is also what makes NC20 below expressible at all — on a
  # developer machine the sibling is always somewhere, so a control that could not
  # pin the search list could never exercise the absent path.)
  local cands=()
  if [ -n "${SELSVC_ADMIN_BFF_ROOT:-}" ]; then
    cands=("${SELSVC_ADMIN_BFF_ROOT}")
  else
    cands=("${REPO}/.stack-src/hugmesh-admin-bff-api"
           "$(cd "${REPO}/.." 2>/dev/null && pwd)/hugmesh-admin-bff-api"
           "${famroot:+${famroot}/hugmesh-admin-bff-api}")
  fi
  local shown=""
  for cand in "${cands[@]}"; do
    [ -n "${cand}" ] || continue
    shown="${shown}${shown:+, }${cand}"
    [ -d "${cand}/${rel}" ] && { real="${cand}"; break; }
  done
  echo "-- C) runtime, SIBLING: the superadmin endpoint itself --"
  if [ -z "${real}" ]; then
    # The list this prints is the list it SEARCHED. With SELSVC_ADMIN_BFF_ROOT set
    # that is exactly one path — printing the whole candidate menu (as this did)
    # named directories it never looked in, including one where the sibling really
    # is, which reads as "we looked everywhere" when we deliberately did not.
    echo "  UNVERIFIED C8 hugmesh-admin-bff-api is not checked out — the /bff/superadmin/optional-services handler was NOT inspected"
    echo "         searched (${#cands[@]}): ${shown:-<none>}"
    [ -n "${SELSVC_ADMIN_BFF_ROOT:-}" ] && \
      echo "         (SELSVC_ADMIN_BFF_ROOT is set and AUTHORITATIVE — no fallback path was tried)"
    echo "         => C6 proves the ROUTE exists; only this leg can prove the endpoint does."
    echo
    return 3
  fi

  # ── WHICH SOURCE, EXACTLY (V3, 2026-08-27) ─────────────────────────────────
  # C8 is a SOURCE check: the question is whether hugmesh-admin-bff-api's main
  # declares the handler. A working tree is not that question's answer — it is
  # whatever the developer last pulled. On 2026-08-27 the local checkout sat 9
  # commits behind its own origin/main; PR #43 (the controller) had merged at
  # 07:04 UTC and was ON main, and C8 nevertheless printed
  #     FAIL C8 hugmesh-admin-bff-api declares NO ... mapping
  # — a FALSE red about the sibling's source, recorded as a defect in two files.
  # So: if the checkout is BEHIND its own remote-tracking default branch, measure
  # THAT REF instead (offline, from objects the checkout already has). If the ref
  # cannot be materialised, the leg is UNVERIFIED — a stale checkout cannot answer
  # a question about main, and must not be allowed to answer it wrongly.
  #
  # KEEP THIS APART from the DEPLOYMENT question. Whether the running admin-bff
  # IMAGE carries the handler is a different fact with a different answer (the jar
  # on kind-hugmesh-local was built at 06:19 UTC, 45 minutes before the endpoint
  # merged, so it does NOT). That is deployment lag, not source, and no check here
  # measures it.
  local srcdir="${real}/${rel}" measured="the directory as given (not a git checkout)" ref="" behind=0
  local top; top="$(git -C "${real}" rev-parse --show-toplevel 2>/dev/null || true)"
  # It must be THIS directory's own repository. `git -C` walks upwards, so a plain
  # directory that merely SITS inside some other checkout (a synthesised fixture
  # under ${TMPDIR}, say) would otherwise be measured against that repo's refs.
  if [ -n "${top}" ] && [ "$(cd "${top}" 2>/dev/null && pwd -P)" = "$(cd "${real}" 2>/dev/null && pwd -P)" ]; then
    local r
    for r in origin/main origin/HEAD origin/master; do
      git -C "${real}" rev-parse --verify -q "${r}^{commit}" >/dev/null 2>&1 && { ref="${r}"; break; }
    done
    local head; head="$(git -C "${real}" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if [ -n "${ref}" ]; then
      behind="$(git -C "${real}" rev-list --count "HEAD..${ref}" 2>/dev/null || echo 0)"
    fi
    if [ "${behind:-0}" -gt 0 ]; then
      local exp="${W}/sibsrc.$$"; rm -rf "${exp}"; mkdir -p "${exp}"
      if git -C "${real}" archive "${ref}" -- "${rel}" 2>/dev/null | tar -x -C "${exp}" 2>/dev/null \
         && [ -d "${exp}/${rel}" ]; then
        srcdir="${exp}/${rel}"
        measured="${ref} ($(git -C "${real}" rev-parse --short "${ref}")), ${behind} commit(s) ahead of the working tree at ${head}"
      else
        echo "  UNVERIFIED C8 $(basename "${real}") is ${behind} commit(s) behind ${ref} and this guard could not materialise that ref offline (a blobless/partial clone, or the objects are absent)"
        echo "         the working tree at ${head} is NOT the sibling's main, so it cannot answer a source question about main"
        echo "         => fetch the sibling, or point SELSVC_ADMIN_BFF_ROOT at a current clone."
        echo
        return 3
      fi
    else
      measured="the working tree at ${head}$([ -n "${ref}" ] && echo " (level with ${ref})")"
    fi
  fi

  local out="${W}/c8.txt"
  # Comment-stripped (line and block), so a Javadoc naming the path cannot satisfy
  # this — the same prose-inversion rule every other check here obeys.
  SC_SRC="${srcdir}" python3 - > "${out}" <<'PY'
import os, re, sys
src = os.environ["SC_SRC"]
def strip_java(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return "\n".join("" if l.lstrip().startswith("//") else l for l in t.split("\n"))
hits = []
for dp, _, fns in os.walk(src):
    for fn in fns:
        if not fn.endswith(".java") or "/test/" in dp.replace(os.sep, "/"):
            continue
        p = os.path.join(dp, fn)
        t = strip_java(open(p, encoding="utf-8", errors="replace").read())
        for m in re.finditer(r'"(/bff/superadmin/optional-services[^"]*)"', t):
            hits.append("%s %s" % (os.path.relpath(p, src), m.group(1)))
# NOT `print("\n".join(...))`: with no hits that writes a single newline, the file
# is then non-empty, `[ -s ]` is true, and this leg reports a PASS over ZERO
# findings — the vacuous pass, planted by nothing but output formatting. Caught
# on the first real run (it "passed" against a checkout that has no such
# endpoint). Write nothing when there is nothing.
for h in sorted(set(hits)):
    print(h)
PY
  # `grep -c .` counts NON-EMPTY lines, so a stray newline cannot be a hit.
  local n; n="$(grep -c . "${out}" 2>/dev/null || true)"
  if [ "${n:-0}" -gt 0 ]; then
    echo "  PASS C8 the superadmin optional-services endpoint exists in $(basename "${real}"): ${n} mapping(s), first in $(grep -m1 . "${out}" | awk '{print $1}')"
    echo "         measured against ${measured}"
    echo
    return 0
  fi
  echo "  FAIL C8 $(basename "${real}") declares NO /bff/superadmin/optional-services mapping"
  echo "         measured against ${measured}"
  echo "         (searched ${rel}, comments stripped)"
  echo "         => C6's route_access row and gateway route forward a superadmin"
  echo "            request to a handler that does not exist: HTTP 404, not a toggle."
  echo "         GREEN WHEN: hugmesh-admin-bff-api's main declares the superadmin"
  echo "            optional-services controller."
  echo
  return 1
}

# =============================================================================
# NEGATIVE CONTROLS. Each one plants a defect — or, for the checks that are RED on
# today's tree, plants the FIX — in a sandbox copy of the REAL tree and requires
# the NAMED check to move. A check stuck green and a check stuck red are the same
# failure: an assertion that is not reading what it claims to read.
#
# Every mutation is byte-verified (cmp against the pre-image) before the guard is
# re-run, so a sed that silently matched nothing is reported instead of being
# mistaken for a passing control.
#
# THREE OF V1'S SIXTEEN HAD GONE STALE against the tree that moved under them, and
# are replaced here. CORRECTING THE RECORD: V2's commit message and this comment
# both said they "measured nothing" and "passed while measuring nothing". That was
# wrong, and overstated in the direction that flatters the replacement. MEASURED,
# from the code: every one of the three would have reported FAIL, loudly, on the
# very next run —
#   NC4  broke a sed anchor inside build-x86-host-stage4.sh. That sed had moved
#        into scripts/_optional-services-lib.sh, so the mutation matched nothing,
#        `changed()` returned false and the control printed
#        "FAIL NC4 mutation changed nothing". It now mutates the library, which is
#        what both builders resolve.
#   NC9  planted prose and required A3 to STAY red. A3 is green now, so the
#        `status_of A3 = FAIL` arm could never be taken and the control printed
#        "FAIL NC9 prose satisfied A3 (A3=PASS) — comment stripping is not working".
#        LOUD, but MISDESCRIBED: comment stripping was fine; A3 had moved. It now
#        plants the real thing prose used to stand in for — a builder-LOCAL no-op
#        override of a renderer — WITH the prose on top, and requires A3 red anyway.
#   NC11 deleted apps/30-akkoma.yaml and required B1 to stop naming akkoma. B1 no
#        longer enumerates Applications, so it printed "FAIL NC11 B1 still names
#        akkoma after its Application was deleted — B1 is stuck". Again loud, again
#        misdescribed. It now deletes the gate's `rm -f` of that file and requires
#        B4 to name it.
# So the defect was NOT a silent vacuous pass; it was three controls whose FAILURE
# MESSAGE named the wrong cause, which is a slower kind of wrong: it sends the
# reader to fix comment stripping, or B1, instead of the control. The replacements
# were right; the reason given for them was not.
# =============================================================================
NCP=0; NCF=0
nc_ok()  { echo "  PASS $*"; NCP=$((NCP+1)); }
nc_bad() { echo "  FAIL $*"; NCF=$((NCF+1)); }

run_legs() {   # $1 root, $2 outfile, $3 static|exec|both
  case "$3" in
    exec)   analyse_executed "$1" >"$2" 2>&1 ;;
    static) analyse_static   "$1" >"$2" 2>&1 ;;
    *)      { analyse_executed "$1"; analyse_static "$1"; } >"$2" 2>&1 ;;
  esac
  return 0
}
status_of() {  # $1 outfile, $2 check id -> PASS|FAIL|UNVERIFIED|ABSENT (first hit)
  awk -v id="$2" '($1=="PASS"||$1=="FAIL"||$1=="UNVERIFIED") && $2==id && !f { print $1; f=1 }
                  END { if (!f) print "ABSENT" }' "$1"
}
has_line() {   # $1 outfile, $2 ERE — grep, never `grep -q`, so a match cannot SIGPIPE
  grep -E -- "$2" "$1" >/dev/null 2>&1
}
changed() {    # $1 file, $2 pre-image
  if cmp -s "$1" "$2"; then return 1; fi
  return 0
}

negative_controls() {
  local MASTER="${W}/master" SB="${W}/sb" OUT="${W}/nc.out" PRE="${W}/nc.pre"
  echo "-- negative controls (mutations planted in a sandbox copy of the real tree) --"
  sandbox_root "${MASTER}"
  [ -f "${MASTER}/specs/cluster/${APPSET_LEAF}" ] || { nc_bad "NC0 sandbox is not a usable copy"; return; }
  [ -f "${MASTER}/scripts/_optional-services-lib.sh" ] || { nc_bad "NC0 sandbox carries no gate library — every A/B result from it would be noise"; return; }
  # NC0 — the sandbox must reproduce the real verdict, or every result below is noise.
  local base="${W}/nc.base"
  run_legs "${MASTER}" "${base}" both
  local realout="${W}/real.out"
  local id diff=""
  for id in A1 A2 A3 A4 B1 B2 B3 B4 C1 C2 C3 C4 C5 C5b C6 C7; do
    [ "$(status_of "${base}" "${id}")" = "$(status_of "${realout}" "${id}")" ] || diff="${diff} ${id}"
  done
  if [ -z "${diff}" ]; then
    nc_ok "NC0 the sandbox copy reproduces the real tree's per-check status"
  else
    nc_bad "NC0 sandbox disagrees with the real tree on:${diff} — controls below are unreadable"
    return
  fi

  _reset() { rm -rf "${SB}"; cp -r "${MASTER}" "${SB}"; }

  # _plant_jetson_gate <file> <mode:unreachable|early|fixed> — give
  # build-jetson-stage4.sh the two things A4 needs BESIDES a call (the sourced
  # gate library and --optional-services parsing), so the three modes differ in
  # exactly ONE thing: WHERE the call is. That is what makes NC10c/NC10d/NC10e a
  # measurement of reachability and ordering rather than of the other two legs.
  _plant_jetson_gate() {
    SC_F="$1" SC_MODE="$2" python3 - <<'PY'
import os, sys
p = os.environ["SC_F"]; mode = os.environ["SC_MODE"]
L = open(p, encoding="utf-8").read().split("\n")
L[1:1] = [
    'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    'source "${SCRIPT_DIR}/scripts/_optional-services-lib.sh"',
    'while [ $# -gt 0 ]; do',
    '    case "$1" in',
    '        --optional-services) OPTIONAL_SERVICES="$2"; shift 2 ;;',
    '        *) shift ;;',
    '    esac',
    'done',
    '',
]
if mode == "fixed":
    for i, l in enumerate(L):
        if l.strip().startswith('info "Baked shared cluster GitOps tree'):
            L[i + 1:i + 1] = ["        gate_optional_services"]
            break
    else:
        sys.exit("anchor: the bake info line")
else:
    add = (['_selected_services_note() {', '    gate_optional_services', '}', '']
           if mode == "unreachable" else ['gate_optional_services', ''])
    for i, l in enumerate(L):
        if l.startswith('if [ "${ROLE_K8S}" != "none" ]; then'):
            L[i:i] = add
            break
    else:
        sys.exit("anchor: the ROLE_K8S bake block")
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  }

  # ── NC1 — the SELECTOR dropped from the ApplicationSet ────────────────────
  _reset; local f="${SB}/specs/cluster/${APPSET_LEAF}"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r'\n      selector:\n        matchLabels:\n          installed: "true"\n', "\n", s, count=1)
open(p, "w", encoding="utf-8").write(s)
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    [ "$(status_of "${OUT}" C1)" = "FAIL" ] \
      && nc_ok "NC1 selector dropped from the ApplicationSet -> C1 RED" \
      || nc_bad "NC1 selector dropped and C1 is $(status_of "${OUT}" C1) — every element would generate"
  else nc_bad "NC1 mutation changed nothing"; fi

  # ── NC2 — an element flipped to installed:"true" IN GIT ───────────────────
  _reset; f="${SB}/specs/cluster/${APPSET_LEAF}"; cp "${f}" "${PRE}"
  sed -i 's/\(slug: coturn,.*installed: "\)false"/\1true"/' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" B3)" = "FAIL" ] && has_line "${OUT}" '^ +coturn: .*element installed'; then
      nc_ok "NC2 a git element flipped installed:\"true\" -> B3 names coturn"
    else
      nc_bad "NC2 element flipped true in git and B3 did not name coturn (B3=$(status_of "${OUT}" B3))"
    fi
  else nc_bad "NC2 mutation changed nothing"; fi

  # ── NC3 — the ignoreDifferences pointer aimed at the WRONG generator index ─
  _reset; f="${SB}/specs/cluster/app-of-apps.yaml"; cp "${f}" "${PRE}"
  sed -i 's#- /spec/generators/0/list/elements#- /spec/generators/1/list/elements#' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" C2)" = "FAIL" ] && has_line "${OUT}" 'generators/1/list/elements does not resolve'; then
      nc_ok "NC3 jsonPointer at the wrong generator index -> C2 RED and names the pointer"
    else
      nc_bad "NC3 wrong generator index and C2 is $(status_of "${OUT}" C2) — the seam protects nothing"
    fi
  else nc_bad "NC3 mutation changed nothing"; fi

  # ── NC4 — the ConfigMap renderer's sed ANCHOR broken so it no-ops at rc 0 ──
  # V1 mutated build-x86-host-stage4.sh, where that sed used to live. It lives in
  # scripts/_optional-services-lib.sh now, so V1's mutation matched nothing and the
  # control had been reporting "changed nothing" — i.e. measuring nothing.
  _reset; f="${SB}/scripts/_optional-services-lib.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = r'''sed -i -E "s#^([[:space:]]*)${slug}:'''
if s.count(old) >= 1:
    open(p, "w", encoding="utf-8").write(s.replace(old, old.replace("${slug}", "XX${slug}"), 1))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" exec
    if has_line "${OUT}" '^  FAIL A2 ' && has_line "${OUT}" 'ConfigMap/akkoma=false'; then
      nc_ok "NC4 ConfigMap renderer anchor broken in the shared library (silent rc-0 no-op) -> A2 RED"
    else
      nc_bad "NC4 anchor broken and A2 did not go red"; sed -n '1,12p' "${OUT}" | sed 's/^/        | /'
    fi
  else nc_bad "NC4 mutation changed nothing"; fi

  # ── NC5 — the SUPERADMIN write path removed ───────────────────────────────
  _reset; f="${SB}/specs/cluster/manifests/route-access/initdb/20-schema.sql"; cp "${f}" "${PRE}"
  sed -i "/'\/bff\/superadmin\/\*\*'/d" "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" C6)" = "FAIL" ] && has_line "${OUT}" 'no enabled ROLE_SUPERADMIN route_access row'; then
      nc_ok "NC5 superadmin route_access rows deleted -> C6 RED"
    else
      nc_bad "NC5 superadmin rows deleted and C6 is $(status_of "${OUT}" C6)"
    fi
  else nc_bad "NC5 mutation changed nothing"; fi

  # ── NC6 — an ignoreDifferences /data key dropped from apps/16 ─────────────
  _reset; f="${SB}/specs/cluster/apps/16-reserved-prefixes-policy.yaml"; cp "${f}" "${PRE}"
  sed -i '\#^ *- /data/akkoma$#d' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" C3)" = "FAIL" ] && has_line "${OUT}" 'no pointer that resolves to their /data node: .*akkoma'; then
      nc_ok "NC6 /data/akkoma dropped from the ConfigMap seam -> C3 names akkoma"
    else
      nc_bad "NC6 pointer dropped and C3 did not name akkoma (C3=$(status_of "${OUT}" C3))"
    fi
  else nc_bad "NC6 mutation changed nothing"; fi

  # ── NC7 — a new element slug that exists in no other source ───────────────
  _reset; f="${SB}/specs/cluster/${APPSET_LEAF}"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    m = re.match(r"^( *)- \{ slug: coturn,", l)
    if m:
        L.insert(i, m.group(1) + '- { slug: ghostsvc, path: specs/cluster/manifests/ghostsvc, '
                                 'namespace: hugmesh-backend, installed: "false" }')
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" C4)" = "FAIL" ] && has_line "${OUT}" 'ghostsvc'; then
      nc_ok "NC7 an element slug absent from the registry/CRD/seed -> C4 names ghostsvc"
    else
      nc_bad "NC7 orphan element added and C4 did not name it (C4=$(status_of "${OUT}" C4))"
    fi
  else nc_bad "NC7 mutation changed nothing"; fi

  # ── NC8 — VACUITY: blind a derivation; the run must ABORT, not pass ───────
  _reset; f="${SB}/specs/cluster/optional-services.yaml"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    if l == "  services:":
        L[i] = "  servicesXX:"
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if has_line "${OUT}" 'FAIL V1 DERIVATION YIELDED ZERO ROWS' && ! has_line "${OUT}" '^  PASS '; then
      nc_ok "NC8 a blinded derivation ABORTS the run (V1 RED, zero PASS lines) — no vacuous green"
    else
      nc_bad "NC8 derivation blinded but the run did not abort: $(grep -c '^  PASS ' "${OUT}") PASS line(s)"
    fi
  else nc_bad "NC8 mutation changed nothing"; fi

  # ── NC9 — THE RESOLVER + COMMENT-TOKEN INVERSION, in one control ──────────
  # Plant a builder-LOCAL no-op override of a renderer (the exact defect class the
  # source-chain resolver exists for — a copy that drifted in one builder), AND
  # prose naming every artefact and function the check greps. bash runs the
  # override; A3 must therefore go RED for that builder, and the prose must not
  # rescue it. V1's version planted prose alone and required A3 to STAY red, which
  # is unreachable now that A3 is green — a control that can only report the state
  # it already found is not a control.
  _reset; f="${SB}/build-x86-host-stage4.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    if l.startswith('source "${SCRIPT_DIR}/scripts/_optional-services-lib.sh"'):
        L[i + 1:i + 1] = [
            '# apps/13a-optional-services.yaml manifests/policy/installed-services-configmap.yaml',
            '# manifests/optional-services-operator/seed-optionalservices.yaml',
            '# _opt_render_appset_flag _opt_render_installed_services gate_optional_services',
            '  _opt_render_installed_services ()  {',
            '    return 0',
            '}',
        ]
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" A3)" = "FAIL" ] && has_line "${OUT}" 'build-x86-host-stage4\.sh never writes:'; then
      nc_ok "NC9 a builder-LOCAL no-op renderer override (+ prose naming every token) -> A3 RED for x86"
    else
      nc_bad "NC9 the override was invisible or the prose satisfied A3 (A3=$(status_of "${OUT}" A3)) — the resolver or the comment stripping is not working"
    fi
  else nc_bad "NC9 mutation changed nothing"; fi

  # ── NC10 — a baking builder loses its gate call ───────────────────────────
  _reset; f="${SB}/build-rpi5-stage4.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    m = re.match(r"^( *)gate_optional_services(\s|$)", l)
    if m:
        L[i] = m.group(1) + ": skipped_gate"
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" A4)" = "FAIL" ] && has_line "${OUT}" 'build-rpi5-stage4\.sh bakes the cluster tree with NO gate_optional_services call'; then
      nc_ok "NC10 gate_optional_services call removed from build-rpi5-stage4.sh -> A4 names it"
    else
      nc_bad "NC10 gate call removed and A4 did not name rpi5 (A4=$(status_of "${OUT}" A4))"
    fi
  else nc_bad "NC10 mutation changed nothing"; fi

  # ── NC11 — the gate stops pruning a slug's Application ────────────────────
  # V1's NC11 deleted apps/30-akkoma.yaml and required B1 to stop naming it. B1
  # does not enumerate Applications any more (PR #183 moved that question), so the
  # control was measuring a check that no longer exists. This plants the defect
  # that MATTERS under the new topology: the gate silently stops deleting the file,
  # and bootstrap.sh then applies it verbatim onto the device.
  _reset; f="${SB}/scripts/_optional-services-lib.sh"; cp "${f}" "${PRE}"
  # Delimiter is `|`: `#` is the shell comment char AND was the sed delimiter here,
  # so the replacement `\1: # pruned` closed the s/// early and sed died with
  # "unknown option to `s'" — the control then reported "mutation changed nothing"
  # for a mutation it never attempted. Caught by running it.
  sed -i 's|^\([[:space:]]*\)rm -f "${apps}/30-akkoma.yaml"|\1: prune_removed|' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" exec
    if [ "$(status_of "${OUT}" B4)" = "FAIL" ] && has_line "${OUT}" 'akkoma STILL PRESENT: apps/30-akkoma\.yaml'; then
      nc_ok "NC11 the gate stops pruning apps/30-akkoma.yaml -> B4 names akkoma"
    else
      nc_bad "NC11 prune removed and B4 did not name akkoma (B4=$(status_of "${OUT}" B4))"
    fi
  else nc_bad "NC11 mutation changed nothing"; fi

  # ── NC11b — the gate prunes a SELECTED slug (the opposite failure) ────────
  # A gate that deletes unconditionally satisfies the deselect direction. Make the
  # akkoma arm unconditional and require the select direction to catch it.
  _reset; f="${SB}/scripts/_optional-services-lib.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace('        _opt_selected "${slug}" && continue\n',
              '        case "${slug}" in akkoma) ;; *) _opt_selected "${slug}" && continue ;; esac\n', 1)
open(p, "w", encoding="utf-8").write(s)
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" exec
    if has_line "${OUT}" 'akkoma WRONGLY PRUNED: apps/30-akkoma\.yaml'; then
      nc_ok "NC11b a gate that prunes a SELECTED slug -> B4's select direction names akkoma"
    else
      nc_bad "NC11b unconditional prune and B4 stayed green in the select direction"
    fi
  else nc_bad "NC11b mutation changed nothing"; fi

  # ── NC12 — STUCK-RED control for B2: plant the FIX ────────────────────────
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    if l.startswith('kubectl apply -f "${CLUSTER_DIR}/namespaces/'):
        L.insert(i + 1, 'kubectl apply -f "${CLUSTER_DIR}/manifests/policy/installed-services-configmap.yaml"')
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if ! has_line "${OUT}" 'applied by NOTHING at boot:.*installed-services-configmap'; then
      nc_ok "NC12 boot applying the baked ConfigMap -> B2 stops naming it (not stuck red)"
    else
      nc_bad "NC12 B2 still names the ConfigMap after bootstrap.sh applies it — B2 is stuck"
    fi
  else nc_bad "NC12 mutation changed nothing"; fi

  # ── NC12b — V10 must SEE the indirect baked-apps apply loop ───────────────
  # PR #183's apply is `for _app in "${CLUSTER_DIR}"/apps/*.yaml; do apply_baked_app`,
  # not a literal one-line `kubectl apply -f <path>`. If V10 stopped deriving that
  # form, B1 would go red against the fix and B2 would name apps/13a again — a
  # FALSE red aimed at the keystone. Break the loop and require exactly that.
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  sed -i 's#^\([[:space:]]*\)for _app in "\${CLUSTER_DIR}"/apps/\*\.yaml; do#\1for _app in /nonexistent/apps/*.yaml; do#' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" B1)" = "FAIL" ] && has_line "${OUT}" 'no boot script applies .*apps'; then
      nc_ok 'NC12b the baked-apps apply loop repointed off ${CLUSTER_DIR} -> B1 RED (V10 really derives the indirect form)'
    else
      nc_bad "NC12b the apply loop was broken and B1 is $(status_of "${OUT}" B1) — V10 is not reading the loop"
    fi
  else nc_bad "NC12b mutation changed nothing"; fi

  # ── NC12c — B1's OTHER half: the escape hatch must STAY an escape hatch ───
  # NC12b proves B1 sees the baked-apps loop. This proves it also refuses the
  # repo-recursing root when that root is on the DEFAULT path: flip the switch's
  # default from 0 to 1 and a device once again syncs specs/cluster/apps from
  # GitHub, discarding every build-time prune — with the baked loop still present
  # and still passing the first half of the check.
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  sed -i 's|HUGMESH_GITOPS_ROOT_RECURSE:-0|HUGMESH_GITOPS_ROOT_RECURSE:-1|' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" B1)" = "FAIL" ] && has_line "${OUT}" 'the DEFAULT takes that branch'; then
      nc_ok "NC12c the repo-recursing root switched default-ON -> B1 RED (the hatch is checked, not just present)"
    else
      nc_bad "NC12c the recursing root defaults ON and B1 is $(status_of "${OUT}" B1) — B1 reads only the baked loop"
    fi
  else nc_bad "NC12c mutation changed nothing"; fi

  # ── NC13 — STUCK-RED control for C5b, both directions (value, not presence) ─
  _reset; f="${SB}/specs/cluster/manifests/admin-bff-api/deployment.yaml"; cp "${f}" "${PRE}"
  sed -i 's#{ name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: "false" }#{ name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: "true" }#' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    # With the switch ON but the cut-over still open, C5b must STILL be red — and
    # for the OTHER reason. A check that only reads the value would flip green here
    # and declare an enable path that double-manages every manifest directory C5b
    # lists. (This comment used to say "eight". C5b DERIVES that list and prints
    # eleven; a hand-written count in a comment beside a derived one is exactly the
    # drift this file exists to catch, so it no longer carries a number at all.)
    if [ "$(status_of "${OUT}" C5b)" = "FAIL" ] && has_line "${OUT}" 'have NOT been cut over'; then
      nc_ok "NC13 flipping the switch to \"true\" alone -> C5b RED for the CUT-OVER, not the value"
    else
      nc_bad "NC13 C5b is $(status_of "${OUT}" C5b) with the switch on and the cut-over open — it reads only the value"
    fi
  else nc_bad "NC13 mutation changed nothing"; fi

  # ── NC13b — C5's LEVER half: delete the declaration entirely ──────────────
  _reset; f="${SB}/specs/cluster/manifests/admin-bff-api/deployment.yaml"; cp "${f}" "${PRE}"
  sed -i '/{ name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED,/d' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" C5)" = "FAIL" ] && has_line "${OUT}" 'declared NOWHERE in the deployed manifest'; then
      nc_ok "NC13b the master switch declaration deleted -> C5 RED (there is no lever at all)"
    else
      nc_bad "NC13b declaration deleted and C5 is $(status_of "${OUT}" C5)"
    fi
  else nc_bad "NC13b mutation changed nothing"; fi

  # ── NC14 — STUCK-RED control for C7: plant the finalizer ──────────────────
  _reset; f="${SB}/specs/cluster/${APPSET_LEAF}"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace('    metadata:\n      name: "optional-{{ .slug }}"\n',
              '    metadata:\n      name: "optional-{{ .slug }}"\n'
              '      finalizers:\n        - resources-finalizer.argocd.argoproj.io\n', 1)
open(p, "w", encoding="utf-8").write(s)
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    [ "$(status_of "${OUT}" C7)" = "PASS" ] \
      && nc_ok "NC14 adding the ArgoCD resources-finalizer to the template -> C7 green (not stuck red)" \
      || nc_bad "NC14 C7 stayed $(status_of "${OUT}" C7) with the finalizer present — C7 is stuck"
  else nc_bad "NC14 mutation changed nothing"; fi

  # ── NC15 — the OptionalService CR awk anchor defeated by legal YAML ───────
  # The gate's awk arms on an exact `slug: <slug>` compare. Quoting the slug is
  # valid YAML and changes nothing semantically; it silently disarms the renderer
  # while it still returns 0 and prints its success line.
  _reset; f="${SB}/specs/cluster/${SEED_LEAF}"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    m = re.match(r"^( *)slug: (akkoma|tuwunel|phpbb)$", l)
    if m:
        L[i] = '%sslug: "%s"' % (m.group(1), m.group(2))
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" exec
    if has_line "${OUT}" '^  FAIL A[12] ' && has_line "${OUT}" 'OptionalService/(akkoma|tuwunel|phpbb)='; then
      nc_ok "NC15 quoting a slug in the seed CRs defeats the awk anchor -> A1/A2 RED (the rc-0 fail-open)"
    else
      nc_bad "NC15 the CR renderer silently no-opped and A1/A2 stayed green"
    fi
  else nc_bad "NC15 mutation changed nothing"; fi

  # ── NC16 — STUCK-RED control for A2's DERIVED 13a expectation ─────────────
  # Cut akkoma over (delete its hardcoded Application) and the double-management
  # guard must stop holding its 13a flag at "false": A2 must expect — and get —
  # installed:"true" for akkoma, with no new failure. If A2 had hard-coded either
  # answer it would go red here, in one direction or the other.
  _reset; rm -f "${SB}/specs/cluster/apps/30-akkoma.yaml"
  if [ ! -f "${SB}/specs/cluster/apps/30-akkoma.yaml" ]; then
    run_legs "${SB}" "${OUT}" exec
    if [ "$(status_of "${OUT}" A2)" = "PASS" ] && ! has_line "${OUT}" '13a/akkoma='; then
      nc_ok "NC16 akkoma cut over -> A2's DERIVED 13a expectation flips to true and still passes"
    else
      nc_bad "NC16 A2 is $(status_of "${OUT}" A2) after the cut-over — its 13a expectation is not derived"
      grep -E '^  FAIL A2|13a/' "${OUT}" | sed 's/^/        | /'
    fi
  else nc_bad "NC16 mutation changed nothing"; fi

  # ── NC17 — VACUITY of the EXECUTED prune leg ──────────────────────────────
  # Blind the registry's apps[] declarations and B4 must ABORT on a zero-row
  # derivation, never report "all 0 file(s) absent".
  _reset; f="${SB}/specs/cluster/optional-services.yaml"; cp "${f}" "${PRE}"
  sed -i 's/^\([[:space:]]*\)buildGate:/\1buildGateXX:/' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" exec
    if has_line "${OUT}" 'FAIL B4 .*DERIVATION YIELDED ZERO ROWS'; then
      nc_ok "NC17 a blinded buildGate[] makes B4 ABORT, not report an empty set as passing"
    else
      nc_bad "NC17 B4 did not abort on a zero-row derivation (B4=$(status_of "${OUT}" B4))"
    fi
  else nc_bad "NC17 mutation changed nothing"; fi

  # ── NC18/NC19/NC20 — the SIBLING leg (C8), all three of its outcomes ──────
  # The real checkout can only ever demonstrate the state it happens to be in
  # (today: no endpoint, so RED). A leg that has only ever been observed in one
  # state is indistinguishable from one that is stuck, so the other two outcomes
  # are exercised against SYNTHESISED checkouts. Nothing here reads, writes or
  # fetches the real sibling repo.
  local SIBR="${W}/sib" REL="src/main/java/net/hugmesh/adminbff"

  # NC18 — a checkout that DOES declare the mapping must go GREEN.
  rm -rf "${SIBR}/green"; mkdir -p "${SIBR}/green/${REL}/optionalservices"
  cat > "${SIBR}/green/${REL}/optionalservices/SuperadminOptionalServiceController.java" <<'JAVA'
package net.hugmesh.adminbff.optionalservices;
@RestController
@RequestMapping("/bff/superadmin/optional-services")
public class SuperadminOptionalServiceController { }
JAVA
  if SELSVC_ADMIN_BFF_ROOT="${SIBR}/green" analyse_sibling >"${OUT}" 2>&1; then
    [ "$(status_of "${OUT}" C8)" = "PASS" ] \
      && nc_ok "NC18 a checkout declaring /bff/superadmin/optional-services -> C8 GREEN (not stuck red)" \
      || nc_bad "NC18 C8 is $(status_of "${OUT}" C8) against a checkout that declares the mapping"
  else
    nc_bad "NC18 C8 is $(status_of "${OUT}" C8) against a checkout that declares the mapping"
  fi

  # NC19 — the same path named ONLY in prose must NOT satisfy it. This is the
  # comment-token inversion rule applied to the one leg whose corpus is Java: a
  # Javadoc `@link` or a `//` note naming the endpoint is documentation, not a
  # handler, and a plain text scan would call it a pass.
  rm -rf "${SIBR}/prose"; mkdir -p "${SIBR}/prose/${REL}/optionalservices"
  cat > "${SIBR}/prose/${REL}/optionalservices/OptionalServiceReconciler.java" <<'JAVA'
package net.hugmesh.adminbff.optionalservices;
/**
 * Reconciles OptionalService CRs. The superadmin console calls
 * "/bff/superadmin/optional-services/{slug}" to flip one of these.
 */
// TODO: expose "/bff/superadmin/optional-services" here.
public class OptionalServiceReconciler { }
JAVA
  SELSVC_ADMIN_BFF_ROOT="${SIBR}/prose" analyse_sibling >"${OUT}" 2>&1
  if [ "$(status_of "${OUT}" C8)" = "FAIL" ]; then
    nc_ok "NC19 the endpoint named ONLY in Javadoc/line comments does NOT satisfy C8"
  else
    nc_bad "NC19 C8 is $(status_of "${OUT}" C8) against a checkout where the path exists only in prose"
  fi

  # NC20 — no checkout at all must be UNVERIFIED and NON-ZERO, never a skip.
  rm -rf "${SIBR}/absent"; mkdir -p "${SIBR}/absent"
  SELSVC_ADMIN_BFF_ROOT="${SIBR}/absent" analyse_sibling >"${OUT}" 2>&1; local sibrc=$?
  if [ "$(status_of "${OUT}" C8)" = "UNVERIFIED" ] && [ "${sibrc}" -ne 0 ]; then
    nc_ok "NC20 no sibling checkout -> C8 UNVERIFIED and rc=${sibrc} (non-zero), never a silent skip"
  else
    nc_bad "NC20 no sibling checkout -> C8=$(status_of "${OUT}" C8) rc=${sibrc} — a missing checkout must not be a pass"
  fi

  # ══ V3 CONTROLS ═══════════════════════════════════════════════════════════
  # Two independent adversarial reviews defeated four checks below with mutations
  # that left them GREEN. Each of those mutations is now a control, planted the
  # same way it was planted then, and each one's check must go RED. The FIX-
  # planting halves for the five checks that are red on this tree are here too —
  # .gitlab-ci.yml claimed all of them had one and only C7 and C8 did.

  # ── NC10b — A4: the gate named ONLY in a usage heredoc ───────────────────
  # build-x86-host-stage4.sh's `usage()` help text names gate_optional_services at
  # the start of a line (line ~635). V2's A4 was a line-anchored NAME scan over the
  # whole file, so deleting x86's REAL call left A4 green, satisfied by help text.
  _reset; f="${SB}/build-x86-host-stage4.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import re, sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    m = re.match(r"^( *)gate_optional_services(\s|$)", l)
    if m and "usage" not in l:
        L[i] = m.group(1) + ": call_deleted"
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" A4)" = "FAIL" ] && has_line "${OUT}" 'build-x86-host-stage4\.sh bakes the cluster tree with NO gate_optional_services call'; then
      nc_ok "NC10b x86's real gate call deleted, the name left in usage() -> A4 RED (heredocs are not evidence)"
    else
      nc_bad "NC10b A4 is $(status_of "${OUT}" A4) with x86's only real call gone — usage prose is satisfying it"
    fi
  else nc_bad "NC10b mutation changed nothing"; fi

  # ── NC10c — A4: a gate call inside a function nothing invokes ────────────
  _reset; f="${SB}/build-jetson-stage4.sh"; cp "${f}" "${PRE}"
  _plant_jetson_gate "${f}" unreachable
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" A4)" = "FAIL" ] && has_line "${OUT}" 'NONE of those calls is reachable'; then
      nc_ok "NC10c the gate sourced, --optional-services parsed, call in a function nothing invokes -> A4 RED"
    else
      nc_bad "NC10c A4 is $(status_of "${OUT}" A4) against an unreachable gate call — A4 is still a name scan"
    fi
  else nc_bad "NC10c mutation changed nothing"; fi

  # ── NC10d — A4: a REACHABLE gate call that runs BEFORE the bake ──────────
  _reset; f="${SB}/build-jetson-stage4.sh"; cp "${f}" "${PRE}"
  _plant_jetson_gate "${f}" early
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" A4)" = "FAIL" ] && has_line "${OUT}" 'do not run after it on the same path'; then
      nc_ok "NC10d a reachable gate call placed BEFORE the tree copy -> A4 RED (ordering is checked)"
    else
      nc_bad "NC10d A4 is $(status_of "${OUT}" A4) with the gate running before the bake"
    fi
  else nc_bad "NC10d mutation changed nothing"; fi

  # ── NC10e — STUCK-RED control for A4: plant the REAL FIX ─────────────────
  _reset; f="${SB}/build-jetson-stage4.sh"; cp "${f}" "${PRE}"
  _plant_jetson_gate "${f}" fixed
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    [ "$(status_of "${OUT}" A4)" = "PASS" ] \
      && nc_ok "NC10e jetson sources the lib, parses --optional-services and gates AFTER the copy -> A4 green (not stuck red)" \
      || { nc_bad "NC10e A4 stayed $(status_of "${OUT}" A4) with the real fix planted — A4 is stuck"; grep -E '^  FAIL A4|^         build-jetson' "${OUT}" | sed 's/^/        | /'; }
  else nc_bad "NC10e mutation changed nothing"; fi

  # ── NC12d — B1: the root apply reached through a VARIABLE and a FUNCTION ──
  # The mutation that defeated V2's B1. The filename literal sits six lines above
  # the apply (outside the ±3 window V2 searched) and the call is unconditional.
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
FN = ['apply_root_app_of_apps() {',
      '    local f="${CLUSTER_DIR}/app-of-apps.yaml"',
      '    [ -f "${f}" ] || return 0',
      '    echo "==> applying the root"',
      '    echo "    (repo-recursing)"',
      '    local tries=0',
      '    kubectl apply -f "${f}" || return 1',
      '}', '', 'apply_root_app_of_apps', '']
for i, l in enumerate(L):
    if l.startswith('if [ "${HUGMESH_GITOPS_ROOT_RECURSE:-0}" = "1" ]; then'):
        L[i:i] = FN
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" B1)" = "FAIL" ] && has_line "${OUT}" 'with NO enclosing condition at all'; then
      nc_ok "NC12d an UNCONDITIONAL root apply behind a variable and a function -> B1 RED"
    else
      nc_bad "NC12d B1 is $(status_of "${OUT}" B1) against an unconditional repo-recursing root apply — B1 is decorative"
    fi
  else nc_bad "NC12d mutation changed nothing"; fi

  # ── NC12e — B1: the glob apply that sweeps up the OTHER recursing root ────
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
out, drop = [], False
for l in L:
    if l.strip() == "00-app-of-apps-waved.yaml)":
        drop = True; continue
    if drop:
        if l.strip().endswith("continue ;;"):
            drop = False
        continue
    out.append(l)
open(p, "w", encoding="utf-8").write("\n".join(out))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" B1)" = "FAIL" ] && has_line "${OUT}" 'SWEEPS UP the repo-recursing root apps/00-app-of-apps-waved\.yaml'; then
      nc_ok "NC12e the waved-root skip arm deleted -> B1 RED (the baked glob would re-import the repo tree)"
    else
      nc_bad "NC12e B1 is $(status_of "${OUT}" B1) with the skip gone — B1 reads only the literal roots"
    fi
  else nc_bad "NC12e mutation changed nothing"; fi

  # ── NC12f — B1: the root target bound through `X="${X:-…}"` ──────────────
  # Found by a mutation battery when carrying V3 onto main (2026-08-27): the
  # reader stored the literal `${ROOT_MANIFEST:-${CLUSTER_DIR}/app-of-apps.yaml}`
  # as the variable's value, so expanding `${ROOT_MANIFEST}` grew instead of
  # resolving and the apply matched no leaf. An UNCONDITIONAL root apply, B1 green.
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    if l.startswith('if [ "${HUGMESH_GITOPS_ROOT_RECURSE:-0}" = "1" ]; then'):
        L[i:i] = ['ROOT_MANIFEST="${ROOT_MANIFEST:-${CLUSTER_DIR}/app-of-apps.yaml}"',
                  'kubectl apply -f "${ROOT_MANIFEST}"', '']
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" B1)" = "FAIL" ] && has_line "${OUT}" 'applies app-of-apps\.yaml \(a repo-recursing root\) with NO enclosing condition'; then
      nc_ok "NC12f the root target bound via \${X:-default} and applied unconditionally -> B1 RED (the idiom resolves to its default)"
    else
      nc_bad "NC12f B1 is $(status_of "${OUT}" B1) against an unconditional root apply bound through \${X:-default} — the reader expands the self-reference into noise"
    fi
  else nc_bad "NC12f mutation changed nothing"; fi

  # ── NC12g — B1: a DIRECT directory apply that sweeps up the waved root ────
  # `kubectl apply -f "${CLUSTER_DIR}/apps"` — no for-loop, so no skip arm. (iii)
  # read only the loop form; measured green before (iv) existed.
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    if l.startswith('if [ "${HUGMESH_GITOPS_ROOT_RECURSE:-0}" = "1" ]; then'):
        L[i:i] = ['kubectl apply -f "${CLUSTER_DIR}/apps"', '']
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" B1)" = "FAIL" ] && has_line "${OUT}" 'COVERS the repo-recursing root apps/00-app-of-apps-waved\.yaml'; then
      nc_ok "NC12g a direct directory apply of \${CLUSTER_DIR}/apps -> B1 RED (a dir apply covers the waved root with no loop to skip it)"
    else
      nc_bad "NC12g B1 is $(status_of "${OUT}" B1) against a direct directory apply that covers the waved root — B1 reads only the loop form"
    fi
  else nc_bad "NC12g mutation changed nothing"; fi

  # ── NC1b — C1: a SECOND, selector-less generator ──────────────────────────
  # ArgoCD applies `selector` PER GENERATOR. V2 set a flag on the first generator
  # that carried one, so this made every slug in the second generator deploy
  # unconditionally and C1 still reported PASS.
  _reset; f="${SB}/specs/cluster/${APPSET_LEAF}"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
a = '      selector:\n        matchLabels:\n          installed: "true"\n'
if a in s:
    s = s.replace(a, a + '''    - list:
        elements:
          - { slug: akkoma,  path: specs/cluster/manifests/akkoma,  namespace: hugmesh-backend, installed: "false" }
          - { slug: tuwunel, path: specs/cluster/manifests/tuwunel, namespace: hugmesh-backend, installed: "false" }
''', 1)
open(p, "w", encoding="utf-8").write(s)
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" C1)" = "FAIL" ] && has_line "${OUT}" 'generators\[1\]: a list generator with NO selector'; then
      nc_ok "NC1b a second, selector-less list generator -> C1 RED (the selector is checked on EVERY generator)"
    else
      nc_bad "NC1b C1 is $(status_of "${OUT}" C1) with a selector-less generator present — the fail-open is invisible"
    fi
  else nc_bad "NC1b mutation changed nothing"; fi

  # ── NC6b — C3: a pointer that protects NOTHING but ends in the key name ───
  _reset; f="${SB}/specs/cluster/apps/16-reserved-prefixes-policy.yaml"; cp "${f}" "${PRE}"
  sed -i 's#^\( *\)- /data/akkoma$#\1- /spec/bogus/akkoma#' "${f}"
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    if [ "$(status_of "${OUT}" C3)" = "FAIL" ] && has_line "${OUT}" '/spec/bogus/akkoma does not resolve'; then
      nc_ok "NC6b a jsonPointer with the right LAST SEGMENT and no resolution -> C3 RED and names it"
    else
      nc_bad "NC6b C3 is $(status_of "${OUT}" C3) against a pointer that protects nothing — it still compares suffixes"
    fi
  else nc_bad "NC6b mutation changed nothing"; fi

  # ── NC7b — C4: the REVERSE parity direction ──────────────────────────────
  # A slug in the registry, the ConfigMap AND the seed CRs but in neither the CRD
  # enum nor the 13a elements. V2 only asserted elements ⊆ each source.
  _reset
  python3 - "${SB}" <<'PY'
import os, re, sys
sb = sys.argv[1]
p = os.path.join(sb, "specs/cluster/optional-services.yaml")
L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    if l.strip() == "- slug: coturn":
        ind = l[:len(l) - len(l.lstrip())]
        L[i:i] = [ind + "- slug: ghostsvc", ind + "  name: Ghost", ind + "  tier: infra"]
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
p = os.path.join(sb, "specs/cluster/manifests/policy/installed-services-configmap.yaml")
s = open(p, encoding="utf-8").read()
s = re.sub(r"(?m)^(  coturn:.*)$", '  ghostsvc: "false"\n\\1', s, count=1)
open(p, "w", encoding="utf-8").write(s)
p = os.path.join(sb, "specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml")
open(p, "a", encoding="utf-8").write(
    "\n---\napiVersion: platform.hugmesh.net/v1alpha1\nkind: OptionalService\n"
    "metadata:\n  name: ghostsvc\n  namespace: devops\nspec:\n  slug: ghostsvc\n  enabled: false\n")
PY
  run_legs "${SB}" "${OUT}" static
  if [ "$(status_of "${OUT}" C4)" = "FAIL" ] && has_line "${OUT}" 'seed OptionalService CR\(s\) with no .*element: ghostsvc'; then
    nc_ok "NC7b a slug in three sources but in neither the CRD enum nor 13a -> C4 RED (parity is two-directional)"
  else
    nc_bad "NC7b C4 is $(status_of "${OUT}" C4) against a half-wired slug — parity is still one-directional"
  fi

  # ── NC21 — STUCK-RED control for B2: plant the WHOLE fix ─────────────────
  # NC12 plants HALF of B2's fix (the ConfigMap) and only requires B2 to stop
  # naming that half; B2 stays red for the seed CRs, so it never proved B2 can go
  # GREEN. This plants both applies and requires exactly that.
  _reset; f="${SB}/specs/cluster/bootstrap/bootstrap.sh"; cp "${f}" "${PRE}"
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    if l.startswith('kubectl apply -f "${CLUSTER_DIR}/namespaces/'):
        L[i + 1:i + 1] = [
            'kubectl apply -f "${CLUSTER_DIR}/manifests/policy/installed-services-configmap.yaml"',
            'kubectl apply -f "${CLUSTER_DIR}/manifests/optional-services-operator/seed-optionalservices.yaml"',
        ]
        break
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
  if changed "${f}" "${PRE}"; then
    run_legs "${SB}" "${OUT}" static
    [ "$(status_of "${OUT}" B2)" = "PASS" ] \
      && nc_ok "NC21 boot applying BOTH baked install-state artefacts -> B2 green (not stuck red)" \
      || { nc_bad "NC21 B2 stayed $(status_of "${OUT}" B2) with both applies planted — B2 is stuck"; grep -E '^  FAIL B2' "${OUT}" | sed 's/^/        | /'; }
  else nc_bad "NC21 mutation changed nothing"; fi

  # ── NC22 — STUCK-RED control for B3: plant the fail-closed baseline ───────
  _reset
  python3 - "${SB}" <<'PY'
import os, re, sys, io
sb = sys.argv[1]
p = os.path.join(sb, "specs/cluster/manifests/policy/installed-services-configmap.yaml")
s = open(p, encoding="utf-8").read()
s = re.sub(r'(?m)^(  [A-Za-z][A-Za-z0-9._-]*:\s*)"true"\s*$', r'\1"false"', s)
open(p, "w", encoding="utf-8").write(s)
p = os.path.join(sb, "specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml")
s = open(p, encoding="utf-8").read()
s = re.sub(r"(?m)^(  enabled:\s*)true\s*$", r"\1false", s)
open(p, "w", encoding="utf-8").write(s)
PY
  run_legs "${SB}" "${OUT}" static
  [ "$(status_of "${OUT}" B3)" = "PASS" ] \
    && nc_ok "NC22 the git install-state baseline flipped all-off -> B3 green (not stuck red)" \
    || { nc_bad "NC22 B3 stayed $(status_of "${OUT}" B3) with an all-off baseline — B3 is stuck"; grep -E '^  FAIL B3|^         [a-z-]+: ' "${OUT}" | head -4 | sed 's/^/        | /'; }

  # ── NC23 — STUCK-RED control for C5b: switch ON *and* the cut-over done ───
  # NC13 flips only the switch and requires C5b to stay red for the cut-over. That
  # is the right assertion for that mutation and it is NOT a fix control: it can
  # never show C5b going green. This deletes every hardcoded Application that still
  # owns a 13a element's manifest path AND lights the switch.
  _reset
  python3 - "${SB}" <<'PY'
import glob, os, re, sys, yaml
sb = sys.argv[1]
appset = os.path.join(sb, "specs/cluster/apps/13a-optional-services.yaml")
paths = set()
for d in yaml.safe_load_all(open(appset, encoding="utf-8")):
    if not isinstance(d, dict) or d.get("kind") != "ApplicationSet":
        continue
    for g in ((d.get("spec") or {}).get("generators") or []):
        for e in (((g or {}).get("list") or {}).get("elements") or []):
            if isinstance(e, dict) and e.get("path"):
                paths.add(e["path"])
gone = 0
for p in sorted(glob.glob(os.path.join(sb, "specs/cluster/apps/*.yaml"))):
    if os.path.basename(p) == "13a-optional-services.yaml":
        continue
    t = open(p, encoding="utf-8").read()
    if any(re.search(r"(?m)^[ \t]*path:[ \t]*%s[ \t]*$" % re.escape(ep), t) for ep in paths):
        os.remove(p); gone += 1
dep = os.path.join(sb, "specs/cluster/manifests/admin-bff-api/deployment.yaml")
s = open(dep, encoding="utf-8").read().replace(
    '{ name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: "false" }',
    '{ name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: "true" }')
open(dep, "w", encoding="utf-8").write(s)
print("removed %d hardcoded Application(s)" % gone, file=sys.stderr)
PY
  run_legs "${SB}" "${OUT}" static
  [ "$(status_of "${OUT}" C5b)" = "PASS" ] \
    && nc_ok "NC23 the cut-over completed AND the switch lit -> C5b green (not stuck red)" \
    || { nc_bad "NC23 C5b stayed $(status_of "${OUT}" C5b) after the full fix — C5b is stuck"; grep -E '^  FAIL C5b' "${OUT}" | sed 's/^/        | /'; }

  # ── NC24 / NC25 — C8 measures a SOURCE, so it must name WHICH source ─────
  # C8 read a working tree. On 2026-08-27 the checkout on this box was 9 commits
  # behind its own origin/main, the handler HAD merged (PR #43, 07:04 UTC) and was
  # on main, and C8 reported "declares NO ... mapping" — a false red about the
  # sibling's source that was then written down as a defect in two files. NC24
  # plants exactly that shape with git plumbing (no checkout, no reset): HEAD has
  # no handler, refs/remotes/origin/main does. NC25 is the same tree with NO remote
  # ref at all, and must still go RED — so NC24 is not just a blanket pass.
  local STALE="${W}/sib/stale" SREL="src/main/java/net/hugmesh/adminbff/optionalservices"
  rm -rf "${STALE}"; mkdir -p "${STALE}/${SREL}"
  ( set -e
    cd "${STALE}"
    git init -q .
    git config user.email selsvc@example.invalid
    git config user.name selsvc
    printf 'package x;\npublic class OptionalServiceReconciler { }\n' > "${SREL}/OptionalServiceReconciler.java"
    git add -A; git commit -q -m base
    printf 'package x;\n@RestController\n@RequestMapping("/bff/superadmin/optional-services")\npublic class OptionalServiceSuperadminController { }\n' \
      > "${SREL}/OptionalServiceSuperadminController.java"
    git add -A
    _t="$(git write-tree)"
    _b="$(git commit-tree "${_t}" -p "$(git rev-parse HEAD)" -m handler)"
    git update-ref refs/remotes/origin/main "${_b}"
    rm -f "${SREL}/OptionalServiceSuperadminController.java"
    git read-tree HEAD
  ) >/dev/null 2>&1
  if [ -d "${STALE}/.git" ] && [ ! -f "${STALE}/${SREL}/OptionalServiceSuperadminController.java" ]; then
    SELSVC_ADMIN_BFF_ROOT="${STALE}" analyse_sibling >"${OUT}" 2>&1
    if [ "$(status_of "${OUT}" C8)" = "PASS" ] && has_line "${OUT}" 'measured against origin/main'; then
      nc_ok "NC24 a checkout BEHIND its own origin/main -> C8 measures the ref, not the stale working tree"
    else
      nc_bad "NC24 C8 is $(status_of "${OUT}" C8) against a stale checkout whose main HAS the handler — it is reading the working tree"
    fi
    rm -rf "${STALE}/.git/refs/remotes"
    SELSVC_ADMIN_BFF_ROOT="${STALE}" analyse_sibling >"${OUT}" 2>&1
    if [ "$(status_of "${OUT}" C8)" = "FAIL" ] && has_line "${OUT}" 'measured against the working tree'; then
      nc_ok "NC25 the same tree with no remote ref -> C8 RED against the working tree (NC24 is not a blanket pass)"
    else
      nc_bad "NC25 C8 is $(status_of "${OUT}" C8) with no remote ref and no handler in the tree"
    fi
  else
    nc_bad "NC24/NC25 could not synthesise the stale checkout"
  fi

  echo
}

# =============================================================================
# MAIN
# =============================================================================
echo "== selected-services-only chain gate =="
echo "   tree: ${ROOT}"
echo "   gate resolution: $([ "${SELSVC_RESOLVER}" = 1 ] && echo 'tests/lib/opt-gate-source.sh (source chain: libs, then the builder, last definition wins)' || echo 'single-file awk fallback (no resolver in this tree)')"
echo
REALOUT="${W}/real.out"
{ analyse_executed "${ROOT}"; analyse_static "${ROOT}"; } >"${REALOUT}" 2>&1
cat "${REALOUT}"

SIBOUT="${W}/sib.out"
analyse_sibling >"${SIBOUT}" 2>&1
cat "${SIBOUT}"
cat "${SIBOUT}" >> "${REALOUT}"

P="$(grep -c '^  PASS ' "${REALOUT}")"
F="$(grep -c '^  FAIL ' "${REALOUT}")"
U="$(grep -c '^  UNVERIFIED ' "${REALOUT}")"

if [ "${SELSVC_NO_NC:-0}" != "1" ]; then
  negative_controls
else
  echo "-- negative controls SKIPPED (SELSVC_NO_NC=1) --"; echo
  NCP=0; NCF=0
fi

P=$((P + NCP)); F=$((F + NCF))
echo "== ${P} passed, ${F} failed, ${U} unverified =="
if [ "${F}" -eq 0 ]; then
  echo "VERDICT: an image built with services X,Y boots with only X,Y, and a superadmin can enable Z."
  [ "${U}" -eq 0 ] || exit 3
  exit 0
fi
echo "VERDICT: the chain does NOT hold — see the FAIL lines above. An image built with a"
echo "         restricted service selection does not boot restricted, and/or a superadmin"
echo "         cannot turn a service on afterwards. Each RED check prints a GREEN WHEN line."
exit 1
