# C-STYLE — header and footer text cannot add stylesheet rules
# (hugmesh-generator#654, decision D19).
#
# WHAT IS DRIVEN: the Studio's stylesheet writer (hugmesh_studio.core.theme
# chrome_css) in a FRESH python process, handed the text an operator could type
# into the header or footer box of the brand design step. The text is hostile on
# purpose: a form feed (which CSS reads as a newline, so an unescaped one ends
# the string), a closing brace (which would end the rule) and url(https://x)
# (which, outside a string, would fetch from anywhere).
#
# The assertions read the rendered stylesheet the way a CSS tokenizer does:
# every string literal is removed — ending at its quote or, as a bad string, at
# the first unescaped LF/CR/FF — and what is left must hold ONE rule block and
# no url(. Looking for the text in the output would pass for the wrong reason:
# the text is SUPPOSED to be there, inside the string.
#
# OFFLINE and Qt-free: the writer is pure Python. No mesh, no browser.
@interface:cli @issue:generator-654
Feature: Header and footer text cannot add stylesheet rules

  Scenario Outline: hostile <surface> text adds no rule and no url(
    When I render the Studio brand chrome with the "<surface>" text "a form feed, a closing brace and url(https://x)"
    Then the command succeeded
    And the rendered stylesheet holds exactly 1 rule block
    And outside its string literals the rendered stylesheet has no "url("
    And outside its string literals the rendered stylesheet has no "background"
    And the rendered stylesheet declares the "<surface>" content exactly once
    And the rendered stylesheet carries no raw control character

    Examples:
      | surface |
      | header  |
      | footer  |
