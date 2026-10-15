# C-GOLIVE-REFUSE — a Tor address is never tripped as a public flip
# (hugmesh-generator#654, decision D12).
#
# WHAT IS DRIVEN: the REAL device driver, specs/usr/sbin/hugmesh-go-live, against
# a scratch device configuration folder (the driver's GL_ETC_HUGMESH seam — never
# /etc). 'commit' is the one verb that flips a device public: it writes the
# go-live marker and hugmesh-firewall-reconcile then opens ports 80 and 443.
# A .onion is served outbound by the node's own Tor daemon and is reachable with
# the firewall closed, so for a Tor address that flip is a mistake the driver
# must refuse — with the sentence the operator reads everywhere else.
#
# The second scenario is the CONTROL: a public provider still commits, so the
# first scenario is red for the right reason (the onion's mechanism), not because
# commit broke for everyone. tests/go-live/test-onion-refuse.sh carries the
# front-end legs (guided CLI through a pty, console menu) and the mutation
# battery; this feature is the end-to-end record of the device-side decision.
#
# OFFLINE. No mesh, no tor, no root; every step runs in seconds with everything
# down, which is why there is no @env: tag.
@interface:cli @issue:generator-654
Feature: A Tor address is never tripped as a public flip

  Scenario: the device driver refuses to commit a Tor address and the device stays internal
    Given a scratch device configuration folder for the go-live driver with the domain "mesh.example"
    When I run the go-live driver against it with "commit --provider tor-onion -y"
    Then the command failed
    And the command output contains "A Tor address needs no public flip."
    And the scratch device configuration holds no go-live marker
    And the go-live driver reports the posture "internal" for it

  Scenario: the refusal is the Tor address's own — a public provider still commits
    Given a scratch device configuration folder for the go-live driver with the domain "mesh.example"
    When I run the go-live driver against it with "commit --provider byo-domain -y"
    Then the command succeeded
    And the scratch device configuration holds a go-live marker
    And the go-live driver reports the posture "public" for it
