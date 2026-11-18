"""The sample domains a local lane shows when nobody recorded one
(core/look_serving.py seed_samples; the Makefile's STACK_SAMPLES; tests/stack/gen-certs.sh).

A person who starts the Docker mesh with no domain of their own used to get exactly one
name to sign in on. Now the lane seeds acme.localhost and example.localhost: each with its
own look and wordmark (served by Host through the HTTPS door), its own `make view` row,
a place in the list the sign-in page offers, and, when Tor is on, its own .onion. These
tests pin every link of that without starting a container.
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
from hugmesh_studio.core.look_serving import (DOMAINS_JSON, LOOKS_RELDIR, SAMPLE_DOMAINS,
                                              SAMPLES_MARKER, ServedBrand)

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MAKEFILE = os.path.join(REPO, "Makefile")
GEN_CERTS = os.path.join(REPO, "tests", "stack", "gen-certs.sh")
HAVE_MAKE = shutil.which("make") is not None
HAVE_OPENSSL = shutil.which("openssl") is not None


def looks(gen: str) -> str:
    return os.path.join(gen, LOOKS_RELDIR)


def real_brand() -> ServedBrand:
    return ServedBrand(name="shop.example", bid="shop", look={"primary": "#112233"}, port=9100)


# ── the samples themselves ──────────────────────────────────────────────────────────
def test_the_samples_are_two_valid_domains_with_a_look_of_their_own():
    brands = look_serving.sample_brands()
    assert [b.name for b in brands] == ["acme.localhost", "example.localhost"]
    assert [b.bid for b in brands] == ["acme", "example"]
    assert all(b.has_own_look for b in brands), "a sample with no look would not be served by Host"
    assert len({b.port for b in brands}) == 2
    # distinct wordmarks: the page of each says its own name
    assert [look_serving.brand_title(b) for b in brands] == ["Acme", "Example"]


def test_every_sample_name_is_one_the_certificate_covers():
    """The host names appear in three places that must agree: the samples here, the
    Makefile's STACK_CERT_SAN_HOSTS and gen-certs.sh's default SNAP_EXTRA_SANS."""
    names = [d["name"] for d in SAMPLE_DOMAINS]
    make = open(MAKEFILE, encoding="utf-8").read()
    m = re.search(r"^STACK_CERT_SAN_HOSTS\s*:=\s*(.+)$", make, re.M)
    assert m and m.group(1).split() == names
    certs = open(GEN_CERTS, encoding="utf-8").read()
    m = re.search(r'SNAP_EXTRA_SANS-([^}]+)\}', certs)
    assert m and m.group(1).split(",") == names


# ── seeding ──────────────────────────────────────────────────────────────────────────
def test_seeding_an_empty_checkout_writes_the_whole_set(tmp_path):
    gen = str(tmp_path)
    ids = look_serving.seed_samples(gen)
    assert ids == ["acme", "example"]
    d = looks(gen)
    for host in ("acme.localhost", "example.localhost"):
        for f in ("hug-theme.css", "snap-theme.css"):
            assert os.path.isfile(os.path.join(d, "by-host", host, f)), (host, f)
    assert os.path.isfile(os.path.join(d, SAMPLES_MARKER))
    rows = open(os.path.join(d, "view.tsv"), encoding="utf-8").read()
    assert "compose-brand-acme" in rows and "compose-brand-example" in rows
    # each domain's page says its own name
    for host, word in (("acme.localhost", "Acme"), ("example.localhost", "Example")):
        css = open(os.path.join(d, "by-host", host, "hug-theme.css"), encoding="utf-8").read()
        assert f"--hug-header-content: '{word}'" in css


def test_the_picker_list_names_every_domain_and_nothing_secret(tmp_path):
    gen = str(tmp_path)
    look_serving.seed_samples(gen)
    doc = json.load(open(os.path.join(looks(gen), DOMAINS_JSON), encoding="utf-8"))
    assert doc == {"schema": 1, "domains": [{"name": "acme.localhost", "title": "Acme"},
                                           {"name": "example.localhost", "title": "Example"}]}


def test_seeding_twice_changes_nothing(tmp_path):
    gen = str(tmp_path)
    look_serving.seed_samples(gen)
    first = {p: open(p, "rb").read() for p in _files(looks(gen))}
    assert look_serving.seed_samples(gen) == ["acme", "example"]
    assert {p: open(p, "rb").read() for p in _files(looks(gen))} == first


def test_domains_a_person_recorded_are_never_touched(tmp_path):
    """The Studio's own write() leaves by-host/ with NO marker: seeding must see that and
    leave it alone, or a recorded domain would be replaced by two samples."""
    gen = str(tmp_path)
    look_serving.write(gen, {}, [real_brand()])
    before = {p: open(p, "rb").read() for p in _files(looks(gen))}
    assert not os.path.exists(os.path.join(looks(gen), SAMPLES_MARKER))
    assert look_serving.seed_samples(gen) == []
    assert {p: open(p, "rb").read() for p in _files(looks(gen))} == before
    assert not os.path.isdir(os.path.join(looks(gen), "by-host", "acme.localhost"))


def test_recording_a_domain_replaces_the_samples_and_removes_the_marker(tmp_path):
    gen = str(tmp_path)
    look_serving.seed_samples(gen)
    look_serving.write(gen, {}, [real_brand()])
    d = looks(gen)
    assert not os.path.exists(os.path.join(d, SAMPLES_MARKER))
    assert sorted(os.listdir(os.path.join(d, "by-host"))) == ["shop.example"]
    doc = json.load(open(os.path.join(d, DOMAINS_JSON), encoding="utf-8"))
    assert [r["name"] for r in doc["domains"]] == ["shop.example"]


def test_a_studio_start_with_no_domains_clears_and_the_next_make_reseeds(tmp_path):
    """No recorded domain -> the Studio clears the folder (samples included); the Makefile
    then seeds again, so a start from the Studio with no domain still has two."""
    gen = str(tmp_path)
    look_serving.seed_samples(gen)
    look_serving.write(gen, {}, [])                  # what the Studio does with no domain
    assert not os.path.exists(looks(gen))
    assert look_serving.seed_samples(gen) == ["acme", "example"]


def test_turning_it_off_removes_the_samples_but_nothing_else(tmp_path):
    gen = str(tmp_path)
    look_serving.seed_samples(gen)
    assert look_serving.seed_samples(gen, enabled=False) == []
    assert not os.path.exists(looks(gen))
    # recorded domains survive an --off
    look_serving.write(gen, {}, [real_brand()])
    assert look_serving.seed_samples(gen, enabled=False) == []
    assert os.path.isdir(os.path.join(looks(gen), "by-host", "shop.example"))


def test_the_command_line_prints_only_the_ids_on_stdout(tmp_path):
    env = dict(os.environ, PYTHONPATH=os.path.join(REPO, "studio"))
    r = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.look_serving",
                        "seed-samples", "--generator-dir", str(tmp_path)],
                       capture_output=True, text=True, env=env, cwd=os.path.join(REPO, "studio"))
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "acme example"
    off = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.look_serving",
                          "seed-samples", "--off", "--generator-dir", str(tmp_path)],
                         capture_output=True, text=True, env=env, cwd=os.path.join(REPO, "studio"))
    assert off.returncode == 0 and off.stdout.strip() == ""


def test_a_failure_never_blocks_make(tmp_path):
    """A generator dir that cannot be written to still exits 0 with an empty list."""
    blocker = tmp_path / "file"
    blocker.write_text("x")
    env = dict(os.environ, PYTHONPATH=os.path.join(REPO, "studio"))
    r = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.look_serving",
                        "seed-samples", "--generator-dir", str(blocker)],
                       capture_output=True, text=True, env=env, cwd=os.path.join(REPO, "studio"))
    assert r.returncode == 0
    assert r.stdout.strip() == ""
    assert "not seeded" in r.stderr


def _files(root):
    out = []
    for dirpath, _d, fs in os.walk(root):
        out += [os.path.join(dirpath, f) for f in fs]
    return sorted(out)


# ── the Makefile ─────────────────────────────────────────────────────────────────────
def test_the_makefile_seeds_before_it_reads_the_looks_gate_and_the_tor_list():
    """STACK_LOOKS_FLAGS is a parse-time $(wildcard): the seed must come first or the
    first start would come up without the looks mount. The Tor list reads the seeded ids."""
    make = open(MAKEFILE, encoding="utf-8").read()
    pos = {n: make.index(n + " :=") for n in ("STACK_SAMPLES", "STACK_TOR_DOMAINS",
                                               "STACK_LOOKS_FLAGS")}
    assert pos["STACK_SAMPLES"] < pos["STACK_TOR_DOMAINS"] < pos["STACK_LOOKS_FLAGS"]
    assert "$(foreach s,$(STACK_SAMPLES),$(s)=default)" in make
    # only a stack-up goal writes anything at parse time
    assert re.search(r"^STACK_SAMPLES := \$\(if \$\(filter stack-up,\$\(MAKECMDGOALS\)\),", make, re.M)


@pytest.fixture
def lane(tmp_path):
    """A throwaway generator tree the Makefile can be parsed in: the real Makefile, the
    real studio package (a symlink: abspath, not realpath, decides where the seed writes),
    and an empty tests/stack. Nothing under the real checkout is written."""
    (tmp_path / "tests" / "stack").mkdir(parents=True)
    shutil.copy(MAKEFILE, tmp_path / "Makefile")
    os.symlink(os.path.join(REPO, "studio"), tmp_path / "studio")
    return tmp_path


def _dry(lane, *args):
    r = subprocess.run(["make", "-n", "stack-up", *args], cwd=lane, capture_output=True,
                       text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    return r.stdout + r.stderr


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_stack_up_with_tor_gives_each_sample_its_own_onion_and_mounts_the_looks(lane):
    out = _dry(lane, "TOR=1")
    assert "TOR_ONION_DOMAINS='acme=default example=default'" in out
    assert "compose.tor-domains.yaml" in out
    assert "compose.looks.yaml" in out
    assert (lane / "tests" / "stack" / ".looks" / "by-host" / "acme.localhost").is_dir()


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_stack_up_without_tor_mounts_the_looks_and_names_no_onion(lane):
    out = _dry(lane)
    assert "compose.looks.yaml" in out
    assert "TOR_ONION_DOMAINS" not in out and "compose.tor-domains.yaml" not in out


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_a_caller_supplied_onion_list_is_kept_not_extended(lane):
    out = _dry(lane, "TOR=1", "TOR_ONION_DOMAINS=shop=shop")
    assert "TOR_ONION_DOMAINS='shop=shop'" in out
    assert "acme=default" not in out


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_turning_the_samples_off_leaves_a_plain_stack(lane):
    out = _dry(lane, "STACK_SAMPLE_DOMAINS=0")
    assert "compose.looks.yaml" not in out
    assert not (lane / "tests" / "stack" / ".looks").exists()


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_recorded_domains_in_the_folder_win_over_the_samples(lane):
    look_serving.write(str(lane), {}, [real_brand()])
    out = _dry(lane, "TOR=1")
    assert "acme=default" not in out
    assert sorted(os.listdir(lane / "tests" / "stack" / ".looks" / "by-host")) == ["shop.example"]


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_any_other_goal_writes_nothing(lane):
    subprocess.run(["make", "-n", "stack-ps"], cwd=lane, capture_output=True, text=True)
    assert not (lane / "tests" / "stack" / ".looks").exists()


# ── the certificate ──────────────────────────────────────────────────────────────────
def _mint(script, out, **env):
    e = dict(os.environ, SNAP_DOMAIN="hugmesh.net", **env)
    r = subprocess.run(["bash", script, str(out)], capture_output=True, text=True, env=e)
    return r


def _verify(out, host):
    r = subprocess.run(["openssl", "verify", "-CAfile", str(out / "ca.crt"),
                        "-verify_hostname", host, str(out / "server.crt")],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip().endswith("OK")


@pytest.mark.skipif(not HAVE_OPENSSL, reason="openssl is not installed")
def test_a_fresh_certificate_covers_the_sample_hosts_and_only_those(tmp_path):
    out = tmp_path / "tls"
    assert _mint(GEN_CERTS, out).returncode == 0
    for host in ("acme.localhost", "example.localhost", "localhost", "hugmesh.net"):
        assert _verify(out, host), host
    assert not _verify(out, "other.localhost"), "a name nobody asked for must not validate"
    assert not _verify(out, "evil.example")


@pytest.mark.skipif(not HAVE_OPENSSL, reason="openssl is not installed")
def test_an_old_leaf_is_reissued_under_the_same_ca_and_secret(tmp_path):
    """A leaf minted before the samples existed lacks their names. LEAF_ONLY re-issues it
    WITHOUT touching the CA (what a browser was told to trust) or values.json."""
    old = subprocess.run(["git", "show", "HEAD:tests/stack/gen-certs.sh"], cwd=REPO,
                         capture_output=True, text=True)
    if old.returncode != 0 or "SNAP_EXTRA_SANS" in old.stdout:
        # HEAD already has the feature (or git history is unavailable): build the old shape
        old_text = open(GEN_CERTS, encoding="utf-8").read().replace(
            "SNAP_EXTRA_SANS-acme.localhost,example.localhost", "SNAP_EXTRA_SANS-")
    else:
        old_text = old.stdout
    script = tmp_path / "old-gen.sh"
    script.write_text(old_text)
    out = tmp_path / "tls"
    assert _mint(str(script), out).returncode == 0
    assert not _verify(out, "acme.localhost")
    ca, secret = (out / "ca.crt").read_bytes(), (out / "values.json").read_text()
    r = _mint(GEN_CERTS, out, LEAF_ONLY="1")
    assert r.returncode == 0, r.stderr
    assert (out / "ca.crt").read_bytes() == ca, "the CA must not change"
    assert (out / "values.json").read_text() == secret, "the session secret must not rotate"
    assert _verify(out, "acme.localhost") and _verify(out, "example.localhost")


@pytest.mark.skipif(not HAVE_OPENSSL, reason="openssl is not installed")
@pytest.mark.parametrize("name", ["evil.example", "a/b.localhost", ".localhost", "x..localhost"])
def test_a_name_the_ca_would_not_vouch_for_is_refused(tmp_path, name):
    r = _mint(GEN_CERTS, tmp_path / "tls", SNAP_EXTRA_SANS=name)
    assert r.returncode != 0
    assert "SNAP_EXTRA_SANS" in r.stderr


@pytest.mark.skipif(not HAVE_OPENSSL, reason="openssl is not installed")
def test_leaf_only_without_a_ca_is_refused(tmp_path):
    r = _mint(GEN_CERTS, tmp_path / "empty", LEAF_ONLY="1")
    assert r.returncode != 0 and "LEAF_ONLY" in r.stderr


# ── the door ─────────────────────────────────────────────────────────────────────────
def test_the_door_serves_the_domain_list_from_the_mount_and_never_proxies_it():
    conf = open(os.path.join(REPO, "tests", "stack", "tls-front", "default.conf"),
                encoding="utf-8").read()
    live = "\n".join(line for line in conf.splitlines() if not line.lstrip().startswith("#"))
    m = re.search(r"location = /hug-domains\.json \{(.*?)\n    \}", live, re.S)
    assert m, "the door has no /hug-domains.json location"
    body = m.group(1)
    assert "root /etc/hugmesh-looks;" in body
    assert "try_files /domains.json =404;" in body
    assert "proxy_pass" not in body
    assert 'add_header Cache-Control "no-store" always;' in body
    assert look_serving.DOMAINS_JSON == "domains.json"
