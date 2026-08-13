# phpBB 3.3 for the local test stack — an ALTERNATIVE forum backend to the
# first-party hugmesh-forum-ui/hugmesh-forum-bff-api pair, behind the `phpbb`
# compose profile (DEFAULT-OFF, like tube/owncast).
#
# WHY A DOCKERFILE INSTEAD OF A PINNED UPSTREAM IMAGE (the pattern the rest of
# the third-party tier uses for mastodon/tuwunel/postgres): phpBB publishes NO
# maintained image. Checked 2026-08-12:
#   - there is no official phpBB image on Docker Hub or ghcr;
#   - github.com/phpbb/docker is test-harness scaffolding pinned to PHP 5.4-7.0
#     and does not build a modern runnable forum;
#   - bitnami/phpbb does not exist (the repo 404s — Bitnami's catalog move);
#   - the community images on Hub are unofficial and mostly stale.
# So the honest option is to build a thin image from the OFFICIAL release
# tarball, pinned by version AND sha256, which is what this does. The checksum
# is the supply-chain control: phpbb.com serves the zip over a CDN, and an
# unverified download would silently accept a substituted archive.
FROM php:8.3-apache

# phpBB 3.3.15 (current 3.3 stable as of 2026-08-12). Bump BOTH lines together —
# the build fails closed on a checksum mismatch rather than installing whatever
# the CDN returned.
ARG PHPBB_VERSION=3.3.15
ARG PHPBB_SHA256=3904cc6668ea52318867fec1f7fe8b9bc0bd5431da1df617aa5c43c092a44252

# pdo_pgsql/pgsql: this stack standardises on Postgres (mastodon-db, casdoor-db,
# the BFF databases), so the forum uses it too rather than dragging in MySQL.
# gd + zip + intl are phpBB's own requirements (avatars, extension installs,
# the `intl` check in its install-time environment report).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libpq-dev libpng-dev libjpeg-dev libfreetype6-dev libzip-dev libicu-dev \
        unzip; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" pdo_pgsql pgsql gd zip intl opcache; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/*

# mod_rewrite is required for phpBB's optional URL rewriting; enabling it here
# keeps the option working if a test flips that setting on.
RUN a2enmod rewrite

RUN set -eux; \
    curl -fsSL -o /tmp/phpbb.zip \
        "https://download.phpbb.com/pub/release/3.3/${PHPBB_VERSION}/phpBB-${PHPBB_VERSION}.zip"; \
    echo "${PHPBB_SHA256}  /tmp/phpbb.zip" | sha256sum -c -; \
    unzip -q /tmp/phpbb.zip -d /tmp/phpbb-unpack; \
    rm -rf /var/www/html; \
    mv /tmp/phpbb-unpack/phpBB3 /var/www/html; \
    rm -rf /tmp/phpbb.zip /tmp/phpbb-unpack; \
    chown -R www-data:www-data /var/www/html

# phpBB writes into these at runtime (and the CLI installer writes config.php
# into the docroot), so they must be group-writable by the apache user.
RUN set -eux; \
    for d in cache files store images/avatars/upload; do \
        mkdir -p "/var/www/html/${d}"; \
    done; \
    chown -R www-data:www-data /var/www/html

COPY docker-entrypoint.sh /usr/local/bin/phpbb-entrypoint
RUN chmod +x /usr/local/bin/phpbb-entrypoint

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/phpbb-entrypoint"]
CMD ["apache2-foreground"]
