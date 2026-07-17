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

The fix is three layers, and each is load-bearing:
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

from snapdragon_studio.core.build_driver import (
    DOCKER_ASSET_FIELDS, _PATH_ADVISORY, _PATH_MUST_EXIST, BuildDriver,
)
from snapdragon_studio.core.config import PLATFORM_FIELD_SUPPORT, ImageConfig
from snapdragon_studio.core.platform_info import HostInfo

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


def _driver(backend: str = "docker") -> BuildDriver:
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="snapdragon-builder")
    return BuildDriver(GENERATOR_DIR, host)


def _inner(cmd: list[str]) -> str:
    """The builder argv, which docker-run carries as ONE `bash -c <string>` element.

    Load-bearing: a naive `assert host_path not in cmd` over the docker argv LIST can never
    fail — the flag value is inside that joined string, never a standalone element — so it
    would pass whether or not the path was remapped. Assert against this instead."""
    assert cmd[-2] == "-c", "docker command shape changed; this helper is now lying"
    return cmd[-1]


def _docker_cfg(tmp_path, **kw) -> ImageConfig:
    cfg = ImageConfig(platform="x86", role="be", mode="mesh", env="test")
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


# ── the mount list ──────────────────────────────────────────────────────────────────────
def test_every_host_path_field_is_mounted_under_docker(tmp_path):
    """THE REGRESSION. Each host-path field, given a real path OUTSIDE the generator dir,
    must be bind-mounted and its flag rewritten to the in-container path. Before the fix
    secureboot_key/_cert/keys_usb/distdir were emitted as raw host paths and silently
    ignored in-container."""
    for field in sorted(_HOST_PATH_FIELDS):
        if field == "distdir" or field == "keys_usb" or field == "branding_dir":
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


def test_mount_list_has_no_duplicates_and_indices_are_stable():
    """Each field's index names its /assets/<i>/ dir; a duplicate would collide two mounts
    onto one path. Also pins the ORDER of the historical entries: appending is safe,
    reordering silently changes every existing mount path."""
    assert len(DOCKER_ASSET_FIELDS) == len(set(DOCKER_ASSET_FIELDS))
    assert DOCKER_ASSET_FIELDS[:7] == ("wallpaper", "grub_background", "login_background",
                                       "brand_logo", "color_scheme", "branding_dir",
                                       "egress_vpn")


def test_paths_already_under_the_generator_dir_are_not_mounted(tmp_path):
    """/src is already mounted — re-mounting a path under it would be redundant (and could
    shadow the repo). Pins the existing early-continue."""
    # NB: a branding field would be the obvious probe but is desktop-class, so it never
    # reaches argv on this mesh/be config at all. secureboot_key does.
    inside = os.path.join(GENERATOR_DIR, "keys-template", "kernel_key.pem")
    cfg = _docker_cfg(tmp_path, secureboot_key=inside)
    cmd = _driver().command(cfg, backend="docker")
    assert inside in _inner(cmd)               # emitted verbatim, reachable via /src
    assert not any(a.startswith(f"{inside}:/assets") for a in cmd)


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
    cfg = ImageConfig(platform="rpi5", role="be", mode="mesh", env="test")
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
