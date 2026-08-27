# SERVICE axis for the onboarding domain — stack-free, @harness.
#
# Every navigating step in this domain resolves its target through
# steps/dimensions.ts SERVICES, which refuses to hand back a path for a service
# nobody has PINNED against a live stack. That refusal is the whole point: an
# invented route 404s into a blank page, and a blank page satisfies far too many
# assertions ("the heading is not visible", "the error is not shown", …). This
# feature asserts the surfaces the onboarding features actually drive are still
# pinned, so a service being un-pinned fails HERE — offline, by name — instead of
# turning a live scenario green against an empty document.
#
# Only services this domain drives are listed. owncast / tube / wiki /
# character-studio are deliberately ABSENT: they carry pinned:false today (zero
# e2e coverage anywhere in the repo) and asserting them pinned would be a row the
# code cannot honour. Pinning them is another unit's work.
@harness @layer:gateway
Feature: The surfaces the onboarding journey drives are pinned, not guessed

  Scenario Outline: the <service> surface is pinned @service:<service> @layer:gateway
    Then the service named by the service dimension has a pinned surface

    Examples:
      | service |
      | login   |
      | admin   |
      | gateway |
      | tuwunel |
      | akkoma  |
