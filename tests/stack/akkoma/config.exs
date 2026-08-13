# Local test-stack overrides for Akkoma.
#
# The image bakes /etc/pleroma/config.exs and ends it with
#   if File.exists?("/var/lib/pleroma/config.exs"), do: import_config(...)
# so this file is imported LAST and therefore wins over the baked defaults.
# It is bind-mounted read-only over that path (see compose.alt-social.yaml).
import Config

# REQUIRED — the container CRASHES ON BOOT without it, with
#   ** (ArgumentError) No base_url set for uploads - please set one in your config!
# raised from Pleroma.Config.DeprecationWarnings.check_uploader_base_url_set/0.
# Akkoma 3.x made this a hard failure rather than a warning, and the image's
# baked config does not set it, so an otherwise-correct compose service exits 1
# immediately. Upstream recommends a SEPARATE media domain in production
# (user-uploaded HTML/JS is same-origin otherwise); on this local test lane
# there is only one host, so it points back at the published port.
config :pleroma, Pleroma.Upload, base_url: "http://localhost:4001/media/"

# The baked config derives this from $DOMAIN as https://<domain>:443, which is
# wrong for a local plain-HTTP lane: Akkoma stamps this into every ActivityPub
# id and Mastodon-API URL it emits, so leaving it https would make the instance
# generate unreachable links for its own objects.
config :pleroma, Pleroma.Web.Endpoint,
  url: [host: "localhost", scheme: "http", port: 4001]

# The baked config ships registrations_open: false (the right production
# default). This is a TEST instance whose whole purpose is letting a suite
# create accounts, so it is opened deliberately here — and only here, in the
# file that is never part of a cluster deployment.
config :pleroma, :instance, registrations_open: true
