# EVERY UPLOAD SURFACE SERVES UNTRUSTED BYTES WITH SOME POSTURE. THE THREE IN
# THIS ESTATE DO NOT AGREE, AND THE DISAGREEMENT IS THE CONTRACT.
#
#   profile-avatar   (hugmesh-user-bff-api ProfileController)
#       the bytes must SNIFF to a real raster (ImageSniffer, which deliberately
#       reports SVG as null); the SNIFFED type is stored and served; nosniff +
#       default-src 'none' + no-store on the serve.
#
#   character-part   (hugmesh-user-bff-api CharacterPartController)
#       an SVG is SANITIZED, stored PENDING and served under a SERVER-FIXED
#       image/svg+xml with default-src 'none'; style-src 'unsafe-inline'; sandbox,
#       nosniff, and Content-Disposition: inline.
#
#   wiki-attachment  (hugmesh-wiki-bff-api WikiAttachmentController)
#       the CLIENT-declared Content-Type is stored verbatim and echoed back on
#       download. No sniff, no allowlist, no Content-Disposition, no CSP.
#
# The first two are two halves of ONE deliberate rule: an SVG may never become a
# raster identity image, but it may become a sanitized, sandboxed character part.
# The third is the odd one out.
#
# WHY THE COMPARISON IS THE ASSERTION. Each posture is individually defensible;
# nothing anywhere states that they are meant to DIFFER. A future "let's just
# accept SVG avatars too" change would touch one file, pass that repo's tests, and
# reopen the stored-XSS gap ProfileController's own javadoc names. This outline
# reads all three controllers in one scenario so neither end can drift alone.
#
# The three values are DERIVED from the source, not tabulated here: the step
# resolves exactly one of server-sniffed / server-fixed / client-declared by which
# signature the controller actually carries, so a surface that grows a sniff — or
# loses one — flips the answer instead of quietly keeping the label.
#
# ON THE WIKI ROW'S BLAST RADIUS, stated so nobody reads more alarm into it than
# is there: upload is WIKI_WRITE (ADMIN/SUPERADMIN) and download is
# WIKI_READ_AUTHENTICATED, so this is an admin-to-reader vector, not an anonymous
# one. The global nosniff (SecurityConfig) does not help, because the type is
# EXPLICIT rather than sniffed.
#
# TIER: fleet-source (the three controllers live in sibling checkouts). Absent
# fleet root -> a skip naming SNAP_FLEET_ROOT; present fleet root + missing file
# -> a hard failure.
@harness @layer:bff
Feature: Every upload surface serves untrusted bytes with a stated posture

  Scenario Outline: the <surface> path takes its served type from <type_source> @service:<svc> @layer:bff
    Then the "<surface>" upload path takes its served Content-Type from "<type_source>"

    Examples:
      | surface         | svc              | type_source     |
      | profile-avatar  | character-studio | server-sniffed  |
      | character-part  | character-studio | server-fixed    |
      | wiki-attachment | wiki             | client-declared |

  Scenario Outline: the <surface> path serves stored bytes with <header> <expected> @service:<svc> @layer:bff
    Then the "<surface>" upload path serves stored bytes with the "<header>" header "<expected>"

    Examples:
      | surface         | svc              | header                  | expected     |
      | profile-avatar  | character-studio | Content-Security-Policy | default-src  |
      | profile-avatar  | character-studio | X-Content-Type-Options  | nosniff      |
      | profile-avatar  | character-studio | Content-Disposition     | absent       |
      | character-part  | character-studio | Content-Security-Policy | sandbox      |
      | character-part  | character-studio | X-Content-Type-Options  | nosniff      |
      | character-part  | character-studio | Content-Disposition     | inline       |
      | wiki-attachment | wiki             | Content-Security-Policy | absent       |
      | wiki-attachment | wiki             | Content-Disposition     | absent       |

  # The branch that actually bites, stated executably so closing it costs nothing.
  @role:e2e-admin @service:wiki @layer:bff
  # NO @fixme TAG, deliberately — MEASURED, not stylistic. Playwright skips a
  # @fixme test BEFORE its first step runs, so the PENDING step never executes and
  # the skip lands in report.json with an EMPTY reason: a silent skip wearing a
  # tag. The step alone skips with the whole paragraph below printed. (@fixme has
  # a second trap too: a .feature in which EVERY scenario carries it generates
  # nothing at all — bddgen still exits 0 and the file simply never appears.)
  Scenario: PENDING (WikiAttachmentController trusts the client Content-Type) — an HTML attachment is served as a download @role:e2e-admin @service:wiki @layer:bff
    Given this scenario is PENDING because "uploadAttachment stores filePart.headers().getContentType() verbatim and downloadAttachment echoes it through ResponseEntity.contentType(MediaType.parseMediaType(a.mimeType())). A writer uploading bytes declared text/html gets them served back as text/html on the platform origin, with no Content-Disposition and no CSP; the global nosniff does not help because the type is EXPLICIT rather than sniffed. Bounded: upload is WIKI_WRITE (ADMIN/SUPERADMIN), download is WIKI_READ_AUTHENTICATED — admin-to-reader, not anonymous. DESIRED: either an allowlist+sniff mirroring ImageSniffer, or Content-Disposition: attachment plus default-src 'none' on the download; then the two 'absent' wiki rows above become 'attachment' and 'default-src' and this scenario asserts the live download header."
    Then the "wiki-attachment" upload path serves stored bytes with the "Content-Disposition" header "attachment"
