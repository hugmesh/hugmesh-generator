"""`make stack-up BRAND=<name>` (core/brand_profile.py; the Makefile's STACK_BRAND block).

A brand's images were built from brands/<name>.{yaml,conf}, but the Docker stack that runs
them never read the profile, so a brand's mesh still called itself HugMesh on hugmesh.net.
These tests pin each link without starting a container: the strict reader (a profile is
read, never run), the title and domain rules, the look the stack is given, the command
line's one-line contract, and the Makefile wiring (DOMAIN from the profile, a refusal that
stops make, an explicit DOMAIN that wins, no BRAND meaning no change).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

import pytest

from hugmesh_studio.core import brand_profile
from hugmesh_studio.core.brand_profile import BrandProfileError, apply, available, load

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MAKEFILE = os.path.join(REPO, "Makefile")
HAVE_MAKE = shutil.which("make") is not None


def tree(tmp_path, **files) -> str:
    """A generator tree whose brands/ holds ``files`` (name -> text)."""
    (tmp_path / "brands").mkdir()
    for name, text in files.items():
        (tmp_path / "brands" / name).write_text(text, encoding="utf-8")
    return str(tmp_path)


def theme(gen: str) -> str:
    return open(os.path.join(gen, "tests", "stack", ".theme.css"), encoding="utf-8").read()


# ── reading a .conf: never sourcing it ───────────────────────────────────────────────
def test_the_quoted_bare_and_commented_forms_all_read(tmp_path):
    gen = tree(tmp_path, **{
        "a.conf": 'BRAND="a"\nBRAND_TITLE="Acme Arcade"   # shown in UIs\nCLUSTER_DOMAIN="Acme.Test"\n',
        "b.conf": "BRAND_TITLE='Bee Co'\nCLUSTER_DOMAIN=bee.test\n",
    })
    a, b = load(gen, "a"), load(gen, "b")
    assert (a.title, a.domain, a.source) == ("Acme Arcade", "acme.test", "a.conf")   # lowercased
    assert (b.title, b.domain) == ("Bee Co", "bee.test")


def test_a_profile_with_no_domain_leaves_the_domain_empty(tmp_path):
    assert load(tree(tmp_path, **{"x.conf": 'BRAND_TITLE="X"\n'}), "x").domain == ""


def test_the_first_assignment_wins_and_unrelated_lines_are_ignored(tmp_path):
    gen = tree(tmp_path, **{"x.conf": 'ADMIN_EMAILS="a@b.c"\nBRAND_TITLE="First"\nBRAND_TITLE="Second"\n'
                                      'DEFAULT_USER_PASS="hunter2"\nexport FOO=$(id)\n'})
    assert load(gen, "x").title == "First"


def test_shell_in_a_title_is_text_and_never_runs(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)                    # a sourced `touch r` would create ./r here
    gen = tree(tmp_path, **{"x.conf": 'BRAND_TITLE="a $(touch r) `touch r` b"\n'})
    p = load(gen, "x")
    assert "$(touch r)" in p.title and "`touch r`" in p.title     # carried as text
    assert not (tmp_path / "r").exists()                           # and nothing was executed


def test_an_unquoted_value_with_shell_syntax_is_not_a_title_at_all(tmp_path):
    gen = tree(tmp_path, **{"x.conf": "BRAND_TITLE=$(whoami)\n"})
    with pytest.raises(BrandProfileError, match="no BRAND_TITLE"):
        load(gen, "x")


def test_a_conf_without_a_title_says_what_to_add(tmp_path):
    with pytest.raises(BrandProfileError, match=r"BRAND_TITLE=.* line"):
        load(tree(tmp_path, **{"x.conf": 'CLUSTER_DOMAIN="x.test"\n'}), "x")


# ── the title and domain rules ───────────────────────────────────────────────────────
def test_a_title_is_one_short_line(tmp_path):
    gen = tree(tmp_path, **{"long.conf": 'BRAND_TITLE="%s"\n' % ("x" * 61),
                            "blank.conf": 'BRAND_TITLE="   "\n',
                            "spaced.conf": 'BRAND_TITLE="  Acme    Arcade "\n'})
    with pytest.raises(BrandProfileError, match="at most 60"):
        load(gen, "long")
    with pytest.raises(BrandProfileError, match="empty"):
        load(gen, "blank")
    assert load(gen, "spaced").title == "Acme Arcade"          # runs of blanks collapse


def test_a_control_character_in_a_yaml_title_is_refused(tmp_path):
    gen = tree(tmp_path, **{"x.yaml": 'title: "Bad\\aTitle"\n'})      # YAML escape for BEL
    with pytest.raises(BrandProfileError, match="control character"):
        load(gen, "x")


@pytest.mark.parametrize("bad", ["not a domain", "a..b", "-x.test", "x.test/../y", "nodots", "a_b.test"])
def test_a_domain_that_is_not_a_dns_name_is_refused(tmp_path, bad):
    gen = tree(tmp_path, **{"x.conf": f'BRAND_TITLE="X"\nCLUSTER_DOMAIN="{bad}"\n'})
    with pytest.raises(BrandProfileError, match="not a domain name"):
        load(gen, "x")


# ── a .yaml, and which file wins ─────────────────────────────────────────────────────
def test_a_yaml_gives_the_title_the_first_domain_and_the_login_colours(tmp_path):
    gen = tree(tmp_path, **{"x.yaml": 'title: Acme Arcade\ndomains:\n  - acme.games\n  - second.games\n'
                                      'login_theme:\n  primary: "#0b6e4f"\n  secondary: "#f2a900"\n  other: x\n'})
    p = load(gen, "x")
    assert (p.title, p.domain, p.source) == ("Acme Arcade", "acme.games", "x.yaml")
    assert p.look == {"primary": "#0b6e4f", "secondary": "#f2a900"}      # only the three fields


def test_a_yaml_without_a_title_is_refused(tmp_path):
    with pytest.raises(BrandProfileError, match="title:"):
        load(tree(tmp_path, **{"x.yaml": "domains: [a.test]\n"}), "x")


def test_an_unreadable_yaml_is_refused(tmp_path):
    with pytest.raises(BrandProfileError, match="not readable YAML"):
        load(tree(tmp_path, **{"x.yaml": "title: [unclosed\n"}), "x")


def test_a_yaml_wins_over_a_conf_of_the_same_name(tmp_path):
    gen = tree(tmp_path, **{"x.yaml": "title: From Yaml\n", "x.conf": 'BRAND_TITLE="From Conf"\n'})
    assert load(gen, "x").title == "From Yaml"


# ── the name ─────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("bad", ["", "../etc", "a/b", "Upper", "a b", "x;y", "-x", ".hidden"])
def test_a_name_that_is_not_a_slug_never_touches_the_disk(tmp_path, bad):
    with pytest.raises(BrandProfileError, match="not a brand name"):
        load(tree(tmp_path), bad)


def test_an_unknown_brand_lists_the_profiles_that_exist(tmp_path):
    gen = tree(tmp_path, **{"one.conf": 'BRAND_TITLE="One"\n', "two.yaml": "title: Two\n",
                            "domains.conf": "# a registry, not a brand\n"})
    with pytest.raises(BrandProfileError) as exc:
        load(gen, "nope")
    assert "one, two" in str(exc.value) and "domains" not in str(exc.value)
    assert available(gen) == ["one", "two"]


# ── what the stack is given ──────────────────────────────────────────────────────────
def test_apply_writes_the_title_as_the_header_text_and_the_brands_colours(tmp_path):
    gen = tree(tmp_path, **{"x.yaml": 'title: Acme Arcade\ndomains: [acme.games]\n'
                                      'login_theme: {primary: "#0b6e4f", secondary: "#f2a900"}\n'})
    p = apply(gen, "x")
    css = theme(gen)
    assert p.domain == "acme.games"
    assert "--sd-header-content: 'Acme Arcade';" in css and "--hug-header-content: 'Acme Arcade';" in css
    assert "--sd-primary: #0b6e4f;" in css
    assert os.stat(os.path.join(gen, "tests", "stack", ".theme.css")).st_mode & 0o777 == 0o644
    assert not os.path.exists(os.path.join(gen, "tests", "stack", ".theme.css.tmp"))


def test_a_hostile_title_reaches_the_css_only_through_the_string_escape(tmp_path):
    # a YAML title may hold quotes and backslashes (a .conf value may not); the look's own
    # CSS string escape is what keeps them inside the one string
    gen = tree(tmp_path, **{"x.yaml": "title: \"a' } body { display:none } /* \\\\ end\"\n"})
    apply(gen, "x")
    css = theme(gen)
    line = [l for l in css.splitlines() if "--sd-header-content" in l][0]
    assert line.strip().startswith("--sd-header-content: '") and line.strip().endswith("';")
    assert "\\'" in line                                          # the quote is escaped: the string stays one
    rest = "\n".join(l for l in css.splitlines() if "header-content" not in l)   # the --sd- and --hug- twins
    assert "} body {" not in rest and "display:none" not in rest   # and it escaped no declaration


def test_a_conf_value_cannot_hold_a_quote_or_a_backslash(tmp_path):
    gen = tree(tmp_path, **{"x.conf": 'BRAND_TITLE="has a \\ backslash"\n'})
    with pytest.raises(BrandProfileError, match="no BRAND_TITLE"):      # not matched, so not read
        load(gen, "x")


def test_a_look_that_is_refused_leaves_the_existing_file_alone(tmp_path):
    gen = tree(tmp_path, **{"x.yaml": 'title: X\nlogin_theme: {primary: "not-a-colour"}\n'})
    path = os.path.join(gen, "tests", "stack", ".theme.css")
    os.makedirs(os.path.dirname(path))
    open(path, "w").write("KEEP ME")
    with pytest.raises(BrandProfileError, match="primary"):
        apply(gen, "x")
    assert open(path).read() == "KEEP ME"


def test_a_title_only_profile_is_enough_to_name_the_mesh(tmp_path):
    gen = tree(tmp_path, **{"x.conf": 'BRAND_TITLE="Just A Name"\n'})
    apply(gen, "x")
    assert "'Just A Name'" in theme(gen)


# ── the profiles that ship must keep loading ─────────────────────────────────────────
@pytest.mark.parametrize("name,title,domain", [("acme", "Acme Arcade", "acme.games"),
                                               ("example", "Example Corp", "example.test"),
                                               ("local", "HugMesh Systems", "hugmesh.test")])
def test_the_committed_profiles_load(name, title, domain):
    p = load(REPO, name)
    assert (p.title, p.domain) == (title, domain)
    assert name in available(REPO) and "domains" not in available(REPO)


# ── the command line ─────────────────────────────────────────────────────────────────
def run_cli(gen: str, *args: str):
    return subprocess.run([sys.executable, "-m", "hugmesh_studio.core.brand_profile", *args,
                           "--generator-dir", gen],
                          cwd=os.path.join(REPO, "studio"), capture_output=True, text=True)


def test_apply_prints_one_domain_line_on_stdout_and_the_rest_on_stderr(tmp_path):
    gen = tree(tmp_path, **{"x.conf": 'BRAND_TITLE="X"\nCLUSTER_DOMAIN="x.test"\n'})
    r = run_cli(gen, "apply", "--brand", "x")
    assert r.returncode == 0 and r.stdout == "DOMAIN=x.test\n"
    assert "title 'X'" in r.stderr
    assert os.path.isfile(os.path.join(gen, "tests", "stack", ".theme.css"))


def test_a_profile_with_no_domain_prints_an_empty_value_not_nothing(tmp_path):
    gen = tree(tmp_path, **{"x.conf": 'BRAND_TITLE="X"\n'})
    r = run_cli(gen, "apply", "--brand", "x")
    assert r.stdout == "DOMAIN=\n" and "DOMAIN keeps its default" in r.stderr   # the Makefile tells this from a refusal


def test_show_reads_and_writes_nothing(tmp_path):
    gen = tree(tmp_path, **{"x.conf": 'BRAND_TITLE="X"\nCLUSTER_DOMAIN="x.test"\n'})
    r = run_cli(gen, "show", "--brand", "x")
    assert r.returncode == 0 and r.stdout == "DOMAIN=x.test\n"
    assert not os.path.exists(os.path.join(gen, "tests"))


def test_a_refusal_exits_one_with_nothing_on_stdout(tmp_path):
    r = run_cli(tree(tmp_path), "apply", "--brand", "nope")
    assert r.returncode == 1 and r.stdout == "" and "no brands/nope" in r.stderr


# ── the Makefile ─────────────────────────────────────────────────────────────────────
@pytest.fixture
def lane(tmp_path):
    """A throwaway tree the real Makefile is parsed in: the real Makefile, the real studio
    package and brands/ (symlinks), an empty tests/stack. Nothing real is written."""
    (tmp_path / "tests" / "stack").mkdir(parents=True)
    shutil.copy(MAKEFILE, tmp_path / "Makefile")
    os.symlink(os.path.join(REPO, "studio"), tmp_path / "studio")
    os.symlink(os.path.join(REPO, "brands"), tmp_path / "brands")
    return tmp_path


def dry(lane, goal, *args):
    r = subprocess.run(["make", "-n", goal, *args], cwd=lane, capture_output=True, text=True,
                       env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    return r.returncode, r.stdout + r.stderr


def issuer(out: str) -> str:
    return out.split("issuer=")[1].split(",")[0]


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_stack_up_takes_its_domain_and_its_look_from_the_brand(lane):
    rc, out = dry(lane, "stack-up", "BRAND=acme", "ENV=prod")
    assert rc == 0 and issuer(out) == "https://id.acme.games"          # DOMAIN came from the profile
    css = (lane / "tests" / "stack" / ".theme.css").read_text()
    assert "--sd-header-content: 'Acme Arcade';" in css                # the name the pages say


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_a_profile_with_login_colours_gives_them_to_the_stack(lane):
    os.unlink(lane / "brands")                                           # a private brands/ with one coloured profile
    (lane / "brands").mkdir()
    (lane / "brands" / "tint.yaml").write_text('title: Tint\ndomains: [tint.test]\n'
                                               'login_theme: {primary: "#0b6e4f", secondary: "#f2a900"}\n')
    rc, out = dry(lane, "stack-up", "BRAND=tint")
    assert rc == 0
    css = (lane / "tests" / "stack" / ".theme.css").read_text()
    assert "--sd-primary: #0b6e4f;" in css and "'Tint'" in css


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_a_domain_on_the_command_line_wins_over_the_profiles(lane):
    rc, out = dry(lane, "stack-up", "BRAND=acme", "DOMAIN=mine.example", "ENV=prod")
    assert rc == 0 and issuer(out) == "https://id.mine.example"
    assert "'Acme Arcade'" in (lane / "tests" / "stack" / ".theme.css").read_text()   # the title still applies


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_an_unusable_brand_stops_make_and_says_why(lane):
    rc, out = dry(lane, "stack-up", "BRAND=nope")
    assert rc != 0 and "BRAND=nope cannot be used for the stack" in out and "no brands/nope" in out
    assert not (lane / "tests" / "stack" / ".theme.css").exists()


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_other_stack_goals_read_the_profile_but_never_rewrite_the_look(lane):
    (lane / "tests" / "stack" / ".theme.css").write_text("SHIPPED BY THE STUDIO")
    rc, out = dry(lane, "stack-seed", "BRAND=acme", "ENV=prod")
    assert "DOMAIN=" not in out and rc == 0
    assert (lane / "tests" / "stack" / ".theme.css").read_text() == "SHIPPED BY THE STUDIO"
    # ... yet it saw the same DOMAIN a stack-up would have used (the prod issuer is built from it)
    rc2, out2 = dry(lane, "stack-up", "BRAND=acme", "ENV=prod")
    assert issuer(out2) == "https://id.acme.games"


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_no_brand_means_no_change(lane):
    rc, out = dry(lane, "stack-up", "ENV=prod")
    assert rc == 0 and "brand_profile" not in out
    assert issuer(out) == "https://id.hugmesh.net"
    assert not (lane / "tests" / "stack" / ".theme.css").exists()


@pytest.mark.skipif(not HAVE_MAKE, reason="make is not installed")
def test_a_builder_goal_with_a_brand_does_not_call_the_stack_reader(lane):
    # `make build-all BRAND=acme` is the builders' own use of BRAND: the stack block must not fire
    rc, out = dry(lane, "x86", "BRAND=acme")
    assert "brand_profile" not in out
    assert not (lane / "tests" / "stack" / ".theme.css").exists()
