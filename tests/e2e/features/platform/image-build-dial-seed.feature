# WHAT THIS IS FOR — hugmesh-admin-bff-api#53 (and its generator half,
# hugmesh-generator#368): no real image build has ever produced a
# device_ssh_dial row. Measured on 2026-09-16 and re-checked against
# origin/main on 2026-09-23 (nothing has changed on either side since):
#   * docker/build-image.sh sets K8S_SECRET_NAME="" and never assigns it, so
#     every ingest carries "k8sSecretName": null;
#   * device_ssh_dial.k8s_secret_name is NOT NULL (changelog 170), so
#     ImageBuildService.seedDial's INSERT violates it and the onErrorResume
#     swallows the failure at WARN while the build stays COMPLETED;
#   * ImageBuildIngestNonSecretTest INVENTS the value ("image-gen-dial-" + id)
#     in its ingest body — the harness supplies what the producer lacks, which is
#     the masking mechanism the issue names.
#
# WHY THIS IS PENDING AND NOT @fixme. The issue lays out two MUTUALLY EXCLUSIVE
# resolutions and says so — (a) build-image.sh reports
# K8S_SECRET_NAME=image-gen-dial-${BUILD_ID}, or (b) seedDial derives the pointer
# server-side from the build id (removing the trust-boundary echo but changing
# the ImageBuildIngestRequest contract) — plus an undecided key-file mismatch
# (the Job's Secret key is dial_private_key, the BFF's default is id_dial). The
# operator's comment split the halves across #368 and #53 and left both
# decisions open. A @fixme scenario must assert the CORRECT behaviour so it goes
# green the day the fix lands; here the correct behaviour is not yet decided, so
# any Then written today would be a guess that turns green only under one of the
# two shapes. The step below skips WITH the reason, executes as a scenario in
# --list, and carries the issue tag, so the gap is visible rather than a comment.
#
# WHAT WOULD CLOSE IT once decided: a real device-license build
# (docker/build-image.sh, x86 or rpi5, with the dial Secret mounted) followed by
# a read of the device_ssh_dial row for that build carrying a non-null
# k8s_secret_name — an @env:kind, @interface:cli smoke heavier than the PR-gated
# lane, exactly as the survey planned it. There is no kind cluster today.
@layer:bff @issue:admin-bff-api-53
Feature: A real image build seeds a device_ssh_dial row with a non-null k8s_secret_name

  Scenario: PENDING (operator decision) — a real device-license build seeds a dial row a device can use @layer:bff
    Given this scenario is PENDING because "hugmesh-admin-bff-api#53 / hugmesh-generator#368 are undecided between two mutually exclusive shapes: (a) docker/build-image.sh reports K8S_SECRET_NAME=image-gen-dial-${BUILD_ID} in its ingest, or (b) ImageBuildService.seedDial derives the pointer server-side from the build id and the ingest contract drops the field. Measured 2026-09-23 on both origin/mains: build-image.sh still sets K8S_SECRET_NAME=\"\" and never assigns it; seedDial still passes it through blankToNull into a NOT NULL column and swallows the violation at WARN; and the build Job's Secret key (dial_private_key) still differs from the BFF's key-file default (id_dial). The proof is a REAL device-license build on the kind lane followed by a read of the device_ssh_dial row for that build carrying a non-null k8s_secret_name — write that scenario against whichever shape the operator picks, and delete this Given."
