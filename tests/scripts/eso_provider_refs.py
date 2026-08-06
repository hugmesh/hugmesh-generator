#!/usr/bin/env python3
"""eso_provider_refs.py — every Secret/ConfigMap an ESO provider block points at
must actually be created, on EVERY delivery path that bootstraps a cluster, by a
statement that actually RUNS on that path.

THE OUTAGE THIS MODELS
----------------------
All 29 VaultDynamicSecret generators under specs/cluster declare

    provider:
      caProvider: { type: Secret, name: vault-ca, key: ca.crt }
      auth: { tokenSecretRef: { name: vault-token, key: token } }

Both of those resolve ONLY in the generator's own namespace. ESO passes
resolvers.EmptyStoreKind for generators, and pkg/utils/resolvers/secret_ref.go
overrides the namespace with ref.Namespace *only* when the store kind is
ClusterSecretStore; the constant's own doc comment reads "The EmptyStoreKind is
not cluster-scoped, hence resources cannot be resolved across namespaces."

The USB/real-node path (specs/etc/keys-provision/provision.sh) created both
Secrets in all three generator namespaces. The kind path never created either.
So on kind, all 26 generator-backed ExternalSecrets sat in SecretSyncedError
(`cannot get Kubernetes secret "vault-ca"`), no *-mtls Secret was ever created,
and every pod mounting one hung in Init:0/1. Not one mTLS certificate had ever
been issued.

WHY THIS IS CHECKED PER DELIVERY PATH
-------------------------------------
This is the whole point of the gate. A check of the form "some file somewhere in
the repo creates vault-ca" PASSES on the broken tree, because provision.sh
created it — just not on the path anyone actually ran. The invariant that really
failed is per-path: EVERY bootstrap path must independently satisfy EVERY
provider reference. So coverage is computed once per path, and a reference
satisfied on one path and missing on another is a failure naming the path.

WHAT COUNTS AS "CREATED"
------------------------
Not a grep for a literal name. The provisioned set is built by modelling the
idioms the repo actually provisions with:

  * `kubectl create secret generic|tls ...` / `kubectl create configmap ...`
    invocations in shell, including --from-literal / --from-file key names;
  * YAML heredocs piped to `kubectl apply` inside shell;
  * YAML manifests declaring kind: Secret / kind: ConfigMap — but ONLY on a path
    that demonstrably APPLIES the file that declares them (see below);

with shell variable and for-loop expansion, so a Secret created for each
namespace in a loop is credited to each of those namespaces and no others.

Keys are modelled too, not just names: an existing Secret under the wrong key is
the same outage. `cluster-ca` is a kubernetes.io/tls Secret carrying tls.crt /
tls.key — pointing caProvider at it while still asking for key `ca.crt` would
resolve the Secret and then fail on the key.

THREE WAYS AN EARLIER DRAFT OF THIS GATE COULD BE FOOLED
--------------------------------------------------------
Each was demonstrated against the draft and each is now closed. They are all the
same disease: crediting a path with something that would not actually happen on
it.

  (1) REACHABILITY.  The draft modelled `kubectl create` and heredocs strictly
      line by line, with no notion of control flow. Wrapping the whole seeding
      block in `if false; then … fi` left it fully credited and the gate green.
      That was not hypothetical: `external-secrets/vault-token` is created ONLY
      inside the not-initialized `else` branch of bootstrap-kind.sh, so a
      re-run against an already-initialized Vault does not create it — and the
      draft could not see that either.  §"shell reachability" below models
      if/elif/else/case/while/for/function nesting, classifies each provisioning
      site as unconditional / conditional / dead, refuses to credit dead sites at
      all, and REPORTS any governed Secret whose only provisioner on a path sits
      behind a branch that is not obviously always taken. Deliberate
      conditionality is declarable, in the source, with a reason — see
      ANNOTATION below.

      That first cut closed the `if false` INSTANCE and not the CLASS: it saw
      only KEYWORD control flow, so five `bash -n`-clean rewrites of the same
      seeding block — including the two most idiomatic ways the regression would
      actually be written — still read as unconditional:

        [ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && { …block… }   opt-in gate
        [ "${OPT_IN_SEED:-0}" = "1" ] || continue               loop early-out
        false && { …block… }                                    kill switch
        seed() { return 0; …block… }                            early return
        exit 0                                                  early exit

      The model now also covers SHORT-CIRCUIT gating (the right-hand side of
      `&&`/`||`, including a `{ … }` group it opens) and EARLY-OUT statements
      (`exit`/`return`/`continue`/`break`). Both are deliberately narrow — see
      the block comment at _EARLY_OUT for exactly where the line is drawn and
      why, because a model that reads `cmd || die …` as a gate on what follows
      it is a model that gets the gate switched off.

  (2) DELIVERY-PATH ATTRIBUTION FOR YAML.  The draft walked every *.yaml under
      specs/ and seeded EVERY path with the result, so a file no Application and
      no script ever applies — `specs/etc/dead-notes/example-not-applied.yaml`
      was the demonstration — silently satisfied all 58 references on the broken
      tree and turned it green. "Per delivery path", the gate's headline
      property, was therefore false for the YAML half. YAML manifests are now
      attributed to a path only through an APPLY CHAIN rooted in that path's own
      scripts: `kubectl apply -f/-k`, one level of shell-function argument flow,
      `git show <ref>:<path> | kubectl apply`, kustomization `resources`/`bases`
      closure, and ArgoCD `Application.spec.source.path` closure (transitively,
      for app-of-apps).

  (3) UNPARSEABLE YAML.  The draft's document loader ended in
      `except Exception: return []`, so a generator living in a file with Helm
      templating vanished together with every dangling reference it declared,
      while "generators found" did not move and the vacuity check saw nothing
      wrong. Parse failures are now counted, listed, and fatal when the file
      looks like it declares a generator/provider or when it is inside a path's
      apply chain and looks like it declares a Secret/ConfigMap. Helm chart
      templates (charts/*/templates/*.yaml containing `{{`) are recognised as
      renderable-not-parseable and excluded from the second rule only — the
      first still applies to them.

ANNOTATION
----------
Real bootstrap code has legitimate conditionality: the USB path cannot seed what
the USB does not carry. Such a site declares itself, in the source, within eight
lines above the statement:

    # eso-provider-refs: conditional-ok <at least 24 characters of reason>

An annotation is a reviewed statement that the conditionality is intended, so it
must carry a reason a reviewer can disagree with. A dead site (`if false`) can
never be annotated away.

WHAT THE ANNOTATION GATE CAN AND CANNOT DO
------------------------------------------
Mechanically it checks SHAPE: at least 24 characters and six distinct words, so
the reason is a sentence rather than padding. It cannot check that the sentence
is TRUE — no static check can, and pretending otherwise would be the more
dangerous illusion. The control that actually holds is that exemptions cannot
accumulate quietly: tests/scripts/test-eso-provider-refs.sh pins the EXACT set
of annotated sites the repo carries, so adding one fails the suite by name until
a human edits the expected list. Length screens gibberish; the pinned inventory
is what forces the review.

Two structural limits are load-bearing and are tested: a dead site can never be
annotated away, and an annotation only exempts a site whose reach is genuinely
conditional — it is never consulted for a site that is already unconditional.
"""

import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("eso_provider_refs: PyYAML is required\n")
    raise SystemExit(2)


# ── delivery paths ───────────────────────────────────────────────────────────
# Each entry: path name -> the shell provisioners that path runs. YAML manifests
# are credited to a path only when that path's own scripts apply them (directly
# or through the kustomize/ArgoCD closure below), never globally. A path whose
# scripts have gone missing is a hard error, never a silent empty set.
DELIVERY_PATHS = {
    "kind-local": [
        "specs/cluster/bootstrap/kind-local/bootstrap-kind.sh",
    ],
    "keys-provision": [
        "specs/etc/keys-provision/provision.sh",
    ],
}

YAML_ROOTS = ["specs"]
GENERATOR_API = "generators.external-secrets.io"

# Text that marks a file as declaring an ESO provider even when it cannot be
# parsed as YAML.
PROVIDER_SIGNATURE = re.compile(
    r'generators\.external-secrets\.io|caProvider|tokenSecretRef'
    r'|kind:\s*(?:VaultDynamicSecret|SecretStore|ClusterSecretStore)')
SECRETISH_SIGNATURE = re.compile(r'kind:\s*(?:Secret|ConfigMap)\b')

ANNOTATION = re.compile(r'#\s*eso-provider-refs:\s*conditional-ok\s*(.*)$')
ANNOTATION_MIN_REASON = 24
# Length alone lets `aaaaaaaaaaaaaaaaaaaaaaaaaaaa` through, so the reason must
# also be a SENTENCE: six distinct words of three letters or more. That is a low
# bar for anyone actually explaining themselves (the four real annotations in
# this repo clear it by an order of magnitude) and an awkward one for filler.
# It is not, and cannot be, a check that the reason is TRUE — see
# ANNOTATION below for why the real control is the pinned inventory in
# tests/scripts/test-eso-provider-refs.sh.
ANNOTATION_MIN_WORDS = 6
ANNOTATION_WORD = re.compile(r'[A-Za-z][A-Za-z-]{2,}')
ANNOTATION_LOOKBACK = 8

# reachability lattice: worse() picks the more doubtful of two classifications.
_ORDER = {"unconditional": 0, "conditional": 1, "dead": 2}


def worse(a, b):
    return a if _ORDER[a] >= _ORDER[b] else b


def better(a, b):
    return a if _ORDER[a] <= _ORDER[b] else b


def _walk(root, exts):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in filenames:
            if fn.endswith(exts):
                yield os.path.join(dirpath, fn)


class ParseFailure:
    def __init__(self, rel, error, text):
        self.rel, self.error, self.text = rel, error, text
        self.declares_provider = bool(PROVIDER_SIGNATURE.search(text))
        self.declares_secretish = bool(SECRETISH_SIGNATURE.search(text))
        # A Helm chart template is *meant* to be rendered before it is YAML.
        self.helm_template = ("{{" in text and
                              re.search(r'(^|/)charts/[^/]+/templates/', rel) is not None)


class Loader:
    """YAML loader that ACCOUNTS for what it could not read.

    `except Exception: return []` is how a guard stops guarding: the documents
    disappear, the dangling references they declared disappear with them, and
    every count the vacuity check keys on stays exactly where it was.
    """

    def __init__(self, repo):
        self.repo = repo
        self.failures = {}   # rel -> ParseFailure
        self._cache = {}

    def docs(self, path):
        rel = os.path.relpath(path, self.repo)
        if rel in self._cache:
            return self._cache[rel]
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except Exception as exc:                       # unreadable is not empty
            self.failures[rel] = ParseFailure(rel, "unreadable: %s" % exc, "")
            self._cache[rel] = []
            return []
        try:
            docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
        except Exception as exc:
            self.failures[rel] = ParseFailure(
                rel, "%s: %s" % (type(exc).__name__,
                                 str(exc).splitlines()[0] if str(exc) else ""),
                text)
            docs = []
        self._cache[rel] = docs
        return docs


# ── 1) what the providers REFERENCE ──────────────────────────────────────────

class Ref:
    def __init__(self, kind, ns, name, key, origin, field, owner):
        self.kind, self.ns, self.name = kind, ns, name
        self.key, self.origin, self.field, self.owner = key, origin, field, owner

    @property
    def tuple(self):
        return (self.kind, self.ns, self.name)

    def __repr__(self):
        return "%s %s/%s key=%s" % (self.kind, self.ns, self.name, self.key)


def _secret_refs_in_auth(auth, ns, origin, owner, out):
    """Every *SecretRef under an auth block is a namespace-local Secret ref."""
    if not isinstance(auth, dict):
        return
    for k, v in auth.items():
        if isinstance(v, dict):
            if k.lower().endswith("secretref") and "name" in v:
                out.append(Ref("Secret", ns, v.get("name"), v.get("key"),
                               origin, "auth.%s" % k, owner))
            else:
                _secret_refs_in_auth(v, ns, origin, owner, out)


def collect_refs(repo, loader):
    """Provider references from ESO generators and SecretStores."""
    refs, problems, generators = [], [], 0
    for root in YAML_ROOTS:
        base = os.path.join(repo, root)
        if not os.path.isdir(base):
            continue
        for f in sorted(_walk(base, (".yaml", ".yml"))):
            rel = os.path.relpath(f, repo)
            for d in loader.docs(f):
                api = str(d.get("apiVersion", ""))
                kind = d.get("kind", "")
                meta = d.get("metadata") or {}
                ns = meta.get("namespace")
                owner = "%s %s" % (kind, meta.get("name"))

                is_gen = GENERATOR_API in api
                is_store = kind in ("SecretStore", "ClusterSecretStore")
                if not (is_gen or is_store):
                    continue
                if is_gen:
                    generators += 1

                # Locate provider blocks. Generators: spec.provider.
                # Stores: spec.provider.<backend>.
                spec = d.get("spec") or {}
                providers = []
                if is_gen:
                    if isinstance(spec.get("provider"), dict):
                        providers.append(spec["provider"])
                else:
                    p = spec.get("provider")
                    if isinstance(p, dict):
                        for v in p.values():
                            if isinstance(v, dict):
                                providers.append(v)

                cluster_scoped = (kind == "ClusterSecretStore")
                if is_gen and not ns:
                    problems.append(
                        "%s: %s has no metadata.namespace; a generator's provider "
                        "refs resolve in its own namespace, so this cannot be checked"
                        % (rel, owner))
                    continue
                if is_store and not cluster_scoped and not ns:
                    continue

                for prov in providers:
                    ca = prov.get("caProvider")
                    if isinstance(ca, dict):
                        ca_ns = ca.get("namespace")
                        ctype = ca.get("type", "Secret")
                        if cluster_scoped:
                            # ESO errors out with "missing namespace on
                            # caProvider secret" when a ClusterSecretStore
                            # omits it.
                            if not ca_ns:
                                problems.append(
                                    "%s: %s caProvider has no namespace; ESO "
                                    "rejects a ClusterSecretStore caProvider "
                                    "without one" % (rel, owner))
                                continue
                            target_ns = ca_ns
                        else:
                            # EmptyStoreKind / SecretStore: ref.Namespace is
                            # IGNORED by resolvers.SecretKeyRef. Declaring one
                            # reads as cross-namespace and silently is not.
                            if ca_ns:
                                problems.append(
                                    "%s: %s caProvider sets namespace=%s, which "
                                    "ESO ignores outside a ClusterSecretStore — "
                                    "it resolves in %s"
                                    % (rel, owner, ca_ns, ns))
                            target_ns = ns
                        refs.append(Ref(ctype, target_ns, ca.get("name"),
                                        ca.get("key"), rel, "caProvider", owner))

                    auth_refs = []
                    _secret_refs_in_auth(prov.get("auth"), ns, rel, owner, auth_refs)
                    refs.extend([r for r in auth_refs if r.ns])
    return refs, problems, generators


# ── 2) what the repo actually CREATES ────────────────────────────────────────

class Prov:
    def __init__(self, kind, ns, name, keys, origin, line=0,
                 reach="unconditional", why="", exempt=None):
        self.kind, self.ns, self.name = kind, ns, name
        self.keys, self.origin, self.line = keys, origin, line
        self.reach, self.why, self.exempt = reach, why, exempt
        self.func = None          # enclosing shell function, if any

    @property
    def tuple(self):
        return (self.kind, self.ns, self.name)

    def where(self):
        return "%s:%d" % (self.origin, self.line) if self.line else self.origin


class Read:
    """A `VAR=$(kubectl -n NS get secret NAME ...)` read-back in a path script.

    Tracked because a script that READS a Secret and then hard-exits when it is
    empty has a dependency exactly as load-bearing as an ESO provider reference,
    and it is satisfied — or not — on the very same per-path terms. This is the
    shape of the regression that shipped in the first draft of the fix: step 8b
    read external-secrets/vault-token and exited 1 when absent, while the only
    statement that creates it sits in the not-initialized `else` branch.
    """

    def __init__(self, var, kind, ns, name, origin, line):
        self.var, self.kind, self.ns, self.name = var, kind, ns, name
        self.origin, self.line = origin, line
        self.hard_exit_line = None
        self.exempt = None

    @property
    def tuple(self):
        return (self.kind, self.ns, self.name)


_ASSIGN = re.compile(
    r'^\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)='
    r'''(?:"([^"$`]*)"|'([^']*)'|([^\s"'$`;|&]+))\s*$''')
_FOR = re.compile(r'^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+?)\s*;?\s*(do)?\s*$')
# `<<<` is a HERESTRING, not a heredoc, and `"# <<< hugmesh nodes"` inside a sed
# program is neither. Reading either as a heredoc makes the scanner hunt for a
# terminator that never comes, run to EOF, and silently stop modelling the rest
# of the file — which is how the whole of provision.sh past line 2770 (including
# `main "$@"`, hence every function call in it) first went missing, and with it
# the USB path's entire provisioning set.
_HEREDOC = re.compile(r'(?<!<)<<(?!<)-?\s*(["\']?)([A-Za-z_][A-Za-z0-9_]*)\1')
_FUNC = re.compile(r'^(\s*)(?:function\s+)?([A-Za-z_][A-Za-z0-9_:.-]*)\s*\(\s*\)\s*\{')
_ARRAY_OPEN = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=\(\s*(.*)$')
# Command position: the start of the line, or right after a separator. Only a
# word THERE is a function call; the same word inside a string or as an argument
# is not, and counting it would make a function look more reachable than it is.
# The `{`/`(` lookbehinds matter: without them `recreate_job … "${CLUSTER_DIR}/…"`
# is chopped at the `${`, the call's third argument becomes the literal `$`, and
# every manifest tree reached through a helper silently drops out of the applied
# set.
_CMD_SPLIT = re.compile(r';|\|\||&&|\||\bthen\b|\belse\b|\bdo\b|(?<!\$)\{|(?<!\$)\(')

_KGET = re.compile(
    r'kubectl\s+(?:[^\n|]*?\s)?get\s+(secrets?|configmaps?|cm)\s+("?)([A-Za-z0-9._${}-]+)\2')
_KCREATE = re.compile(
    r'kubectl\s+(?:[^\n|]*?\s)?create\s+(secret\s+(?:generic|tls|docker-registry)|configmap)\s+(\S+)(.*)',
    re.S)
_APPLY = re.compile(r'kubectl\s+(?:[^\n|]*?\s)?apply\s+(?:[^\n|]*?\s)?(-[fk])[= ]+(\S+)')
_GITSHOW = re.compile(r'git\s+(?:-C\s+\S+\s+)?show\s+"?\$?\{?[A-Za-z_0-9]*\}?[^"\s:]*:([^"\s|]+)"?')

_KINDMAP = {"secret": "Secret", "secrets": "Secret",
            "configmap": "ConfigMap", "configmaps": "ConfigMap", "cm": "ConfigMap"}


def _literal_words(text, scalars, arrays):
    """Expand a for-loop word list into literal values, or None if unresolvable."""
    text = text.strip()
    if text.endswith(";"):
        text = text[:-1]
    words, out = text.split(), []
    for w in words:
        w = w.strip('"').strip("'")
        ma = re.fullmatch(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]\}', w)
        if ma:
            vals = arrays.get(ma.group(1))
            if vals is None:
                return None
            out.extend(vals)
            continue
        m = re.fullmatch(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', w)
        if m:
            vals = scalars.get(m.group(1))
            if vals is None:
                return None
            out.extend(vals.split())
        elif re.fullmatch(r'[A-Za-z0-9._/-]+', w):
            out.append(w)
        else:
            return None
    return out or None


def _subst(text, env):
    def rep(m):
        return env.get(m.group(1) or m.group(2), m.group(0))
    return re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)',
                  rep, text)


def _expand_envs(loops):
    """Cartesian product of the active loop variables."""
    envs = [{}]
    for var, values in loops:
        envs = [dict(e, **{var: v}) for e in envs for v in values]
    return envs


def _strip_comment(line):
    """Drop a trailing comment for STRUCTURAL tokenising only."""
    out, quote = [], None
    for i, ch in enumerate(line):
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t;|&("):
            break
        out.append(ch)
    return "".join(out)


_ALWAYS_TRUE = re.compile(r'^(?:true|:|\[\[?\s*1\s*(?:=|-eq)\s*1\s*\]\]?|test\s+1\s*=\s*1)$')
_ALWAYS_FALSE = re.compile(r'^(?:false|\[\[?\s*1\s*(?:=|-eq)\s*0\s*\]\]?|test\s+1\s*=\s*0)$')
_ENSURE = re.compile(
    r'^!\s*(?:KUBECONFIG=\S+\s+)?kubectl\s+(?:[^|]*?\s)?get\s+'
    r'(secrets?|configmaps?|cm)\s+("?)([A-Za-z0-9._-]+)\2')


def _classify_cond(cond):
    cond = cond.strip().rstrip(";").strip()
    if _ALWAYS_TRUE.match(cond):
        return "true"
    if _ALWAYS_FALSE.match(cond):
        return "false"
    return "unknown"


_EMPTYVAR = re.compile(r'^\[\[?\s*-z\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?\s*\]\]?$')


# ── short-circuit gating and early-out statements ────────────────────────────
# `if/else/case/while/for` is only half of bash's control flow. The other half —
# and the half a regression is far likelier to be written in, because it is one
# line and reads as a guard clause — is
#
#     [ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && { …seeding… }   # opt-in gate
#     [ "${OPT_IN_SEED:-0}" = "1" ] || continue                 # loop early-out
#     false && { …seeding… }                                    # kill switch
#     seed() { return 0; …seeding… }                            # early return
#     exit 0                                                    # early exit
#
# All five are `bash -n` clean, all five leave the seeding block textually
# intact, and all five left the block fully credited by the frame-only model.
#
# THE LINE THAT MUST NOT BE CROSSED
# ---------------------------------
# `cmd || die …` and `x="$(foo)" || true` are ERROR HANDLING, not gates on the
# provisioning that follows, and a model that reads them as gates makes the gate
# unusable. Two rules keep them out:
#
#   1. An `&&`/`||` gates only what is to its RIGHT. Position 0 of every line is
#      unconditional, so the LEFT-hand side — which is where `kubectl create …
#      || warn …` puts the provisioning — is never touched.
#   2. An UNCONDITIONAL early-out kills the rest of its block outright — that is
#      a claim about the text, not about runtime state, and it is what catches
#      `return 0; …block…` and `exit 0` above a block.
#   3. A CONDITIONAL early-out downgrades the rest of its block only when it
#      SKIPS SILENTLY — `|| continue`, `&& break`, `|| return 0`, `|| exit 0`:
#      those carry on (or finish) reporting success, having not done the work,
#      which is precisely what a gate is. A conditional `exit`/`return` with a
#      NON-zero status is left alone — that is where `cmd || die …`,
#      `… || { echo …; exit 1; }` and `x="$(foo)" || return 1` live, they abort
#      loudly rather than carrying on half-seeded, and they open nearly every
#      function in provision.sh. Aborting with SUCCESS and aborting with FAILURE
#      are different statements about the run, and the model splits on exactly
#      that.
#
# KNOWN LIMIT, stated rather than hidden, and named precisely because a vaguer
# statement of it misled a reader once already. What is NOT modelled as a gate
# is the MULTI-LINE, `if`-wrapped guard clause on unknown RUNTIME state:
#
#     if [ "${phase:-}" != "Running" ]; then warn …; exit 0; fi
#
# bootstrap-kind.sh:431 (the SKIP_VAULT_BOOTSTRAP escape) and :457 (vault-0 never
# came up) are exactly this, and treating them as gates turned seven correct
# provisioners red on the real repo — everything from step 8 down becomes
# conditional. The ONE-LINE short-circuit spelling of the same idea,
# `[ … ] || return 0` and `[ … ] || exit 0`, IS modelled as a gate: it is
# `|| continue` with a different keyword, it is the spelling a regression would
# most naturally take once a block is wrapped in a function, and leaving it out
# while `|| continue` went red was an asymmetry, not a design. The nested form
# of the skip (`if …; then <provision>; fi`) is still caught by the frame model.
# So the uncovered case is one shape only: a top-level `if` whose then-branch
# `exit 0`s, gating what follows the `fi`.
_EARLY_OUT = ("exit", "return", "continue", "break")
_SC_RESET = re.compile(r'\bthen\b|\bdo\b|\belse\b|\bin\b|;;')


def _blank_quoted(code):
    """Same string, every quoted span replaced by spaces, offsets preserved.

    Structural scanning MUST NOT see inside a string: `log "a || b"` is not a
    short-circuit, `"${GEN_NAMESPACES}"` is not a closing brace, and
    `echo "; exit 0"` is not an early-out. Preserving length means every offset
    computed on the blanked copy indexes the original.
    """
    out, quote = [], None
    for ch in code:
        if quote:
            out.append(" ")
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            out.append(" ")
            continue
        out.append(ch)
    return "".join(out)


def _sc_gate(op, lhs):
    """How `lhs && …` / `lhs || …` gates everything to the right of the op."""
    c = _classify_cond(lhs)
    if op == "&&":
        return {"true": "unconditional", "false": "dead"}.get(c, "conditional")
    return {"true": "dead", "false": "unconditional"}.get(c, "conditional")


def shortcircuit_map(code):
    """[(offset, reach)] — how this line's &&/|| chain gates each position.

    Always starts at (0, "unconditional"): an operator gates its right-hand side
    only. A `;` at brace depth zero ends the AND-OR list and resets the gate, as
    do `then`/`do`/`else`/`in`, so `if a && b; then …` is left entirely to the
    `if` frame rather than being gated twice.
    """
    blank = _blank_quoted(code)
    cuts = [(0, "unconditional")]
    cur, seg_start, depth, i = "unconditional", 0, 0, 0
    while i < len(blank):
        two = blank[i:i + 2]
        ch = blank[i]
        if two in ("&&", "||"):
            cur = worse(cur, _sc_gate(two, blank[seg_start:i]))
            cuts.append((i + 2, cur))
            seg_start, i = i + 2, i + 2
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        elif ch == ";" and depth == 0:
            cur, seg_start = "unconditional", i + 1
            cuts.append((i + 1, cur))
        i += 1
    for m in _SC_RESET.finditer(blank):
        cuts.append((m.end(), "unconditional"))
    cuts.sort(key=lambda c: c[0])
    return cuts


def sc_reach_at(cuts, offset):
    r = "unconditional"
    for off, val in cuts:
        if off <= offset:
            r = val
        else:
            break
    return r


# `{` and `}` in COMMAND position — the delimiter context the old
# _BARE_BRACE_OPEN / _BARE_BRACE_CLOSE pair used, so `${VAR}`, `jq '{a:1}'` and
# awk bodies are not mistaken for grouping. The `}` half is byte-for-byte the
# old _BARE_BRACE_CLOSE pattern: nothing that used to be recognised as a close
# has stopped being recognised, only the bookkeeping around it changed.
_BARE_BRACE_TOK = re.compile(r'(?:^|[\s;&|])([{}])(?=[\s;&|]|$)')


def _param_closes(blank):
    """Offsets of every `}` that closes a `${…}` PARAMETER EXPANSION.

    _blank_quoted() blanks quoted spans, and that is what makes an expansion
    look like grouping: `${label:+-L "${label}"}` comes out as `${label:+-L   }`
    and `${label//,/ }` keeps its own space, so in both the closing `}` is
    preceded by a blank and matches _BARE_BRACE_TOK's command-position rule.
    provision.sh:1698 and :2351 are those two lines, and each was counted as a
    close of a group nothing opened — one more ordinary line that pops the
    frame above it, the same defect class as everything else in this function's
    history. `${` is tracked over the WHOLE line rather than by regex because
    only the nesting says which `}` belongs to which `${`.

    If the nesting does NOT return to zero — an expansion spanning lines, which
    no line in this tree has — the whole set is discarded rather than trusted.
    Skipping a `}` that is really a group close would leave a gate standing over
    code it does not govern, i.e. RED on correct code; not skipping one leaves
    an unmatched brace, which the caller reports. Between a silent false
    accusation and a loud "I lost track", take the loud one.
    """
    out, depth, i = set(), 0, 0
    while i < len(blank):
        if blank.startswith("${", i):
            depth += 1
            i += 2
            continue
        c = blank[i]
        if depth and c == "{":
            depth += 1
        elif depth and c == "}":
            depth -= 1
            out.add(i)
        i += 1
    return out if depth == 0 else set()


def _brace_tokens(blank):
    """[(offset, '{' | '}')] for every grouping brace on the line, in order.

    A function-definition line is grouping too. `foo() {` is already in command
    position and matches _BARE_BRACE_TOK, but `foo(){` — no space — is not
    preceded by a delimiter and would be seen as a close-with-no-open on the
    matching `}`. _FUNC's own `{` is therefore added when the delimiter rule
    misses it, so the two halves of a definition can never disagree.

    A `}` that closes a `${…}` expansion is dropped: see _param_closes().
    """
    skip = _param_closes(blank)
    toks = [(m.start(1), m.group(1)) for m in _BARE_BRACE_TOK.finditer(blank)
            if m.start(1) not in skip]
    mf = _FUNC.match(blank)
    if mf:
        off = mf.end() - 1
        if all(o != off for o, _ in toks):
            toks.append((off, "{"))
            toks.sort()
    return toks


def _brace_scan(blank):
    """(outer closes, [offsets of `{` still open at end of line]).

    ONE pass, so the two halves of the brace model cannot drift apart — which
    is the whole history of this function.

    OUTER CLOSES — how many `}` on this line close a group opened on an EARLIER
    line. A `{ … }` that OPENS AND CLOSES on the same line closes nothing outer
    and must not pop an enclosing frame — the identical correction
    _intraline_nesting() makes for a one-line `case … esac`, which was never
    applied to `{ … }`. Without it the commonest error-handling idiom in this
    tree

        [ -n "${GEN_TOKEN}" ] || { echo "…" >&2; exit 1; }

    (bootstrap-kind.sh, sitting INSIDE step 8b) cancelled the enclosing frame on
    the very line it appeared on, so the vault-ca/vault-token seeding below it
    scored "top-level / unconditional" and the checker exited 0.

    OPENS — every `{` left unclosed at end of line, each of which the caller
    pushes a frame for. Round 4 pushed a frame ONLY for a `{` that both ended
    the line AND sat on the right of a `&&`/`||`; a `}` closing anything else
    still counted as an outer close and still popped. That asymmetry is a bug
    with the same effect as the one above and it survived a whole round: a
    MULTI-LINE group the frame stack never opened — a function definition body,
    or a plain `{` … `}` grouping — popped the enclosing gate and everything
    above it. Wrap the real step 8b in
    `[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && { … }` and put ANY of

        _noop() {          {                 foo() { :
          :                  :               } ; echo after
        }                  }

    inside it, and the gate was cancelled exactly as it was before the one-line
    fix. Opening a frame for EVERY multi-line `{` — gating or not — and popping
    to the topmost brace-opened frame makes open and close symmetric by
    construction: a `}` can now only ever close a group this scan itself saw
    open.

    Counting closes rather than returning a bool because one line may
    legitimately close several outer groups (`}; }`), and returning a LIST of
    open offsets because one line may open several (`{ ( … ) ; {`) and each
    needs its own short-circuit gate scored at its own offset.

    `find … -exec … {} ;` is not grouping and is not counted either: the `{`
    there is not followed by a delimiter, so neither brace matches.

    KNOWN LIMIT — what this still does NOT model, named rather than papered
    over, because an unqualified "nothing is weakened" written over a hole is
    how the multi-line shape above survived a whole review round.

    (1) BRACES THIS SCAN CANNOT PAIR. A `}` written without a delimiter after
        it — `}>log`, `})` — is not in command position and is invisible,
        while the `{` it belongs to is seen; and a bare `}` in ARGUMENT
        position (`printf '%s' }`) is the reverse. Neither is silently
        absorbed: the caller records them in ShellScript.brace_underflows /
        .brace_residual and REPORTS them, because an unmatched brace is the
        signature of every round of this defect. `} > log` and `} )` are
        modelled normally. test-eso-provider-refs.sh §4f plants both
        directions, in valid shell, and requires the report.

    (2) SUBSHELL grouping — `[ … ] && ( … )` — is not modelled at all, in
        either direction. Neither `(` nor `)` touches the frame stack, so such
        a block reads as UNGATED: this one under-approximates silently, and it
        is the one shape in this function that still can. `( … )` forks, so a
        provisioner inside one does not affect the parent shell the way the
        rest of this model assumes, and the two questions want answering
        together rather than by extending the brace rule to parentheses.

    (3) A keyword or brace inside a MULTI-LINE quoted string. _blank_quoted()
        has no state across lines, so a `"$( … )"` spanning lines is blanked
        on its first line and bare on the rest. provision.sh:211-214 is that
        shape; the `done` handler's brace floor keeps it from eating the
        enclosing group, but the loop frame it pops is one level off.

    (4) A BACKSLASH-QUOTED HEREDOC DELIMITER — `<<\\EOF` — is not matched by
        _HEREDOC, so its body is parsed as code. A bare `{` or `}` on a body
        line then produces a brace_underflow / brace_residual finding on shell
        that is `bash -n` clean and correct. This one errs toward the FALSE
        ALARM direction, which is fatal to adoption rather than dangerous, and
        it is loud — it names the offending line rather than quietly cancelling
        a gate. Latent, not live: neither modelled script uses that spelling
        (`grep -nE '<<[-]?\\' <both>` finds nothing; the heads present are
        `<<EOF`, `<<'PY'`, `<<'SHIM'`). Extending _HEREDOC to `<<\\WORD` is the
        fix if one ever appears; it is left undone deliberately so the pattern
        keeps matching exactly what the two scripts actually contain.
    """
    depth, outer, opens = 0, 0, []
    for off, ch in _brace_tokens(blank):
        if ch == "{":
            depth += 1
            opens.append(off)
        elif depth:
            depth -= 1
            opens.pop()
        else:
            outer += 1
    return outer, opens


def _command_segments(code):
    """[(offset, text)] for every command-position segment on the line."""
    blank = _blank_quoted(code)
    cuts = [0]
    for m in re.finditer(r'&&|\|\||[;|&]|(?<![\w./-])(?:then|do|else)(?![\w./-])'
                         r'|(?<!\$)\{|(?<!\$)\(', blank):
        cuts.append(m.end())
    cuts.append(len(blank))
    out, seen = [], set()
    for k in range(len(cuts) - 1):
        a, b = cuts[k], cuts[k + 1]
        if a in seen:
            continue
        seen.add(a)
        seg = code[a:b]
        if seg.strip():
            out.append((a + (len(seg) - len(seg.lstrip())), seg.strip()))
    return out


_NEST_TOK = re.compile(
    r'(?<![\w./-])(if|case|for|while|until|fi|esac|done)(?![\w./-])')


def _intraline_nesting(blank):
    """[(offset, depth)] for control structures opened AND closed on one line.

    The frame stack is per-LINE, so a self-contained
    `case "$X" in a) ;; *) echo …; exit 1;; esac` leaves it empty by the time
    the line is scored — and the `exit 1` in the catch-all arm then reads as an
    unconditional top-level abort that kills the rest of the script. It is not:
    it is one arm of a case. Depth at an offset says how many same-line
    structures enclose it.
    """
    cuts, depth = [(0, 0)], 0
    for m in _NEST_TOK.finditer(blank):
        depth += 1 if m.group(1) in ("if", "case", "for", "while", "until") else -1
        depth = max(0, depth)
        cuts.append((m.end(), depth))
    return cuts


def _early_out(seg):
    """(command, silent) if `seg` is an early-out, else None.

    `silent` = the run carries on and still reports success having skipped what
    follows. That is the property that makes an early-out a GATE rather than an
    abort, and it is what separates `|| continue` from `|| { echo …; exit 1; }`.
    """
    w = seg.split()
    if not w or w[0] not in _EARLY_OUT:
        return None
    cmd = w[0]
    if cmd in ("continue", "break"):
        return (cmd, True)
    status = w[1].strip('"').strip("'") if len(w) > 1 else ""
    # bare `exit`/`return` carries $? — after a failed test in `… || return`
    # that is non-zero, so it is an abort, not a silent skip.
    return (cmd, status == "0")


def _ensured_tuple(cond, reads=(), before_line=None):
    """The two "ensure it exists" idioms, whose POST-condition is unconditional.

        if ! kubectl -n NS get secret NAME …; then  kubectl … create NAME  fi
        VAR="$(kubectl -n NS get secret NAME …)"
        if [ -z "${VAR}" ]; then                    kubectl apply … NAME    fi

    A create of exactly the tuple the guard tested is not really conditional:
    after the construct, that tuple exists either way. Only that tuple — the
    six-namespace cluster-ca loop at step 3b is gated on a single
    `kubectl -n vault get secret cluster-ca`, so it ensures vault/cluster-ca and
    genuinely does NOT ensure the other five.
    """
    cond = cond.strip().rstrip(";").strip()
    m = _ENSURE.match(cond)
    if m:
        nsm = re.search(r'(?:-n|--namespace)[= ]+(\S+)', cond)
        ns = nsm.group(1).strip('"').strip("'") if nsm else None
        if ns and re.search(r'[${}]', ns):
            ns = None
        return (_KINDMAP[m.group(1)], ns, m.group(3))
    me = _EMPTYVAR.match(cond)
    if me:
        var = me.group(1)
        prior = [r for r in reads
                 if r.var == var and (before_line is None or r.line <= before_line)]
        if prior:
            return prior[-1].tuple
    return None


# Frame kinds pushed by a multi-line `{`. A `}` pops the topmost of these, so
# open and close are the same set by construction. See _brace_scan().
_BRACE_KINDS = ("sc", "grp")


class Frame:
    __slots__ = ("kind", "cond", "branch", "ensures", "resolved", "loopvar",
                 "tail", "line")

    def __init__(self, kind, cond="unknown", resolved=True):
        self.kind, self.cond, self.branch = kind, cond, "then"
        self.ensures, self.resolved, self.loopvar = None, resolved, None
        # Where a brace frame was opened, so an unclosed one can be NAMED.
        self.line = 0
        # `tail` is what an early-out INSIDE this frame imposes on the
        # statements after it. Deliberately separate from contribution(): the
        # `ensures` shortcut says "after this construct the tuple exists either
        # way", which stops being true the moment something in the middle can
        # skip out, so the tail is applied even to an ensured frame.
        self.tail = "unconditional"

    def contribution(self):
        if self.kind == "grp":
            # A multi-line `{ … }` that is NOT on the right of a short-circuit
            # gates nothing — a function body, a plain grouping. It exists on
            # the stack purely so its own `}` has something of its own to pop
            # instead of eating the gate above it. See _brace_scan().
            return "unconditional"
        if self.kind == "sc":
            return self.cond
        if self.kind == "if":
            if self.branch == "then":
                return {"true": "unconditional", "false": "dead"}.get(
                    self.cond, "conditional")
            return {"true": "dead", "false": "unconditional"}.get(
                self.cond, "conditional")
        if self.kind in ("case", "loop"):
            return "conditional"
        if self.kind == "for":
            return "unconditional" if self.resolved else "conditional"
        return "unconditional"


class ShellScript:
    """Structural model of one delivery-path script."""

    def __init__(self, repo, relpath):
        self.repo, self.relpath = repo, relpath
        self.provisioners = []
        self.reads = []
        self.applies = []          # (mode '-f'/'-k', literal target, reach)
        self.func_defs = {}        # name -> (start, end)
        self.func_calls = []       # (name, local_reach, enclosing_func)
        self.func_applies = []     # (fname, mode, template-with-$N)
        self.func_reach = {}
        self.lines = []
        self.scalars = {}
        self.arrays = {}
        self.suspect_heredocs = []
        # Braces the model could not pair. An unmatched `}` pops a frame it
        # never opened (the whole history of _brace_scan); an unmatched `{`
        # leaves a gate standing over code it does not govern. Either way the
        # reachability scores past that point are guesses, so they are recorded
        # and reported rather than quietly used. See _brace_scan()'s KNOWN
        # LIMIT for the shapes that can cause this.
        self.brace_underflows = []   # line numbers of `}` with nothing to close
        self.brace_residual = []     # line numbers of `{` never closed

    # -- annotation ---------------------------------------------------------
    def annotation_above(self, idx):
        for j in range(max(0, idx - ANNOTATION_LOOKBACK), idx + 1):
            m = ANNOTATION.search(self.lines[j])
            if m:
                reason = m.group(1).strip()
                return (j + 1, reason)
        return None

    # -- reach --------------------------------------------------------------
    def reach_at(self, frames, tup=None, base="unconditional"):
        r = base
        for f in frames:
            r = worse(r, f.tail)
            if tup is not None and f.ensures == tup:
                continue
            r = worse(r, f.contribution())
        return r

    def guard_desc(self, frames, base="unconditional"):
        bits = []
        if base != "unconditional":
            bits.append("after an early-out(%s)" % base)
        for f in frames:
            c = f.contribution()
            if c != "unconditional":
                bits.append("%s/%s(%s)" % (f.kind, f.branch, c))
            if f.tail != "unconditional":
                bits.append("%s/after-early-out(%s)" % (f.kind, f.tail))
        return ",".join(bits) or "top-level"

def _split_words(text):
    return re.findall(r'[^\s"\']+|"[^"]*"|\'[^\']*\'', text)


def _cmd_split_offsets(code):
    """_CMD_SPLIT.split(code), but keeping each piece's offset in the line.

    Same segmentation as before — only the offset is new — so that a call in a
    short-circuited position can be scored where it actually sits.
    """
    out, pos = [], 0
    for m in _CMD_SPLIT.finditer(code):
        out.append((pos, code[pos:m.start()]))
        pos = m.end()
    out.append((pos, code[pos:]))
    return out


def function_spans(lines):
    """name -> (first_line_idx, last_line_idx) for every function definition.

    Brace COUNTING does not survive a real shell script: `${VAR}`, jq programs,
    awk bodies and heredocs all carry braces, and one miscount silently swallows
    every following definition — which is exactly how a first cut of this model
    concluded that provision.sh's provision_vault() was never called, and marked
    the entire USB path dead. The repo's actual convention is used instead: a
    definition line `name() {`, closed by `}` at the SAME indentation, or a
    complete one-liner `name() { …; }`.
    """
    spans = {}
    for i, ln in enumerate(lines):
        code = _strip_comment(ln)
        m = _FUNC.match(code)
        if not m:
            continue
        indent, name = m.group(1), m.group(2)
        if code.count("{") <= code.count("}") and code.rstrip().endswith("}"):
            spans[name] = (i, i)             # one-liner
            continue
        close = re.compile(r'^%s\}' % re.escape(indent))
        j = i + 1
        while j < len(lines) and not close.match(lines[j]):
            j += 1
        spans[name] = (i, min(j, len(lines) - 1))
    return spans


def _enclosing_func(spans, idx):
    best, bestlen = None, None
    for name, (a, b) in spans.items():
        if a <= idx <= b and (bestlen is None or (b - a) < bestlen):
            best, bestlen = name, b - a
    return best


def parse_shell(repo, relpath):
    """Model provisioning, reading and applying in a shell script, WITH the
    control-flow context each statement sits in."""
    full = os.path.join(repo, relpath)
    if not os.path.isfile(full):
        return None
    s = ShellScript(repo, relpath)
    with open(full, encoding="utf-8") as fh:
        s.lines = fh.readlines()
    lines = s.lines
    s.func_defs = function_spans(lines)
    names = set(s.func_defs)

    frames = []
    pending_loop = None      # ("for", var, values) | ("loop", None, None)
    array_name, array_vals = None, None
    # Tails imposed by early-outs, kept per scope: a `return 0` at the top of a
    # function kills the rest of THAT function and nothing else, and a top-level
    # `exit 0` kills the rest of the top level and not the body of some function
    # defined below it (whose call site is dead anyway, and is scored there).
    root_tail = "unconditional"
    func_tail = {}
    i = 0
    while i < len(lines):
        raw = lines[i]
        code = _strip_comment(raw)

        # ── multi-line array literal ──
        if array_name is not None:
            if ")" in code:
                array_vals.extend(_split_words(code.split(")")[0]))
                s.arrays[array_name] = [w.strip('"').strip("'")
                                        for w in array_vals if w.strip()]
                array_name, array_vals = None, None
            else:
                array_vals.extend(_split_words(code))
            i += 1
            continue
        ma = _ARRAY_OPEN.match(code)
        if ma and not code.rstrip().endswith("\\"):
            rest = ma.group(2)
            if ")" in rest:
                s.arrays[ma.group(1)] = [w.strip('"').strip("'")
                                         for w in _split_words(rest.split(")")[0])
                                         if w.strip()]
            else:
                array_name, array_vals = ma.group(1), _split_words(rest)
            i += 1
            continue

        m = _ASSIGN.match(code)
        if m:
            s.scalars[m.group(1)] = next(g for g in m.groups()[1:] if g is not None)

        # ── heredoc bodies are DATA: never tokenise them for structure ──
        mh = _HEREDOC.search(code)
        heredoc_body, heredoc_end = None, None
        if mh:
            marker, body, j = mh.group(2), [], i + 1
            while j < len(lines) and lines[j].strip() != marker:
                body.append(lines[j])
                j += 1
            if j < len(lines):
                heredoc_body, heredoc_end = "".join(body), j
            else:
                # No terminator: the `<<` was not a heredoc at all. Skipping to
                # EOF here would silently stop modelling the file, so treat the
                # match as spurious and keep going, and SAY SO.
                s.suspect_heredocs.append((i + 1, marker))

        enclosing_fn = _enclosing_func(s.func_defs, i)
        blank = _blank_quoted(code)

        # A function definition line opens a fresh scope: whatever early-out
        # governed the previous one says nothing about this body.
        if _FUNC.match(code):
            func_tail[_FUNC.match(code).group(2)] = "unconditional"

        # ── close a multi-line `{ … }` group ──
        # Only braces that close a group opened on an EARLIER line count; a
        # self-contained `cmd || { echo …; exit 1; }` closes nothing outer.
        # A close pops the topmost BRACE-OPENED frame — gating (`sc`) or not
        # (`grp`) — never the nearest `sc` further down, or a function body's
        # `}` would cancel the gate wrapping it. See _brace_scan().
        #
        # Scanned over the LOGICAL line. A `\`-continued statement is consumed
        # whole further down (`i` jumps past every continuation line), so a
        # group that opens on the head and closes on a continuation must be
        # matched here or its `{` opens a frame nothing will ever pop.
        # provision.sh:2639-2640 is exactly that shape:
        #     [ -d "${BASE}/keystores" ] && { cp -f …/*.jks … || true; \
        #         log "Installed JKS keystores from KEYS/keystores"; }
        # — self-contained once joined, and a dangling gate over the rest of
        # provision_truststore() if it is not. The join condition is the same
        # one the chunk builder below uses, and it is skipped for a heredoc
        # head for the same reason that builder is: the parser jumps to the
        # heredoc terminator instead.
        brace_blank, k = blank, i
        if heredoc_end is None:
            brace_code = code
            while brace_code.rstrip().endswith("\\") and k + 1 < len(lines):
                k += 1
                brace_code += _strip_comment(lines[k])
            if k != i:
                brace_blank = _blank_quoted(brace_code)
        brace_closes, brace_opens = _brace_scan(brace_blank)
        for _ in range(brace_closes):
            if not any(f.kind in _BRACE_KINDS for f in frames):
                s.brace_underflows.append(i + 1)
                break
            while frames and frames[-1].kind not in _BRACE_KINDS:
                frames.pop()
            if frames:
                frames.pop()

        # ── structural tokens on this line ──
        # Matched on the BLANKED copy, which is what _blank_quoted() exists for
        # and what every other scan on this line already does. Matching on the
        # raw text read keywords out of the middle of strings, and provision.sh
        # has one:
        #
        #     log "desktop-governance: done (domain ${dom}; …)"
        #
        # yields `done`, `until` and `for`. The `done` handler unwinds the frame
        # stack to the nearest loop, so that one log line discarded the frame
        # for the function it sits in, and would discard an enclosing gate the
        # same way — the identical defect as the brace over-pop, in the other
        # half of the tokenizer. Offsets are preserved by _blank_quoted(), so
        # the slices below still read the REAL text.
        for tok in re.finditer(
                r'(?<![\w./-])(if|elif|else|fi|case|esac|for|while|until|do|done)(?![\w./-])',
                blank):
            t = tok.group(1)
            if t == "if":
                cond = re.split(r';\s*then\b|\bthen\b', code[tok.end():])[0]
                fr = Frame("if", _classify_cond(cond))
                fr.ensures = _ensured_tuple(cond, s.reads, i + 1)
                frames.append(fr)
            elif t == "elif":
                if frames and frames[-1].kind == "if":
                    frames[-1].cond = "unknown"
                    frames[-1].branch = "then"
                    frames[-1].ensures = None
            elif t == "else":
                if frames and frames[-1].kind == "if":
                    frames[-1].branch = "else"
                    frames[-1].ensures = None
            elif t == "fi":
                if frames and frames[-1].kind == "if":
                    frames.pop()
            elif t == "case":
                frames.append(Frame("case"))
            elif t == "esac":
                if frames and frames[-1].kind == "case":
                    frames.pop()
            elif t == "for":
                mf = _FOR.match(code[tok.start():])
                vals = _literal_words(mf.group(2), s.scalars, s.arrays) if mf else None
                pending_loop = ("for", mf.group(1) if mf else None, vals)
            elif t in ("while", "until"):
                pending_loop = ("loop", None, None)
            elif t == "do":
                if pending_loop and pending_loop[0] == "for":
                    fr = Frame("for", resolved=bool(pending_loop[2]))
                    fr.loopvar = (pending_loop[1], pending_loop[2])
                else:
                    fr = Frame("loop")
                frames.append(fr)
                pending_loop = None
            elif t == "done":
                # A `done` unwinds to its loop, but it can NEVER cross a `{`:
                # shell has no `{ … done`, so a brace frame is a hard floor.
                # Without the floor a `done` whose `do` the scanner did not see
                # eats the enclosing group instead — provision.sh:214 is that
                # line, a `done` closing a `while` opened inside a multi-line
                # `"$( … )"` whose `do` is hidden in the quoted span. It then
                # popped the frame of the function it sits in and left the `}`
                # at :244 closing nothing. Same defect as the brace over-pop,
                # same fix: stop at the topmost brace-opened frame.
                while frames and frames[-1].kind not in ("for", "loop"):
                    if frames[-1].kind in _BRACE_KINDS:
                        break
                    frames.pop()
                if frames and frames[-1].kind in ("for", "loop"):
                    frames.pop()

        # resolved for-loop variables in scope, for literal expansion
        active = [f.loopvar for f in frames
                  if f.kind == "for" and f.resolved and f.loopvar]
        tail_base = func_tail.get(enclosing_fn, "unconditional") if enclosing_fn \
            else root_tail
        sc_cuts = shortcircuit_map(code)
        base_reach = s.reach_at(frames, base=tail_base)

        def _reach(offset, tup=None):
            """Reach of the statement at `offset` on this line."""
            return worse(s.reach_at(frames, tup, base=tail_base),
                         sc_reach_at(sc_cuts, offset))

        # ── early-out statements: what follows them in this block cannot run ──
        nest_cuts = _intraline_nesting(blank)
        for off, seg in _command_segments(code):
            eo = _early_out(seg)
            if not eo:
                continue
            cmd, silent = eo
            r = _reach(off)
            if sc_reach_at(nest_cuts, off):
                r = worse(r, "conditional")   # one arm/branch on this same line
            if r == "dead":
                continue                       # the early-out itself never runs
            loopy = cmd in ("continue", "break")
            # Does the conditionality come from a short-circuit on THIS line —
            # `[ … ] || return 0` — rather than from an enclosing `if`? That
            # distinction is what keeps the rule below narrow. See the KNOWN
            # LIMIT note under it.
            sc_gated = sc_reach_at(sc_cuts, off) != "unconditional"
            if r == "unconditional":
                imposed = "dead"               # the rest of the block cannot run
            elif silent and (loopy or sc_gated):
                # A `|| continue` / `&& break` guard clause genuinely gates the
                # rest of the ITERATION, and the frame it is recorded on pops at
                # the matching `done`, so the claim cannot leak past the loop.
                #
                # `[ … ] || return 0` and `[ … ] || exit 0` are the SAME idiom
                # with the same effect — skip the rest and report success — and
                # the more natural spelling the moment the block is wrapped in a
                # function. Leaving them out while `|| continue` went red was an
                # asymmetry a regression could simply be spelled around: move
                # step 8b into `seed_generator_credentials()`, put
                # `[ "${SEED:-0}" = 1 ] || return 0` at the top, and the gate
                # went unnoticed. `exit 0` and `exit 1` are not the same thing —
                # aborting with SUCCESS is a guard clause, aborting with FAILURE
                # is error handling — and `_early_out`'s `silent` flag is exactly
                # that distinction, so only the success spelling is caught.
                imposed = "conditional"
            else:
                # Everything else stays out. A CONDITIONAL `exit`/`return` that
                # is NOT silent is where `cmd || die …`, `… || { echo …; exit 1; }`
                # and `x="$(foo)" || return 1` live: those abort loudly rather
                # than carrying on half-seeded, and they sit at the top of nearly
                # every function in provision.sh. Reading them as gates turned
                # seven correct provisioners red on the real repo — the precise
                # failure mode that gets a guard switched off — so a conditional
                # abort is modelled as what it is: error handling.
                #
                # KNOWN LIMIT, and it is narrower than it was. The guard-clause
                # spelling that is still NOT modelled as a gate is the multi-line
                # `if`-wrapped one:
                #
                #     if [ "${phase:-}" != "Running" ]; then warn …; exit 0; fi
                #
                # bootstrap-kind.sh:431 and :457 are exactly this — the
                # SKIP_VAULT_BOOTSTRAP escape and the "vault-0 never came up"
                # skip — and treating THEM as gates is what turned those seven
                # provisioners red, because everything from step 8 down then
                # reads as conditional. The one-line `|| return 0` / `|| exit 0`
                # spelling above IS caught; the `if …; then exit 0; fi` spelling
                # is not. The nested form of the same skip
                # (`if …; then <provision>; fi`) is still caught by the frame
                # model, so what is left uncovered is only: a top-level `if`
                # whose then-branch exits 0, gating everything BELOW the `fi`.
                continue
            if loopy:
                for f in reversed(frames):
                    if f.kind in ("for", "loop"):
                        f.tail = worse(f.tail, imposed)
                        break
            elif enclosing_fn:
                func_tail[enclosing_fn] = worse(
                    func_tail.get(enclosing_fn, "unconditional"), imposed)
            elif cmd == "exit":
                root_tail = worse(root_tail, imposed)

        # ── open every multi-line `{ … }` group on this line ──
        # A gating one (`… && {`, `… || {`) becomes an `sc` frame carrying the
        # gate; every other one — function body, plain grouping — becomes a
        # non-gating `grp` frame that contributes nothing but owns its own `}`.
        # An offset past the end of the head line (a `\`-continued statement)
        # simply reads the last short-circuit cut on the head, which is the
        # gate in force where the continuation begins.
        for bo in brace_opens:
            gate = sc_reach_at(sc_cuts, bo)
            fr = Frame("sc", gate) if gate != "unconditional" else Frame("grp")
            fr.line = i + 1
            frames.append(fr)

        # ── function calls (command position only) ──
        for off, seg in _cmd_split_offsets(code):
            w = seg.strip().split()
            if not (w and w[0] in names) or _FUNC.match(code):
                continue
            raw_args = _split_words(seg.strip())[1:]
            call_reach = _reach(off)
            # `for f in "${CORE_APPS[@]}"; do apply_core_app "${f}"; done` — the
            # argument is the loop variable, so record one call per literal value
            # or the manifest tree behind it is never attributed to this path.
            for env in (_expand_envs(active) or [{}]):
                s.func_calls.append((w[0], call_reach, enclosing_fn,
                                     [_subst(a, env) for a in raw_args]))

        # ── heredoc piped into kubectl apply: parse as manifests ──
        if heredoc_body is not None and "kubectl" in code and "apply" in code:
            hd_off = code.find("kubectl")
            for env in _expand_envs(active):
                rendered = _subst(heredoc_body, env)
                rendered = re.sub(
                    r'\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*',
                    'x', rendered)
                try:
                    docs = list(yaml.safe_load_all(rendered))
                except Exception:
                    docs = []
                for d in docs:
                    if isinstance(d, dict) and d.get("kind") in ("Secret", "ConfigMap"):
                        meta = d.get("metadata") or {}
                        keys = set()
                        for sec in ("data", "stringData", "binaryData"):
                            if isinstance(d.get(sec), dict):
                                keys |= set(d[sec].keys())
                        _emit_prov(s, frames, d["kind"], meta.get("namespace"),
                                   meta.get("name"), keys, i, enclosing_fn,
                                   tail_base, sc_reach_at(sc_cuts, hd_off))
        if heredoc_end is not None:
            i = heredoc_end + 1
            continue

        # ── multi-line continuation chunk ──
        chunk, j = code, i
        while chunk.rstrip().endswith("\\") and j + 1 < len(lines):
            j += 1
            chunk += _strip_comment(lines[j])

        if "kubectl" in chunk and "create" in chunk:
            mc = _KCREATE.search(chunk)
            if mc:
                subkind, name, rest = mc.group(1), mc.group(2), mc.group(3)
                kind = "ConfigMap" if subkind == "configmap" else "Secret"
                # `kubectl -n NS create secret ...` puts the flag BEFORE the
                # subcommand, so the namespace must be looked for across the
                # whole invocation, not just the part after the name. Getting
                # this wrong yields ns=None, and a None namespace that matched
                # anything would let one Secret in one namespace silently
                # satisfy references from every other namespace — exactly the
                # blindness this gate exists to remove.
                nsm = re.search(r'(?:-n|--namespace)[= ]+(\S+)', chunk)
                ns_raw = nsm.group(1) if nsm else None
                keys = set(re.findall(r'--from-literal[= ]([A-Za-z0-9._-]+)=', rest))
                keys |= set(re.findall(r'--from-file[= ]([A-Za-z0-9._-]+)=', rest))
                if subkind == "secret tls":
                    keys |= {"tls.crt", "tls.key"}
                for env in _expand_envs(active):
                    n = _subst(name, env).strip('"').strip("'")
                    ns = _subst(ns_raw, env).strip('"').strip("'") if ns_raw else None
                    if ns and re.search(r'[${}]', ns):
                        ns = None
                    if not re.search(r'[${}]', n):
                        _emit_prov(s, frames, kind, ns, n, keys, i, enclosing_fn,
                                   tail_base,
                                   sc_reach_at(sc_cuts, min(mc.start(),
                                                            max(0, len(code) - 1))))

        # ── read-backs: VAR="$(kubectl -n NS get secret NAME ...)" ──
        mr = re.match(r'^\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=', chunk)
        if mr and "kubectl" in chunk and "get" in chunk:
            mg = _KGET.search(chunk)
            if mg:
                nsm = re.search(r'(?:-n|--namespace)[= ]+(\S+)', chunk)
                ns = nsm.group(1).strip('"').strip("'") if nsm else None
                if ns and re.search(r'[${}]', ns):
                    ns = None
                nm = mg.group(3)
                if not re.search(r'[${}]', nm):
                    s.reads.append(Read(mr.group(1), _KINDMAP[mg.group(1)],
                                        ns, nm, relpath, i + 1))

        # ── kubectl apply -f/-k <target> ──
        if base_reach != "dead":
            for mapp in _APPLY.finditer(chunk):
                target = mapp.group(2).strip('"').strip("'")
                if target == "-":
                    continue
                ar = _reach(min(mapp.start(), max(0, len(code) - 1)))
                if ar == "dead":
                    continue
                if enclosing_fn:
                    s.func_applies.append((enclosing_fn, mapp.group(1), target))
                else:
                    s.applies.append((mapp.group(1), target, ar))
            if "kubectl" in chunk and "apply" in chunk and "-f -" in chunk:
                # `git show <ref>:<path> | kubectl apply -f -`
                for mg2 in _GITSHOW.finditer(chunk):
                    s.applies.append(("-f", mg2.group(1), base_reach))
                # a path literal handed to a filter that then pipes into apply
                for w in re.findall(r'"([^"]*\$\{[A-Za-z_][A-Za-z0-9_]*\}[^"]*)"', chunk):
                    if "/" in w:
                        if enclosing_fn:
                            s.func_applies.append((enclosing_fn, "-f", w))
                        else:
                            s.applies.append(("-f", w, base_reach))

        i = j + 1

    s.brace_residual = [f.line for f in frames if f.kind in _BRACE_KINDS]
    _resolve_function_reach(s)
    return s


def _emit_prov(s, frames, kind, ns, name, keys, idx, enclosing_fn,
               tail_base="unconditional", sc="unconditional"):
    tup = (kind, ns, name)
    reach = worse(s.reach_at(frames, tup, base=tail_base), sc)
    why = s.guard_desc(frames, tail_base)
    if sc != "unconditional":
        why = ("short-circuit RHS(%s)" % sc) + ("," + why if why != "top-level" else "")
    p = Prov(kind, ns, name, keys, s.relpath, idx + 1, reach, why)
    p.func = enclosing_fn
    ann = s.annotation_above(idx)
    if ann:
        p.exempt = ann
    s.provisioners.append(p)


def _resolve_function_reach(s):
    """Least-doubtful reach over all call sites, to a fixpoint.

    A `kubectl create secret` inside a function nothing calls has never
    provisioned anything; one inside a function called from an `if` branch is
    exactly as conditional as that branch.
    """
    names = set(s.func_defs)
    if not names:
        return
    reach = {n: "dead" for n in names}
    for _ in range(len(names) + 2):
        changed = False
        for name, local, encl, _args in s.func_calls:
            outer = reach.get(encl, "dead") if encl else "unconditional"
            r = worse(local, outer)
            if _ORDER[r] < _ORDER[reach[name]]:
                reach[name] = r
                changed = True
        if not changed:
            break
    s.func_reach = reach

    for p in s.provisioners:
        fn = p.func
        if not fn:
            continue
        fr = reach.get(fn, "dead")
        p.reach = worse(p.reach, fr)
        if fr == "dead":
            p.why = "%s (function %s() is never called)" % (p.why, fn)
        elif fr != "unconditional":
            p.why = "%s (function %s() is itself called conditionally)" % (p.why, fn)



# ── 3) which YAML files a delivery path actually APPLIES ─────────────────────

def _script_path_vars(repo, relpath, lines):
    """Resolve the `VAR="$(cd "…" && pwd)"` idiom the bootstrap scripts open with."""
    env = {}
    script_dir = os.path.dirname(os.path.join(repo, relpath))
    for ln in lines[:80]:
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)="\$\(cd\s+"(.+?)"\s*&&\s*pwd\)"', ln)
        if not m:
            continue
        var, expr = m.group(1), m.group(2)
        expr = expr.replace('$(dirname "${BASH_SOURCE[0]}")', script_dir)
        expr = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}',
                      lambda mm: env.get(mm.group(1), "\0"), expr)
        if "\0" in expr or "$" in expr:
            continue
        env[var] = os.path.normpath(expr)
    return env


def _resolve_target(repo, target, env):
    if "://" in target or target.startswith(("s/", "s#", "-")):
        return None                       # a URL or a sed program, not a path
    t = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}',
               lambda m: env.get(m.group(1), "\0"), target)
    t = t.replace("${BRAND:-hugmesh}", "hugmesh")
    if "\0" in t or "$" in t or "*" in t:
        return None
    repo = os.path.abspath(repo)
    if not os.path.isabs(t):
        t = os.path.join(repo, t)
    t = os.path.normpath(t)
    # Containment must be computed on ABSOLUTE paths. Comparing against a
    # relative repo root ("." — how CI invokes this) made every target look like
    # an escape and silently reduced the applied set to nothing, which would have
    # under-credited every path instead of over-crediting it: quieter, equally
    # wrong.
    if os.path.commonpath([t, repo]) != repo:
        return None
    return t


def _kustomize_closure(path, seen):
    """Files pulled in by a kustomization, transitively."""
    out = []
    for cand in ("kustomization.yaml", "kustomization.yml", "Kustomization"):
        kfile = os.path.join(path, cand)
        if os.path.isfile(kfile):
            break
    else:
        return None
    if kfile in seen:
        return []
    seen.add(kfile)
    out.append(kfile)
    try:
        with open(kfile, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh) or {}
    except Exception:
        return out
    for key in ("resources", "bases", "components", "patches", "patchesStrategicMerge"):
        for r in (doc.get(key) or []):
            if isinstance(r, dict):
                r = r.get("path")
            if not isinstance(r, str) or "://" in r:
                continue
            tgt = os.path.normpath(os.path.join(path, r))
            if os.path.isdir(tgt):
                sub = _kustomize_closure(tgt, seen)
                out.extend(sub if sub is not None else _dir_yaml(tgt, recurse=True))
            elif os.path.isfile(tgt):
                out.append(tgt)
    # kustomize's own secretGenerator/configMapGenerator are deliberately NOT
    # credited: it appends a content hash to the name, so the Secret that lands
    # in the cluster is not the name any ESO provider could be pointing at.
    return out


def _dir_yaml(path, recurse=False):
    out = []
    if not os.path.isdir(path):
        return out
    if recurse:
        out.extend(sorted(_walk(path, (".yaml", ".yml"))))
    else:
        for fn in sorted(os.listdir(path)):
            if fn.endswith((".yaml", ".yml")) and os.path.isfile(os.path.join(path, fn)):
                out.append(os.path.join(path, fn))
    return out


def _expand_apply(repo, mode, target):
    if os.path.isfile(target):
        return [target]
    if os.path.isdir(target):
        if mode == "-k":
            got = _kustomize_closure(target, set())
            return got if got is not None else _dir_yaml(target, recurse=True)
        return _dir_yaml(target, recurse=False)
    return []


def applied_files(repo, scripts, models):
    """The YAML files a delivery path's own scripts put into the cluster.

    Rooted in the scripts, then closed over kustomization `resources` and ArgoCD
    `Application.spec.source.path` (transitively, so an app-of-apps counts). A
    manifest nothing applies is credited to nothing — which is the entire point:
    the draft of this gate seeded every path with every YAML under specs/, so a
    file referenced by no Application and no script satisfied all 58 references
    on the broken tree.
    """
    roots, unresolved = [], []
    for rel, s in zip(scripts, models):
        if s is None:
            continue
        env = _script_path_vars(repo, rel, s.lines)
        seeds = list(s.applies)
        # one level of shell-function argument flow: apply_core_app "$1",
        # recreate_job … "$3" and friends.
        for fname, mode, tmpl in s.func_applies:
            for cname, _local, _encl, args in s.func_calls:
                if cname != fname:
                    continue
                filled = re.sub(r'\$\{?([0-9])\}?',
                                lambda m: args[int(m.group(1)) - 1].strip('"').strip("'")
                                if len(args) >= int(m.group(1)) else "\0", tmpl)
                # a `local x="$N"` alias inside the function body
                for var, val in _positional_aliases(s, fname).items():
                    idx = int(val)
                    filled = filled.replace(
                        "${%s}" % var,
                        args[idx - 1].strip('"').strip("'") if len(args) >= idx else "\0")
                seeds.append((mode, filled, "unconditional"))
        for mode, target, _reach in seeds:
            t = _resolve_target(repo, target, env)
            if t is None:
                unresolved.append((rel, target))
                continue
            roots.append((mode, t))

    files, seen_apps = set(), set()
    queue = list(roots)
    while queue:
        mode, target = queue.pop()
        for f in _expand_apply(repo, mode, target):
            if f in files:
                continue
            files.add(f)
            # ArgoCD Application closure
            try:
                with open(f, encoding="utf-8") as fh:
                    docs = [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]
            except Exception:
                continue
            for d in docs:
                if d.get("kind") != "Application" or "argoproj.io" not in str(d.get("apiVersion", "")):
                    continue
                spec = d.get("spec") or {}
                sources = []
                if isinstance(spec.get("source"), dict):
                    sources.append(spec["source"])
                for sub in (spec.get("sources") or []):
                    if isinstance(sub, dict):
                        sources.append(sub)
                for src in sources:
                    p = src.get("path")
                    if not isinstance(p, str):
                        continue
                    key = (f, p)
                    if key in seen_apps:
                        continue
                    seen_apps.add(key)
                    tgt = os.path.normpath(os.path.join(repo, p))
                    if not os.path.isdir(tgt):
                        continue
                    recurse = bool(((src.get("directory") or {}).get("recurse")))
                    if _kustomize_closure(tgt, set()) is not None:
                        queue.append(("-k", tgt))
                    else:
                        for g in _dir_yaml(tgt, recurse=recurse):
                            queue.append(("-f", g))
    return files, unresolved


def _positional_aliases(s, fname):
    """`local dir="$3"` inside fname's body -> {"dir": "3"}."""
    span = s.func_defs.get(fname)
    out = {}
    if not span or not span[1]:
        return out
    for ln in s.lines[span[0] - 1:span[1]]:
        for m in re.finditer(
                r'(?:local\s+|declare\s+)?([A-Za-z_][A-Za-z0-9_]*)="\$\{?([0-9])\}?"', ln):
            out[m.group(1)] = m.group(2)
    return out


def yaml_provisioned(repo, loader, files):
    out = []
    for f in sorted(files):
        if not f.endswith((".yaml", ".yml")):
            continue
        rel = os.path.relpath(f, repo)
        for d in loader.docs(f):
            if d.get("kind") not in ("Secret", "ConfigMap"):
                continue
            meta = d.get("metadata") or {}
            keys = set()
            for section in ("data", "stringData", "binaryData"):
                if isinstance(d.get(section), dict):
                    keys |= set(d[section].keys())
            out.append(Prov(d["kind"], meta.get("namespace"),
                            meta.get("name"), keys, rel))
    return out


# ── 4) coverage ──────────────────────────────────────────────────────────────

def satisfied(ref, provs):
    """Is `ref` created by any LIVE provisioner in `provs`?

    Namespace match is STRICT. A provisioner whose namespace could not be
    resolved (ns is None) satisfies nothing: treating unknown as "matches any"
    is how a gate goes quietly vacuous, and it is the precise mistake that let
    an early draft of this checker miss the missing per-namespace vault-token.
    A provisioner classified `dead` (behind an always-false guard, or inside a
    function nothing calls) satisfies nothing either — it cannot run.
    """
    name_hits = [p for p in provs
                 if p.kind == ref.kind and p.name == ref.name
                 and p.ns is not None and p.ns == ref.ns
                 and p.reach != "dead"]
    if not name_hits:
        return False, "nothing creates %s %s in namespace %s" % (
            ref.kind, ref.name, ref.ns)
    if ref.key:
        keyed = [p for p in name_hits if p.keys]
        if keyed and not any(ref.key in p.keys for p in keyed):
            have = sorted({k for p in keyed for k in p.keys})
            return False, ("%s %s/%s exists (%s) but carries no key %r — it has %s"
                           % (ref.kind, ref.ns, ref.name,
                              keyed[0].where(), ref.key, have))
    return True, ""


def _annotation_findings(prov_or_read, what):
    """A conditional site may declare itself, but the declaration must say why."""
    ann = prov_or_read.exempt
    if not ann:
        return None, False
    line, reason = ann
    words = {w.lower() for w in ANNOTATION_WORD.findall(reason)}
    if len(reason) < ANNOTATION_MIN_REASON or len(words) < ANNOTATION_MIN_WORDS:
        return ("%s carries an `eso-provider-refs: conditional-ok` annotation at "
                "line %d with no usable reason (%r): an exemption is a reviewed "
                "claim and must state one, in at least %d characters and %d "
                "distinct words." % (what, line, reason, ANNOTATION_MIN_REASON,
                                     ANNOTATION_MIN_WORDS)), False
    return None, True


def analyse(repo):
    repo = os.path.abspath(repo)
    loader = Loader(repo)
    refs, problems, ngen = collect_refs(repo, loader)
    ref_tuples = {r.tuple for r in refs}

    findings = list(problems)
    path_report = {}
    for path, scripts in sorted(DELIVERY_PATHS.items()):
        models = [parse_shell(repo, s) for s in scripts]
        missing_scripts = [s for s, m in zip(scripts, models) if m is None]
        for s in missing_scripts:
            findings.append(
                "delivery path %r: provisioner script %s does not exist — the "
                "path cannot be checked, and an unverifiable path is a failure"
                % (path, s))

        live_models = [m for m in models if m is not None]
        yaml_files, unresolved_targets = applied_files(repo, scripts, models)
        provs = list(yaml_provisioned(repo, loader, yaml_files))
        shell_provs = []
        for m in live_models:
            shell_provs.extend(m.provisioners)
        provs.extend(shell_provs)

        reads = []
        for m in live_models:
            reads.extend(m.reads)
        _mark_hard_exits(live_models, reads)

        d = path_report[path] = {
            "provisioners": provs, "missing_scripts": missing_scripts,
            "unresolved": [p for p in provs if p.ns is None],
            "yaml_files": yaml_files, "unresolved_targets": unresolved_targets,
            "unsatisfied": [], "conditional": [], "dead": [],
            "reads": [r for r in reads if r.hard_exit_line],
            "suspect_heredocs": [(m.relpath, ln, mk)
                                 for m in live_models
                                 for ln, mk in m.suspect_heredocs],
        }

        # ── the model's own brace bookkeeping must balance ──────────────────
        # This gate has now had the SAME defect three times: an ordinary line
        # popped a frame it never opened, the enclosing gate vanished, and the
        # checker exited 0 with the regression in the tree. Each time it was
        # found by reading, not by the gate. An unmatched brace is the
        # SIGNATURE of that defect and of every future spelling of it, so it is
        # reported instead of being absorbed — the same standard the
        # unparseable-YAML and unterminated-heredoc reporting already holds.
        # A `}` with nothing to close means every frame above it may already
        # have been cancelled; a `{` never closed means a gate is standing over
        # code it does not govern.
        for m in live_models:
            for ln in m.brace_underflows:
                findings.append(
                    "delivery path %r: %s:%d closes a `{ … }` group that was "
                    "never opened, so the reachability model has lost the "
                    "frames above it and every guard below this line is "
                    "unreliable. Write the brace in command position "
                    "(`} > log`, not `}>log`) or fix the pairing."
                    % (path, m.relpath, ln))
            for ln in m.brace_residual:
                findings.append(
                    "delivery path %r: %s:%d opens a `{ … }` group that is "
                    "never closed, so its guard is applied to the rest of the "
                    "file rather than to the block it governs."
                    % (path, m.relpath, ln))

        for ref in refs:
            ok, why = satisfied(ref, provs)
            if not ok:
                d["unsatisfied"].append((ref, why))
                findings.append(
                    "delivery path %r: %s (%s -> %s) %s"
                    % (path, ref.owner, ref.origin, ref.field, why))

        # ── reachability of GOVERNED material ────────────────────────────────
        # Governed = a tuple an ESO provider names, or one a path script reads
        # back and then hard-exits on. Those are the tuples whose absence breaks
        # the bring-up; the rule is that at least one statement creating each of
        # them must actually run on the default path.
        governed = set(ref_tuples)
        for r in reads:
            if r.hard_exit_line:
                governed.add(r.tuple)

        for tup in sorted(governed, key=str):
            sites = [p for p in provs if p.tuple == tup]
            if not sites:
                continue                       # already reported as unsatisfied
            live = [p for p in sites if p.reach == "unconditional"]
            dead = [p for p in sites if p.reach == "dead"]
            for p in dead:
                findings.append(
                    "delivery path %r: %s %s/%s is created at %s but that "
                    "statement can NEVER run (%s) — a provisioner behind an "
                    "always-false guard, after an unconditional "
                    "exit/return/continue/break, or in a function nothing "
                    "calls, has provisioned nothing"
                    % (path, tup[0], tup[1], tup[2], p.where(), p.why))
            if live:
                continue
            cond = [p for p in sites if p.reach == "conditional"]
            if not cond:
                continue
            bad_ann, exempted = [], []
            for p in cond:
                msg, ok_ann = _annotation_findings(
                    p, "%s %s/%s at %s" % (tup[0], tup[1], tup[2], p.where()))
                if msg:
                    bad_ann.append(msg)
                elif ok_ann:
                    exempted.append(p)
            findings.extend("delivery path %r: %s" % (path, m) for m in bad_ann)
            if bad_ann:
                continue
            if len(exempted) == len(cond):
                d["conditional"].append((tup, cond, True))
                continue
            d["conditional"].append((tup, cond, False))
            findings.append(
                "delivery path %r: %s %s/%s is created ONLY behind a conditional "
                "(%s; guard: %s) — nothing creates it on the path taken by "
                "default, so a run that does not enter that branch proceeds "
                "without it. Make it unconditional, or declare the "
                "conditionality with `# eso-provider-refs: conditional-ok <why>`."
                % (path, tup[0], tup[1], tup[2],
                   ", ".join(p.where() for p in cond),
                   cond[0].why or "n/a"))

    findings.extend(_parse_findings(loader, path_report))
    return {"refs": refs, "generators": ngen, "findings": findings,
            "paths": path_report, "loader": loader}


def _mark_hard_exits(models, reads):
    """A read whose emptiness aborts the script is a hard dependency."""
    for m in models:
        for r in reads:
            if r.origin != m.relpath:
                continue
            pat = re.compile(r'-[zn]\s+"?\$\{?%s\}?"?' % re.escape(r.var))
            for idx in range(r.line, min(len(m.lines), r.line + 40)):
                if not pat.search(m.lines[idx]):
                    continue
                window = "".join(m.lines[idx:idx + 6])
                if re.search(r'(?<![\w-])exit\s+[0-9]', window):
                    r.hard_exit_line = idx + 1
                    ann = m.annotation_above(idx)
                    if ann:
                        r.exempt = ann
                    break


def _parse_findings(loader, path_report):
    """Unparseable YAML is ACCOUNTED FOR, never silently dropped."""
    out = []
    applied = set()
    for d in path_report.values():
        applied |= {os.path.relpath(f, loader.repo) for f in d["yaml_files"]}
    for rel, f in sorted(loader.failures.items()):
        if f.declares_provider:
            out.append(
                "%s cannot be parsed as YAML (%s) but its text declares an ESO "
                "provider (caProvider/tokenSecretRef/generator kind). Every "
                "reference in it is invisible to this gate, and an invisible "
                "reference is exactly the outage this gate exists to catch."
                % (rel, f.error))
        elif rel in applied and f.declares_secretish and not f.helm_template:
            out.append(
                "%s is applied by a delivery path but cannot be parsed as YAML "
                "(%s), and its text declares a Secret/ConfigMap — so whatever it "
                "provisions is credited to nothing and whatever it references is "
                "checked against nothing." % (rel, f.error))
    return out


# ── 5) CLI ───────────────────────────────────────────────────────────────────

def vacuity_errors(result):
    """A scan that looked at nothing must never report success."""
    v = []
    if len(DELIVERY_PATHS) < 2:
        v.append("fewer than two delivery paths are declared; the per-path "
                 "invariant this gate exists for cannot be exercised")
    if result["generators"] == 0:
        v.append("no ESO generators were found under specs/ — either the scan "
                 "is broken or the manifests moved; refusing to pass vacuously")
    if not result["refs"]:
        v.append("no provider references (caProvider/tokenSecretRef) were "
                 "extracted — refusing to pass vacuously")
    for path, d in sorted(result["paths"].items()):
        if not d["provisioners"]:
            v.append("delivery path %r contributed no provisioners at all — a "
                     "path that creates nothing cannot be satisfying anything"
                     % path)
    return v


def print_exemptions(result):
    """One stable line per annotated exemption: `<kind> <ns>/<name> <file>`.

    Emitted for the test suite to PIN. Parsing it back out of the prose notes
    was not good enough: those are keyed by tuple, and the same tuple is
    legitimately exempted on one path while a NEW exemption is added for it on
    another — which is exactly how an annotation added to bury a regression
    slipped past the first cut of the pin. The file is part of the key here, so
    a second site for an already-exempted Secret is a new entry.
    """
    seen = set()
    for _path, d in sorted(result["paths"].items()):
        for tup, sites, exempted in d["conditional"]:
            if not exempted:
                continue
            for s in sites:
                seen.add("%s %s/%s %s" % (tup[0], tup[1], tup[2], s.origin))
    for line in sorted(seen):
        print(line)
    return 0


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    repo = args[0] if args else "."
    if "--exemptions" in flags:
        return print_exemptions(analyse(repo))
    result = analyse(repo)
    vac = vacuity_errors(result)
    loader = result["loader"]

    print("   generators found        : %d" % result["generators"])
    print("   provider references     : %d" % len(result["refs"]))
    print("   YAML files unparseable  : %d%s"
          % (len(loader.failures),
             "" if not loader.failures else
             " (" + ", ".join(sorted(loader.failures)) + ")"))
    for path, d in sorted(result["paths"].items()):
        print("   path %-15s: %d provisioners from %d applied manifest file(s), "
              "%d unsatisfied reference(s)"
              % (path, len(d["provisioners"]), len(d["yaml_files"]),
                 len(d["unsatisfied"])))
        for p in d["unresolved"]:
            print("        note: provisioner %s %s (%s) has an unresolvable "
                  "namespace and satisfies nothing"
                  % (p.kind, p.name, p.where()))
        for tup, sites, exempted in d["conditional"]:
            if exempted:
                print("        note: %s %s/%s is provisioned only conditionally "
                      "(%s) — declared deliberate at line %d: %s"
                      % (tup[0], tup[1], tup[2],
                         ", ".join(s.where() for s in sites),
                         sites[0].exempt[0], sites[0].exempt[1]))
        for r in d["reads"]:
            print("        note: %s reads %s %s/%s and hard-exits at line %d if "
                  "it is empty" % (r.origin, r.kind, r.ns, r.name,
                                   r.hard_exit_line))
        # What the model could NOT resolve is printed, not swallowed. An apply
        # target it cannot expand is a manifest tree it under-credits, and a `<<`
        # it could not pair is a place the structural scan had to guess.
        if d["unresolved_targets"]:
            print("        note: %d apply target(s) could not be resolved to a "
                  "path and were not credited: %s"
                  % (len(d["unresolved_targets"]),
                     ", ".join(sorted({t for _s, t in d["unresolved_targets"]})[:4])))
        for rel, ln, mk in d["suspect_heredocs"]:
            print("        note: %s:%d looks like `<<%s` but no terminator was "
                  "found — treated as not-a-heredoc" % (rel, ln, mk))

    if vac:
        print("  FAIL the scan is vacuous:")
        for m_ in vac:
            print("       - %s" % m_)
        # Print the findings too. A vacuous scan usually has a CAUSE among them
        # (a path whose script vanished, say), and swallowing it turns a precise
        # diagnosis into "something is wrong somewhere".
        for f in sorted(result["findings"]):
            print("       - %s" % f)
        return 1
    if result["findings"]:
        print("  FAIL %d dangling/unreachable ESO provider reference(s):"
              % len(result["findings"]))
        for f in sorted(result["findings"]):
            print("       - %s" % f)
        print()
        print("       Every Secret/ConfigMap an ESO provider names must be")
        print("       created by the SAME delivery path that brings the cluster")
        print("       up, in the generator's OWN namespace, by a statement that")
        print("       actually runs. ESO resolves a generator's caProvider and")
        print("       tokenSecretRef with resolvers.EmptyStoreKind, documented")
        print("       upstream as 'not cluster-scoped, hence resources cannot be")
        print("       resolved across namespaces' — a copy in another namespace")
        print("       does not count, neither does one created only by the other")
        print("       path, and neither does one behind a branch that is not")
        print("       taken.")
        return 1
    print("  OK   every ESO provider reference is created on every delivery path,")
    print("       by a statement that runs on that path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
