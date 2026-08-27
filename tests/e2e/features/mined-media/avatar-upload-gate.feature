# THE PROFILE-PICTURE UPLOAD TRUSTS BYTES, NEVER THE DECLARED TYPE.
#
# The central suite covers the STICKER magic-byte gate
# (features/moderation-media/sticker-character-vn.feature: kinds svg and
# oversize-png -> 400). It has never touched the AVATAR path: grep 'profile/avatar'
# across features/, steps/ and specs/ returns zero. That path is a SECOND,
# separately-implemented gate with an extra branch and a different cap, and it is
# the one that decides what an identity image may be.
#
# FOUR DISTINCT BRANCHES in ProfileController.uploadAvatar, in the order they
# fire — each with its own message, which is why the message fragment is asserted
# rather than just the status:
#
#   text-plain     the header does not even claim image/*   (no bytes are read)
#   svg            claims image/svg+xml; ImageSniffer reports null by design
#   html-polyglot  claims image/png; the bytes are markup   (the stored-XSS gap)
#   oversize-png   real PNG magic bytes, 5 MB + 1 payload   (the cap, at the join)
#
# The accept row is the mirror image and is the property a header-trusting
# refactor would break while every reject row stayed green: real PNG bytes
# uploaded under a LYING image/gif header are accepted and served as image/png.
#
# THE THIRD SCENARIO IS A NAMED, FIXED, USER-VISIBLE REGRESSION. /bff/user/profile/
# avatar/body is the SAME URL for every user — the owner comes from the JWT, never
# the path — and the browser HTTP cache is keyed by URL alone: it neither varies on
# the session cookie nor is emptied by sign-out. The old `private, max-age=300`
# therefore served the PREVIOUS account's face after a switch with no request
# leaving the browser, surviving full reloads until the cache was cleared by hand
# (operator report 2026-08-19, "need to clear cache every time after log out").
# One line holds it shut: CacheControl.noStore(). grep 'no-store' across this
# suite returns zero.
#
# THE SECOND SCENARIO IS THE ASYMMETRY, driven with the SAME payload in both
# directions in ONE scenario: the same script-bearing SVG must be REFUSED as an
# avatar and SANITIZED-and-PENDING as a character part. Each half exists somewhere;
# nothing asserts they are two halves of one rule, so "let's just accept SVG
# avatars too" would touch one file and pass that repo's tests.
#
# NEEDS A MESH. Tagged @env:docker, so world.ts's Before hook probes the door with
# a real request and SKIPS NAMING `make stack-up ENV=test` when nothing answers.
# It never passes against a dead mesh.
@service:character-studio @layer:bff @env:docker @interface:browser
Feature: The profile-picture upload trusts bytes, never the declared type

  Scenario Outline: an avatar payload of kind <kind> is rejected with HTTP 400 @role:e2e-user @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I upload an avatar of kind "<kind>"
    Then the avatar upload was rejected with HTTP 400
    And the avatar upload reject reports "<reason>"
    And my profile still carries no avatar url

    Examples:
      | kind          | reason                  |
      | text-plain    | Content-Type image/*    |
      | svg           | magic-byte check failed |
      | html-polyglot | magic-byte check failed |
      | oversize-png  | 5MB limit               |

  Scenario: a real PNG is accepted and the SNIFFED type is what gets stored @role:e2e-user @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I upload an avatar of kind "valid-png" declaring the content type "image/gif"
    Then the avatar upload was accepted
    And my stored avatar body is served as "image/png"

  Scenario: the same script-bearing SVG is refused as an avatar and sanitized as a part @role:e2e-user @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I upload an avatar of kind "svg"
    Then the avatar upload was rejected with HTTP 400
    And the avatar upload reject reports "magic-byte check failed"
    When I save a character part whose SVG carries a script tag
    Then the character part was stored PENDING with the script stripped
    And the served part SVG is sanitized and typed as SVG
    And the served part SVG carries the header "Content-Security-Policy" containing "sandbox"
    And the served part SVG carries the header "X-Content-Type-Options" equal to "nosniff"
    And the served part SVG carries the header "Content-Disposition" equal to "inline"

  Scenario: the avatar body forbids storage and locks its own type @role:e2e-user @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I upload an avatar of kind "valid-png"
    Then the avatar upload was accepted
    And the avatar body response carries the header "Cache-Control" containing "no-store"
    And the avatar body response carries the header "X-Content-Type-Options" equal to "nosniff"
    And the avatar body response carries the header "Content-Security-Policy" equal to "default-src 'none'"
