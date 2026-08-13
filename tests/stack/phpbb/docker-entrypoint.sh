#!/usr/bin/env bash
# phpBB first-run bootstrap for the local test stack.
#
# Runs phpBB's OWN unattended CLI installer (install/phpbbcli.php, shipped since
# 3.2) so the `phpbb` profile comes up as a WORKING, logged-into-able forum
# instead of parking the operator on the web setup wizard. This mirrors what
# mastodon-init does for the Mastodon tier (`rails db:prepare` on an empty
# Postgres) — without it the container serves an installer page and every test
# against it would be asserting on a wizard.
#
# Idempotent: a NON-EMPTY config.php is phpBB's "installed" marker, so a restart
# (or a re-up against a surviving volume) skips straight to apache.
#
# It must be `-s`, NOT `-f`: the 3.3 release zip SHIPS config.php as a 0-byte
# placeholder, so an existence test matches on a brand-new container, skips the
# installer, and leaves the board redirecting to /install/app.php — i.e. the
# setup wizard this entrypoint exists to avoid. Verified against 3.3.15.
set -euo pipefail

DOCROOT=/var/www/html
CONFIG="${DOCROOT}/config.php"

: "${PHPBB_DB_HOST:=phpbb-db}"
: "${PHPBB_DB_PORT:=5432}"
: "${PHPBB_DB_NAME:=phpbb}"
: "${PHPBB_DB_USER:=phpbb}"
: "${PHPBB_DB_PASSWORD:=phpbb}"
: "${PHPBB_ADMIN_USER:=admin}"
: "${PHPBB_ADMIN_PASSWORD:=adminadmin}"
: "${PHPBB_ADMIN_EMAIL:=admin@hugmesh.local}"
: "${PHPBB_BOARD_NAME:=HugMesh Test Forum (phpBB)}"
: "${PHPBB_SERVER_NAME:=localhost}"
: "${PHPBB_SERVER_PORT:=80}"
: "${PHPBB_SERVER_PROTOCOL:=http://}"
# Mount path at the front door. The fe-gateway serves phpBB under
# /social/phpbb/, and phpBB bakes this into generated URLs at install time, so
# it must match the gateway route or every link 404s.
: "${PHPBB_SCRIPT_PATH:=/social/phpbb}"

if [ -s "${CONFIG}" ]; then
    echo "[phpbb-entrypoint] already installed (config.php non-empty) — starting apache"
    exec "$@"
fi

echo "[phpbb-entrypoint] waiting for postgres at ${PHPBB_DB_HOST}:${PHPBB_DB_PORT}"
for _ in $(seq 1 60); do
    if php -r '
        $c = @pg_connect(sprintf("host=%s port=%s dbname=%s user=%s password=%s",
            getenv("PHPBB_DB_HOST"), getenv("PHPBB_DB_PORT"), getenv("PHPBB_DB_NAME"),
            getenv("PHPBB_DB_USER"), getenv("PHPBB_DB_PASSWORD")));
        exit($c ? 0 : 1);
    ' 2>/dev/null; then
        break
    fi
    sleep 2
done

INSTALL_YML=$(mktemp /tmp/phpbb-install.XXXXXX.yml)
# phpBB's installer config schema (docs/INSTALL.html "Command line installation").
cat > "${INSTALL_YML}" <<YML
installer:
    admin:
        name: ${PHPBB_ADMIN_USER}
        password: ${PHPBB_ADMIN_PASSWORD}
        email: ${PHPBB_ADMIN_EMAIL}
    board:
        lang: en
        name: ${PHPBB_BOARD_NAME}
        description: Local test-stack forum
    database:
        dbms: postgres
        dbhost: ${PHPBB_DB_HOST}
        dbport: ${PHPBB_DB_PORT}
        dbuser: ${PHPBB_DB_USER}
        dbpasswd: ${PHPBB_DB_PASSWORD}
        dbname: ${PHPBB_DB_NAME}
        table_prefix: phpbb_
    email:
        enabled: false
    server:
        cookie_secure: false
        server_protocol: ${PHPBB_SERVER_PROTOCOL}
        force_server_vars: false
        server_name: ${PHPBB_SERVER_NAME}
        server_port: ${PHPBB_SERVER_PORT}
        script_path: ${PHPBB_SCRIPT_PATH}
    extensions: []
YML

echo "[phpbb-entrypoint] running phpBB unattended installer"
cd "${DOCROOT}"
if ! php install/phpbbcli.php install "${INSTALL_YML}"; then
    echo "[phpbb-entrypoint] INSTALL FAILED — leaving the installer in place so the" >&2
    echo "                   web wizard at ${PHPBB_SCRIPT_PATH}/install/ still works" >&2
    rm -f "${INSTALL_YML}"
    exec "$@"
fi
rm -f "${INSTALL_YML}"

# phpBB refuses to serve a board while install/ is present (it is the documented
# post-install step, and leaving it exposed is a real admin-takeover vector).
if [ -d "${DOCROOT}/install" ]; then
    rm -rf "${DOCROOT}/install"
    echo "[phpbb-entrypoint] removed install/ (required post-install step)"
fi

chown -R www-data:www-data "${DOCROOT}"
echo "[phpbb-entrypoint] install complete — admin user '${PHPBB_ADMIN_USER}'"
exec "$@"
