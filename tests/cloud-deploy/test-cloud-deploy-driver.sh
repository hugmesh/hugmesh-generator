#!/usr/bin/env bash
# test-cloud-deploy-driver.sh — offline logic test for the cloud-deploy wizard:
# the shared driver (specs/usr/sbin/hugmesh-cloud-deploy) + the provider
# registry (specs/usr/lib/hugmesh/cloud-deploy-providers.sh), exercised
# end-to-end across all four providers. Mirrors tests/go-live/
# test-go-live-driver.sh conventions.
#
# Runs ANYWHERE with just bash — NO root, NO network, NO cloud. It points the
# driver's CD_ETC_HUGMESH seam at a throwaway dir, and every cloud CLI the
# emitted scripts drive (aws/az/oc) is a PATH-shadow STUB owned by THIS test
# that records argv into a log — a real CLI is never reachable.
#
# Asserts the wizard's contract:
#   (a) list reflects the provider catalogue; all four are full, none stub.
#   (b) validate_inputs REJECTS malformed --domain/--region/--image/
#       --creds-file/--keys-dir/--out-dir before any emit runs.
#   (c) plan is PURE: per-provider artifacts are emitted into --out-dir and
#       NOTHING else is touched (no state, no cloud calls, no creds reads).
#   (d) per-provider emission proofs: aws-ec2 (UEFI+ENA register, vmimport
#       policies, ENA kernel caveat), azure-image (Gen2, entra/ incl. the
#       honest 3-blocker claims-mapping + NO secrets), openshift-cnv
#       (datavolume+vm+scc/rhel notes), generic-qcow2 (no apply.sh by design).
#   (e) FAIL-SAFE: apply/destroy on a non-TTY refuse (no --yes flag exists;
#       the emitted scripts' OWN gates also refuse when run directly).
#   (f) CUSTODY: apply refuses without --creds-file and refuses loose perms;
#       creds file CONTENTS never appear in any recorded argv.
#   (g) apply with CD_ASSUME_YES=1 + stubs drives the documented argv shapes
#       and records state hints; status prints them WITHOUT any cloud call;
#       destroy drives the teardown argv and clears the hints.
#   (h) the Makefile OIDC_* seam: OIDC_ISSUER overrides the derived
#       CASDOOR_ISSUER in STACK_ENV, OIDC_CLIENT_ID/OIDC_JWKS_URI thread as
#       CASDOOR_APP_CLIENT_ID/CASDOOR_JWKS_URI (make -n proof), empty/unset
#       leaves today's behavior byte-for-byte (empty EXPANDS TO NOTHING), and
#       compose.local.yaml's gateways/BFFs read the threaded names in
#       ${VAR:-default} style.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="${REPO}/specs/usr/sbin/hugmesh-cloud-deploy"
LIB="${REPO}/specs/usr/lib/hugmesh/cloud-deploy-providers.sh"

[ -r "${DRIVER}" ] || { echo "  FAIL driver missing: ${DRIVER}"; exit 1; }
[ -r "${LIB}" ]    || { echo "  FAIL registry lib missing: ${LIB}"; exit 1; }
# Tool preflight is FAIL-CLOSED (tests/lib/guard-preflight.sh): a missing tool
# makes this guard exit 1, never 0. The old `SKIP … exit 0` shape turned an
# under-provisioned CI image into a green check. Deliberate local opt-out:
# GUARD_TOOLING_ALLOW_SKIP=1 — a name .gitlab-ci.yml is forbidden to contain.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-preflight.sh"
guard_require_tools bash

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

ETC="${WORK}/etc"
mkdir -p "${ETC}"
DOMAIN="example.com"
printf '%s\n' "${DOMAIN}" > "${ETC}/cluster-domain"

# The test's OWN cloud-CLI stubs (prepended to PATH for apply/destroy runs):
# each records its argv (oc also its KUBECONFIG) into ARGV_LOG and answers the
# few queries the emitted scripts parse. NOTHING here ever reaches a real CLI.
STUB="${WORK}/bin"; mkdir -p "${STUB}"
ARGV_LOG="${WORK}/argv.log"; : > "${ARGV_LOG}"
cat > "${STUB}/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "${ARGV_LOG}"
case "$*" in
    *describe-import-snapshot-tasks*) printf 'completed snap-0stub\n' ;;
    *import-snapshot*)                printf 'import-snap-0stub\n' ;;
    *register-image*)                 printf 'ami-0stub\n' ;;
    *"iam get-role"*)                 exit 1 ;;   # forces the create-role branch
esac
exit 0
EOF
cat > "${STUB}/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >> "${ARGV_LOG}"
exit 0
EOF
cat > "${STUB}/oc" <<'EOF'
#!/usr/bin/env bash
echo "oc $* KUBECONFIG=${KUBECONFIG:-}" >> "${ARGV_LOG}"
exit 0
EOF
chmod +x "${STUB}/aws" "${STUB}/az" "${STUB}/oc"
export ARGV_LOG

# A fake image + a 0600 creds file whose CONTENTS must never leak into argv.
IMG="${WORK}/hugmesh-x86.img"; truncate -s 4096 "${IMG}" 2>/dev/null || dd if=/dev/zero of="${IMG}" bs=1024 count=4 2>/dev/null
CREDS="${WORK}/creds"; printf '[default]\naws_access_key_id=AKIATESTFAKEKEY00000\naws_secret_access_key=secretpayload-never-argv\n' > "${CREDS}"; chmod 0600 "${CREDS}"

# Always invoke the driver with the seams pointing at the throwaway tree, stdin
# from /dev/null so the "non-TTY" fail-safe path is exercised by default.
cdd() { CD_ETC_HUGMESH="${ETC}" CD_PROVIDERS_LIB="${LIB}" bash "${DRIVER}" "$@" </dev/null 2>&1; }
# Mutating-verb wrapper: stubs FIRST on PATH + the test-only confirmation seam.
cdy() { PATH="${STUB}:${PATH}" CD_ASSUME_YES=1 CD_ETC_HUGMESH="${ETC}" CD_PROVIDERS_LIB="${LIB}" bash "${DRIVER}" "$@" </dev/null 2>&1; }
# Non-TTY gate probe: stubs on PATH but NO assume-yes — if the confirmation gate
# ever regressed, the leak lands in ARGV_LOG (and never reaches a real CLI).
cdn() { PATH="${STUB}:${PATH}" CD_ETC_HUGMESH="${ETC}" CD_PROVIDERS_LIB="${LIB}" bash "${DRIVER}" "$@" </dev/null 2>&1; }

echo "== cloud-deploy wizard: offline driver + 4-provider emission test =="

# (a) registry sanity via list ---------------------------------------------------
out="$(cdd list)"
for want in aws-ec2 azure-image openshift-cnv generic-qcow2; do
    echo "${out}" | grep -E "^${want} .* full " >/dev/null && ok "list includes ${want} (full)" || { bad "list missing/!full ${want}"; echo "${out}"; }
done
echo "${out}" | grep ' stub ' >/dev/null && bad "a provider lists as stub" || ok "no provider lists as stub"
echo "${out}" | grep -E '^aws-ec2 +raw ' >/dev/null && ok "list carries the format column (aws-ec2 raw)" || bad "format column wrong for aws-ec2"

# (b) validate_inputs rejection table -------------------------------------------
while IFS='|' read -r desc flag val; do
    RJOUT="${WORK}/rej"; rm -rf "${RJOUT}"
    out="$(cdd plan --provider generic-qcow2 "${flag}" "${val}" --out-dir "${RJOUT}")"; rc=$?
    if [ "${rc}" -ne 0 ] && [ ! -e "${RJOUT}/destroy.sh" ]; then
        ok "rejects ${desc}"
    else
        bad "did NOT reject ${desc} (rc=${rc})"; echo "${out}"
    fi
done <<'TABLE'
--domain with a path escape|--domain|evil.com/../../etc
--domain with a metachar|--domain|exa mple.com
--region with whitespace|--region|us east 1
--region with a shell metachar|--region|us-east-1;rm
--image with whitespace|--image|/tmp/a b.img
--image with traversal|--image|../../etc/passwd
--creds-file with a command substitution|--creds-file|$(touch pwn)
--keys-dir with a semicolon|--keys-dir|/tmp/a;b
TABLE
# --out-dir metachar rejection (checked before mkdir: the dir must not appear).
out="$(cdd plan --provider generic-qcow2 --out-dir "${WORK}/x|y")"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -d "${WORK}/x|y" ] && ok "rejects --out-dir with a metachar (dir never created)" \
    || bad "did NOT reject metachar --out-dir (rc=${rc})"
[ ! -e "pwn" ] && [ ! -e "${WORK}/pwn" ] && ok "no rejection payload ever executed" || bad "a rejection payload EXECUTED"

# (c)+(d) per-provider plan emission proofs -------------------------------------
# aws-ec2 ------------------------------------------------------------------------
AWSOUT="${WORK}/out-aws"
cdd plan --provider aws-ec2 --image "${IMG}" --region us-east-1 --creds-file "${CREDS}" --out-dir "${AWSOUT}" >/dev/null
for f in apply.sh destroy.sh status.sh vmimport-trust-policy.json vmimport-role-policy.json keys-volume.md checklist.md; do
    [ -s "${AWSOUT}/${f}" ] && ok "aws-ec2 emitted ${f}" || bad "aws-ec2 did NOT emit ${f}"
done
bash -n "${AWSOUT}/apply.sh" && bash -n "${AWSOUT}/destroy.sh" && bash -n "${AWSOUT}/status.sh" \
    && ok "aws-ec2 emitted scripts parse (bash -n)" || bad "an aws-ec2 emitted script has a syntax error"
grep -q -- '--boot-mode uefi' "${AWSOUT}/apply.sh" && grep -q -- '--ena-support' "${AWSOUT}/apply.sh" \
    && ok "aws-ec2 apply registers UEFI + ENA" || bad "aws-ec2 apply missing --boot-mode uefi/--ena-support"
grep -q 'CONFIG_ENA_ETHERNET' "${AWSOUT}/checklist.md" && ok "aws-ec2 checklist carries the honest ENA kernel caveat" || bad "aws-ec2 checklist missing CONFIG_ENA_ETHERNET"
grep -q 'vmie.amazonaws.com' "${AWSOUT}/vmimport-trust-policy.json" && ok "vmimport trust policy is the vmie service trust" || bad "vmimport trust policy wrong"
grep -q "example-com-hugmesh-import" "${AWSOUT}/vmimport-role-policy.json" && ok "vmimport role policy scoped to the derived bucket" || bad "vmimport role policy not bucket-scoped"
grep -q 'KEYS' "${AWSOUT}/keys-volume.md" && grep -q 'KEYS_PREMOUNTED' "${AWSOUT}/keys-volume.md" \
    && ok "keys-volume.md documents the KEYS label + KEYS_PREMOUNTED hook" || bad "keys-volume.md incomplete"
# plan purity: no cloud call, no creds read into artifacts, no state, nothing outside out.
[ ! -d "${AWSOUT}/state" ] && ok "plan wrote NO state (pure)" || bad "plan created state/ — purity violated"
[ ! -s "${ARGV_LOG}" ] && ok "plan made NO cloud-CLI calls (argv log empty)" || { bad "plan CALLED a cloud CLI"; cat "${ARGV_LOG}"; }
grep -rq 'secretpayload-never-argv' "${AWSOUT}" && bad "plan artifacts CONTAIN creds material" || ok "plan artifacts carry no creds material (path-only custody)"
[ "$(ls -A "${ETC}")" = "cluster-domain" ] && ok "plan touched nothing under the etc seam" || bad "plan wrote into the etc seam"

# azure-image --------------------------------------------------------------------
AZOUT="${WORK}/out-az"
VHD="${WORK}/hugmesh-x86.vhd"; truncate -s 4096 "${VHD}" 2>/dev/null || cp "${IMG}" "${VHD}"
CD_ENTRA_TENANT="00000000-1111-2222-3333-444444444444" CD_ETC_HUGMESH="${ETC}" CD_PROVIDERS_LIB="${LIB}" \
    bash "${DRIVER}" plan --provider azure-image --image "${VHD}" --region westeurope --out-dir "${AZOUT}" </dev/null >/dev/null 2>&1
for f in apply.sh destroy.sh image-builder-template.json keys-disk.md checklist.md \
         entra/README.md entra/app-registrations.md entra/claims-mapping.md \
         entra/env/stack.env entra/env/gateway.env entra/env/user-bff.env entra/env/admin-bff.env; do
    [ -s "${AZOUT}/${f}" ] && ok "azure-image emitted ${f}" || bad "azure-image did NOT emit ${f}"
done
bash -n "${AZOUT}/apply.sh" && bash -n "${AZOUT}/destroy.sh" && ok "azure-image emitted scripts parse" || bad "an azure-image emitted script has a syntax error"
grep -q -- '--hyper-v-generation V2' "${AZOUT}/apply.sh" && ok "azure-image apply creates a Gen2 image" || bad "azure-image apply missing --hyper-v-generation V2"
grep -q -- '--type page' "${AZOUT}/apply.sh" && ok "azure-image apply uploads a PAGE blob (image requirement)" || bad "azure-image apply not a page-blob upload"
grep -q 'hv_storvsc' "${AZOUT}/checklist.md" && grep -q 'hv_netvsc' "${AZOUT}/checklist.md" && grep -qi 'Gen1 (BIOS) is impossible' "${AZOUT}/checklist.md" \
    && ok "azure checklist carries the Gen2-only + hv_* kernel caveats" || bad "azure checklist caveats missing"
grep -q 'az login --service-principal' "${AZOUT}/apply.sh" && bad "azure apply handles credentials (service-principal login found)" \
    || ok "azure apply NEVER handles credentials (existing az session required)"
# entra emission: real tenant threaded, Entra JWKS path, the 3 honest blockers.
grep -q 'login.microsoftonline.com/00000000-1111-2222-3333-444444444444/v2.0' "${AZOUT}/entra/env/gateway.env" \
    && ok "entra env fragment threads CD_ENTRA_TENANT into the issuer" || bad "entra issuer not tenant-threaded"
grep -q '/discovery/v2.0/keys' "${AZOUT}/entra/env/gateway.env" && ok "entra env fragment moves JWKS to /discovery/v2.0/keys" || bad "entra JWKS path wrong"
grep -q 'PAIRWISE' "${AZOUT}/entra/claims-mapping.md" && grep -q '`oid`' "${AZOUT}/entra/claims-mapping.md" \
    && ok "claims-mapping blocker 1: pairwise sub -> fold on oid" || bad "claims-mapping missing blocker 1"
grep -q 'allowed_groups' "${AZOUT}/entra/claims-mapping.md" && grep -q 'Harbor' "${AZOUT}/entra/claims-mapping.md" \
    && grep -q 'desktop-sudo' "${AZOUT}/entra/claims-mapping.md" && grep -q 'On-Behalf-Of' "${AZOUT}/entra/claims-mapping.md" \
    && ok "claims-mapping blocker 2: roles/groups model incl. headscale/Harbor/desktop-sudo mapper + OBO" || bad "claims-mapping missing blocker 2"
grep -q 'mfa_satisfied' "${AZOUT}/entra/claims-mapping.md" && grep -qi 'redirect model' "${AZOUT}/entra/claims-mapping.md" \
    && ok "claims-mapping blocker 3: mfa stamping + native login are Casdoor-coupled" || bad "claims-mapping missing blocker 3"
grep -q 'CanonicalIdentityResolver' "${AZOUT}/entra/claims-mapping.md" && ok "claims-mapping names the required service-repo change" || bad "claims-mapping doesn't name CanonicalIdentityResolver"
grep -q 'OIDC_ISSUER=' "${AZOUT}/entra/env/stack.env" && ok "entra stack.env documents the Makefile OIDC_ISSUER seam" || bad "stack.env missing the OIDC_ISSUER seam"
grep -q '^OIDC_JWKS_URI=.*discovery/v2.0/keys$' "${AZOUT}/entra/env/stack.env" && grep -q 'OIDC_CLIENT_ID=' "${AZOUT}/entra/env/stack.env" \
    && ok "entra stack.env carries the seam's JWKS half + documents OIDC_CLIENT_ID (issuer-only pairs Entra iss with Casdoor keys)" \
    || bad "stack.env missing OIDC_JWKS_URI/OIDC_CLIENT_ID — the Makefile does no per-provider JWKS derivation"
# NO-SECRETS sweep over the entra emit (keys/tokens/secret-material shapes).
if grep -rEq -- '-----BEGIN|AKIA[0-9A-Z]{16}|(client_secret|client-secret|password)[=:][A-Za-z0-9]' "${AZOUT}/entra"; then
    bad "entra/ artifacts contain secret-shaped material"; grep -rE -- '-----BEGIN|AKIA[0-9A-Z]{16}|(client_secret|client-secret|password)[=:][A-Za-z0-9]' "${AZOUT}/entra"
else
    ok "entra/ artifacts carry NO secret-shaped material"
fi

# openshift-cnv ------------------------------------------------------------------
OCOUT="${WORK}/out-oc"
QCOW="${WORK}/hugmesh-x86.qcow2"; truncate -s 4096 "${QCOW}" 2>/dev/null || cp "${IMG}" "${QCOW}"
cdd plan --provider openshift-cnv --image "${QCOW}" --creds-file "${CREDS}" --out-dir "${OCOUT}" >/dev/null
for f in datavolume.yaml vm.yaml oc-apply.sh scc-notes.md rhel-notes.md destroy.sh; do
    [ -s "${OCOUT}/${f}" ] && ok "openshift-cnv emitted ${f}" || bad "openshift-cnv did NOT emit ${f}"
done
grep -q 'kind: DataVolume' "${OCOUT}/datavolume.yaml" && grep -q 'cdi.kubevirt.io' "${OCOUT}/datavolume.yaml" \
    && ok "datavolume.yaml is a CDI DataVolume" || bad "datavolume.yaml wrong kind"
grep -q 'kind: VirtualMachine' "${OCOUT}/vm.yaml" && grep -q 'efi' "${OCOUT}/vm.yaml" \
    && ok "vm.yaml is a UEFI KubeVirt VirtualMachine" || bad "vm.yaml wrong"
grep -q 'restricted-v2' "${OCOUT}/scc-notes.md" && grep -q 'Calico' "${OCOUT}/scc-notes.md" && grep -qi 'Routes' "${OCOUT}/scc-notes.md" \
    && ok "scc-notes carry the vanilla->OpenShift deltas (SCC/Calico/Routes)" || bad "scc-notes incomplete"
grep -q 'virt-install' "${OCOUT}/rhel-notes.md" && ok "rhel-notes carry the libvirt one-liner" || bad "rhel-notes missing virt-install"

# generic-qcow2 ------------------------------------------------------------------
GENOUT="${WORK}/out-gen"
cdd plan --provider generic-qcow2 --image "${QCOW}" --out-dir "${GENOUT}" >/dev/null
for f in domain.xml virt-install.md paas-upload.md destroy.sh; do
    [ -s "${GENOUT}/${f}" ] && ok "generic-qcow2 emitted ${f}" || bad "generic-qcow2 did NOT emit ${f}"
done
[ ! -e "${GENOUT}/apply.sh" ] && ok "generic-qcow2 emits NO apply.sh (nothing remote, by design)" || bad "generic-qcow2 unexpectedly emitted apply.sh"
grep -q '<domain type="kvm">' "${GENOUT}/domain.xml" && grep -q 'firmware="efi"' "${GENOUT}/domain.xml" \
    && ok "domain.xml is a UEFI kvm libvirt domain" || bad "domain.xml wrong"

# (e) FAIL-SAFE gates ------------------------------------------------------------
# Stubs ARE on PATH here (cdn): a gate regression would run apply.sh and its
# aws calls would land in ARGV_LOG — so the emptiness assertion can really fail.
: > "${ARGV_LOG}"
out="$(cdn apply --provider aws-ec2 --out-dir "${AWSOUT}" --creds-file "${CREDS}")"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -s "${ARGV_LOG}" ] && echo "${out}" | grep 'not a TTY' >/dev/null \
    && ok "apply on a non-TTY refused AT THE GATE (fail-safe), no cloud call" \
    || { bad "apply on non-TTY did NOT fail-safe at the gate (rc=${rc})"; echo "${out}"; }
: > "${ARGV_LOG}"
out="$(cdn destroy --provider aws-ec2 --out-dir "${AWSOUT}" --creds-file "${CREDS}")"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -s "${ARGV_LOG}" ] && echo "${out}" | grep 'not a TTY' >/dev/null \
    && ok "destroy on a non-TTY refused AT THE GATE (fail-safe), no cloud call" \
    || { bad "destroy on non-TTY did NOT fail-safe at the gate (rc=${rc})"; echo "${out}"; }
# There is deliberately NO --yes flag on this driver.
out="$(cdd apply --provider aws-ec2 --out-dir "${AWSOUT}" --creds-file "${CREDS}" --yes)"; rc=$?
[ "${rc}" -ne 0 ] && ok "a --yes flag is rejected (no confirmation bypass exists)" || bad "--yes was ACCEPTED"
# The emitted script's OWN gate also refuses when run directly (outside the driver).
out="$(PATH="${STUB}:${PATH}" bash "${AWSOUT}/apply.sh" </dev/null 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -s "${ARGV_LOG}" ] && ok "emitted apply.sh re-confirms on its own TTY (direct run refused)" \
    || { bad "emitted apply.sh did NOT self-gate (rc=${rc})"; echo "${out}"; }

# (f) credentials custody --------------------------------------------------------
out="$(cdy apply --provider aws-ec2 --out-dir "${AWSOUT}")"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -s "${ARGV_LOG}" ] && ok "apply without --creds-file refused (provider requires creds)" \
    || { bad "apply without creds did NOT refuse (rc=${rc})"; echo "${out}"; }
LOOSE="${WORK}/loose-creds"; cp "${CREDS}" "${LOOSE}"; chmod 0644 "${LOOSE}"
out="$(cdy apply --provider aws-ec2 --out-dir "${AWSOUT}" --creds-file "${LOOSE}")"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -s "${ARGV_LOG}" ] && ok "apply with a 0644 creds file refused (0600 custody enforced)" \
    || { bad "loose-perms creds NOT refused (rc=${rc})"; echo "${out}"; }
out="$(cdy apply --provider generic-qcow2 --out-dir "${GENOUT}")"; rc=$?
[ "${rc}" -ne 0 ] && echo "${out}" | grep 'virt-install' >/dev/null && ok "generic-qcow2 apply refuses with the virt-install pointer (by design)" \
    || { bad "generic-qcow2 apply wrong (rc=${rc})"; echo "${out}"; }

# (g) apply/status/destroy against the recording stubs ---------------------------
# aws-ec2 apply: creds must be 0600 + present; the plan baked the creds PATH.
: > "${ARGV_LOG}"
out="$(cdy apply --provider aws-ec2 --out-dir "${AWSOUT}" --creds-file "${CREDS}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "aws-ec2 apply ran against the stub (rc=0)" || { bad "aws-ec2 apply failed (rc=${rc})"; echo "${out}"; }
grep -q "s3 cp ${IMG} s3://example-com-hugmesh-import/" "${ARGV_LOG}" && ok "argv: s3 upload of the image to the derived bucket" || { bad "argv missing s3 cp"; cat "${ARGV_LOG}"; }
grep -q 'ec2 import-snapshot' "${ARGV_LOG}" && grep -q 'S3Bucket=example-com-hugmesh-import' "${ARGV_LOG}" \
    && ok "argv: import-snapshot from the staged object" || bad "argv missing import-snapshot"
grep -q 'iam create-role --role-name vmimport' "${ARGV_LOG}" && ok "argv: vmimport role created from the emitted policy JSONs" || bad "argv missing vmimport create-role"
grep -q 'register-image' "${ARGV_LOG}" && grep -q -- '--boot-mode uefi' "${ARGV_LOG}" && grep -q -- '--ena-support' "${ARGV_LOG}" \
    && ok "argv: register-image with --boot-mode uefi --ena-support" || bad "argv register-image shape wrong"
grep -q 'secretpayload-never-argv' "${ARGV_LOG}" && bad "creds CONTENTS leaked into argv!" || ok "creds contents never touched argv (path-only custody)"
[ "$(cat "${AWSOUT}/state/ami-id" 2>/dev/null)" = "ami-0stub" ] && [ "$(cat "${AWSOUT}/state/snapshot-id" 2>/dev/null)" = "snap-0stub" ] \
    && ok "apply recorded the state hints (ami/snapshot ids)" || bad "state hints missing/wrong"
# status: prints the hints, calls NOTHING.
LOG_BEFORE="$(wc -l < "${ARGV_LOG}")"
out="$(PATH="${STUB}:${PATH}" cdd status --provider aws-ec2 --out-dir "${AWSOUT}")"
echo "${out}" | grep 'ami-0stub' >/dev/null && ok "status prints the recorded state hints" || { bad "status missing hints"; echo "${out}"; }
[ "$(wc -l < "${ARGV_LOG}")" = "${LOG_BEFORE}" ] && ok "status made NO cloud-CLI calls (read-only)" || bad "status CALLED a cloud CLI"
# destroy: teardown argv + hints cleared.
out="$(cdy destroy --provider aws-ec2 --out-dir "${AWSOUT}" --creds-file "${CREDS}")"; rc=$?
[ "${rc}" -eq 0 ] && grep -q 'deregister-image --image-id ami-0stub' "${ARGV_LOG}" && grep -q 'delete-snapshot --snapshot-id snap-0stub' "${ARGV_LOG}" \
    && ok "aws-ec2 destroy deregisters the AMI + deletes the snapshot" || { bad "aws-ec2 destroy argv wrong (rc=${rc})"; cat "${ARGV_LOG}"; }
[ ! -e "${AWSOUT}/state/ami-id" ] && ok "destroy cleared the state hints" || bad "destroy left stale state hints"

# azure-image apply: no creds required (existing az session model), stub az records.
: > "${ARGV_LOG}"
out="$(cdy apply --provider azure-image --out-dir "${AZOUT}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "azure-image apply ran against the stub (rc=0)" || { bad "azure-image apply failed (rc=${rc})"; echo "${out}"; }
grep -q 'az account show' "${ARGV_LOG}" && ok "argv: azure apply checks the EXISTING az session first" || bad "argv missing az account show"
grep -q 'az group create' "${ARGV_LOG}" && grep -q "storage blob upload" "${ARGV_LOG}" && grep -q -- '--hyper-v-generation V2' "${ARGV_LOG}" \
    && ok "argv: group create -> blob upload -> Gen2 image create" || { bad "azure argv chain wrong"; cat "${ARGV_LOG}"; }
grep -q -- '--service-principal' "${ARGV_LOG}" && bad "azure apply attempted a service-principal login (secret custody breach)" \
    || ok "argv: no credential-bearing az login ever issued"

# openshift-cnv apply: KUBECONFIG must be the creds PATH; dv before vm.
: > "${ARGV_LOG}"
out="$(cdy apply --provider openshift-cnv --out-dir "${OCOUT}" --creds-file "${CREDS}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "openshift-cnv apply ran against the stub (rc=0)" || { bad "openshift-cnv apply failed (rc=${rc})"; echo "${out}"; }
grep -q "KUBECONFIG=${CREDS}" "${ARGV_LOG}" && ok "argv: kubeconfig threaded by PATH only (KUBECONFIG env)" || bad "KUBECONFIG not threaded"
grep -n 'apply -f' "${ARGV_LOG}" | head -2 | tr '\n' ' ' | grep 'datavolume.yaml.*vm.yaml' >/dev/null \
    && ok "argv: datavolume applied before vm" || { bad "oc apply order wrong"; cat "${ARGV_LOG}"; }

# (h) unknown provider + missing plan dir ---------------------------------------
cdd plan --provider not-a-provider --out-dir "${WORK}/x" >/dev/null 2>&1 && bad "unknown provider was accepted" || ok "unknown provider rejected"
out="$(cdy apply --provider aws-ec2 --out-dir "${WORK}/never-planned" --creds-file "${CREDS}")"; rc=$?
[ "${rc}" -ne 0 ] && echo "${out}" | grep "run 'plan" >/dev/null && ok "apply without a prior plan refuses with guidance" || bad "apply without plan wrong (rc=${rc})"

# (i) Makefile OIDC_* seam (make -n proof; stack-ps has no prereqs) --------------
# THREE vars, one seam: OIDC_ISSUER overrides the derived issuer on the frozen
# CASDOOR_ISSUER_URI threading; OIDC_CLIENT_ID / OIDC_JWKS_URI (the Lane-B half)
# ride the equally-frozen CASDOOR_APP_CLIENT_ID / CASDOOR_JWKS_URI names. The
# two Lane-B vars must EXPAND TO NOTHING when empty — not to an empty
# assignment — so the compose `${VAR:-default}` fallbacks stay byte-identical
# AND an operator's own exported CASDOOR_* still reaches the containers.
if command -v make >/dev/null 2>&1; then
    def_out="$(make -s -n -C "${REPO}" stack-ps 2>/dev/null)"
    def="$(printf '%s' "${def_out}" | grep -o "CASDOOR_ISSUER_URI='[^']*'" | head -1)"
    [ "${def}" = "CASDOOR_ISSUER_URI='http://localhost:8000'" ] \
        && ok "Makefile default: STACK_ENV threads the derived Casdoor issuer" || bad "Makefile default issuer wrong: ${def}"
    printf '%s' "${def_out}" | grep "CASDOOR_APP_CLIENT_ID=\|CASDOOR_JWKS_URI=" >/dev/null \
        && bad "Makefile default STACK_ENV names CASDOOR_APP_CLIENT_ID/CASDOOR_JWKS_URI — empty must expand to NOTHING (compose fallbacks + operator env both depend on it)" \
        || ok "Makefile default: no client-id/JWKS assignment rides STACK_ENV (compose defaults untouched)"
    ovr="$(make -s -n -C "${REPO}" stack-ps OIDC_ISSUER=https://login.microsoftonline.com/tid/v2.0 2>/dev/null | grep -o "CASDOOR_ISSUER_URI='[^']*'" | head -1)"
    [ "${ovr}" = "CASDOOR_ISSUER_URI='https://login.microsoftonline.com/tid/v2.0'" ] \
        && ok "Makefile OIDC_ISSUER overrides the derived issuer in STACK_ENV" || bad "OIDC_ISSUER override failed: ${ovr}"
    lb_out="$(make -s -n -C "${REPO}" stack-ps \
        OIDC_ISSUER=https://login.microsoftonline.com/tid/v2.0 \
        OIDC_CLIENT_ID=app-mesh \
        OIDC_JWKS_URI=https://login.microsoftonline.com/tid/discovery/v2.0/keys 2>/dev/null)"
    cid="$(printf '%s' "${lb_out}" | grep -o "CASDOOR_APP_CLIENT_ID='[^']*'" | head -1)"
    [ "${cid}" = "CASDOOR_APP_CLIENT_ID='app-mesh'" ] \
        && ok "Makefile OIDC_CLIENT_ID threads as CASDOOR_APP_CLIENT_ID (BFF client id)" || bad "OIDC_CLIENT_ID threading failed: ${cid}"
    jwks="$(printf '%s' "${lb_out}" | grep -o "CASDOOR_JWKS_URI='[^']*'" | head -1)"
    [ "${jwks}" = "CASDOOR_JWKS_URI='https://login.microsoftonline.com/tid/discovery/v2.0/keys'" ] \
        && ok "Makefile OIDC_JWKS_URI threads as CASDOOR_JWKS_URI (gateway/resource-server key fetch)" || bad "OIDC_JWKS_URI threading failed: ${jwks}"
    emp_out="$(make -s -n -C "${REPO}" stack-ps OIDC_ISSUER= OIDC_CLIENT_ID= OIDC_JWKS_URI= 2>/dev/null)"
    emp="$(printf '%s' "${emp_out}" | grep -o "CASDOOR_ISSUER_URI='[^']*'" | head -1)"
    [ "${emp}" = "CASDOOR_ISSUER_URI='http://localhost:8000'" ] \
        && ok "Makefile empty OIDC_ISSUER leaves today's behavior byte-for-byte" || bad "empty OIDC_ISSUER changed behavior: ${emp}"
    printf '%s' "${emp_out}" | grep "CASDOOR_APP_CLIENT_ID=\|CASDOOR_JWKS_URI=" >/dev/null \
        && bad "explicitly-empty OIDC_CLIENT_ID/OIDC_JWKS_URI still emit an assignment (must expand to NOTHING)" \
        || ok "Makefile explicitly-empty OIDC_CLIENT_ID/OIDC_JWKS_URI expand to NOTHING"
else
    ok "make absent — OIDC_* seam proof skipped (covered on CI images with make)"
fi
# …and the compose side of the same seam (static greps — no make needed): the
# three gateways' JWT key fetch and hugmesh-api's JWKSETURI must READ the
# threaded name in the house ${VAR:-default} style (a hardcoded value silently
# strands the seam), and both login BFFs must read the threaded client id.
n_jwks="$(grep -c 'CASDOOR_JWKS_URI: ${CASDOOR_JWKS_URI:-http://casdoor:8000/.well-known/jwks}' "${REPO}/tests/stack/compose.local.yaml")"
[ "${n_jwks}" -ge 12 ] \
    && ok "compose.local.yaml: ${n_jwks} services (gateways included) read CASDOOR_JWKS_URI passthrough" \
    || bad "compose.local.yaml JWKS passthrough count dropped to ${n_jwks} (expected >=12 — a gateway went back to a hardcoded JWKS?)"
grep -q 'SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWKSETURI: ${CASDOOR_JWKS_URI:-http://casdoor:8000/.well-known/jwks}' "${REPO}/tests/stack/compose.local.yaml" \
    && ok "compose.local.yaml: hugmesh-api key fetch follows the same passthrough" \
    || bad "hugmesh-api JWKSETURI no longer reads CASDOOR_JWKS_URI"
n_cid="$(grep -c 'APP_BFF_OIDC_CLIENT_ID: ${CASDOOR_APP_CLIENT_ID:-app-user-bff}' "${REPO}/tests/stack/compose.local.yaml")"
[ "${n_cid}" -ge 2 ] \
    && ok "compose.local.yaml: admin-bff + user-bff read CASDOOR_APP_CLIENT_ID passthrough" \
    || bad "BFF client-id passthrough count dropped to ${n_cid} (expected >=2)"

# (j) I7 IdP passthrough ---------------------------------------------------------
# Default (casdoor): NO idp/ dir — the plan tree is byte-identical to pre-I7.
IDPDEF="${WORK}/out-idp-default"
cdd plan --provider aws-ec2 --image "${IMG}" --out-dir "${IDPDEF}" >/dev/null
[ ! -e "${IDPDEF}/idp" ] && ok "idp: casdoor default emits NO idp/ artifacts" || bad "idp: default unexpectedly emitted idp/"
# External entra: idp.conf lands with the Entra-specific JWKS default.
IDPOUT="${WORK}/out-idp-entra"
cdd plan --provider azure-image --image "${VHD}" --out-dir "${IDPOUT}" \
    --idp entra --idp-issuer https://login.microsoftonline.com/tid/v2.0 --idp-client-id app-mesh >/dev/null
grep -q '^provider=entra$' "${IDPOUT}/idp/idp.conf" \
    && grep -q '^issuer=https://login.microsoftonline.com/tid/v2.0$' "${IDPOUT}/idp/idp.conf" \
    && grep -q '^client_id=app-mesh$' "${IDPOUT}/idp/idp.conf" \
    && ok "idp: entra idp.conf carries provider/issuer/client_id" || bad "idp: entra idp.conf wrong: $(cat "${IDPOUT}/idp/idp.conf" 2>/dev/null)"
grep -q '^jwks_uri=https://login.microsoftonline.com/tid/v2.0/discovery/v2.0/keys$' "${IDPOUT}/idp/idp.conf" \
    && ok "idp: entra JWKS defaults to /discovery/v2.0/keys (NOT /.well-known/jwks)" || bad "idp: entra jwks default wrong"
# aws-ec2 + --idp aws: the cognito:groups claim-name note appears.
IDPAWS="${WORK}/out-idp-aws"
cdd plan --provider aws-ec2 --image "${IMG}" --out-dir "${IDPAWS}" \
    --idp aws --idp-issuer https://cognito-idp.us-east-1.amazonaws.com/pool-1 >/dev/null
grep -q 'cognito:groups' "${IDPAWS}/idp/README.md" \
    && ok "idp: aws-on-aws-ec2 README carries the cognito:groups claim note" || bad "idp: cognito note missing"
# Validation refusals — each must die BEFORE any emit.
cdd plan --provider aws-ec2 --out-dir "${WORK}/x1" --idp nonsense >/dev/null 2>&1 \
    && bad "idp: unknown --idp accepted" || ok "idp: unknown --idp refused"
cdd plan --provider aws-ec2 --out-dir "${WORK}/x2" --idp entra >/dev/null 2>&1 \
    && bad "idp: external without --idp-issuer accepted" || ok "idp: external without --idp-issuer refused"
cdd plan --provider aws-ec2 --out-dir "${WORK}/x3" --idp entra --idp-issuer http://insecure.example >/dev/null 2>&1 \
    && bad "idp: http:// issuer accepted" || ok "idp: non-https issuer refused"
cdd plan --provider aws-ec2 --out-dir "${WORK}/x4" --idp-issuer https://x.example >/dev/null 2>&1 \
    && bad "idp: issuer with casdoor default accepted" || ok "idp: --idp-issuer without external --idp refused"
[ ! -e "${WORK}/x1/idp" ] && [ ! -e "${WORK}/x2/idp" ] && ok "idp: refused plans emitted nothing" || bad "idp: a refused plan left artifacts"

echo
echo "== cloud-deploy wizard test: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
