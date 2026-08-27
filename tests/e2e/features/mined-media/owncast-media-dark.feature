# THE OWNCAST MEDIA ENDPOINT IS DARK BY DEFAULT, ON BOTH SIDES.
#
# hugmesh-owncast-bff-api ships `owncast.playback.url-template: "${OWNCAST_PLAYBACK_URL_TEMPLATE:}"`
# — an env placeholder with an EMPTY default. OwncastPlaybackUrlResolver.resolve()
# returns null on an empty template, and OwncastStreamService.fillPlaybackUrl
# swallows the broadcast guard's 403 into "no URL" rather than propagating it, so
# a caller the view gate denies gets the stream metadata with playbackUrl absent
# and never learns the media endpoint exists.
#
# Neither half is asserted anywhere: grep 'playbackUrl' / 'm3u8' / 'hls' across
# this suite returns 0, and across owncast-ui's own twelve .feature files it also
# returns 0.
#
# THE HALF WORTH HAVING TODAY IS THE CONFIG HALF, and it is the reason this
# feature is @harness rather than driven: it is a rendered-artefact assertion
# that runs with every environment down. The one colon in "${VAR:}" is the entire
# dark-by-default posture; "${VAR:https://…}" would ship every mesh a live media
# endpoint, and nothing else in the estate would notice.
#
# The DRIVEN half of this rule lives in owncast-runtime.feature, where it is
# PENDING for a reason that is measured, not assumed — see that file's header.
#
# TIER NOTE. The second and third scenarios read the SERVICE SOURCE in the
# sibling hugmesh-owncast-bff-api checkout, which is not part of this repo. When
# that checkout is absent the scenario SKIPS naming SNAP_FLEET_ROOT and the repo;
# when it is present, a missing file is a hard failure, never a skip. The FIRST
# scenario reads only this repo and therefore always runs.
@harness @service:owncast @layer:gateway
Feature: The Owncast media endpoint is dark by default and never leaks on deny

  # In-repo. Always runs.
  Scenario: nothing this generator deploys turns the in-platform player on @harness @service:owncast @layer:gateway
    Then no generator manifest sets the environment variable "OWNCAST_PLAYBACK_URL_TEMPLATE"

  Scenario: the playback template ships UNSET, so an un-opted-in mesh has no in-platform player @harness @service:owncast @layer:gateway
    Then the owncast bff config declares "owncast.playback.url-template" as an empty-defaulted env placeholder

  Scenario: a blank template resolves to no URL for any (domain, subject) @harness @service:owncast @layer:gateway
    Then the owncast playback resolver returns nothing when its template is empty
