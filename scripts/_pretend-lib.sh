# _pretend-lib.sh — the Studio Desktop step's "Check with emerge --pretend" run.
# Staged into the sysroot's /tmp and sourced INSIDE the build chroot by
# build-x86-host-stage4.sh --pretend-only (the same staging pattern as
# _emerge-plan-lib.sh), so it can be shell-tested on its own with a stub `emerge`.
#
# --pretend-only does everything a real build does up to the payload emerge —
# argv validation, seed fetch/verify, extract, the specs' portage config, the
# Desktop step's overlay (dc_apply_portage_overlay), make.conf and the seed's
# Python targets — then asks the resolver ONE question and stops:
#
#   emerge --pretend --update --deep --newuse --autounmask=y --autounmask-write=n
#          --autounmask-backtrack=y --exclude sys-apps/portage <toolchain excludes>
#          @world <the role payload>
#
# --autounmask=y is what makes portage NAME the USE / keyword changes it needs
# instead of only failing (the payload gate, hugmesh_payload_plan_gate, asks the
# same way). Nothing is merged, written or packaged.
#
# WIRE CONTRACT (studio/hugmesh_studio/core/desktop_pretend.py parses it; pinned
# by tests/scripts/test-desktop-config-lib.sh and studio/tests/test_desktop_pretend.py):
#   ==> Pretend result: status=clean|needs|error rc=N seed_python=a,b video_cards=x,y
#   ==> Pretend needs: package.use <line>
#   ==> Pretend needs: accept_keywords <line>
#   ==> Pretend needs: mask <line>
#   ==> Pretend needs: license <line>
#   ===== PRETEND RESOLVER OUTPUT =====
#   ...the last lines the resolver printed...
#   ===== END PRETEND RESOLVER OUTPUT =====
# Exit status of hugmesh_pretend_report: 0 clean, 3 needs, 1 error.
#
# FAILS CLOSED: "clean" needs POSITIVE evidence — emerge exited 0, printed its
# "Total: N packages" plan line, and named no change. A timeout, an empty log, a
# slot conflict with no named change, or anything else is "error", never clean.
#
# HONESTY: this resolves the seed + @world + payload in ONE pass. The real build
# merges @world first and resolves the payload after it (its own fail-fast gate
# re-checks there), so "clean" means "no wall the resolver can see from the
# seed", not "the build will succeed".

HUGMESH_PRETEND_TIMEOUT="${HUGMESH_PRETEND_TIMEOUT:-2400}"

# hugmesh_pretend_run LOG ARGS... -> runs the resolution into LOG, returns emerge's rc
hugmesh_pretend_run() {
    local log="$1"; shift
    local to=""
    command -v timeout >/dev/null 2>&1 && to="timeout ${HUGMESH_PRETEND_TIMEOUT}"
    # shellcheck disable=SC2086
    # --verbose: portage prints its "Total: N packages" plan line ONLY with it, and
    # that line is the positive evidence hugmesh_pretend_report needs for "clean".
    NOCOLOR=true ${to} emerge --pretend --verbose --color=n --update --deep --newuse \
        --autounmask=y --autounmask-write=n --autounmask-backtrack=y "$@" > "${log}" 2>&1
}

# hugmesh_pretend_needs LOG -> "KIND line" for every change portage named
hugmesh_pretend_needs() {
    # tr: emerge prints its spinner with \r and \b; drop them before matching.
    tr -d '\r\b\000' < "$1" | awk '
        /^The following USE changes are necessary to proceed/      { kind = "package.use"; next }
        /^The following keyword changes are necessary to proceed/  { kind = "accept_keywords"; next }
        /^The following mask changes are necessary to proceed/     { kind = "mask"; next }
        /^The following license changes are necessary to proceed/  { kind = "license"; next }
        # The OTHER form a USE wall takes. When autounmask does not list the change
        # (the real 2026-11-11 OBS run: the keyword change listed, the ffmpeg USE wall
        # not), portage prints its suggestion as a hint instead:
        #   emerge: there are no ebuilds built with USE flags to satisfy "...".
        #   !!! One of the following packages is required to complete your request:
        #   - media-video/ffmpeg-8.1.2::gentoo (Change USE: +opus +x264)
        # The first alternative is portage'"'"'s preferred one (highest version), and its
        # line becomes ">=CAT/PN-VER opus x264" (what --autounmask-write writes). Only
        # a hint that is NOTHING BUT a USE change counts: ", this change violates use
        # flag constraints ..." or "Missing IUSE" stay unnamed, so the result is error.
        /^!!! One of the following packages is required to complete your request/ { oneof = 1; kind = ""; next }
        oneof && /^- / {
            oneof = 0
            if (match($0, /^- [a-z0-9][a-z0-9+._-]*\/[A-Za-z0-9+_.-]+(::[A-Za-z0-9_-]+)? \(Change USE: [^),]+\)[[:space:]]*$/)) {
                cpv = $2; sub(/::.*$/, "", cpv)
                chg = $0; sub(/^.*\(Change USE: /, "", chg); sub(/\)[[:space:]]*$/, "", chg)
                n = split(chg, f, /[[:space:]]+/); flags = ""; okf = (n > 0)
                for (i = 1; i <= n; i++) {
                    if (f[i] ~ /^\+[A-Za-z0-9][A-Za-z0-9+_@-]*$/) flags = flags " " substr(f[i], 2)
                    else if (f[i] ~ /^-[A-Za-z0-9][A-Za-z0-9+_@-]*$/) flags = flags " " f[i]
                    else okf = 0
                }
                if (okf && flags != "") print "package.use >=" cpv flags
            }
            next
        }
        { oneof = 0 }
        kind == "" { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\(see / { next }
        /^#/ { next }
        /^[<>=~]*[a-z0-9][a-z0-9+._-]*\/[A-Za-z0-9+_]/ {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            print kind " " line
            next
        }
        { kind = "" }
    ' | awk '!seen[$0]++'
}

# _hugmesh_pretend_conf_list VAR -> the make.conf value of VAR, comma-joined
_hugmesh_pretend_conf_list() {
    local v
    v="$(grep -a -E "^[[:space:]]*$1=" /etc/portage/make.conf 2>/dev/null | tail -n 1)"
    v="${v#*=}"; v="${v#\"}"; v="${v%\"}"
    # shellcheck disable=SC2086
    printf '%s' "$(printf '%s\n' ${v} | paste -sd, -)"
}

# hugmesh_pretend_report LOG RC -> prints the wire contract; returns 0/3/1
hugmesh_pretend_report() {
    local log="$1" rc="$2" needs status ret
    needs="$(hugmesh_pretend_needs "${log}")"
    if [ -n "${needs}" ]; then
        status=needs; ret=3
    elif [ "${rc}" = "0" ] && [ -s "${log}" ] && grep -a -E '^Total: [0-9]+ package' "${log}" >/dev/null; then
        status=clean; ret=0
    else
        status=error; ret=1
    fi
    printf '==> Pretend result: status=%s rc=%s seed_python=%s video_cards=%s\n' \
        "${status}" "${rc}" "$(_hugmesh_pretend_conf_list PYTHON_TARGETS)" \
        "$(_hugmesh_pretend_conf_list VIDEO_CARDS)"
    if [ -n "${needs}" ]; then
        printf '%s\n' "${needs}" | while IFS= read -r n; do
            printf '==> Pretend needs: %s\n' "${n}"
        done
    fi
    printf '===== PRETEND RESOLVER OUTPUT =====\n'
    tr -d '\r\b\000' < "${log}" | grep -a -v -E '^[[:space:]]*$' | tail -n 200 || true
    printf '===== END PRETEND RESOLVER OUTPUT =====\n'
    return "${ret}"
}
