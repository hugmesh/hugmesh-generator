# Vendored Headwind (hmdm-docker) runtime files

Source: <https://github.com/h-mdm/hmdm-docker> (Apache-2.0), pinned at commit
`5f544820689aa532717075312d76179146a823d0` (master, fetched 2026-07-19). Everything the runtime image needs
beyond the WAR itself lives here so the Dockerfile builds without boot-time or
build-time fetches from h-mdm.com.

| File | Provenance | Role |
| --- | --- | --- |
| `templates/conf/context_template.xml` | verbatim upstream | Tomcat context template — the WHOLE app config (JDBC.*, base.url, files dirs, hash.secret). Rendered to `conf/Catalina/localhost/ROOT.xml` by the entrypoint from headwind.yaml's `SQL_*`/`PROTOCOL`/`BASE_DOMAIN` env. |
| `templates/conf/log4j_template.xml` | verbatim upstream | Copied to `work/log4j-hmdm.xml` (referenced by the context's `log4j.config`). |
| `templates/sql/hmdm_init.en.sql` | verbatim upstream | First-boot DATA seed the WAR consumes from `work/init.sql`; line 6 is the `_ADMIN_EMAIL_` stamp + forced `passwordReset` headwind.yaml documents. (The `ru` variant is not vendored: the entrypoint always reads the `en` seed.) |
| `templates/emails/en/*` | verbatim upstream | Password-recovery mail templates copied to `work/emails`. |
| `server.xml` | verbatim upstream (`tomcat_conf/server.xml`) | Tomcat server config (plain HTTP :8080 connector — TLS is the gateway's). |
| `docker-entrypoint.sh` | **DERIVED**, not verbatim | Upstream's flow is the prebuilt-WAR product (wget's an unsigned WAR from h-mdm.com, rewrites /etc/hosts as root, builds a letsencrypt JKS, downloads catalog APKs at boot, edits the root-owned java.security at runtime, runs catalina un-exec'd). None of that fits a build-from-source, rootless (UID 1000), gateway-TLS, no-boot-egress image — the derived script keeps only the required-env check, config templating, init.sql seeding, and DB wait; the header lists every divergence. |
| `build.properties` | hugmesh header; provenance of the values not recorded | The `server/build.properties` the Maven build requires. Baked defaults only; the entrypoint's `ROOT.xml` overrides them at runtime. The Dockerfile replaces `jwt.secretkey` and `hash.secret` with fresh random values at each image build. |

Refresh procedure: bump the pinned ref above, re-fetch the verbatim files from
that ref, re-diff `docker-entrypoint.sh` against upstream's for new steps, and
re-run the image build.
