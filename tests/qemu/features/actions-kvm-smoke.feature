# QEMU on a GitHub-hosted runner, as BDD — the 2026-11-04 TRIAL.
#
# EXECUTED, not decoration. tests/qemu/actions-kvm-smoke_test.sh is the runner:
# it parses THIS file, dispatches every Given/When/Then line to a step
# definition, and FAILS a scenario on any step it has no definition for. It is
# not the tests/e2e playwright-bdd lane on purpose: that lane needs
# tests/e2e/node_modules and a chromium, and nothing here touches a browser.
# The pairing is recorded in ALLOW_UNCOMPILED in
# tests/scripts/test-e2e-gherkin-harness.sh, which fails if either half vanishes.
#
# The image is a STOCK Alpine 'virt' ISO, pinned by URL and sha256 in
# .github/workflows/qemu-bdd-spike.yml. It is not a hugmesh image and carries no
# hugmesh key; this trial measures the RUNNER, not our build.
#
# Machine shape matches tests/qemu/launch-x86.sh: q35 + OVMF/UEFI, with a
# per-run copy of OVMF_VARS. Scenarios tagged @tcg run only under --tcg.

Feature: A tiny stock x86 image boots under KVM on a GitHub-hosted runner

  Background:
    Given the pinned image is present and matches its pinned sha256

  Scenario: KVM is available to the runner
    Given the host exposes /dev/kvm as a character device
    Then the runner user can open /dev/kvm for reading and writing
    And the CPU advertises hardware virtualisation
    And qemu-system-x86_64 starts a machine with -accel kvm

  Scenario: a tiny x86 image boots under KVM to a login prompt on serial within 90 seconds
    When the image is booted with -accel kvm on q35 with UEFI firmware and a serial log
    Then the serial console shows a login prompt within 90 seconds
    And the boot time is recorded as "kvm"

  Scenario: the boot is accelerated (KVM in use, not TCG)
    Given the guest from the previous scenario is still running under "kvm"
    When the QEMU monitor is asked "info kvm"
    Then the monitor answers "kvm support: enabled"

  # The comparison run, and the NEGATIVE CONTROL for the scenario above: the
  # same assertion machinery must read "disabled" when acceleration is off, or
  # an "enabled" answer proves nothing.
  @tcg
  Scenario: the same boot forced to TCG, for comparison
    When the image is booted with -accel tcg on q35 with UEFI firmware and a serial log
    Then the serial console shows a login prompt within 900 seconds
    And the boot time is recorded as "tcg"
    When the QEMU monitor is asked "info kvm"
    Then the monitor answers "kvm support: disabled"
