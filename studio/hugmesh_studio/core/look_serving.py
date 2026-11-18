"""A domain's own look, served by Host on the Docker mesh (theme survey item B).

WHAT HAPPENS. When the Docker mesh starts, :func:`write` turns the recorded domains into
generated files under ``tests/stack/.looks/`` (gitignored, like ``.theme.css``):

* ``<brand id>/hug-theme.css`` and ``snap-theme.css`` for every added domain, plus the
  mesh's own look in ``default/`` (``brand_look.write_look_files`` does this part);
* ``by-host/<domain name>/`` holding a copy of those two files, for every added domain
  that has a look of its OWN, and for no other name. The HTTPS front door
  (``tests/stack/tls-front/default.conf``) answers any request whose path ends in
  ``hug-theme.css`` or ``snap-theme.css`` from ``by-host/$host/`` when that file
  exists, and passes the request to the gateway otherwise. So a Host with no folder
  (the mesh's own name, localhost, a domain that only inherits) keeps the mesh's own
  look from ``HUG_THEME_CSS``, pictures and header included;
* ``view.tsv``: one ``make view`` row per added domain (lane ``compose``), so a browser
  on this machine can reach the domain BY ITS NAME through the HTTPS door with no
  ``/etc/hosts`` edit and no root.

WHY FOLDERS AND NOT AN NGINX MAP. nginx looks for the file on disk on every request,
but reads a ``map`` include only when it starts. With a map, a domain added (or
switched from inheriting to its own look) while the front door was already running
stayed on the gateway until someone restarted the door, because ``make stack-up`` does
not recreate a container whose compose settings did not change. A folder per Host is
picked up by the very next request, whoever started the mesh.

The folder is mounted read-only into the front door by ``tests/stack/compose.looks.yaml``,
which the Makefile adds only while ``by-host/`` exists, so a checkout the Studio never
touched brings up a byte-identical stack.

THE KIND LANE gets the same from :func:`kind_bundle` (a look door in the cluster behind
per-domain Ingresses; ``scripts/kind-local-domains.sh``, ``make kind-domains``), read from
this same folder.

WHAT IS NOT DONE HERE. The plain http door (8088) goes straight to the gateway, Tor
addresses go straight to the gateway, a built image and a Fleet cluster have one look
per mesh: none of them shows a domain's own look. A domain with its own look is
composed over the mesh's WHOLE look (``LocalMeshBootstrapConfig.login_look``, the look
``login_theme_css`` is made from: header, footer, pictures and font included), so what
its Look tab shows as inherited is what its page shows. A config without it (the CLI,
an older record) falls back to the record's eight look fields (``brand_model.LOOK_KEYS``).

Qt-free; nothing here starts a container.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping

from . import brand_look
from .config import default_brand_id

#: Generated folder, relative to the generator checkout. Gitignored.
LOOKS_RELDIR = os.path.join("tests", "stack", ".looks")
#: The per-Host folders the front door reads (``root .../by-host/$host``). Its presence
#: is also the Makefile's gate for the mount overlay.
HOSTS_DIRNAME = "by-host"
#: What the first version of this feature wrote (an nginx map include). Never written
#: now; removed when found, so a checkout that ran that version is cleaned up.
LEGACY_MAP_NAME = "hosts.map"
#: Extra ``make view`` rows, read by scripts/hugmesh-view.py with the shipped catalog.
VIEW_NAME = "view.tsv"
#: The two stylesheet names a sign-in page requests (``brand_look.write_look_files``).
_LOOK_FILES = ("hug-theme.css", "snap-theme.css")
#: The committed pieces whose presence is what makes the sentence "served" true.
TLS_FRONT_CONF_REL = os.path.join("tests", "stack", "tls-front", "default.conf")
LOOKS_COMPOSE_REL = os.path.join("tests", "stack", "compose.looks.yaml")
#: Where the folder is mounted inside the front door container.
MOUNT_POINT = "/etc/hugmesh-looks"
#: The first loopback port a domain's ``make view`` row gets; the shipped catalog ends
#: at 9095. Each row's port is overridable with HUGMESH_VIEW_PORT_<NAME>.
VIEW_PORT_BASE = 9100
VIEW_ROW_PREFIX = "compose-brand-"
#: The upstream every domain row talks to: the TLS door, because the plain door skips
#: the front door and with it the per-Host look.
VIEW_UPSTREAM = "https://127.0.0.1:${PUBLIC_HTTPS_PORT:-8488}"
VIEW_PATH = "/login/"
#: The list the sign-in page's "another domain" choice reads (the front door serves it as
#: /hug-domains.json, see tls-front/default.conf). Written beside the looks.
DOMAINS_JSON = "domains.json"
#: Present in ``.looks/`` while the folder holds the SAMPLE domains (:func:`seed_samples`)
#: and not domains a person recorded. :func:`write` and :func:`clear` remove it, so a mesh
#: the Studio starts with real domains replaces the samples and never sits beside them.
SAMPLES_MARKER = "samples"
#: What a local lane shows when nobody recorded a domain, so there is always a second
#: name to sign in on. ``.localhost`` names resolve to this machine in every browser with
#: no /etc/hosts edit and no root, and the front door's certificate covers ``*.localhost``
#: (tests/stack/gen-certs.sh). Each has a look of its OWN (a colour and a wordmark), so the
#: front door answers its stylesheet by Host and the shell and sign-in page say its name.
SAMPLE_DOMAINS: tuple[dict, ...] = (
    {"name": "acme.localhost", "id": "acme",
     "look": {"primary": "#0b6e4f", "secondary": "#f2a900", "header_text": "Acme"}},
    {"name": "example.localhost", "id": "example",
     "look": {"primary": "#5b3cc4", "secondary": "#e0457b", "header_text": "Example"}},
)

_DNS_NAME_RE = re.compile(
    r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\Z")
_ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,57}[a-z0-9])?\Z")
_GENERATED_HEADER = ("# GENERATED by HugMesh Studio (core/look_serving.py) when the Docker "
                     "mesh starts. Do not edit:\n# the next start rewrites it. Delete "
                     "tests/stack/.looks/ to stop serving domain looks.\n")


@dataclass(frozen=True)
class ServedBrand:
    """One added domain as the front door sees it."""
    name: str                       # the Host it is reached on
    bid: str                        # its brand id: the folder name
    look: dict = field(default_factory=dict)   # ONLY the fields it changes
    port: int = 0                   # its make view loopback port

    @property
    def has_own_look(self) -> bool:
        return any(v not in ("", None, False) for v in (self.look or {}).values())

    @property
    def view_name(self) -> str:
        return VIEW_ROW_PREFIX + self.bid

    @property
    def view_url(self) -> str:
        return f"https://127.0.0.1:{self.port}{VIEW_PATH}"


def _get(row, key):
    return row.get(key) if isinstance(row, Mapping) else getattr(row, key, None)


def served_brands(domains: Iterable[Any] | None, own_name: str = "") -> list[ServedBrand]:
    """Every recorded domain other than the mesh's own, in record order, whose name is
    a plain DNS name and whose brand id can name a folder. A row that fails either is
    left out (it could not name a folder safely); a second row on a name or id already
    taken is left out too, and so is an id spelled like one of the generated folders
    (``default``, ``by-host``). Accepts the bootstrap's record dicts or
    ``config.Domain`` rows."""
    own = (own_name or "").strip().lower()
    out: list[ServedBrand] = []
    names: set[str] = set()
    ids: set[str] = set()
    for row in domains or ():
        name = str(_get(row, "name") or "").strip().lower()
        if not name or name == own or not _DNS_NAME_RE.fullmatch(name):
            continue
        bid = str(_get(row, "id") or "").strip() or default_brand_id(name)
        if (bid in ("default", HOSTS_DIRNAME) or not _ID_RE.fullmatch(bid)
                or bid in ids or name in names):
            continue
        look = _get(row, "look") or {}
        look = dict(look) if isinstance(look, Mapping) else {}
        names.add(name)
        ids.add(bid)
        out.append(ServedBrand(name=name, bid=bid, look=look,
                               port=VIEW_PORT_BASE + len(out)))
    return out


def served_hosts(brands: Iterable[ServedBrand]) -> list[str]:
    """The Host names the front door answers from disk: only domains with a look of
    their own. An inheriting domain is left to the gateway, whose page already carries
    the mesh's whole look."""
    return [b.name for b in brands if b.has_own_look]


def view_rows_text(brands: Iterable[ServedBrand]) -> str:
    """One ``make view`` row per added domain (six TAB-separated columns)."""
    rows = ["\t".join((b.view_name, "compose", b.name, VIEW_UPSTREAM, str(b.port),
                       VIEW_PATH)) for b in brands]
    return _GENERATED_HEADER + "".join(r + "\n" for r in rows)


def brand_title(brand: ServedBrand) -> str:
    """What a person calls this domain: its wordmark when its look sets one, else its name."""
    return str((brand.look or {}).get("header_text") or "").strip() or brand.name


def domains_json_text(brands: Iterable[ServedBrand]) -> str:
    """The sign-in page's list of the other domains this mesh serves, one object per
    domain with its host name and the name to show. Names and titles only: nothing in it is
    secret, and the page asks for it from the door before anyone has signed in."""
    rows = [{"name": b.name, "title": brand_title(b)} for b in brands]
    return json.dumps({"schema": 1, "domains": rows}, indent=2, ensure_ascii=False) + "\n"


def looks_dir(generator_dir: str) -> str:
    return os.path.join(generator_dir, LOOKS_RELDIR)


def clear(generator_dir: str) -> None:
    """Remove what :func:`write` wrote: the two generated files and every folder that
    holds only look files. Anything else a person put there stays, and so does the
    folder then. Never raises for a missing folder."""
    d = looks_dir(generator_dir)
    if not os.path.isdir(d):
        return
    for name in (LEGACY_MAP_NAME, VIEW_NAME, DOMAINS_JSON, SAMPLES_MARKER):
        p = os.path.join(d, name)
        if os.path.isfile(p):
            os.remove(p)
    hosts = os.path.join(d, HOSTS_DIRNAME)
    if os.path.isdir(hosts) and not os.path.islink(hosts):
        _prune_look_folders(hosts, keep=())
        if not os.listdir(hosts):
            os.rmdir(hosts)
    _prune_look_folders(d, keep=())
    if not os.listdir(d):
        os.rmdir(d)


def _prune_look_folders(parent: str, keep: Iterable[str]) -> None:
    """Remove every folder under ``parent`` that holds only look files and is not named
    in ``keep``. A folder holding anything else is left alone."""
    keep = set(keep)
    for entry in os.listdir(parent):
        folder = os.path.join(parent, entry)
        if (entry not in keep and os.path.isdir(folder) and not os.path.islink(folder)
                and set(os.listdir(folder)) <= set(_LOOK_FILES)):
            shutil.rmtree(folder)


def write(generator_dir: str, superbrand_look: Mapping[str, Any] | None,
          brands: Iterable[ServedBrand]) -> list[str]:
    """Write the looks, the per-Host folders and the view rows. With no added domain it
    CLEARS instead, so the Makefile stops adding the mount and the stack is as before.

    ``by-host/`` is rebuilt as a SET every time: a folder for a domain that now
    inherits, or that is gone, is removed, so the front door stops answering for it on
    the next request.

    The looks are composed and checked first (``write_look_files`` refuses the whole
    write on a bad look or one past its budget): on that refusal the folder is cleared,
    so a look from an earlier start is never served under a newer record, and the
    :class:`brand_look.LookError` is raised for the caller to say."""
    brands = list(brands)
    if not brands:
        clear(generator_dir)
        return []
    d = looks_dir(generator_dir)
    try:
        written = brand_look.write_look_files(
            superbrand_look or {}, {b.bid: b.look for b in brands}, d)
    except brand_look.LookError:
        clear(generator_dir)
        raise
    legacy = os.path.join(d, LEGACY_MAP_NAME)
    if os.path.isfile(legacy):
        os.remove(legacy)
    hosts = os.path.join(d, HOSTS_DIRNAME)
    os.makedirs(hosts, exist_ok=True)
    own = {b.name: b.bid for b in brands if b.has_own_look}
    _prune_look_folders(hosts, keep=own)
    for name, bid in own.items():
        folder = os.path.join(hosts, name)
        os.makedirs(folder, exist_ok=True)
        for fname in _LOOK_FILES:
            dst = os.path.join(folder, fname)
            shutil.copyfile(os.path.join(d, bid, fname), dst)
            written.append(dst)
    p = os.path.join(d, VIEW_NAME)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(view_rows_text(brands))
    written.append(p)
    p = os.path.join(d, DOMAINS_JSON)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(domains_json_text(brands))
    written.append(p)
    marker = os.path.join(d, SAMPLES_MARKER)
    if os.path.isfile(marker):          # a real write replaces the samples
        os.remove(marker)
    _readable_by_the_door(d)
    return written


def _readable_by_the_door(root: str) -> None:
    """Make every folder and file under ``root`` readable by anyone. The front door's
    nginx workers run as the image's own ``nginx`` user, not as the operator, and a
    Studio started under a strict umask (077) would write files they cannot open:
    try_files then falls through to the gateway WITHOUT A WORD and every domain shows
    the mesh's own look. Nothing here is secret (the same colours the sign-in page
    sends to anyone who asks). Symbolic links are left alone."""
    for dirpath, _dirs, files in os.walk(root):
        if not os.path.islink(dirpath):
            os.chmod(dirpath, 0o755)
        for f in files:
            p = os.path.join(dirpath, f)
            if not os.path.islink(p):
                os.chmod(p, 0o644)


#: The front door's theme location regex, as committed in tls-front/default.conf (an
#: nginx PCRE). login-ui links the stylesheet relatively, so it arrives as
#: /login/hug-theme.css, /_remotes/login/snap-theme.css or /hug-theme.css: the regex
#: must match a name at the end of ANY path, not only at the root.
#: :func:`theme_location_regex` reads it back out of a conf so tests can run real
#: request paths through the committed text.
THEME_LOCATION_PCRE = r"(?:^|/)(?<hug_look_file>hug|snap)-theme\.css$"


def theme_location_regex(conf_text: str) -> "re.Pattern[str] | None":
    """The theme location's regex from a tls-front conf, compiled as Python (``(?<name>``
    becomes ``(?P<name>``), or None when the conf has no ``location ~ "...-theme..."``."""
    m = re.search(r'^\s*location ~ "([^"]*-theme[^"]*)"\s*\{', _live(conf_text), re.M)
    if not m:
        return None
    return re.compile(m.group(1).replace("(?<", "(?P<"))


def sample_brands() -> list[ServedBrand]:
    """The sample domains as the front door sees them."""
    return served_brands(SAMPLE_DOMAINS)


def seed_samples(generator_dir: str, *, enabled: bool = True) -> list[str]:
    """Give a local lane two named domains when nobody recorded any, so a person can
    always sign in somewhere else. Returns the sample brand ids now in place (their
    ``<id>=default`` is also the per-domain Tor list when Tor is on).

    * ``by-host/`` there with no marker: the Studio recorded real domains (or a person
      made the folder). Nothing is touched and ``[]`` comes back.
    * no folder, or the folder is the samples': (re)write them. Idempotent.
    * ``enabled`` false: remove samples left by an earlier start, touch nothing else.

    The samples are always the superbrand's tenant (``default``): the same people, the
    same admins, a different name and look. Never raises for a missing folder."""
    d = looks_dir(generator_dir)
    hosts = os.path.join(d, HOSTS_DIRNAME)
    marker = os.path.join(d, SAMPLES_MARKER)
    if not enabled:
        if os.path.isfile(marker):
            clear(generator_dir)
        return []
    if os.path.isdir(hosts) and not os.path.isfile(marker):
        return []
    brands = sample_brands()
    write(generator_dir, {}, brands)
    with open(os.path.join(generator_dir, LOOKS_RELDIR, SAMPLES_MARKER), "w",
              encoding="utf-8") as fh:
        fh.write("The domains in this folder are the SAMPLES a local lane shows when no "
                 "domain was recorded. Recording a domain in the Studio replaces them.\n")
    return [b.bid for b in brands]


# ── the kind lane: the same looks, served by an in-cluster door ──────────────────────
#: The kind cluster's front door is ingress-nginx in front of the fe-gateway, with one
#: Ingress for ``hugmesh.net`` and ``*.hugmesh.net``. It has no folder to mount and no
#: per-Host stylesheet, so the lane showed ONE look and no other domain. :func:`kind_bundle`
#: turns the SAME ``.looks/`` folder the Docker door reads into cluster objects: a small
#: nginx "look door" that does exactly what ``tls-front/default.conf`` does (a stylesheet
#: by Host from ``by-host/<Host>/``, ``/hug-domains.json``, everything else to the
#: gateway), a ConfigMap holding the files, and Ingresses that send the domain hosts (and
#: ``/hug-domains.json`` on the mesh's own hosts) to it. Applied by
#: ``scripts/kind-local-domains.sh``; not part of GitOps, because the domains are a local
#: choice (samples or what the Studio recorded), like the Vault seeds the bootstrap writes.
KIND_NAMESPACE = "hugmesh-frontend"
KIND_DOOR_NAME = "hugmesh-look-door"
KIND_LOOKS_NAME = "hugmesh-look-door-looks"
KIND_CONF_NAME = "hugmesh-look-door-conf"
#: Every object the bundle makes carries this label, so ``down`` removes exactly them.
KIND_LABEL = "hugmesh.net/local-domains"
KIND_INGRESS_CLASS = "nginx-internal"
KIND_GATEWAY_UPSTREAM = "hugmesh-fe-gateway.hugmesh-frontend.svc.cluster.local:8080"
#: nginx-unprivileged listens on 8080 as uid 101: no root, a read-only root filesystem.
KIND_DOOR_IMAGE = "nginxinc/nginx-unprivileged:1.27-alpine"
#: The hosts the mesh itself answers on (the fe-gateway's own Ingress): they keep going
#: straight to the gateway, except for ``/hug-domains.json``.
KIND_MESH_HOSTS = ("hugmesh.net", "*.hugmesh.net")
#: A ConfigMap holds 1 MiB; leave room for the object around the data.
KIND_CONFIGMAP_LIMIT = 900_000


class KindBundleError(Exception):
    """The looks folder cannot be turned into cluster objects (nothing is applied)."""


def kind_door_conf() -> str:
    """The look door's nginx server block: the Docker door's two answers without TLS (the
    ingress terminates it), the gateway as the upstream, and cluster DNS as the resolver
    so a recreated gateway is found again on the next request (the reason the Docker door
    resolves per request too). The theme location is the committed one, from
    :data:`THEME_LOCATION_PCRE`."""
    return f"""\
# GENERATED by HugMesh Studio (core/look_serving.py kind_door_conf). Do not edit.
map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
# ingress-nginx sets X-Forwarded-Proto; fall back to the scheme when it did not.
map $http_x_forwarded_proto $door_proto {{ default $http_x_forwarded_proto; '' $scheme; }}

server {{
    listen 8080;
    server_name _;
    resolver kube-dns.kube-system.svc.cluster.local valid=10s ipv6=off;
    set $fe_gateway {KIND_GATEWAY_UPSTREAM};

    client_max_body_size 100m;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $door_proto;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_buffering off;
    proxy_read_timeout 300s;

    location / {{
        proxy_pass http://$fe_gateway$request_uri;
    }}

    # A domain's own look, by Host; the gateway answers when the Host has no folder.
    location ~ "{THEME_LOCATION_PCRE}" {{
        root /etc/hugmesh-looks/by-host/$host;
        try_files /${{hug_look_file}}-theme.css @gateway;
        add_header Cache-Control "no-store" always;
    }}

    # The other domains, for the sign-in page's "another domain" choice.
    location = /hug-domains.json {{
        root /etc/hugmesh-looks;
        default_type application/json;
        try_files /domains.json =404;
        add_header Cache-Control "no-store" always;
    }}

    location @gateway {{
        proxy_pass http://$fe_gateway$request_uri;
    }}
}}
"""


def _kind_meta(name: str, namespace: str) -> dict:
    return {"name": name, "namespace": namespace,
            "labels": {KIND_LABEL: "true", "app.kubernetes.io/name": KIND_DOOR_NAME,
                       "app.kubernetes.io/part-of": "hugmesh.net"}}


def _kind_ingress(name: str, namespace: str, hosts: Iterable[str], path: str,
                  path_type: str, *, force_ssl: bool) -> dict:
    backend = {"service": {"name": KIND_DOOR_NAME, "port": {"number": 8080}}}
    meta = _kind_meta(name, namespace)
    if force_ssl:
        meta["annotations"] = {"nginx.ingress.kubernetes.io/force-ssl-redirect": "true"}
    return {"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": meta,
            "spec": {"ingressClassName": KIND_INGRESS_CLASS,
                     "rules": [{"host": h, "http": {"paths": [
                         {"path": path, "pathType": path_type, "backend": backend}]}}
                         for h in hosts]}}


def kind_bundle(generator_dir: str, namespace: str = KIND_NAMESPACE,
                image: str = KIND_DOOR_IMAGE) -> str:
    """The cluster objects that serve ``.looks/`` on the kind lane, as one JSON ``List``
    (valid YAML, so ``kubectl apply -f -`` takes it). Raises :class:`KindBundleError`
    when there is nothing to serve (no ``domains.json``) or it will not fit.

    * a domain host gets an Ingress sending EVERY path to the look door (no forced https
      redirect: ingress-nginx's http port is mapped to the host, so
      ``http://acme.localhost:8080`` works as the Docker lane's does);
    * the mesh's own hosts get an Ingress for ``/hug-domains.json`` only (an exact-name prefix beats the
      gateway's Prefix ``/``), so the sign-in page on ``hugmesh.net`` lists the others too.
    """
    d = looks_dir(generator_dir)
    dj = os.path.join(d, DOMAINS_JSON)
    if not os.path.isfile(dj):
        raise KindBundleError(f"no {DOMAINS_JSON} in {d}: no domains to serve "
                              "(run seed-samples, or record a domain in the Studio)")
    try:
        rows = json.load(open(dj, encoding="utf-8")).get("domains", [])
    except (OSError, ValueError) as exc:
        raise KindBundleError(f"{dj} is not readable: {exc}") from exc
    hosts = [str(r.get("name", "")).lower() for r in rows if isinstance(r, dict)]
    hosts = sorted({h for h in hosts if _DNS_NAME_RE.match(h)})
    if not hosts:
        raise KindBundleError(f"{dj} names no usable domain")

    data: dict[str, str] = {DOMAINS_JSON: open(dj, encoding="utf-8").read()}
    items = [{"key": DOMAINS_JSON, "path": DOMAINS_JSON}]
    hosts_dir = os.path.join(d, HOSTS_DIRNAME)
    for host in sorted(os.listdir(hosts_dir)) if os.path.isdir(hosts_dir) else []:
        if not _DNS_NAME_RE.match(host):
            continue
        for fname in _LOOK_FILES:
            src = os.path.join(hosts_dir, host, fname)
            if os.path.isfile(src):
                key = f"{host}__{fname}"          # ConfigMap keys cannot hold a "/"
                data[key] = open(src, encoding="utf-8").read()
                items.append({"key": key, "path": f"{HOSTS_DIRNAME}/{host}/{fname}"})
    size = sum(len(v.encode("utf-8")) for v in data.values())
    if size > KIND_CONFIGMAP_LIMIT:
        raise KindBundleError(
            f"the looks are {size:,} bytes; a ConfigMap holds about {KIND_CONFIGMAP_LIMIT:,}. "
            "Shrink a picture in a domain's Look tab.")

    cm_looks = {"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": _kind_meta(KIND_LOOKS_NAME, namespace), "data": data}
    cm_conf = {"apiVersion": "v1", "kind": "ConfigMap",
               "metadata": _kind_meta(KIND_CONF_NAME, namespace),
               "data": {"default.conf": kind_door_conf()}}
    labels = {"app": KIND_DOOR_NAME}
    deploy = {
        "apiVersion": "apps/v1", "kind": "Deployment",
        "metadata": _kind_meta(KIND_DOOR_NAME, namespace),
        "spec": {
            "replicas": 1, "selector": {"matchLabels": labels},
            "template": {
                "metadata": {"labels": labels, "annotations": {
                    # a changed look or conf rolls the pod, so nothing is ever stale
                    "hugmesh.net/looks-bytes": str(size)}},
                "spec": {
                    "securityContext": {"runAsNonRoot": True, "runAsUser": 101,
                                        "seccompProfile": {"type": "RuntimeDefault"}},
                    "containers": [{
                        "name": "nginx", "image": image,
                        "ports": [{"containerPort": 8080, "name": "http"}],
                        "securityContext": {"allowPrivilegeEscalation": False,
                                            "readOnlyRootFilesystem": True,
                                            "capabilities": {"drop": ["ALL"]}},
                        "resources": {"requests": {"cpu": "10m", "memory": "32Mi"},
                                      "limits": {"cpu": "200m", "memory": "128Mi"}},
                        "readinessProbe": {"httpGet": {"path": "/hug-domains.json",
                                                       "port": "http"},
                                           "periodSeconds": 5},
                        "volumeMounts": [
                            {"name": "conf", "mountPath": "/etc/nginx/conf.d/default.conf",
                             "subPath": "default.conf", "readOnly": True},
                            {"name": "looks", "mountPath": "/etc/hugmesh-looks",
                             "readOnly": True},
                            {"name": "tmp", "mountPath": "/tmp"}]}],
                    "volumes": [
                        {"name": "conf", "configMap": {"name": KIND_CONF_NAME}},
                        {"name": "looks", "configMap": {"name": KIND_LOOKS_NAME,
                                                        "items": items}},
                        {"name": "tmp", "emptyDir": {}}]}}}}
    svc = {"apiVersion": "v1", "kind": "Service",
           "metadata": _kind_meta(KIND_DOOR_NAME, namespace),
           "spec": {"selector": labels,
                    "ports": [{"name": "http", "port": 8080, "targetPort": "http"}]}}
    objects = [
        cm_conf, cm_looks, deploy, svc,
        _kind_ingress(KIND_DOOR_NAME + "-domains", namespace, hosts, "/", "Prefix",
                      force_ssl=False),
        _kind_ingress(KIND_DOOR_NAME + "-mesh", namespace, KIND_MESH_HOSTS,
                      "/hug-domains.json", "ImplementationSpecific", force_ssl=True),
    ]
    return json.dumps({"apiVersion": "v1", "kind": "List", "items": objects},
                      indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    """``python3 -m hugmesh_studio.core.look_serving seed-samples [--off] [--generator-dir D]``:
    what ``make stack-up`` runs. ``kind-bundle`` prints the kind lane's objects (exit 1 and
    a message on stderr when there is nothing to serve). Prints the sample ids on stdout (space separated, empty
    when none) and nothing else there; every message goes to stderr. A failure is reported
    and exits 0 with an empty list: the stack must still come up without its samples."""
    ap = argparse.ArgumentParser(prog="look_serving")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("seed-samples", help="seed the sample domains when none are recorded")
    sp.add_argument("--off", action="store_true", help="remove samples an earlier start left")
    sp.add_argument("--generator-dir", default=default_generator_dir())
    kb = sub.add_parser("kind-bundle", help="print the kind lane's look-door objects (JSON)")
    kb.add_argument("--generator-dir", default=default_generator_dir())
    kb.add_argument("--namespace", default=KIND_NAMESPACE)
    kb.add_argument("--image", default=KIND_DOOR_IMAGE)
    args = ap.parse_args(argv)
    if args.cmd == "kind-bundle":
        try:
            sys.stdout.write(kind_bundle(args.generator_dir, args.namespace, args.image))
        except KindBundleError as exc:
            print(f"look_serving: {exc}", file=sys.stderr)
            return 1
        return 0
    try:
        ids = seed_samples(args.generator_dir, enabled=not args.off)
    except Exception as exc:                      # noqa: BLE001 - never block make
        print(f"look_serving: sample domains not seeded: {exc}", file=sys.stderr)
        return 0
    if ids:
        print("look_serving: sample domains " + ", ".join(ids), file=sys.stderr)
    print(" ".join(ids))
    return 0


# ── measured truth: does THIS checkout's front door serve a domain's own look? ──────
def door_serves_looks(generator_dir: str) -> bool:
    """True when the checkout carries all three committed halves: the front door's theme
    location that reads ``by-host/$host``, the overlay that mounts the folder, and the
    Makefile line that adds that overlay. Measured, never assumed (the makefile_holds_tor
    pattern), so a screen cannot say "served" for a checkout that would not serve it."""
    try:
        with open(os.path.join(generator_dir, TLS_FRONT_CONF_REL), encoding="utf-8") as fh:
            conf = _live(fh.read())
        with open(os.path.join(generator_dir, LOOKS_COMPOSE_REL), encoding="utf-8") as fh:
            overlay = _live(fh.read())
        with open(os.path.join(generator_dir, "Makefile"), encoding="utf-8") as fh:
            make = _live(fh.read())
    except OSError:
        return False
    up_lines = [line for line in make.splitlines()
                if line.rstrip().endswith(" up -d") and "$(STACK_COMPOSE)" in line]
    return (f'location ~ "{THEME_LOCATION_PCRE}"' in conf
            and re.search(rf"^\s*root {re.escape(MOUNT_POINT)}/{HOSTS_DIRNAME}/\$host;",
                          conf, re.M) is not None
            and "try_files /${hug_look_file}-theme.css @gateway;" in conf
            and f"./.looks:{MOUNT_POINT}:ro" in overlay
            and re.search(r"^STACK_LOOKS_GATE\s*:=\s*tests/stack/\.looks/by-host\s*$",
                          make, re.M) is not None
            and re.search(r"^STACK_LOOKS_COMPOSE\s*:=\s*tests/stack/compose\.looks\.yaml\s*$",
                          make, re.M) is not None
            and re.search(r"^STACK_LOOKS_FLAGS\s*:=.*\$\(wildcard \$\(STACK_LOOKS_GATE\)\),"
                          r"-f \$\(STACK_LOOKS_COMPOSE\)", make, re.M) is not None
            and bool(up_lines) and all("$(STACK_LOOKS_FLAGS)" in line for line in up_lines))


def _live(text: str) -> str:
    """The text without comment lines (a commented-out line serves nothing)."""
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("#"))


def default_generator_dir() -> str:
    """The checkout this Studio runs from (studio/hugmesh_studio/core -> the root)."""
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


def own_look_sentence(path: str, generator_dir: str = "") -> str:
    """What a domain's Look tab says about where its own look shows, for ``path``
    (image | docker | fleet). The Docker answer is measured on ``generator_dir`` (the
    Studio's own checkout when none is given)."""
    if path not in brand_look.PATHS_WITH_OWN_LOOK:
        return brand_look.DOCKER_ONLY_SENTENCE
    if door_serves_looks(generator_dir or default_generator_dir()):
        return brand_look.DOCKER_SERVED_SENTENCE
    return brand_look.DOCKER_NOT_SERVED_SENTENCE


if __name__ == "__main__":
    from .entry import bootstrap as _bootstrap   # the Mac PATH hook: core/entry.py
    _bootstrap()
    raise SystemExit(main())
