# THE OWNCAST RUNTIME LANE IS UNDRIVABLE BY ANY SEEDED IDENTITY. MEASURED.
#
# The mining pass proposed three driven owncast features — the player's four
# states, the fail-closed visibility flips, and the null-playbackUrl-on-deny leg.
# All three premises hold in the source. None of the three can be driven, and the
# reason is not "the stack is down":
#
#   hugmesh-owncast-bff-api SecurityConfig:
#       /bff/owncast/user/**  ->  hasRole("OWNCAST")
#   and its roleHierarchy() declares only
#       ROLE_SUPERADMIN > ROLE_ADMIN | ROLE_MOD | ROLE_USER
#
# There is NO edge to ROLE_OWNCAST. So the streamer surface is closed to every
# persona in both rosters INCLUDING the superadmin — this is not the usual "drive
# it as an admin instead" situation the console features use, because no admin
# reaches it either. features/uncovered-services/access-role-roster.feature
# already pins that nothing seeds ROLE_OWNCAST; this file records what that gap
# COSTS, in the same run output as the coverage it blocks.
#
# The owncast-ui player states are blocked one layer earlier still: /owncast/stream
# is behind owncastStreamGuard, so a persona without the role is redirected to
# /owncast/forbidden and the player never mounts at all.
#
# WHY THESE ARE PENDING SCENARIOS AND NOT A COMMENT. A comment cannot fail. Seed
# `e2e-owncast:ROLE_OWNCAST,ROLE_USER:E2E_OWNCAST_PASSWORD` and
# access-role-roster.feature's owncast row goes red on the same day; that is the
# prompt to come back here and write the bodies described below, which are already
# specified against verified line-level behaviour.
#
# The OFFLINE half of the owncast rule — the dark-by-default playback template —
# is NOT pending. It runs today: see owncast-media-dark.feature.
#
# *** HARNESS TRAP, MEASURED HERE ON 2026-08-26 — DO NOT REPEAT IT ***
# This file carries NO @fixme tag, deliberately. playwright-bdd emits NOTHING at
# all for a .feature in which EVERY scenario is @fixme: `npx bddgen` still exits
# 0, .features-gen gains no spec for the file, and its scenarios never appear in
# --list. A silent zero that looks exactly like coverage. Measured three ways:
# @fixme on the Feature line -> 0 specs; @fixme on all N scenarios -> 0 specs;
# @fixme on 1 of 3 scenarios -> 1 test.fixme + 2 test(), file generated. That is
# why features/uncovered-services/console-discovery.feature (6 pending rows + 1
# real one) works and a file of pure pending rows does not.
# The PENDING idiom that DOES work everywhere is the step, not the tag:
#   Given this scenario is PENDING because "<reason>"
# which calls $testInfo.skip() and PRINTS the reason — strictly more evidence
# than the tag ever gave. Use the step; add @fixme only when the file also holds
# at least one scenario that really runs.
# The tag also skips a test BEFORE its first step runs, so the PENDING step never
# executes and the skip lands in report.json with an EMPTY reason — a silent skip
# wearing a tag. Measured in this lane's own run5 report.
#
@service:owncast @layer:bff
Feature: The owncast runtime scenarios, pending an identity that can drive them

  Scenario: PENDING (nothing seeds ROLE_OWNCAST) — the player reports offline, buffering, failed and unsupported-browser @role:e2e-admin @service:owncast @layer:ui
    Given this scenario is PENDING because "owncast-ui's /owncast/stream route is behind owncastStreamGuard and the BFF behind it gates /bff/owncast/user/** on hasRole('OWNCAST'), whose roleHierarchy carries no SUPERADMIN edge — so NO persona in either roster, admin and superadmin included, can mount the player. The four states are real and testable the day one exists: owncast-stream.component.ts attachPlayer sets playerLoading and only MANIFEST_PARSED clears it; the hls.js ERROR leg and the native <video> error leg land on the SAME sentence 'The stream player could not load this stream.'; and with neither hls.js nor native HLS the component says 'In-platform playback is not supported by this browser.' The four test ids exist today: owncast-stream-player-empty, -player-loading, -player-error, and owncast-stream-video-el. DESIRED: seed e2e-owncast:ROLE_OWNCAST,ROLE_USER, then drive the four states with page.route interception of the manifest (never-responds / 404 / 500) plus an addInitScript that deletes window.Hls and stubs HTMLMediaElement.prototype.canPlayType to '' for the unsupported-browser row — a Chromium-only run reaches that branch never, so it must be forced."
    Then the element with test id "owncast-stream-player-empty" is visible

  Scenario: PENDING (nothing seeds ROLE_OWNCAST) — a new stream is born internal and cannot be flipped public without a live grant @role:e2e-admin @service:owncast @layer:bff
    Given this scenario is PENDING because "PUT /bff/owncast/user/stream needs ROLE_OWNCAST, which nothing seeds and no role hierarchy edge supplies. The behaviour is verified in OwncastStreamService: a first upsert inserts VISIBILITY_INTERNAL ('a new stream is never born public'); a flip to public consults broadcastGuard.assertCanBroadcast and a flip to internal never does; a flip against a stream that does not exist is 404 rather than an implicit create. CORRECTION TO THE MINING PASS, verified in source: OwncastStream.normalizeVisibility does raw.trim().toLowerCase() BEFORE comparing, so 'PUBLIC' normalizes to public and is refused 403 by the grant gate, NOT 400 — the proposed 400 row for 'PUBLIC' was wrong and would have pinned a behaviour the code does not have. The 400 cases are 'unlisted' (normalizes to null) and the empty string (@NotBlank on the request record)."
    Then the element with test id "owncast-stream-current-visibility" is visible

  Scenario: PENDING (nothing seeds ROLE_OWNCAST) — a gate-denied caller gets the stream metadata with a null playbackUrl @role:e2e-admin @service:owncast @layer:bff
    Given this scenario is PENDING because "GET /bff/owncast/user/stream needs ROLE_OWNCAST. OwncastStreamService.fillPlaybackUrl swallows ONLY the broadcast guard's 403 into 'no URL' (any other error, e.g. a 401, still propagates so an unexpected failure is never masked), so a denied caller gets the stream with playbackUrl absent and never learns the media endpoint exists. This ALSO needs owncast.playback.url-template configured, which the generator deliberately never sets — see owncast-media-dark.feature, the offline half of this same rule, which DOES run today. Driving this row therefore needs both a seeded ROLE_OWNCAST persona AND an opted-in stack: OWNCAST_PLAYBACK_URL_TEMPLATE set on the owncast BFF."
    Then the element with test id "owncast-stream-title" is visible
