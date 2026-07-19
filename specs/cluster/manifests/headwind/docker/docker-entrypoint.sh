#!/bin/sh
# snapdragon-headwind entrypoint — DERIVED from h-mdm/hmdm-docker's
# docker-entrypoint.sh (Apache-2.0; pinned ref in docker/README.md), reduced to
# the steps that apply to THIS image and deployment (build-from-source WAR,
# rootless UID 1000, in-cluster Postgres, PROTOCOL=http behind the
# superadmin-gateway). Divergences from upstream, and why (full table in
# docker/README.md):
#   - NO WAR download (upstream wget's an unsigned prebuilt WAR from h-mdm.com;
#     our WAR is baked at build time from source — the whole point of the image).
#   - NO /etc/hosts rewrite (root-only; cluster DNS resolves BASE_DOMAIN).
#   - NO letsencrypt/JKS branch (PROTOCOL=http is forced; the gateway owns TLS).
#   - NO h-mdm.com APK downloads for the seeded catalog (sovereign posture: no
#     unpinned binaries pulled at boot — seeded catalog rows stay placeholders
#     until the operator uploads vetted APKs through the console).
#   - java.security urandom tweak moved to BUILD time (root-owned file).
#   - exec "$@" (upstream ran catalina.sh un-exec'd, orphaning PID 1 signals).
set -eu

HMDM_DIR=/opt/hmdm
TEMPLATE_DIR=$HMDM_DIR/templates
TOMCAT_DIR=/usr/local/tomcat
BASE_DIR=$TOMCAT_DIR/work

# Two escaping layers, applied inside-out (same defect class as the
# attestation-server SMTP seeder fix — a secret with an active character must
# never corrupt the rendered artifact):
#   xml()  — XML-entity-escape a value destined for a ROOT.xml attribute
#            (Tomcat parses it as STRICT XML: a raw & or < in SQL_PASS would
#            fail the whole context deploy; the parser decodes the entities, so
#            the app still reads the original bytes).
#   sql()  — double single-quotes for a value spliced into init.sql literals.
#   esc()  — then escape sed-REPLACEMENT metacharacters (\, &, |) so the value
#            survives the substitution itself.
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'; }
sql() { printf '%s' "$1" | sed -e "s/'/''/g"; }

for DIR in cache files plugins logs; do
    [ -d "$BASE_DIR/$DIR" ] || mkdir -p "$BASE_DIR/$DIR"
done

if [ ! -f "$BASE_DIR/log4j-hmdm.xml" ] || [ "${FORCE_RECONFIGURE:-}" = "true" ]; then
    cp "$TEMPLATE_DIR/conf/log4j_template.xml" "$BASE_DIR/log4j-hmdm.xml"
fi

if [ ! -d "$BASE_DIR/emails" ] || [ "${FORCE_RECONFIGURE:-}" = "true" ]; then
    rm -rf "$BASE_DIR/emails"
    cp -r "$TEMPLATE_DIR/emails" "$BASE_DIR/emails"
fi

# ROOT.xml — the Tomcat context that carries the WHOLE app config (JDBC.*,
# base.url, files dirs). Rendered from the vendored upstream template with the
# ConfigMap/Secret env (headwind.yaml's SQL_*/PROTOCOL/BASE_DOMAIN contract —
# CONFIRMED against templates/conf/context_template.xml). Holds SQL_PASS, so
# 0600. SHARED_SECRET may be unset: secure.enrollment is 0 in the template.
mkdir -p "$TOMCAT_DIR/conf/Catalina/localhost"
if [ ! -f "$TOMCAT_DIR/conf/Catalina/localhost/ROOT.xml" ] || [ "${FORCE_RECONFIGURE:-}" = "true" ]; then
    umask 077
    sed "s|_SQL_HOST_|$(esc "$(xml "$SQL_HOST")")|g; \
         s|_SQL_PORT_|$(esc "$(xml "$SQL_PORT")")|g; \
         s|_SQL_BASE_|$(esc "$(xml "$SQL_BASE")")|g; \
         s|_SQL_USER_|$(esc "$(xml "$SQL_USER")")|g; \
         s|_SQL_PASS_|$(esc "$(xml "$SQL_PASS")")|g; \
         s|_PROTOCOL_|$(esc "$(xml "$PROTOCOL")")|g; \
         s|_BASE_DOMAIN_|$(esc "$(xml "$BASE_DOMAIN")")|g; \
         s|_SHARED_SECRET_|$(esc "$(xml "${SHARED_SECRET:-}")")|g;" \
        "$TEMPLATE_DIR/conf/context_template.xml" \
        > "$TOMCAT_DIR/conf/Catalina/localhost/ROOT.xml"
    umask 022
fi

# init.sql — the WAR's first-boot DATA seed (the DDL is the WAR's own
# Liquibase). Line 6 of the template is the ADMIN_EMAIL contract headwind.yaml
# documents: it stamps the seeded admin's email AND forces passwordReset=true.
# h-mdm.com catalog URLs are rewritten onto our base URL like upstream does,
# but the APKs behind them are NOT downloaded (see header); the rows are
# console-visible placeholders until the operator uploads vetted builds.
if [ ! -f "$BASE_DIR/init.sql" ] || [ "${FORCE_RECONFIGURE:-}" = "true" ]; then
    sed "s|_ADMIN_EMAIL_|$(esc "$(sql "$ADMIN_EMAIL")")|g; \
         s|_HMDM_VERSION_|$(esc "$(sql "${CLIENT_VERSION:-source}")")|g; \
         s|_HMDM_VARIANT_|$(esc "$(sql "${HMDM_VARIANT:-os}")")|g; \
         s|https://h-mdm.com|$(esc "$(sql "$PROTOCOL://$BASE_DOMAIN")")|g" \
        "$TEMPLATE_DIR/sql/hmdm_init.en.sql" > "$BASE_DIR/init.sql"
fi

# Wait for the database (headwind-db may still be starting).
until PGPASSWORD="$SQL_PASS" psql -h "$SQL_HOST" -p "$SQL_PORT" -U "$SQL_USER" -d "$SQL_BASE" -c '\q' >/dev/null 2>&1; do
    echo "Waiting for the PostgreSQL database at $SQL_HOST:$SQL_PORT/$SQL_BASE..."
    sleep 5
done

exec "$@"
