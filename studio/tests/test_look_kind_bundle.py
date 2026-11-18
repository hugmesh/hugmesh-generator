"""The kind lane's per-domain look door (core/look_serving.py kind_bundle;
scripts/kind-local-domains.sh; the Makefile's kind-up / kind-domains targets).

The Docker lane answers a stylesheet by Host and serves the list of the mesh's domains from
its front door. The kind lane's front door is ingress-nginx and had neither, so every domain
showed the mesh's own look and the other domains could not be reached. These tests pin each
link of the cluster objects that give it the same without touching a cluster; the script
itself was run against a live kind cluster (probes in the pull request).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys

import pytest

from hugmesh_studio.core import look_serving
from hugmesh_studio.core.look_serving import (DOMAINS_JSON, KIND_DOOR_NAME, KIND_LABEL,
                                              KIND_LOOKS_NAME, KindBundleError, ServedBrand)

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MAKEFILE = os.path.join(REPO, "Makefile")
DOCKER_DOOR_CONF = os.path.join(REPO, "tests", "stack", "tls-front", "default.conf")
SCRIPT = os.path.join(REPO, "scripts", "kind-local-domains.sh")


def seeded(tmp_path) -> str:
    gen = str(tmp_path)
    look_serving.seed_samples(gen)
    return gen


def objects(gen: str, **kw) -> dict:
    """The bundle's objects keyed by 'Kind/name'."""
    d = json.loads(look_serving.kind_bundle(gen, **kw))
    assert d["kind"] == "List"
    return {f"{o['kind']}/{o['metadata']['name']}": o for o in d["items"]}


# ── what the bundle holds ───────────────────────────────────────────────────────────
def test_the_samples_make_the_six_objects_and_every_one_carries_the_label(tmp_path):
    objs = objects(seeded(tmp_path))
    assert set(objs) == {
        f"ConfigMap/{KIND_DOOR_NAME}-conf", f"ConfigMap/{KIND_LOOKS_NAME}",
        f"Deployment/{KIND_DOOR_NAME}", f"Service/{KIND_DOOR_NAME}",
        f"Ingress/{KIND_DOOR_NAME}-domains", f"Ingress/{KIND_DOOR_NAME}-mesh"}
    for key, o in objs.items():
        assert o["metadata"]["labels"][KIND_LABEL] == "true", key   # `down` deletes by this
        assert o["metadata"]["namespace"] == look_serving.KIND_NAMESPACE, key


def test_the_looks_configmap_holds_the_same_files_the_docker_door_reads(tmp_path):
    gen = seeded(tmp_path)
    cm = objects(gen)[f"ConfigMap/{KIND_LOOKS_NAME}"]
    folder = os.path.join(gen, look_serving.LOOKS_RELDIR)
    want = {DOMAINS_JSON}
    for host in ("acme.localhost", "example.localhost"):
        for fname in ("hug-theme.css", "snap-theme.css"):
            want.add(f"{host}__{fname}")
            on_disk = open(os.path.join(folder, "by-host", host, fname), encoding="utf-8").read()
            assert cm["data"][f"{host}__{fname}"] == on_disk
    assert set(cm["data"]) == want
    assert cm["data"][DOMAINS_JSON] == open(os.path.join(folder, DOMAINS_JSON),
                                            encoding="utf-8").read()


def test_the_volume_puts_each_file_where_the_door_looks_for_it(tmp_path):
    # ConfigMap keys cannot hold a "/", so items re-create by-host/<Host>/<file>
    dep = objects(seeded(tmp_path))[f"Deployment/{KIND_DOOR_NAME}"]
    vols = {v["name"]: v for v in dep["spec"]["template"]["spec"]["volumes"]}
    paths = {i["path"] for i in vols["looks"]["configMap"]["items"]}
    assert paths == {"domains.json",
                     "by-host/acme.localhost/hug-theme.css", "by-host/acme.localhost/snap-theme.css",
                     "by-host/example.localhost/hug-theme.css",
                     "by-host/example.localhost/snap-theme.css"}


def test_each_domain_has_its_own_colour_in_what_the_door_serves(tmp_path):
    data = objects(seeded(tmp_path))[f"ConfigMap/{KIND_LOOKS_NAME}"]["data"]
    acme, example = data["acme.localhost__hug-theme.css"], data["example.localhost__hug-theme.css"]
    assert "#0b6e4f" in acme and "#0b6e4f" not in example
    assert "#5b3cc4" in example and "#5b3cc4" not in acme


def test_a_domain_host_sends_every_path_to_the_door_without_a_forced_https_redirect(tmp_path):
    ing = objects(seeded(tmp_path))[f"Ingress/{KIND_DOOR_NAME}-domains"]
    assert ing["spec"]["ingressClassName"] == "nginx-internal"
    assert [r["host"] for r in ing["spec"]["rules"]] == ["acme.localhost", "example.localhost"]
    for r in ing["spec"]["rules"]:
        (p,) = r["http"]["paths"]
        assert (p["path"], p["pathType"]) == ("/", "Prefix")
        assert p["backend"]["service"] == {"name": KIND_DOOR_NAME, "port": {"number": 8080}}
    # ingress-nginx's :80 is mapped to the host (kind-local.yaml), so plain http must work:
    assert "force-ssl-redirect" not in json.dumps(ing["metadata"].get("annotations", {}))


def test_the_mesh_hosts_hand_over_only_the_domain_list(tmp_path):
    ing = objects(seeded(tmp_path))[f"Ingress/{KIND_DOOR_NAME}-mesh"]
    assert [r["host"] for r in ing["spec"]["rules"]] == ["hugmesh.net", "*.hugmesh.net"]
    for r in ing["spec"]["rules"]:
        (p,) = r["http"]["paths"]
        assert p["path"] == "/hug-domains.json"          # everything else stays on the gateway
        assert p["pathType"] == "ImplementationSpecific"  # `Exact` draws an API warning on the dot
    # the gateway's own Ingress forces https; this path must not be an http hole beside it
    assert ing["metadata"]["annotations"]["nginx.ingress.kubernetes.io/force-ssl-redirect"] == "true"


def test_the_door_runs_unprivileged_with_a_read_only_root(tmp_path):
    spec = objects(seeded(tmp_path))[f"Deployment/{KIND_DOOR_NAME}"]["spec"]["template"]["spec"]
    c = spec["containers"][0]
    assert spec["securityContext"]["runAsNonRoot"] is True and spec["securityContext"]["runAsUser"] == 101
    assert c["securityContext"]["readOnlyRootFilesystem"] is True
    assert c["securityContext"]["allowPrivilegeEscalation"] is False
    assert c["securityContext"]["capabilities"] == {"drop": ["ALL"]}
    assert c["resources"]["requests"] and c["resources"]["limits"]
    assert c["image"] == look_serving.KIND_DOOR_IMAGE and ":latest" not in c["image"]
    mounts = {m["mountPath"] for m in c["volumeMounts"]}
    assert {"/etc/nginx/conf.d/default.conf", "/etc/hugmesh-looks", "/tmp"} <= mounts


def test_the_readiness_probe_asks_the_door_for_the_list(tmp_path):
    c = objects(seeded(tmp_path))[f"Deployment/{KIND_DOOR_NAME}"]["spec"]["template"]["spec"]["containers"][0]
    assert c["readinessProbe"]["httpGet"]["path"] == "/hug-domains.json"


def test_recorded_domains_are_served_by_name_and_the_samples_are_gone(tmp_path):
    gen = str(tmp_path)
    look_serving.write(gen, {}, [ServedBrand(name="shop.example", bid="shop",
                                              look={"primary": "#112233", "header_text": "Shop"})])
    objs = objects(gen)
    hosts = [r["host"] for r in objs[f"Ingress/{KIND_DOOR_NAME}-domains"]["spec"]["rules"]]
    assert hosts == ["shop.example"]
    assert "shop.example__hug-theme.css" in objs[f"ConfigMap/{KIND_LOOKS_NAME}"]["data"]


def test_a_domain_that_inherits_is_listed_and_routed_but_has_no_folder_of_its_own(tmp_path):
    gen = str(tmp_path)
    look_serving.write(gen, {}, [ServedBrand(name="plain.example", bid="plain", look={}),
                                 ServedBrand(name="own.example", bid="own", look={"primary": "#abcdef"})])
    objs = objects(gen)
    data = objs[f"ConfigMap/{KIND_LOOKS_NAME}"]["data"]
    assert sorted(r["host"] for r in objs[f"Ingress/{KIND_DOOR_NAME}-domains"]["spec"]["rules"]) \
        == ["own.example", "plain.example"]
    assert "plain.example__hug-theme.css" not in data      # falls through to the gateway's look
    assert "own.example__hug-theme.css" in data
    assert "plain.example" in data[DOMAINS_JSON]


# ── refusals: nothing is applied rather than something half-right ─────────────────────
def test_no_domains_file_means_nothing_to_serve_and_says_how_to_get_some(tmp_path):
    with pytest.raises(KindBundleError, match="seed-samples"):
        look_serving.kind_bundle(str(tmp_path))


def test_an_unreadable_domains_file_is_refused(tmp_path):
    gen = seeded(tmp_path)
    with open(os.path.join(gen, look_serving.LOOKS_RELDIR, DOMAINS_JSON), "w") as fh:
        fh.write("{not json")
    with pytest.raises(KindBundleError, match="not readable"):
        look_serving.kind_bundle(gen)


def test_a_host_that_is_not_a_dns_name_never_becomes_an_ingress_rule(tmp_path):
    gen = seeded(tmp_path)
    p = os.path.join(gen, look_serving.LOOKS_RELDIR, DOMAINS_JSON)
    rows = json.load(open(p))
    rows["domains"].append({"name": "bad host/../x", "title": "x"})
    rows["domains"].append({"name": "*.wild.example", "title": "w"})
    json.dump(rows, open(p, "w"))
    hosts = [r["host"] for r in objects(gen)[f"Ingress/{KIND_DOOR_NAME}-domains"]["spec"]["rules"]]
    assert hosts == ["acme.localhost", "example.localhost"]


def test_a_list_with_no_usable_name_is_refused(tmp_path):
    gen = seeded(tmp_path)
    p = os.path.join(gen, look_serving.LOOKS_RELDIR, DOMAINS_JSON)
    json.dump({"schema": 1, "domains": [{"name": "../etc", "title": "x"}]}, open(p, "w"))
    with pytest.raises(KindBundleError, match="no usable domain"):
        look_serving.kind_bundle(gen)


def test_looks_too_big_for_a_configmap_are_refused_with_the_remedy(tmp_path, monkeypatch):
    gen = seeded(tmp_path)
    monkeypatch.setattr(look_serving, "KIND_CONFIGMAP_LIMIT", 100)
    with pytest.raises(KindBundleError, match="Shrink a picture"):
        look_serving.kind_bundle(gen)


# ── the door's nginx text ───────────────────────────────────────────────────────────
def test_the_door_uses_the_same_theme_location_as_the_docker_door():
    conf = look_serving.kind_door_conf()
    docker = open(DOCKER_DOOR_CONF, encoding="utf-8").read()
    assert f'location ~ "{look_serving.THEME_LOCATION_PCRE}"' in conf
    assert f'location ~ "{look_serving.THEME_LOCATION_PCRE}"' in docker   # one regex, two doors
    rx = look_serving.theme_location_regex(conf)
    assert rx is not None
    for path in ("/login/hug-theme.css", "/_remotes/login/snap-theme.css", "/hug-theme.css"):
        assert rx.search(path), path
    for path in ("/login/hug-theme.cssx", "/hug-theme.css/x", "/login/other.css"):
        assert not rx.search(path), path


def test_the_door_answers_the_list_from_disk_and_proxies_the_rest_to_the_gateway():
    conf = look_serving.kind_door_conf()
    assert re.search(r"location = /hug-domains\.json \{[^}]*try_files /domains\.json =404;", conf)
    assert "root /etc/hugmesh-looks/by-host/$host;" in conf
    assert "try_files /${hug_look_file}-theme.css @gateway;" in conf
    assert conf.count(f"proxy_pass http://$fe_gateway$request_uri;") == 2   # `/` and @gateway
    assert look_serving.KIND_GATEWAY_UPSTREAM in conf
    # per-request resolution, so a recreated gateway is found again (the Docker door's lesson)
    assert "resolver kube-dns.kube-system.svc.cluster.local" in conf and "set $fe_gateway" in conf
    assert conf.count('add_header Cache-Control "no-store" always;') == 2


@pytest.mark.skipif(shutil.which("nginx") is None, reason="no nginx binary to parse the text")
def test_the_door_conf_parses_under_nginx(tmp_path):
    main = tmp_path / "nginx.conf"
    main.write_text("events {}\nhttp {\n include %s;\n}\n" % (tmp_path / "default.conf"))
    (tmp_path / "default.conf").write_text(look_serving.kind_door_conf())
    r = subprocess.run(["nginx", "-t", "-c", str(main), "-p", str(tmp_path)],
                       capture_output=True, text=True)
    # `resolver <name>` is resolved at parse time and may not resolve here: that alone is fine
    assert r.returncode == 0 or "host not found" in r.stderr, r.stderr


# ── the command line, the script and the Makefile ───────────────────────────────────
def run_cli(gen: str, *args: str):
    return subprocess.run([sys.executable, "-m", "hugmesh_studio.core.look_serving", *args,
                           "--generator-dir", gen],
                          cwd=os.path.join(REPO, "studio"), capture_output=True, text=True)


def test_the_command_prints_the_list_and_nothing_else_on_stdout(tmp_path):
    gen = seeded(tmp_path)
    r = run_cli(gen, "kind-bundle")
    assert r.returncode == 0 and r.stderr == ""
    assert json.loads(r.stdout)["kind"] == "List"


def test_the_command_exits_one_with_the_reason_on_stderr_when_there_is_nothing_to_serve(tmp_path):
    r = run_cli(str(tmp_path), "kind-bundle")
    assert r.returncode == 1 and r.stdout == "" and "seed-samples" in r.stderr


def test_the_makefile_hooks_kind_up_and_offers_the_standalone_targets():
    mk = open(MAKEFILE, encoding="utf-8").read()
    up = mk[mk.index("\nkind-up:"):mk.index("\nkind-domains:")]
    assert "bootstrap-kind.sh" in up and "scripts/kind-local-domains.sh up" in up
    # the door is added only AFTER the bootstrap line (a failed bootstrap stops make first),
    # is skippable, and a failure is reported rather than swallowed
    assert up.index("bootstrap-kind.sh") < up.index("kind-local-domains.sh")
    assert "KIND_DOMAINS ?= 1" in mk and "filter 0,$(KIND_DOMAINS)" in up
    assert 'echo "WARN:' in up and "make kind-domains" in up
    for target, verb in (("kind-domains", "up"), ("kind-domains-down", "down"),
                         ("kind-domains-status", "status")):
        m = re.search(rf"^{target}:.*\n\tbash scripts/kind-local-domains\.sh {verb}$", mk, re.M)
        assert m, target


def test_the_script_only_ever_deletes_what_it_labelled():
    text = open(SCRIPT, encoding="utf-8").read()
    deletes = re.findall(r"^\s*K .*delete .*$", text, re.M)
    assert len(deletes) == 1 and '-l "${LABEL}"' in deletes[0]
    assert 'LABEL="hugmesh.net/local-domains=true"' in text
    assert look_serving.KIND_LABEL + "=true" in text
    code = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
    assert "sudo" not in code
