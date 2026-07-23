#!/usr/bin/env bash
# flag-coverage.sh — builder-flag coverage differ: NO builder option may drift
# out of the Studio GUI unnoticed again.
#
# For each of the six builder scripts it diffs TWO real surfaces against each
# other (nothing hand-copied — both sides are extracted live):
#
#   PARSED   the builder's own arg-parser case arms (the `while [[ $# -gt 0 ]]`
#            … `done` region of build-*-stage4.sh), every `--flag)` alternative.
#   FIELDED  the flags the Studio can actually EMIT for that platform — computed
#            by exercising ImageConfig.to_cli_args() over a per-field sample
#            battery driven by config.py's PLATFORM_FIELD_SUPPORT capability
#            table (a sample-coverage assert makes a new field without a sample
#            fail loudly here, so the battery cannot silently rot).
#
# FORWARD check (6): every PARSED case arm must have at least one alternative
# that is FIELDED, driver-provided (-w/-j from BuildDriver) or on the DOCUMENTED
# allowlist below (aliases, deprecated no-ops, marker-only escape hatches,
# host-side plumbing). An unlisted, unfielded flag = a GUI gap = FAIL.
# REVERSE check (6): every FIELDED flag must be PARSED by that builder — an
# emitted-but-unparsed flag would make every GUI build exit "Unknown option".
#
# Fully static + Qt-free (imports the studio core only); no root, no writes
# outside mktemp. Run directly or via tests/build-matrix/check.sh (COVG bucket):
#   bash tests/build-matrix/flag-coverage.sh
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
PYTHON="${PYTHON:-python3}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${REPO_DIR}"

FAILS=0

# ── the documented out-of-scope list: "<platform> <flag> — <reason>" ────────────
# Every entry must name a REASON; the forward check prints it on match so the
# report stays self-explaining. Alternatives sharing a case arm with a fielded
# flag (e.g. --domain riding --cluster-domain's arm) need no entry — the arm is
# already covered.
ALLOWLIST="${TMP_DIR}/allowlist.txt"
cat >"${ALLOWLIST}" <<'EOF'
all --print-plan — harness-only dry-run flag (this suite's own probe channel)
all --help — usage text, not an image option
all --no-grow — pure alias of '--grow none' (the fielded spelling)
x86 --nvidia — pure alias of '--gpu-driver nvidia' (the fielded matrix spelling)
x86 --nvidia-driver — back-compat open|proprietary alias of --gpu-driver
x86 --skip-mesh — alias posture; the Studio emits the explicit --no-tailscale pair
x86 --skip-sso — alias posture; the Studio emits the explicit --no-sso pair
x86 --managed-service — managed backing-services axis (I8-DESIGN); driven by the MANAGED_SERVICES env / build-image Job channel, NOT a Studio ImageConfig field yet (the Studio surface is lane M2, deferred)
rpi5 --managed-service — managed backing-services axis (I8-DESIGN); driven by the MANAGED_SERVICES env / build-image Job channel, NOT a Studio field yet (Studio surface is lane M2, deferred)
rpi5 --both — pure alias of '--img --iso' (both fielded individually)
rpi5 --user-password — deprecated no-op on this builder (warn+ignore; x86-only field by design)
rpi5 --root-password — deprecated no-op on this builder (warn+ignore; x86-only field by design)
rpi5 --specs-dir — host-side build plumbing (specs tree override), deliberately not a GUI knob
rpi5 --target — host-side cross-toolchain plumbing, deliberately not a GUI knob
frite --user-password — deprecated no-op on this builder (warn+ignore)
frite --root-password — deprecated no-op on this builder (warn+ignore)
frite --specs-dir — host-side build plumbing, deliberately not a GUI knob
frite --target — host-side cross-toolchain plumbing, deliberately not a GUI knob
frite --role — undocumented marker-only escape hatch (no real role axis on this builder)
frite --live — pure alias of '--flavor live' (the fielded axis)
frite --installer — pure alias of '--flavor installer' (the fielded axis)
jetson --user-password — deprecated no-op on this builder (warn+ignore)
jetson --root-password — deprecated no-op on this builder (warn+ignore)
jetson --specs-dir — host-side build plumbing, deliberately not a GUI knob
jetson --target — host-side cross-toolchain plumbing, deliberately not a GUI knob
jetson --standalone — parsed then HARD-BLOCKED platform-wide (single boot+root partition); the Studio raises pre-emission by the same contract
jetson --encrypt-root — parsed then HARD-BLOCKED platform-wide (see --standalone); the Studio raises pre-emission
jetson --luks-pass — only meaningful with the hard-blocked --encrypt-root; Studio emission is unreachable on this platform by the same contract
orangepi5 --user-password — deprecated no-op on this builder (warn+ignore)
orangepi5 --root-password — deprecated no-op on this builder (warn+ignore)
orangepi5 --specs-dir — host-side build plumbing, deliberately not a GUI knob
orangepi5 --target — host-side cross-toolchain plumbing, deliberately not a GUI knob
orangepi5 --role — undocumented marker-only escape hatch (no real role axis; path-traversal-gated in the builder)
orangepi5 --live — pure alias of '--flavor live' (the fielded axis)
orangepi5 --installer — pure alias of '--flavor installer' (the fielded axis)
orangepizero2 --user-password — deprecated no-op on this builder (warn+ignore)
orangepizero2 --root-password — deprecated no-op on this builder (warn+ignore)
orangepizero2 --specs-dir — host-side build plumbing, deliberately not a GUI knob
orangepizero2 --target — host-side cross-toolchain plumbing, deliberately not a GUI knob
orangepizero2 --role — undocumented marker-only escape hatch (no real role axis; path-traversal-gated in the builder)
orangepizero2 --live — pure alias of '--flavor live' (the fielded axis)
orangepizero2 --installer — pure alias of '--flavor installer' (the fielded axis)
all --packages-only — host/CI PREBUILD-phase flag (shared-binpkg): run the emerge that populates PKGDIR then exit BEFORE image assembly; NOT a Studio ImageConfig field (same class as --specs-dir; driven by the prebuild-binaries make target, not a GUI knob)
rpi5 --distdir — host-side build plumbing (shared READ-ONLY distfiles cache path); NOT a GUI knob on ARM (same class as --specs-dir). x86 DOES field it; the cross builders take it as host plumbing only
frite --distdir — host-side build plumbing (shared READ-ONLY distfiles cache path); NOT a GUI knob on ARM (same class as --specs-dir)
jetson --distdir — host-side build plumbing (shared READ-ONLY distfiles cache path); NOT a GUI knob on ARM (same class as --specs-dir)
orangepi5 --distdir — host-side build plumbing (shared READ-ONLY distfiles cache path); NOT a GUI knob on ARM (same class as --specs-dir)
orangepizero2 --distdir — host-side build plumbing (shared READ-ONLY distfiles cache path); NOT a GUI knob on ARM (same class as --specs-dir)
EOF

allow_reason() { # platform flag -> print reason, rc 0 if allowlisted
    local line
    line="$(grep -m1 -E "^($1|all) $2 — " "${ALLOWLIST}")" || return 1
    printf '%s' "${line#* $2 — }"
}

# ── FIELDED: the Studio's real per-platform emission vocabulary ─────────────────
# One "<platform> <flag>" line per emittable flag. The sample battery is driven
# by PLATFORM_FIELD_SUPPORT and asserted complete, so a new config.py field
# without a sample here is a loud failure, not a silent coverage hole.
gui_vocab() {
    (cd studio && "${PYTHON}" - <<'PYEOF'
import sys
from snapdragon_studio.core.config import (
    BUILDER_SCRIPTS, PLATFORM_FIELD_SUPPORT, ImageConfig, Domain)

BASELINES = {
    "x86": dict(mode="cloud", role="desktop", platform="x86"),
    "rpi5": dict(mode="mesh", role="be", platform="rpi5"),
    "frite": dict(mode="cloud", role="frite", platform="frite"),
    "jetson": dict(mode="mesh", role="edge_ai", platform="jetson"),
    "orangepi5": dict(mode="cloud", role="orangepi5", platform="orangepi5"),
    "orangepizero2": dict(mode="cloud", role="orangepizero2", platform="orangepizero2"),
}

# field -> LIST of override dicts (tri-states get an on AND an off variant so
# both case arms of a --with-x/--no-x pair count as fielded).
SAMPLES = {
    "brand": [{"brand": "acme"}], "brand_title": [{"brand_title": "Acme Co"}],
    "org": [{"org": "Acme-Org"}], "brand_profile": [{"brand_profile": "/tmp/brand.conf"}],
    "hostname": [{"hostname": "myhost"}], "timezone": [{"timezone": "America/New_York"}],
    "user": [{"user": "bob"}],
    "cluster_domain": [{"cluster_domain": "acme.example"}],
    # superdomain emits ONLY in mesh mode (WS-SUPER-B), and the x86/frite/opi5/opz2
    # baselines are cloud — so force mesh here to field the flag on every builder, the
    # same baseline-override trick `unaffiliated` uses.
    "superdomain": [{"mode": "mesh", "superdomain": "acme.internal"}],
    "games_domain": [{"games_domain": "games.acme.example"}],
    "release_state": [{"release_state": "public"}],
    "person_role": [{"person_role": "admin"}],
    "domains": [{"domains": [Domain(name="probe.example")]}],
    "local_user": [{"local_user": "alice"}], "local_pass": [{"local_pass": "pw"}],
    "user_password": [{"user_password": "pw"}], "root_password": [{"root_password": "pw"}],
    "standalone": [{"standalone": True}], "capable": [{"capable": True}],
    "unaffiliated": [{"mode": "standalone", "role": "standalone-thin", "unaffiliated": True}],
    # MODE-AWARE tri-states: the cloud/mesh baselines resolve never-set "" to ON,
    # so the explicit-False (GUI unchecked-box) variant is what fields the
    # --no-tailscale/--no-sso (x86) and --skip-mesh (ARM) case arms.
    "tailscale": [{"tailscale": True}, {"tailscale": False}],
    "sso": [{"sso": True}, {"sso": False}],
    "headscale_version": [{"headscale_version": "0.23"}],
    "tailscale_version": [{"tailscale_version": "1.60"}],
    "skip_tailscale": [{"skip_tailscale": True}],
    "gpu_driver": [{"gpu_driver": "nvidia"}], "nvidia_cuda": [{"nvidia_cuda": True}],
    "kernel_builtin": [{"kernel_builtin": True}],
    "enable_wifi": [{"enable_wifi": True}], "enable_bluetooth": [{"enable_bluetooth": True}],
    "theme": [{"theme": "boogiepop"}], "branding_dir": [{"branding_dir": "/tmp/b"}],
    "wallpaper": [{"wallpaper": "/tmp/w.png"}],
    "grub_background": [{"grub_background": "/tmp/g.png"}],
    "grub_theme": [{"grub_theme": "/tmp/gt"}],
    "login_background": [{"login_background": "/tmp/l.png"}],
    "brand_logo": [{"brand_logo": "/tmp/logo.png"}],
    "accent_color": [{"accent_color": "#123456"}],
    "color_scheme": [{"color_scheme": "dark"}], "brand_locked": [{"brand_locked": True}],
    "egress_vpn": [{"egress_vpn": "/tmp/e.ovpn"}],
    "egress_vpn_locked": [{"egress_vpn": "/tmp/e.ovpn", "egress_vpn_locked": True}],
    "proxy_stack": [{"proxy_stack": "on"}, {"proxy_stack": "off"}],
    "snort": [{"snort": False}],
    "aide": [{"aide": "on"}, {"aide": "off"}],
    "root_login": [{"root_login": "yes"}],
    "edge_ai_service": [{"edge_ai_service": "on"}, {"edge_ai_service": "off"}],
    "edge_ai_runtime": [{"edge_ai_service": "on", "edge_ai_runtime": "vllm"}],
    "edge_ai_models": [{"edge_ai_service": "on", "edge_ai_models": "llama3"}],
    "edge_ai_model_default": [{"edge_ai_service": "on", "edge_ai_model_default": "llama3"}],
    "edge_ai_analysis": [{"edge_ai_analysis": True}],
    # edge_ai_tts is CPU-only + self-contained (NO edge_ai_service dependency, unlike the
    # edge_ai_runtime/models fields above) — a plain on/off tri-state like character_studio.
    "edge_ai_tts": [{"edge_ai_tts": "on"}, {"edge_ai_tts": "off"}],
    "tor_onion_service": [{"tor_onion_service": "on"}, {"tor_onion_service": "off"}],
    "character_studio": [{"character_studio": "on"}, {"character_studio": "off"}],
    # idp (I6): the external-OIDC combo fields the --idp/--idp-issuer/--idp-client-id
    # [--idp-jwks] flags. casdoor (the default) emits nothing by design, so the sample
    # must pick an external provider + its required issuer/client-id (mirrors
    # test_cli_args._FIELD_PROBE). Scoped _X86_RPI5, so checked on x86/rpi5 only.
    "idp": [{"idp": "oidc", "idp_issuer": "https://idp.example", "idp_client_id": "probe-client"}],
    "idp_issuer": [{"idp": "oidc", "idp_issuer": "https://idp.example", "idp_client_id": "probe-client"}],
    "idp_client_id": [{"idp": "oidc", "idp_issuer": "https://idp.example", "idp_client_id": "probe-client"}],
    "idp_jwks": [{"idp": "oidc", "idp_issuer": "https://idp.example", "idp_client_id": "probe-client",
                  "idp_jwks": "https://idp.example/keys"}],
    "optional_services": [{"optional_services": ["akkoma"]},
                          {"optional_services": ["none"]}, {"optional_services": ["all"]}],
    "exclude_services": [{"exclude_services": ["games"]}],
    "enable_games": [{"enable_games": True}],
    "desktop": [{"desktop": "thin"}], "steam": [{"steam": "native"}],
    "media_data": [{"media_data": "on"}, {"media_data": "off"}],
    "media_label": [{"media_label": "DATA"}], "no_vaults": [{"no_vaults": True}],
    "encrypt_root": [{"encrypt_root": True}], "luks_pass": [{"luks_pass": "pw"}],
    "unlock_keyfile": [{"unlock_keyfile": "boot"}],
    "unlock_yubikey": [{"unlock_yubikey": "login"}],
    "secure_boot": [{"secure_boot": "on"}, {"secure_boot": "off"}],
    "keys_usb": [{"keys_usb": "/tmp/keys"}],
    "secureboot_key": [{"secureboot_key": "/tmp/k.pem"}],
    "secureboot_cert": [{"secureboot_cert": "/tmp/c.pem"}],
    "home_mode": [{"home_mode": "adopt", "home_device": "LABEL=HOME"}],
    "home_device": [{"home_device": "LABEL=HOME"}],
    "home_backup": [{"home_backup": "auto"}], "home_encrypted": [{"home_encrypted": True}],
    "home_seed_code": [{"home_seed_code": "repos"}],
    "home_seed_code_from": [{"home_seed_code_from": "/tmp/seed"}],
    "include_home_archive": [{"include_home_archive": "/tmp/home.tar"}],
    "seed_packages_from": [{"seed_packages_from": "/tmp/pkgs"}],
    "installer_ui": [{"installer_ui": "cli"}],
    "cached": [{"cached": True}], "live_toram": [{"live_toram": False}],
    "bundle_source": [{"bundle_source": False}],
    "build_img": [{"build_img": "on"}, {"build_img": "off"}],
    "live_iso": [{"live_iso": "on"}, {"live_iso": "off"}],
    "installer_iso": [{"installer_iso": True}],
    "build_tar": [{"build_tar": "on"}, {"build_tar": "off"}],
    "skip_iso": [{"skip_iso": True}], "build_iso": [{"build_iso": True}],
    "sd_only": [{"sd_only": True}], "image_only": [{"image_only": True}],
    "grow": [{"grow": "fill"}], "img_size": [{"img_size": 4096}],
    "compress": [{"compress": True}], "resume": [{"resume": True}],
    "cpu": [{"cpu": "cortex-a53"}], "defconfig": [{"defconfig": "foo_defconfig"}],
    "dtb": [{"dtb": "foo.dtb"}], "dtb_prefix": [{"dtb_prefix": "bcm2712"}],
    "kernel_img": [{"kernel_img": "Image"}], "pcie_gen3": [{"pcie_gen3": True}],
    "kernel_flavor": [{"kernel_flavor": "l4t"}],
    "uboot_url": [{"uboot_url": "http://x/u.bin"}],
    "uboot_defconfig": [{"uboot_defconfig": "foo_defconfig"}],
    "skip_uboot": [{"skip_uboot": True}],
    "skip_kernel": [{"skip_kernel": True}], "skip_clean": [{"skip_clean": True}],
    "distdir": [{"distdir": "/tmp/dist"}], "build_subdir": [{"build_subdir": "sub"}],
    "seed_url": [{"seed_url": "http://s/x"}], "version": [{"version": "1.2.3"}],
    "release_tag": [{"release_tag": "rc1"}],
    "extra_packages": [{"extra_packages": "app-editors/vim"}],
    "packages_add": [{"packages_add": "app-editors/vim"}],
    "packages_drop": [{"packages_drop": "app-editors/vim"}],
}

# structural axes (role/env/board/flavor/desktop) are deliberately absent from
# PLATFORM_FIELD_SUPPORT (RolePage/BuildPage concerns, not gateable options) but
# still part of the emission vocabulary — probe the non-default board axes the
# baselines leave unset (frite/opi5/opz2 emit --board/--flavor unconditionally).
STRUCTURAL = {
    "rpi5": [{"board": "rpi4"}],
    "jetson": [{"board": "orin-nano"}],
}

missing = set(PLATFORM_FIELD_SUPPORT) - set(SAMPLES)
if missing:
    print(f"FLAGCOV-VOCAB-ERROR: capability-table field(s) with no sample here: "
          f"{sorted(missing)} — add a sample so coverage cannot rot", file=sys.stderr)
    sys.exit(2)

for platform in BUILDER_SCRIPTS:
    base = BASELINES[platform]
    vocab = set()
    batteries = [dict(base)]
    batteries += [{**base, **ov} for ov in STRUCTURAL.get(platform, [])]
    for field, plats in PLATFORM_FIELD_SUPPORT.items():
        if platform not in plats:
            continue
        for ov in SAMPLES[field]:
            batteries.append({**base, **ov})
    for kwargs in batteries:
        try:
            args = ImageConfig(**kwargs).to_cli_args()
        except ValueError:
            continue   # a rejected combination never reaches the builder
        vocab.update(a for a in args if a.startswith("-"))
    for flag in sorted(vocab):
        print(f"{platform} {flag}")
PYEOF
    )
}

# ── PARSED: the builder's arg-parser case-arm tokens, one arm per line ──────────
# Bounded to the parser region (`while … $# …` up to its `done`) so unrelated
# case statements never leak in. Alternatives stay together on the line
# ("--cluster-domain|--domain"), so an arm counts as covered when ANY
# alternative is fielded.
parser_arms() { # builder-file
    awk '/^while \[\[? *"?\$#"? /{p=1} p{print} p&&/^done/{exit}' "$1" \
        | grep -oE '^[[:space:]]*-{1,2}[A-Za-z0-9|_-]+\)' \
        | sed 's/^[[:space:]]*//; s/)$//' \
        | grep -vx -- '--'   # the POSIX end-of-options marker is not a flag
}

check_builder() { # platform builder-file
    local platform="$1" builder="$2"
    local arms arm alt covered reason unfielded="" nparsed=0 nfielded=0 nallowed=0
    local vocab="${TMP_DIR}/vocab-${platform}.txt"
    grep "^${platform} " "${TMP_DIR}/gui-vocab.txt" | cut -d' ' -f2 >"${vocab}"
    if [ ! -s "${vocab}" ]; then
        echo "FLAGCOV FAIL ${builder} forward — no GUI vocabulary extracted for '${platform}'"
        echo "FLAGCOV FAIL ${builder} reverse — no GUI vocabulary extracted for '${platform}'"
        FAILS=$((FAILS+2)); return
    fi
    arms="$(parser_arms "${builder}")"
    if [ -z "${arms}" ]; then
        echo "FLAGCOV FAIL ${builder} forward — could not extract the arg-parser case arms (parser region drifted; update parser_arms)"
        echo "FLAGCOV FAIL ${builder} reverse — could not extract the arg-parser case arms"
        FAILS=$((FAILS+2)); return
    fi

    # FORWARD: every parsed arm fielded / driver-provided / allowlisted
    while IFS= read -r arm; do
        nparsed=$((nparsed+1))
        covered=false
        for alt in ${arm//|/ }; do
            # -w/-j are BuildDriver-provided on every platform (command assembly)
            [ "${alt}" = "-w" ] || [ "${alt}" = "-j" ] && { covered=true; break; }
            grep -qxF -- "${alt}" "${vocab}" && { covered=true; break; }
        done
        if ${covered}; then
            nfielded=$((nfielded+1)); continue
        fi
        reason=""
        for alt in ${arm//|/ }; do
            reason="$(allow_reason "${platform}" "${alt}")" && break
        done
        if [ -n "${reason}" ]; then
            nallowed=$((nallowed+1))
        else
            unfielded+=" ${arm}"
        fi
    done <<<"${arms}"
    if [ -n "${unfielded}" ]; then
        echo "FLAGCOV FAIL ${builder} forward — parsed but UNFIELDED (add a field, grey it, or allowlist with a reason):${unfielded}"
        FAILS=$((FAILS+1))
    else
        echo "FLAGCOV PASS ${builder} forward (${nparsed} arms: ${nfielded} fielded, ${nallowed} allowlisted)"
    fi

    # REVERSE: every GUI-emitted flag parsed by this builder (any arm alternative)
    local unparsed="" flag nvocab=0
    local flat="${TMP_DIR}/arms-flat-${platform}.txt"
    printf '%s\n' "${arms}" | tr '|' '\n' >"${flat}"
    while IFS= read -r flag; do
        nvocab=$((nvocab+1))
        grep -qxF -- "${flag}" "${flat}" || unparsed+=" ${flag}"
    done <"${vocab}"
    if [ -n "${unparsed}" ]; then
        echo "FLAGCOV FAIL ${builder} reverse — Studio emits flags this builder does NOT parse (every GUI build would exit 'Unknown option'):${unparsed}"
        FAILS=$((FAILS+1))
    else
        echo "FLAGCOV PASS ${builder} reverse (${nvocab} emitted flags all parsed)"
    fi
}

gui_vocab >"${TMP_DIR}/gui-vocab.txt" || {
    echo "FLAGCOV FAIL vocabulary — studio emission dump failed (see stderr)"; exit 1; }

check_builder x86           build-x86-host-stage4.sh
check_builder rpi5          build-rpi5-stage4.sh
check_builder frite         build-frite-stage4.sh
check_builder jetson        build-jetson-stage4.sh
check_builder orangepi5     build-orangepi5-stage4.sh
check_builder orangepizero2 build-orangepi-zero2-stage4.sh

# ── packages-delta coverage (WS-BUILDER atomic flip) ────────────────────────────
# --packages-add / --packages-drop are the two flags that landed on ALL SIX
# builders in one train. Assert, per builder per flag (2 x 6 = 12 explicit
# checks), that the flag is BOTH parsed by that builder (its arg-parser case arms,
# extracted above into arms-flat-<platform>.txt) AND fielded by the Studio for
# that platform (its emission vocab, gui-vocab.txt / vocab-<platform>.txt). This
# is the round-trip guarantee for the ONE flag-pair that moves the gate numbers,
# reported as its own countable bucket so a regression names the exact cell.
check_packages_delta() { # platform builder
    local platform="$1" builder="$2" flag
    local flat="${TMP_DIR}/arms-flat-${platform}.txt" vocab="${TMP_DIR}/vocab-${platform}.txt"
    for flag in --packages-add --packages-drop; do
        local parsed=false fielded=false
        grep -qxF -- "${flag}" "${flat}"  && parsed=true
        grep -qxF -- "${flag}" "${vocab}" && fielded=true
        if ${parsed} && ${fielded}; then
            echo "FLAGCOV PASS ${builder} ${flag} (parsed + fielded)"
        else
            echo "FLAGCOV FAIL ${builder} ${flag} — parsed=${parsed} fielded=${fielded} (WS-BUILDER flip incomplete on this builder)"
            FAILS=$((FAILS+1))
        fi
    done
}

check_packages_delta x86           build-x86-host-stage4.sh
check_packages_delta rpi5          build-rpi5-stage4.sh
check_packages_delta frite         build-frite-stage4.sh
check_packages_delta jetson        build-jetson-stage4.sh
check_packages_delta orangepi5     build-orangepi5-stage4.sh
check_packages_delta orangepizero2 build-orangepi-zero2-stage4.sh

# ── superdomain coverage (WS-SUPER-B) ───────────────────────────────────────────
# --superdomain is the ONE flag that landed on ALL SIX builders in the WS-SUPER-B
# train. Assert per builder (1 x 6 = 6 explicit checks) that it is BOTH parsed by
# that builder AND fielded by the Studio for that platform (its mesh emission vocab).
# Its own countable bucket so a regression names the exact cell — mirrors
# check_packages_delta.
check_superdomain() { # platform builder
    local platform="$1" builder="$2"
    local flat="${TMP_DIR}/arms-flat-${platform}.txt" vocab="${TMP_DIR}/vocab-${platform}.txt"
    local parsed=false fielded=false
    grep -qxF -- --superdomain "${flat}"  && parsed=true
    grep -qxF -- --superdomain "${vocab}" && fielded=true
    if ${parsed} && ${fielded}; then
        echo "FLAGCOV PASS ${builder} --superdomain (parsed + fielded)"
    else
        echo "FLAGCOV FAIL ${builder} --superdomain — parsed=${parsed} fielded=${fielded} (WS-SUPER-B flip incomplete on this builder)"
        FAILS=$((FAILS+1))
    fi
}

check_superdomain x86           build-x86-host-stage4.sh
check_superdomain rpi5          build-rpi5-stage4.sh
check_superdomain frite         build-frite-stage4.sh
check_superdomain jetson        build-jetson-stage4.sh
check_superdomain orangepi5     build-orangepi5-stage4.sh
check_superdomain orangepizero2 build-orangepi-zero2-stage4.sh

[ "${FAILS}" -eq 0 ]
