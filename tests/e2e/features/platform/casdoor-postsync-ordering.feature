# WHAT THIS ASSERTS — hugmesh-generator#396, fixed by PR #401 (merged d02aa325,
# 2026-09-17; re-checked on origin/main 9f4d6d30, 2026-09-23).
#
# `make kind-up` exited 1 on a cluster that then converged BY ITSELF 7m37s
# later. specs/cluster/manifests/casdoor shipped FOUR ArgoCD PostSync hook Jobs
# that all log in as the ONE built-in/admin account, with no sync-wave between
# them: the three derived-role syncs know only the Vault-provisioned password,
# which cannot be right until casdoor-init has taken the account over from
# casdoor's bootstrap default, so ArgoCD started all four at once and the three
# guaranteed-wrong logins tripped casdoor's 5-attempt / 15-minute sign-in
# throttle 2.3 s in. Measured spend on that run: 104 wrong attempts across 111
# logins, casdoor-init's CORRECT login refused inside the ban.
#
# Four properties landed and every one is pinned here, offline, by reading the
# committed manifests and the bring-up script — the same artefacts ArgoCD and
# `make kind-up` consume, so the pin cannot drift from what deploys:
#   1. casdoor-init is wave 0 and every Job sharing its admin Secret is a LATER
#      wave (a derived property, so a fifth sibling with no wave goes red);
#   2. the takeover Job ENDS on casdoor's throttle (exit 75 -> podFailurePolicy
#      FailJob, restartPolicy Never) instead of replaying the ban backoffLimit+1
#      times, which is what turned a self-clearing lockout into a permanent one;
#   3. the bring-up restarts casdoor-init by applying init-job.yaml ALONE —
#      `kubectl apply -k` honours no sync-wave, so re-applying the directory
#      re-created the same four-way race by hand (#401 item 5);
#   4. the bring-up waits LONGER than casdoor's own 900 s lockout (600 s
#      expired while the cluster was merely serving out a ban it recovered from).
#
# The mutation battery for the same contract is tests/scripts/test-casdoor-login-
# budget.sh (31 checks; 9/22 on the pre-fix tree). It is NOT run from here: it
# mutates a staged copy of the tree, which is not a scenario's business. These
# scenarios are the executable index of the property; that script is the guard.
#
# STILL OPEN FOR A HUMAN (from the issue, unchanged): the 5-attempt / 15-minute
# constants are inferred from the log, not read from casdoor-pg; and only a
# genuinely fresh `make kind-up` proves the bring-up now converges inside its
# wait. Neither is expressible offline, and there is no kind cluster today.
#
# THIS RUNS OFFLINE. Both sources are files in THIS repository; nothing here can
# skip and nothing here needs a cluster.
@layer:casdoor @issue:generator-396
Feature: The casdoor PostSync Jobs are wave-ordered, not racing the same admin account

  Background:
    Given the casdoor manifest Jobs are loaded

  Scenario Outline: <job> is a PostSync hook at sync-wave <wave> @layer:casdoor
    Then the casdoor manifest job "<job>" is an ArgoCD PostSync hook at sync-wave "<wave>"

    Examples:
      | job                        | wave |
      | casdoor-init               | 0    |
      | games-admin-sync           | 1    |
      | games-services-admin-sync  | 1    |
      | games-services-runner-sync | 1    |

  # The DERIVED form of the table above: it is not "these three are wave 1" but
  # "every Job that opens a session with the admin Secret runs strictly after the
  # one that owns the takeover". A new sync Job that mounts casdoor-admin and
  # forgets its wave fails here by construction, without anyone editing a row.
  Scenario: every Job sharing the admin Secret runs strictly after the takeover @layer:casdoor
    Then every casdoor Job mounting the "casdoor-admin" Secret other than "casdoor-init" sits in a later sync-wave than it

  # The skeptic's MAJOR on #396: sync-waves fix the fresh-cluster path but not
  # the password-drift path, where casdoor-init ALONE self-locks in three runs
  # (2+2+2 >= 5) and the pod backoff then replays the ban forever. reconcile.py
  # exits 75 and ONLY 75 for "the throttle is refusing every login"; the Job
  # must end on it, not restart into it.
  Scenario: a throttled takeover stops the Job instead of replaying the ban @layer:casdoor
    Then the casdoor Job "casdoor-init" fails the whole Job on container exit code 75 and never restarts its pod

  # Item 5 of the fix, found while fixing item 1: `recreate_job` used to
  # `kubectl apply -k` the WHOLE casdoor directory to restart one Job. Once
  # ttlSecondsAfterFinished has reaped the three wave-1 Jobs, that apply
  # re-creates all four at once — the identical race, immune to the annotation.
  Scenario: the bring-up restarts the takeover alone and outwaits the lockout @layer:casdoor
    Then the kind bring-up re-applies only "init-job.yaml" when it restarts the "casdoor-init" Job
    And the kind bring-up waits 1200 seconds for the "casdoor-init" Job, longer than the 900 second casdoor lockout
