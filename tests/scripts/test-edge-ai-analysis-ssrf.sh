#!/usr/bin/env bash
# test-edge-ai-analysis-ssrf.sh — the image_url SSRF guard of the edge-ai-analysis
# service (specs/cluster/manifests/edge-ai-analysis/image/app.py; CodeQL
# py/full-ssrf alert #9).
#
# image_url is user-supplied on a ROLE_USER route. Before this suite, the guard
# refused private, loopback, link-local, reserved, multicast and unspecified
# addresses but not 100.64.0.0/10. That range is the mesh's own headscale tailnet,
# MagicDNS 100.100.100.100 included. The fetch also resolved the name a second
# time after the check, and the error detail echoed the httpx error.
#
# 1) Runs tests/scripts/edge_ai_analysis_ssrf.py against the real app.py. The
#    tests drive POST /v1/analyze/image/hash through FastAPI's TestClient with name
#    resolution and TCP connect replaced in-process, so no packet leaves the
#    runner.
# 2) NEGATIVE CONTROLS. Re-runs the same tests against copies of app.py, each
#    carrying one planted defect, and requires that the named test FAILS by
#    assertion. An import error or a crash does not count as caught. A mutation
#    whose anchor text is no longer in app.py fails this suite too, so the controls
#    cannot rot into no-ops after a refactor.
#
# FAIL-CLOSED on tooling. It needs the image's pinned requirements (pip install -r
# specs/cluster/manifests/edge-ai-analysis/image/requirements.txt) and the openssl
# CLI. If either is missing it exits 2 rather than skipping.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
APP="${REPO}/specs/cluster/manifests/edge-ai-analysis/image/app.py"
PYTEST="${HERE}/edge_ai_analysis_ssrf.py"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== edge-ai-analysis image_url SSRF guard =="

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "  FAIL openssl CLI not available (the TLS tests need it)"; exit 2; }
if ! python3 -c 'import httpx, fastapi, PIL, imagehash' >/dev/null 2>&1; then
  echo "  FAIL the app's requirements are not importable here; install them with"
  echo "       pip install -r specs/cluster/manifests/edge-ai-analysis/image/requirements.txt"
  exit 2
fi
[ -f "${APP}" ] || { echo "  FAIL ${APP} is missing"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/edge-ai-ssrf.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# ── 1) the real app ──────────────────────────────────────────────────────────
echo "-- 1) the guard on the real app.py --"
if EDGE_AI_ANALYSIS_APP="${APP}" PYTHONDONTWRITEBYTECODE=1 python3 "${PYTEST}" \
     </dev/null >"${WORK}/real.log" 2>&1; then
  ok "all tests pass on the real app.py ($(grep -E '^Ran [0-9]+ tests' "${WORK}/real.log"))"
else
  bad "tests fail on the real app.py:"
  sed 's/^/         /' "${WORK}/real.log"
fi

# ── 2) negative controls ─────────────────────────────────────────────────────
echo "-- 2) each planted defect is caught --"
# mutate NAME TEST OLD NEW: copy app.py, replace OLD (must occur exactly once) with
# NEW, and require that TEST fails by assertion against the copy.
mutate() {
  local name test old new mut log
  name="$1"; test="$2"; old="$3"; new="$4"
  mut="${WORK}/${name}.py"; log="${WORK}/${name}.log"
  if ! OLD="${old}" NEW="${new}" python3 - "${APP}" "${mut}" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = os.environ["OLD"], os.environ["NEW"]
n = src.count(old)
if n != 1:
    print("anchor occurs %d times (want 1)" % n)
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  then
    bad "${name}: the mutation did not apply; app.py changed and this control must be updated"
    return
  fi
  if cmp -s "${APP}" "${mut}"; then
    bad "${name}: the mutated copy is identical to app.py"
    return
  fi
  if EDGE_AI_ANALYSIS_APP="${mut}" PYTHONDONTWRITEBYTECODE=1 python3 "${PYTEST}" \
       </dev/null >"${log}" 2>&1; then
    bad "${name}: every test still passes with the defect planted"
    return
  fi
  if grep -Eq "^FAIL: ${test} " "${log}"; then
    ok "${name}: caught by ${test}"
  else
    bad "${name}: the run failed, but not by an assertion in ${test}:"
    grep -E '^(FAIL|ERROR):|Error' "${log}" | head -n 8 | sed 's/^/         /'
  fi
}

mutate no-is-global test_internal_literal_addresses_are_refused_without_connecting \
  $'    if not ip.is_global:\n        return False\n' ''
mutate no-explicit-predicates test_internal_literal_addresses_are_refused_without_connecting \
  $'    return not (ip.is_private or ip.is_loopback or ip.is_link_local\n                or ip.is_reserved or ip.is_multicast or ip.is_unspecified)' \
  $'    return True'
mutate first-answer-only test_one_internal_answer_among_public_ones_refuses_the_url \
  'for info in addrinfos:' 'for info in addrinfos[:1]:'
mutate request-by-name test_fetch_connects_to_the_vetted_address_not_a_second_lookup \
  'pinned = parsed.copy_with(host=address)' 'pinned = parsed'
mutate host-header-dropped test_fetch_dials_the_ip_literal_and_keeps_the_host_header \
  'headers={"Host": host_header},' 'headers={},'
mutate sni-dropped test_https_verifies_against_the_original_name \
  'extensions={"sni_hostname": server_name}' 'extensions={}'
mutate verify-off test_https_with_a_certificate_for_another_name_fails \
  'verify=_TLS_CONTEXT) as client:' 'verify=False) as client:'
mutate redirects-followed test_redirect_is_not_followed \
  'follow_redirects=False, trust_env=False,' 'follow_redirects=True, trust_env=False,'
mutate proxy-env-honoured test_proxy_environment_cannot_reroute_the_fetch \
  'follow_redirects=False, trust_env=False,' 'follow_redirects=False, trust_env=True,'
mutate error-echoed test_fetch_failure_detail_is_generic \
  $'    except httpx.HTTPError:\n        raise HTTPException(status_code=400, detail=_IMAGE_URL_FETCH_FAILED) from None' \
  $'    except httpx.HTTPError as e:\n        raise HTTPException(status_code=400, detail=f"{_IMAGE_URL_FETCH_FAILED}: {e}") from None'
mutate resolve-oracle test_unresolvable_and_internal_names_get_the_same_detail \
  $'    except (OSError, UnicodeError):\n        raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED) from None' \
  $'    except (OSError, UnicodeError):\n        raise HTTPException(status_code=400, detail="image_url host does not resolve") from None'
mutate any-scheme test_non_http_schemes_are_refused \
  'if parsed.scheme not in ("http", "https") or not parsed.raw_host:' 'if not parsed.raw_host:'

echo
echo "== edge-ai-analysis SSRF: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
