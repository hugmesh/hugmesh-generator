#!/usr/bin/env python3
"""service_env_defaults.py — DERIVE, from a service's own application.yml, the env
keys its cluster Deployment is obliged to override.

WHY THIS IS A LIBRARY AND NOT A LIST. The defect this whole gate exists for is:

    a Deployment omits an override, so the service silently adopts its OWN
    packaged default — and that default names a host/namespace/domain the
    rebranded cluster does not have.

A gate built from a hand-typed key list can only ever catch the entries someone
remembered to type. This module instead reads the SERVICE's `application.yml`
(the authority on what the service falls back to) and the CLUSTER's own
specs/cluster tree (the authority on what actually exists), and reports every
placeholder whose default resolves to something that does not exist. Nobody
maintains a list; a new stale default anywhere is a new finding on the next run.

THE THREE DERIVED RULES — none of them contains a brand string:

  R1 dangling-namespace   the default names <svc>.<ns>.svc.cluster.local where <ns>
                          is not a namespace specs/cluster creates or deploys into.
                          (NXDOMAIN in the pod — finding #14's exact shape.)
  R2 dangling-namespace   the property is a *namespace* (its YAML key ends in
                          `namespace`) and the value is not one of those namespaces.
                          A namespace never resolved by DNS still targets nothing.
  R3 foreign-domain       the default names a public DNS host whose registrable
                          domain is not a domain this cluster serves (derived from
                          the Ingress/route host positions in specs/cluster).
                          Finding #13's shape: https://hugmesh.net/... .

Spring semantics this relies on, verified against upstream docs:
  * `${NAME:default}` — ":" is the value separator
    (AbstractPropertyResolver.setValueSeparator: "The default is ':'").
  * placeholders NEST — `${A:${B:c}}` resolves B (then c) only when A is unset
    (AbstractPropertyResolver.setIgnoreUnresolvableNestedPlaceholders speaks of
    "an unresolvable placeholder nested within the value of a given property"), so
    a chain is satisfied by setting ANY name in it.
  * a placeholder with NO default and no value is fatal, not empty:
    "Unresolvable placeholders with no default value will cause an
    IllegalArgumentException to be thrown" (resolveRequiredPlaceholders) — which is
    finding #15 verbatim ("Could not resolve placeholder 'SVC_PASSWORD'").

THE JAVA HALF (hugmesh-generator#507, finding 26). application.yml is not the whole of
what a service falls back to: a `@ConfigurationProperties` field initialiser or a
`DEFAULT_*` constant in src/main/java is a packaged default too, and a yaml default that
is EMPTY hands the value straight to it. admin-bff's `SessionExchangeConfig.DEFAULT_SELF_HOST`
(a pre-rebrand host, NXDOMAIN) survived the yaml-only gate exactly that way, and the
same class of default is still in `PhoneLockProperties` today (see java_stale_literals).
Two rules, deliberately narrow, because a Java file is full of strings that merely look
like hosts (property keys such as `app.tenancy.issuers`, event names such as `wiki.ban`):

  J1 dangling-namespace   ANY string literal naming <svc>.<ns>.svc.cluster.local where <ns>
                          is not a namespace this cluster has (R1's rule, anywhere).
  J2 foreign-domain       a String FIELD or CONSTANT whose NAME says it is an address
                          (HOST/URL/URI/ENDPOINT/BASE/ADDRESS/ISSUER/SERVER/DOMAIN/ORIGIN) and
                          whose literal is a `scheme://host` URL under a domain this cluster
                          does not serve (R3's rule). A bare dotted string is never read as a
                          host here: that is where the property-key false positives live.

Comments are blanked first (a javadoc that explains a stale host is not a default), and only
src/main is read: a test's fixture host is not what the pod falls back to.

Usable as a CLI for humans:
    service_env_defaults.py <specs/cluster> <application.yml> [...]
"""
from __future__ import annotations

import ipaddress
import re
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - the callers guard this too
    print("  FAIL PyYAML not available (pip install pyyaml)")
    sys.exit(2)


# ── placeholder parsing ──────────────────────────────────────────────────────
def _top_level_placeholders(text: str):
    """Yield (start, end, name, default|None) for each outermost ${...} in text."""
    i, n = 0, len(text)
    while i < n - 1:
        if text[i] == "$" and text[i + 1] == "{":
            depth, j = 0, i
            while j < n:
                if text[j] == "{" and j > 0 and text[j - 1] == "$":
                    depth += 1
                elif text[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= n:  # unterminated — nothing more to read
                return
            body = text[i + 2 : j]
            depth, cut = 0, -1
            for k, ch in enumerate(body):
                if ch == "{" and k > 0 and body[k - 1] == "$":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                elif ch == ":" and depth == 0:
                    cut = k
                    break
            yield (i, j + 1, body, None) if cut < 0 else (i, j + 1, body[:cut], body[cut + 1 :])
            i = j + 1
        else:
            i += 1


def placeholder_chains(text: str, properties: dict[str, str] | None = None) -> list[tuple[list[str], str | None]]:
    """[(names, terminal_default)] — names outermost-first.

    `${A:${B:c}}` -> (["A", "B"], "c"): Spring only reaches B when A is unset, so
    setting EITHER name overrides the stale terminal default.

    A chain also follows a DOTTED name — a reference to another property in the
    same file, e.g. `app.bff.oidc.issuer: ${APP_BFF_OIDC_ISSUER:${casdoor.gateway-base}}`
    where `casdoor.gateway-base` is itself `${PKI_GATEWAY_BASE:<stale host>}`. Without
    following it the real terminal default is invisible, which is precisely how a
    stale value hides one indirection deep.
    """
    properties = properties or {}
    out: list[tuple[list[str], str | None]] = []
    for _, _, name, default in _top_level_placeholders(text):
        names = [name]
        seen = {name}
        followed: set[str] = set()
        while True:
            if default is None:
                # a bare `${some.property}` reference: continue through it
                target = names[-1]
                if "." in target and target in properties and target not in followed:
                    followed.add(target)
                    inner = list(_top_level_placeholders(properties[target]))
                    if len(inner) == 1 and inner[0][0] == 0 and inner[0][1] == len(properties[target]):
                        if inner[0][2] in seen:
                            break
                        seen.add(inner[0][2])
                        names.append(inner[0][2])
                        default = inner[0][3]
                        continue
                break
            inner = list(_top_level_placeholders(default))
            # extend the chain only when the default IS one whole placeholder
            if len(inner) == 1 and inner[0][0] == 0 and inner[0][1] == len(default) and inner[0][2] not in seen:
                seen.add(inner[0][2])
                names.append(inner[0][2])
                default = inner[0][3]
                continue
            break
        out.append((names, default))
    return out


def flatten_properties(docs: list) -> dict[str, str]:
    """dotted property name -> raw string value, for following in-file references."""
    out: dict[str, str] = {}
    for doc in docs:
        for path, value in _walk(doc):
            out.setdefault(".".join(path), value)
    return out


def _walk(node, path: tuple[str, ...] = ()):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from _walk(value, path + (str(key),))
    elif isinstance(node, list):
        for idx, value in enumerate(node):
            yield from _walk(value, path + (f"[{idx}]",))
    elif isinstance(node, str):
        yield path, node
    elif node is not None:
        yield path, str(node)


def _active_documents(text: str) -> list:
    """The application.yml documents that load UNCONDITIONALLY.

    A `spring.config.activate.on-profile` document only contributes when that
    profile is active, so its defaults are not something the pod silently adopts.
    """
    docs = []
    for doc in yaml.safe_load_all(text):
        if not isinstance(doc, dict):
            continue
        activate = ((doc.get("spring") or {}).get("config") or {}).get("activate") or {}
        if isinstance(activate, dict) and activate.get("on-profile"):
            continue
        docs.append(doc)
    return docs


# ── what the cluster actually has ────────────────────────────────────────────
_IN_CLUSTER_FQDN = re.compile(r"\b([a-z0-9][a-z0-9-]*)\.([a-z0-9][a-z0-9-]*)\.svc\.cluster\.local\b")
_URL_HOST = re.compile(r"\b[a-z][a-z0-9+.-]*://([A-Za-z0-9._-]+)")
_BARE_HOST = re.compile(r"^([A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9])(?::\d+)?$")
_PLACEHOLDER_LEFT = re.compile(r"\$\{|\{\{")


class ClusterFacts:
    """The namespaces and domains specs/cluster ITSELF establishes.

    Derived, never typed: `kind: Namespace` objects, every `metadata.namespace`,
    and every ArgoCD `destination.namespace` (which is where a chart's objects
    land even when no Namespace object is committed); domains come from the
    HOST-shaped positions only — Ingress `rules[].host`, the `host` /
    `extraHosts` / `gatewayHost` values the gateway charts route on, and the
    `app.kubernetes.io/part-of` label every object carries (which is how the
    second platform domain, hugmesh.games, states itself: its public host is
    `games.${GAMES_DOMAIN}`, a template hole no host position resolves).
    Position matters: `hugmesh.net/backend` is a live, deliberately frozen
    nodeSelector LABEL KEY, and reading it as a domain would be wrong.
    """

    #: namespaces every Kubernetes cluster has, which no manifest needs to create
    BUILTIN_NAMESPACES = frozenset({"default", "kube-system", "kube-public", "kube-node-lease"})
    _HOST_KEYS = frozenset({"host", "hosts", "extrahosts", "gatewayhost"})

    def __init__(self, cluster: Path):
        self.namespaces: set[str] = set(self.BUILTIN_NAMESPACES)
        self.hosts: set[str] = set()
        for path in sorted(cluster.rglob("*.yaml")):
            if f"{path.parent.name}" == "templates":
                continue  # Helm templates are not YAML until rendered
            try:
                docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
            except Exception:  # noqa: BLE001 - other gates own YAML validity
                continue
            for doc in docs:
                self._scan(doc)
                values = (((doc.get("spec") or {}).get("source") or {}).get("helm") or {}).get("values") \
                    if isinstance(doc, dict) else None
                if isinstance(values, str):
                    try:
                        self._scan(yaml.safe_load(values))
                    except Exception:  # noqa: BLE001
                        pass
        self.domains = {
            self.registrable(h)
            for h in self.hosts
            if h and not _PLACEHOLDER_LEFT.search(h) and re.fullmatch(r"[a-z]{2,}", h.rsplit(".", 1)[-1])
        }
        self.domains.discard("")

    def _scan(self, node, path: tuple[str, ...] = ()) -> None:
        if isinstance(node, dict):
            if node.get("kind") == "Namespace":
                self._add_ns((node.get("metadata") or {}).get("name"))
            meta = node.get("metadata")
            if isinstance(meta, dict):
                self._add_ns(meta.get("namespace"))
            dest = ((node.get("spec") or {}).get("destination") or {})
            if isinstance(dest, dict):
                self._add_ns(dest.get("namespace"))
            for key, value in node.items():
                if key == "app.kubernetes.io/part-of" and isinstance(value, str):
                    self.hosts.add(value)
                self._scan(value, path + (str(key).lower(),))
        elif isinstance(node, list):
            for value in node:
                self._scan(value, path)
        elif isinstance(node, str):
            if path and path[-1] in self._HOST_KEYS:
                self.hosts.add(node.lstrip("*."))

    def _add_ns(self, name) -> None:
        """A namespace name, unless it is an unrendered template hole."""
        if name and not _PLACEHOLDER_LEFT.search(str(name)):
            self.namespaces.add(str(name))

    @staticmethod
    def registrable(host: str) -> str:
        labels = host.strip().rstrip(".").split(".")
        return ".".join(labels[-2:]) if len(labels) >= 2 else ""


# ── the derived findings ─────────────────────────────────────────────────────
class StaleDefault:
    """One placeholder chain whose packaged default does not exist in this cluster."""

    def __init__(self, names: list[str], default: str, prop: str, rule: str, detail: str):
        self.names = names
        self.default = default
        self.prop = prop
        self.rule = rule
        self.detail = detail

    def __repr__(self) -> str:  # pragma: no cover - diagnostics only
        return f"StaleDefault({'|'.join(self.names)}={self.default!r}, {self.rule})"


def _is_ip(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def classify(names: list[str], default: str, prop: str, facts: ClusterFacts) -> StaleDefault | None:
    """R1/R2/R3 over ONE placeholder chain. None = the default is fine."""
    if default is None or not default.strip() or _PLACEHOLDER_LEFT.search(default):
        return None

    # R1 — in-cluster DNS in a namespace this cluster does not have.
    for match in _IN_CLUSTER_FQDN.finditer(default):
        namespace = match.group(2)
        if namespace not in facts.namespaces:
            return StaleDefault(
                names, default, prop, "dangling-namespace",
                f"{match.group(0)} resolves in namespace {namespace!r}, which specs/cluster "
                "neither creates nor deploys into — NXDOMAIN in the pod",
            )

    # R2 — the property IS a namespace and names one that does not exist.
    leaf = prop.rsplit(".", 1)[-1]
    if (leaf == "namespace" or leaf.endswith("-namespace")) and re.fullmatch(r"[a-z0-9][a-z0-9-]*", default):
        if default not in facts.namespaces:
            return StaleDefault(
                names, default, prop, "dangling-namespace",
                f"namespace {default!r} is not one specs/cluster creates or deploys into",
            )

    # R3 — a public host under a domain this cluster does not serve.
    for host in [m.group(1) for m in _URL_HOST.finditer(default)] + (
        [m.group(1) for m in _BARE_HOST.finditer(default)] if "://" not in default else []
    ):
        host = host.rstrip(".")
        if host.endswith(".local") or "." not in host or _is_ip(host):
            continue  # in-cluster (R1's business), a bare Service name, or a literal IP
        if not re.fullmatch(r"[a-z]{2,}", host.rsplit(".", 1)[-1]):
            continue  # not a DNS name at all — a version string, a decimal, a path fragment
        domain = ClusterFacts.registrable(host)
        if domain and domain not in facts.domains:
            return StaleDefault(
                names, default, prop, "foreign-domain",
                f"host {host!r} sits under {domain!r}; this cluster serves "
                f"{sorted(facts.domains)} — the pod would talk to someone else's domain",
            )
    return None


# ── the Java half of a service's packaged defaults ───────────────────────────────────
_ADDRESSY_NAME = re.compile(r"(HOST|URL|URI|ENDPOINT|BASE|ADDRESS|ISSUER|SERVER|DOMAIN|ORIGIN)", re.I)
_URL_LITERAL = re.compile(r"^[a-z][a-z0-9+.-]*://[A-Za-z0-9._-]+")
_FIELD_BEFORE = re.compile(r"\bString\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*$")
_CLASS_HEAD = re.compile(r"\b(?:class|record|enum|interface)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
_CONFIG_PROPS = re.compile(r'@ConfigurationProperties\s*\(\s*(?:(?:prefix|value)\s*=\s*)?"([^"]+)"')


@dataclass(frozen=True)
class JavaStale:
    """One stale literal in a service's Java source."""
    rel: str            # path under src/main/java, with forward slashes
    line: int
    field: str          # the String field/constant it initialises, "" when it is a bare literal
    literal: str
    rule: str           # dangling-namespace | foreign-domain
    detail: str
    prop: str = ""      # the property key that feeds it, when it can be derived (else "")
    env: str = ""       # the env var that overrides that property (Spring's canonical form)

    @property
    def external_key(self) -> str:
        """What an externalIntegrations entry's `property` names for a Java default."""
        return f"{self.rel.rsplit('/', 1)[-1]}#{self.field}" if self.field else self.rel.rsplit("/", 1)[-1]


def _scan_java(text: str):
    """(code, literals): the source with every comment BLANKED (newlines kept, so line
    numbers hold) and each string literal as (start, end, value). Text blocks, char
    literals and escapes are handled: a `//` inside a string is not a comment."""
    out: list[str] = []
    lits: list[tuple[int, int, str]] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:j])); i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(text[i:j]); i = j          # a text block: kept as code, not scanned
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            end = min(j + 1, n)
            lits.append((i, end, text[i + 1:j]))
            out.append(text[i:end]); i = end
        elif c == "'":
            j = i + 1
            while j < n and text[j] != "'" and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:min(j + 1, n)]); i = min(j + 1, n)
        else:
            out.append(c); i += 1
    return "".join(out), lits


def _kebab(name: str) -> str:
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"-\1", name).lower()


def _class_chain(code: str, pos: int) -> list[str]:
    """The names of the classes enclosing offset `pos`, outermost first."""
    stack: list[tuple[str | None, int]] = []     # (class name or None for a plain block, depth)
    depth = 0
    pending: str | None = None
    for m in re.finditer(r"[{};]|\b(?:class|record|enum|interface)\s+[A-Za-z_][A-Za-z0-9_]*", code[:pos]):
        tok = m.group(0)
        head = _CLASS_HEAD.match(tok)
        if head:
            pending = head.group(1)
        elif tok == "{":
            depth += 1
            stack.append((pending, depth)); pending = None
        elif tok == "}":
            if stack:
                stack.pop()
            depth -= 1
        elif tok == ";":
            pending = None
    return [name for name, _ in stack if name]


def _derive_property(code: str, field: str, pos: int) -> str:
    """The Spring property key a `@ConfigurationProperties` field is bound to, or "".

    prefix + the kebab-cased name of each outer FIELD that holds a nested class +
    the kebab-cased field. Only the plain shape is derived (`private Nested nested = new
    Nested();`); anything else returns "" rather than a guess, and the caller then asks for
    an explicit declaration instead of pretending it knows what feeds the field."""
    m = _CONFIG_PROPS.search(code)
    chain = _class_chain(code, pos)
    if not m or not chain or not field:
        return ""
    segments: list[str] = []
    outer_body = code
    for nested in chain[1:]:
        holder = re.search(rf"\b{re.escape(nested)}\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*new\s+{re.escape(nested)}\s*\(|;)", outer_body)
        if not holder:
            return ""
        segments.append(_kebab(holder.group(1)))
    return ".".join([m.group(1)] + segments + [_kebab(field)])


def _env_for(prop: str) -> str:
    """Spring Boot's canonical environment-variable form of a property key: dots become
    underscores, dashes are REMOVED, upper case (the documented binding rule)."""
    return prop.replace(".", "_").replace("-", "").upper() if prop else ""


def java_stale_literals(repo_dir: Path, facts: ClusterFacts) -> list[JavaStale]:
    """Every stale literal under <repo_dir>/src/main/java (rules J1 and J2 above)."""
    base = repo_dir / "src" / "main" / "java"
    found: list[JavaStale] = []
    for path in sorted(base.rglob("*.java")):
        code, lits = _scan_java(path.read_text(encoding="utf-8", errors="replace"))
        rel = path.relative_to(base).as_posix()
        for start, _end, value in lits:
            if len(value) < 4:
                continue
            field = ""
            fm = _FIELD_BEFORE.search(code[max(0, start - 200):start])
            if fm:
                field = fm.group(1)
            hit = None
            if _IN_CLUSTER_FQDN.search(value):                                    # J1
                hit = classify(["<java>"], value, field or "<literal>", facts)
                if hit is not None and hit.rule != "dangling-namespace":
                    hit = None
            if hit is None and field and _ADDRESSY_NAME.search(field) and _URL_LITERAL.match(value):   # J2
                hit = classify(["<java>"], value, field, facts)
                if hit is not None and hit.rule != "foreign-domain":
                    hit = None
            if hit is None:
                continue
            prop = _derive_property(code, field, start)
            found.append(JavaStale(rel, code.count("\n", 0, start) + 1, field, value, hit.rule, hit.detail,
                                   prop, _env_for(prop)))
    return found


#: an env-var-shaped chain member — the only kind a Deployment can actually set.
ENV_NAME = re.compile(r"[A-Z][A-Z0-9_]*")


def stale_defaults(application_yml: Path, facts: ClusterFacts) -> list[StaleDefault]:
    """Every placeholder in this service's application.yml with a non-existent default."""
    docs = _active_documents(application_yml.read_text(encoding="utf-8"))
    props = flatten_properties(docs)
    found: dict[tuple[str, ...], StaleDefault] = {}
    for doc in docs:
        for path, value in _walk(doc):
            for names, default in placeholder_chains(value, props):
                if not any(ENV_NAME.fullmatch(n) for n in names):
                    continue  # nothing a Deployment could set — not this gate's business
                hit = classify(names, default, ".".join(path), facts)
                if hit is not None:
                    found.setdefault((tuple(names), default), hit)
    return list(found.values())


def required_placeholders(application_yml: Path) -> list[tuple[list[str], str]]:
    """Chains with NO default at all — unset means the app cannot start (finding #15).

    "Unresolvable placeholders with no default value will cause an
    IllegalArgumentException to be thrown" (AbstractPropertyResolver
    .resolveRequiredPlaceholders). Restricted to chains that are ENTIRELY
    env-var-shaped: a chain ending in a dotted property reference we could not
    resolve in-file is reported by nothing here rather than guessed at.
    """
    docs = _active_documents(application_yml.read_text(encoding="utf-8"))
    props = flatten_properties(docs)
    out: dict[tuple[str, ...], tuple[list[str], str]] = {}
    for doc in docs:
        for path, value in _walk(doc):
            for names, default in placeholder_chains(value, props):
                if default is None and all(ENV_NAME.fullmatch(n) for n in names):
                    out.setdefault(tuple(names), (names, ".".join(path)))
    return list(out.values())


def main(argv: list[str]) -> int:  # pragma: no cover - human CLI
    if len(argv) < 2:
        print(__doc__)
        return 2
    facts = ClusterFacts(Path(argv[0]).resolve())
    print(f"cluster namespaces: {sorted(facts.namespaces)}")
    print(f"cluster domains:    {sorted(facts.domains)}")
    for arg in argv[1:]:
        path = Path(arg)
        print(f"\n== {path}")
        for hit in stale_defaults(path, facts):
            print(f"  [{hit.rule}] {'|'.join(hit.names)} = {hit.default!r}\n      at {hit.prop}: {hit.detail}")
        for names, prop in required_placeholders(path):
            print(f"  [no-default] {'|'.join(names)} (at {prop}) — unset is a startup failure")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
