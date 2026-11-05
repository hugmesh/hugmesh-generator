"""Host-path honesty: every path-valued flag must actually REACH the builder (findings 2/7).

THE BUG, in one line: under the docker backend the container sees only /src (the generator
repo) and /out. A config field holding a host path outside those was emitted VERBATIM, so
the builder received a path that cannot exist in-container.

That did not fail loudly, because every path consumer in the builder guards itself and
SKIPS when the guard fails:

  * `[ -n "${SECUREBOOT_KEY}" ] && [ -f "${SECUREBOOT_KEY}" ]` — else-path GENERATES a
    throwaway org key and signs the UKI with it. The key is in no firmware db, so the
    delivered image does not boot under Secure Boot on the target; the build exits 0 and
    says nothing. This fired for a PERFECTLY CORRECT host path, on the DEFAULT backend,
    100% of the time — not merely for a typo.
  * `[ -n "${DISTDIR_SRC}" ] && [ -d "${DISTDIR_SRC}" ]` — else-path falls back to scanning
    /media/*, so a build meant to reuse a local cache silently re-downloaded everything.

Two hand-maintained lists had drifted apart with NO test pinning either: the docker mount
list (build_driver.DOCKER_ASSET_FIELDS, then an inline tuple) and preflight's existence
check. The SAME four fields were missing from both — which is precisely why the failure was
silent at every layer. These tests pin both lists to the real path-valued flag surface.

The fix is three layers, and each is relied on:
  1. preflight        — a host path that does not exist BLOCKS before dispatch;
  2. the docker mount — a host path that DOES exist is bind-mounted :ro and the flag
                        rewritten, so the feature genuinely works under docker;
  3. the builder      — `--secureboot-key: file not found` fails fast at second 0, covering
                        the native / make / build-menu.sh / hand-run channels python cannot
                        reach.
Layer 2 without 3 leaves the silent path open off-studio; layer 3 without 2 would turn a
silent wrong image into a hard failure for every docker user. Both directions are tested.
"""
from __future__ import annotations

import os
import re

from hugmesh_studio.core.build_driver import (
    DOCKER_ASSET_FIELDS, DOCKER_EXTRA_ASSET_FIELDS, _PATH_ADVISORY, _PATH_MUST_EXIST,
    BuildDriver,
)
from hugmesh_studio.core.config import PLATFORM_FIELD_SUPPORT, ImageConfig
from hugmesh_studio.core.platform_info import HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# Path-valued fields the x86 builder reads from the HOST filesystem. Hand-listed because
# "is this value a path" is not derivable from the dataclass (they are all `str`), and the
# completeness test below pins this list against the builder's own `--flag PATH|DIR|FILE`
# help text so a new path flag cannot be added without landing here.
_HOST_PATH_FIELDS = {
    "wallpaper", "grub_background", "login_background", "brand_logo", "color_scheme",
    "branding_dir", "egress_vpn", "secureboot_key", "secureboot_cert", "keys_usb", "distdir",
}
# 2026-11-04: the brand profile (`--config`, sourced by every builder) and the x86
# home/seed inputs + GRUB theme dir were path flags missing from the mount list. They are
# mounted, but kept out of _PATH_MUST_EXIST (checked only when emitted).
_EXTRA_HOST_PATH_FIELDS = {
    "brand_profile", "grub_theme", "home_seed_code_from", "include_home_archive",
    "seed_packages_from",
}
_DIR_FIELDS = {"distdir", "keys_usb", "branding_dir", "grub_theme", "home_seed_code_from"}


def _driver(backend: str = "docker") -> BuildDriver:
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")
    return BuildDriver(GENERATOR_DIR, host)


def _inner(cmd: list[str]) -> str:
    """The builder argv, which docker-run carries as ONE `bash -c <string>` element.

    Relied on: a naive `assert host_path not in cmd` over the docker argv LIST can never
    fail — the flag value is inside that joined string, never a standalone element — so it
    would pass whether or not the path was remapped. Assert against this instead."""
    assert cmd[-2] == "-c", "docker command shape changed; this helper is now lying"
    return cmd[-1]


def _docker_cfg(tmp_path, **kw) -> ImageConfig:
    cfg = ImageConfig(platform="x86", role="backend", mode="mesh", env="test")
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


# ── the mount list ──────────────────────────────────────────────────────────────────────
def test_every_host_path_field_is_mounted_under_docker(tmp_path):
    """THE REGRESSION. Each host-path field, given a real path OUTSIDE the generator dir,
    must be bind-mounted and its flag rewritten to the in-container path. Before the fix
    secureboot_key/_cert/keys_usb/distdir were emitted as raw host paths and silently
    ignored in-container."""
    for field in sorted(_HOST_PATH_FIELDS | _EXTRA_HOST_PATH_FIELDS):
        if field in _DIR_FIELDS:
            p = tmp_path / f"{field}_dir"
            p.mkdir()
        else:
            p = tmp_path / f"{field}.bin"
            p.write_text("x")
        cfg = _docker_cfg(tmp_path, **{field: str(p)})
        cmd = _driver().command(cfg, backend="docker")
        assert any(a.startswith(f"{p}:/assets/") and a.endswith(":ro") for a in cmd), \
            f"{field}: host path not bind-mounted -> unreachable in-container, silently ignored"
        assert str(p) not in _inner(cmd), \
            f"{field}: raw HOST path still emitted as the flag value; must be the /assets path"
        assert "/assets/" in _inner(cmd), f"{field}: flag value not rewritten to the mount"


def test_mount_list_covers_every_host_path_field():
    """Completeness, so a NEW path field cannot silently rejoin the ignore club."""
    assert set(DOCKER_ASSET_FIELDS) == _HOST_PATH_FIELDS
    assert set(DOCKER_EXTRA_ASSET_FIELDS) == _EXTRA_HOST_PATH_FIELDS
    assert not set(DOCKER_ASSET_FIELDS) & set(DOCKER_EXTRA_ASSET_FIELDS)


def test_mount_list_has_no_duplicates_and_indices_are_stable():
    """Each field's index names its /assets/<i>/ dir; a duplicate would collide two mounts
    onto one path. Also pins the ORDER of the historical entries: appending is safe,
    reordering silently changes every existing mount path."""
    assert len(DOCKER_ASSET_FIELDS) == len(set(DOCKER_ASSET_FIELDS))
    assert DOCKER_ASSET_FIELDS[:7] == ("wallpaper", "grub_background", "login_background",
                                       "brand_logo", "color_scheme", "branding_dir",
                                       "egress_vpn")


def test_paths_already_under_the_generator_dir_are_translated_to_src_not_mounted(tmp_path):
    """/src is already mounted, so a path under the checkout needs no new mount (one
    could shadow the repo) — but its FLAG still has to name the IN-CONTAINER path.

    This test used to pin the opposite ("emitted verbatim, reachable via /src"), and that
    was the bug: the container sees the repo at /src, not at the host's absolute path, so
    the verbatim value names a file that does not exist in-container."""
    # NB: a branding field would be the obvious probe but is desktop-class, so it never
    # reaches argv on this mesh/be config at all. secureboot_key does.
    inside = os.path.join(GENERATOR_DIR, "keys-template", "kernel_key.pem")
    cfg = _docker_cfg(tmp_path, secureboot_key=inside)
    cmd = _driver().command(cfg, backend="docker")
    assert inside not in _inner(cmd), "the HOST path does not exist in-container"
    assert "--secureboot-key /src/keys-template/kernel_key.pem" in _inner(cmd)
    assert not any(a.startswith(f"{inside}:") for a in cmd)


# ── the brand profile (operator session 20261031-104549, backend docker) ────────────────
_EXAMPLE_CONF = os.path.join(GENERATOR_DIR, "brands", "example.conf")


def test_brands_example_conf_exists_in_the_checkout():
    """The file the failed session named is a real, committed profile — so the failure
    was the path translation, not a missing file."""
    assert os.path.isfile(_EXAMPLE_CONF)


def test_brand_profile_under_the_checkout_reaches_the_container_as_src_path():
    """THE REGRESSION. The session's worklist carried the HOST absolute path of
    brands/example.conf for three rpi5 images; every one died in the builder with
    `config file not found: <host path>` while the native backend read the same file."""
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = _EXAMPLE_CONF
    inner = _inner(_driver().command(cfg, backend="docker"))
    assert _EXAMPLE_CONF not in inner, "host path handed to the container"
    assert "--config /src/brands/example.conf" in inner


def test_relative_brand_profile_resolves_against_the_checkout(tmp_path, monkeypatch):
    """A typed `brands/example.conf` means the checkout's file (native builds run with
    cwd = the checkout), whatever the Studio process's own cwd is. In the container the
    builder's cwd is /src, so the relative spelling is kept as typed."""
    monkeypatch.chdir(tmp_path)
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = "brands/example.conf"
    d = _driver()
    cmd = d.command(cfg, backend="docker")
    assert "--config brands/example.conf" in _inner(cmd)
    assert not any(":/assets/" in a for a in cmd), "a checkout file needs no mount"
    assert not [p for p in d.preflight(cfg, backend="docker") if "brand-profile" in p]


def test_brand_profile_outside_the_checkout_is_mounted_read_only(tmp_path):
    prof = tmp_path / "acme.conf"
    prof.write_text('BRAND="acme"\n')
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = str(prof)
    cmd = _driver().command(cfg, backend="docker")
    mounts = [a for a in cmd if a.startswith(f"{prof}:")]
    assert len(mounts) == 1 and mounts[0].endswith("/acme.conf:ro"), mounts
    cpath = mounts[0][len(f"{prof}:"):-len(":ro")]
    assert f"--config {cpath}" in _inner(cmd)
    assert str(prof) not in _inner(cmd)


def test_missing_brand_profile_blocks_before_dispatch(tmp_path):
    """Every builder hard-errors on a --config it cannot find; say so at second 0."""
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = str(tmp_path / "nope.conf")
    problems = _driver().preflight(cfg, backend="docker")
    assert any("brand-profile" in p and "does not exist" in p for p in problems)


def test_native_backend_never_remaps(tmp_path):
    """The remap is docker-only: a native build reads the host path directly, so rewriting
    it to /assets/N would BREAK a working flag."""
    p = tmp_path / "k.pem"
    p.write_text("x")
    cfg = _docker_cfg(tmp_path, secureboot_key=str(p))
    cmd = _driver("native").command(cfg, backend="native")
    assert str(p) in cmd
    assert not any("/assets/" in a for a in cmd)


# ── preflight (BLOCK) ───────────────────────────────────────────────────────────────────
def test_missing_secureboot_key_blocks_before_dispatch(tmp_path):
    """Finding 2: a signing key that does not exist must STOP the build, not sign the UKI
    with a throwaway key and exit 0."""
    cfg = _docker_cfg(tmp_path, secureboot_key=str(tmp_path / "nope.pem"))
    problems = _driver().preflight(cfg, backend="docker")
    assert any("secureboot-key" in p and "does not exist" in p for p in problems)


def test_missing_secureboot_cert_and_keys_usb_block(tmp_path):
    for field, label in (("secureboot_cert", "secureboot-cert"), ("keys_usb", "keys-usb")):
        cfg = _docker_cfg(tmp_path, **{field: str(tmp_path / "nope")})
        problems = _driver().preflight(cfg, backend="docker")
        assert any(label in p and "does not exist" in p for p in problems), field


def test_existing_paths_do_not_block(tmp_path):
    p = tmp_path / "k.pem"
    p.write_text("x")
    cfg = _docker_cfg(tmp_path, secureboot_key=str(p))
    assert not [x for x in _driver().preflight(cfg, backend="docker") if "secureboot" in x]


def test_preflight_must_exist_list_is_derived_and_excludes_advisory():
    """The two lists are siblings; deriving one from the other is what stops them drifting
    apart again. keyzip is host-side only (never a builder flag, so never mounted)."""
    assert set(_PATH_MUST_EXIST) == (_HOST_PATH_FIELDS - set(_PATH_ADVISORY)) | {"keyzip"}
    assert "keyzip" not in DOCKER_ASSET_FIELDS


def test_stale_x86_only_path_does_not_block_an_arm_build(tmp_path):
    """FALSE-BLOCK GUARD. secureboot_key is x86-only, so an rpi5 build never emits it. A
    stale value riding an ARM config must NOT block a build over a flag that platform
    cannot receive."""
    assert "rpi5" not in PLATFORM_FIELD_SUPPORT["secureboot_key"]
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.secureboot_key = str(tmp_path / "nope.pem")
    assert not [p for p in _driver().preflight(cfg, backend="docker") if "secureboot" in p]


# ── distdir: WARN, never BLOCK ──────────────────────────────────────────────────────────
def test_missing_distdir_warns_and_does_not_block(tmp_path):
    """Finding 7, and the deliberate asymmetry with finding 2: an ignored distfiles cache
    yields a CORRECT artifact that merely took longer, so it must warn rather than block —
    blocking would break the "cache drive is sometimes attached" workflow to prevent
    nothing. Silence was still wrong: the flag is documented as FORCING a cache."""
    cfg = _docker_cfg(tmp_path, distdir=str(tmp_path / "nope"))
    d = _driver()
    assert not [p for p in d.preflight(cfg, backend="docker") if "distdir" in p]
    assert any("distdir" in w and "IGNORED" in w for w in d._config_warnings(cfg))


def test_existing_distdir_is_silent(tmp_path):
    p = tmp_path / "dist"
    p.mkdir()
    cfg = _docker_cfg(tmp_path, distdir=str(p))
    assert not [w for w in _driver()._config_warnings(cfg) if "distdir" in w]


def test_config_warnings_reach_preflight_warnings(tmp_path):
    """The per-config channel must be wired into the advisory surface the GUI reads —
    a warning nobody surfaces is the same silence we are fixing."""
    cfg = _docker_cfg(tmp_path, distdir=str(tmp_path / "nope"))
    assert any("distdir" in w for w in _driver().preflight_warnings(cfg, backend="docker"))


# ── the builder half (layer 3: covers the channels python cannot reach) ─────────────────
def _x86_builder_text() -> str:
    with open(os.path.join(GENERATOR_DIR, "build-x86-host-stage4.sh"), encoding="utf-8") as fh:
        return fh.read()


def _uncommented(text: str) -> str:
    """Strip comments before matching. The builder's own comments QUOTE the guard
    expressions verbatim, so an unstripped search matches prose and passes vacuously —
    the exact hole found in #380's log guard."""
    return "\n".join(re.sub(r"(^|\s)#.*$", "", ln) for ln in text.splitlines())


def test_builder_fails_fast_on_a_missing_secureboot_key():
    """The preflight must exist in the BUILDER too: studio is only one of several channels
    (make, scripts/build-menu.sh, a hand-run command) and the others never touch python."""
    body = _uncommented(_x86_builder_text())
    assert re.search(r'\[ -n "\$\{SECUREBOOT_KEY\}" \] && \[ ! -f "\$\{SECUREBOOT_KEY\}" \]', body), \
        "build-x86 lost its --secureboot-key preflight: a bad key silently signs with a throwaway"
    assert re.search(r'--secureboot-cert needs --secureboot-key', body), \
        "build-x86 lost the cert-without-key check: a lone cert is never used"


def test_cert_without_key_check_fires_only_for_an_EXPLICIT_cert():
    """FALSE-BLOCK GUARD for the cert-without-key preflight.

    --keys-usb auto-discovery writes SECUREBOOT_KEY and SECUREBOOT_CERT from two
    INDEPENDENT -f probes (Keys/kernel_key.pem, Keys/kernel_key.der). A KEYS USB holding
    only the public .der — private key withheld / on an HSM, a normal shape — therefore
    sets CERT and leaves KEY empty. If the cert-without-key check reads the bare
    ${SECUREBOOT_CERT}, that build hard-exits with "--secureboot-cert needs
    --secureboot-key (or --keys-usb DIR)": naming a flag the operator never passed, and
    prescribing the flag they DID pass. With no key at all, :378's documented default (a
    generated throwaway key) is the builder's intended behaviour, so erroring invents a
    constraint. The check must key off what the operator EXPLICITLY passed.
    """
    body = _uncommented(_x86_builder_text())
    m = re.search(r'if \[ -n "\$\{(SECUREBOOT_CERT[A-Z_]*)\}" \] && \[ -z "\$\{SECUREBOOT_KEY\}" \]; then\n'
                  r'\s*err "--secureboot-cert needs --secureboot-key', body)
    assert m, "the cert-without-key check is gone or reshaped — re-verify this guard"
    assert m.group(1) == "SECUREBOOT_CERT_EXPLICIT", (
        "the cert-without-key check reads the POST-discovery ${SECUREBOOT_CERT}, so a "
        "--keys-usb DIR carrying only kernel_key.der hard-errors a build that never asked "
        "to sign. It must read the pre-discovery explicit capture.")


def test_explicit_secureboot_cert_is_captured_before_keys_usb_discovery():
    """Ordering pin for the guard above: the capture is only 'what the operator passed' if
    it happens BEFORE --keys-usb writes to the same variable. Captured after, it is just an
    alias for the discovered value and the false-block returns silently."""
    body = _uncommented(_x86_builder_text())
    capture = body.index('SECUREBOOT_CERT_EXPLICIT="${SECUREBOOT_CERT}"')
    discovery = body.index('SECUREBOOT_CERT="${KEYS_USB}/Keys/kernel_key.der"')
    assert capture < discovery, (
        "SECUREBOOT_CERT_EXPLICIT is captured AFTER --keys-usb auto-discovery, so it also "
        "holds discovered certs and the cert-without-key check false-blocks again.")


def test_keys_usb_der_without_pem_warns_instead_of_failing():
    """The der-only KEYS USB is not an error, but it is not nothing either: the image gets
    a throwaway key and will NOT boot on a host enrolled to that cert. Silence is what let
    finding 2 ship, so the fallback must say so."""
    body = _uncommented(_x86_builder_text())
    m = re.search(r'if \[ -n "\$\{SECUREBOOT_CERT\}" \] && \[ -z "\$\{SECUREBOOT_KEY\}" \]; then\n'
                  r'((?:\s*warn .*\n)+)', body)
    assert m, "the der-only KEYS USB case no longer warns — an ignored cert went silent again"
    assert "NOT boot under Secure Boot" in m.group(1)


def test_builder_secureboot_preflight_runs_before_print_plan():
    """A preflight after the --print-plan exit would never run for a validation-only pass,
    and — far worse — a preflight placed after the build starts costs the operator the very
    hours this fix exists to save. Pin the ordering.

    Comment-stripped like its sibling: on raw text a fully commented-out block would still
    satisfy both index() calls and this would pass while pinning nothing."""
    body = _uncommented(_x86_builder_text())
    assert body.index("--secureboot-key: file not found") < body.index("if ${PRINT_PLAN}; then")


def test_builder_distdir_warns_rather_than_erring():
    """Mirrors the studio-side tier decision, in the builder."""
    body = _uncommented(_x86_builder_text())
    m = re.search(r'\[ -n "\$\{DISTDIR_SRC\}" \] && \[ ! -d "\$\{DISTDIR_SRC\}" \]', body)
    assert m, "build-x86 lost its --distdir advisory"
    tail = body[m.end():m.end() + 400]
    assert "warn " in tail and "exit 1" not in tail.split("fi")[0]


# ── refutation round (PR #851): only an EMITTED flag is checked or mounted ─────────────
def _fake_checkout(tmp_path):
    """A generator dir of our own, so symlinks and siblings can be laid next to it."""
    gen = tmp_path / "hugmesh-generator"
    (gen / "brands").mkdir(parents=True)
    return gen


def _gen_driver(gen) -> BuildDriver:
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")
    return BuildDriver(str(gen), host)


def _unaffiliated(**kw) -> ImageConfig:
    cfg = ImageConfig(platform="x86", role="standalone-unaffiliated", mode="standalone",
                      env="test")
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


def test_stale_brand_profile_on_an_unaffiliated_image_never_blocks(tmp_path):
    """FALSE-BLOCK GUARD. The unaffiliated role bakes zero brand, so _x86_args never emits
    --config. A stale profile riding a loaded/saved/restarted config (worklist.materialize
    deep-copies it as-is) must not block, on either backend, a build that never reads it."""
    cfg = _unaffiliated(brand_profile=str(tmp_path / "old-brand.conf"))
    assert "--config" not in cfg.to_cli_args()
    for backend in ("docker", "native"):
        assert not [p for p in _driver().preflight(cfg, backend=backend)
                    if "brand-profile" in p], backend


def test_stale_brand_profile_on_an_unaffiliated_image_is_not_mounted(tmp_path):
    """Missing OR present: a flag that is not emitted gets no mount either way."""
    stale = tmp_path / "old-brand.conf"
    for present in (False, True):
        if present:
            stale.write_text('BRAND="old"\n')
        cfg = _unaffiliated(brand_profile=str(stale))
        cmd = _driver().command(cfg, backend="docker")
        assert not any(a.startswith(f"{stale}:") for a in cmd), present


def test_present_x86_only_paths_on_an_arm_config_are_not_mounted(tmp_path):
    """The flag is not emitted for rpi5, so even an EXISTING path gets no mount: the
    container must not be handed host files its builder will never be told about."""
    theme = tmp_path / "theme"
    theme.mkdir()
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.grub_theme = str(theme)
    cmd = _driver().command(cfg, backend="docker")
    assert not any(a.startswith(f"{theme}:") for a in cmd)


def test_stale_x86_only_paths_on_an_arm_config_are_not_mounted(tmp_path):
    """rpi5 never receives --grub-theme / --home-seed-code-from / --secureboot-key; a stale
    value must not become a `-v` of a missing path (docker creates the source as an empty
    ROOT-owned directory on the host)."""
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.grub_theme = str(tmp_path / "gone-theme")
    cfg.home_seed_code_from = str(tmp_path / "gone-src")
    cfg.secureboot_key = str(tmp_path / "gone.pem")
    cmd = _driver().command(cfg, backend="docker")
    assert not any(str(tmp_path) in a for a in cmd[:-1]), \
        [a for a in cmd if str(tmp_path) in a]
    assert not [p for p in _driver().preflight(cfg, backend="docker")
                if str(tmp_path) in p]


def test_an_emitted_but_missing_outside_path_is_never_bind_mounted(tmp_path):
    """distdir only WARNS when missing, so the build proceeds: a `-v` of the missing path
    would make docker create it on the host as root. Leave it unmounted; the builder's own
    [ -d ] guard then reports it as ignored."""
    gone = tmp_path / "no-distfiles"
    cfg = _docker_cfg(tmp_path, distdir=str(gone))
    cmd = _driver().command(cfg, backend="docker")
    assert not any(a.startswith(f"{gone}:") for a in cmd)


def test_an_emitted_missing_extra_path_still_blocks(tmp_path):
    """The gate removes FALSE blocks only: an emitted --grub-theme that is missing would
    hard-fail the x86 builder hours in, so preflight still says so at second 0."""
    cfg = _docker_cfg(tmp_path, grub_theme=str(tmp_path / "nope-theme"))
    assert "--grub-theme" in cfg.to_cli_args()
    problems = _driver().preflight(cfg, backend="docker")
    assert any("grub-theme" in p and "does not exist" in p for p in problems)


def test_a_symlink_in_the_checkout_to_outside_is_mounted_not_src_rewritten(tmp_path):
    """brands/link.conf -> /elsewhere/acme.conf is under the checkout by SPELLING only: in
    the container /src/brands/link.conf dangles. Its target must be mounted read-only."""
    gen = _fake_checkout(tmp_path)
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    target = outside / "acme.conf"
    target.write_text('BRAND="acme"\n')
    link = gen / "brands" / "link.conf"
    os.symlink(target, link)
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = str(link)
    cmd = _gen_driver(gen).command(cfg, backend="docker")
    assert "/src/brands/link.conf" not in _inner(cmd)
    mounts = [a for a in cmd if a.startswith(f"{target}:")]
    assert len(mounts) == 1 and mounts[0].endswith(":ro"), cmd
    cpath = mounts[0][len(f"{target}:"):-len(":ro")]
    assert f"--config {cpath}" in _inner(cmd)


def test_a_symlink_in_the_checkout_to_inside_maps_to_its_real_src_path(tmp_path):
    gen = _fake_checkout(tmp_path)
    real = gen / "brands" / "real.conf"
    real.write_text('BRAND="x"\n')
    link = gen / "brands" / "alias.conf"
    os.symlink(real, link)
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = str(link)
    cmd = _gen_driver(gen).command(cfg, backend="docker")
    assert "--config /src/brands/real.conf" in _inner(cmd)
    assert not any(a.startswith(f"{real}:") for a in cmd)


def test_a_sibling_directory_is_not_inside_the_checkout(tmp_path):
    """hugmesh-generator-sibling/ shares the checkout's name as a PREFIX. A separator-less
    startswith would call it inside and emit /src/../hugmesh-generator-sibling/x.conf."""
    gen = _fake_checkout(tmp_path)
    sib = tmp_path / "hugmesh-generator-sibling"
    sib.mkdir()
    prof = sib / "x.conf"
    prof.write_text('BRAND="x"\n')
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = str(prof)
    cmd = _gen_driver(gen).command(cfg, backend="docker")
    assert "/src/" not in _inner(cmd).split("--config", 1)[1].split()[0]
    assert ".." not in _inner(cmd)
    assert any(a.startswith(f"{prof}:/assets/") and a.endswith(":ro") for a in cmd)


# ── the fleet lane: FleetDriver forwards --config to every builder in the container ────
def test_fleet_docker_brand_profile_under_the_checkout_is_a_src_path(tmp_path):
    from hugmesh_studio.core.fleet import FleetConfig, FleetDriver
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")
    cfg = FleetConfig(brand_profile=_EXAMPLE_CONF, output_dir=str(tmp_path / "out"))
    inner = _inner(FleetDriver(GENERATOR_DIR, host).command(cfg, "docker"))
    assert _EXAMPLE_CONF not in inner
    assert "--config /src/brands/example.conf" in inner


def test_fleet_docker_brand_profile_outside_the_checkout_is_mounted(tmp_path):
    from hugmesh_studio.core.fleet import FleetConfig, FleetDriver
    prof = tmp_path / "acme.conf"
    prof.write_text('BRAND="acme"\n')
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")
    cfg = FleetConfig(brand_profile=str(prof), output_dir=str(tmp_path / "out"))
    cmd = FleetDriver(GENERATOR_DIR, host).command(cfg, "docker")
    mounts = [a for a in cmd if a.startswith(f"{prof}:")]
    assert len(mounts) == 1 and mounts[0].endswith(":ro"), cmd
    assert str(prof) not in _inner(cmd)


def test_fleet_native_brand_profile_is_untouched(tmp_path):
    from hugmesh_studio.core.fleet import FleetConfig, FleetDriver
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")
    cfg = FleetConfig(brand_profile=_EXAMPLE_CONF, output_dir=str(tmp_path / "out"))
    cmd = FleetDriver(GENERATOR_DIR, host).command(cfg, "native")
    assert _EXAMPLE_CONF in cmd


def test_a_relative_symlink_spelling_is_resolved_to_its_real_src_path(tmp_path, monkeypatch):
    """A relative value that goes through a link whose target is an ABSOLUTE host path
    inside the checkout would dangle in the container if kept as typed; it is resolved."""
    gen = _fake_checkout(tmp_path)
    real = gen / "brands" / "real.conf"
    real.write_text('BRAND="x"\n')
    os.symlink(str(real), gen / "brands" / "abs-alias.conf")   # absolute target
    monkeypatch.chdir(tmp_path)
    cfg = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    cfg.brand_profile = "brands/abs-alias.conf"
    assert "--config /src/brands/real.conf" in _inner(_gen_driver(gen).command(cfg, "docker"))


def test_the_fallback_emission_rule_when_argv_cannot_be_built():
    """When to_cli_args() refuses a config, preflight still has to decide; the fallback is
    the platform table plus the unaffiliated rule the table cannot express."""
    from hugmesh_studio.core.build_driver import _path_emitted
    assert _path_emitted("brand_profile", _unaffiliated(brand_profile="/x.conf"), None) is False
    arm = ImageConfig(platform="rpi5", role="backend", mode="mesh", env="test")
    assert _path_emitted("grub_theme", arm, None) is False
    assert _path_emitted("brand_profile", arm, None) is True
    assert _path_emitted("keyzip", arm, set()) is True
