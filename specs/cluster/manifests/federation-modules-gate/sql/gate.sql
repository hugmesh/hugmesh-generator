-- gate.sql — the federation_modules VISIBILITY gate, RENDERED AT BUILD TIME.
--
-- WHAT WAS OBSERVED (2026-08-26). A USB built with `--exclude-services akkoma`
-- pruned akkoma's Application, manifests, gateway routes and route-access rows,
-- flipped the installed-services ConfigMap to "false" and flipped the 13a
-- ApplicationSet element to installed:"false" — and the host shell STILL rendered
-- the Mastodon menu entry. Nothing in the build-time selection ever touched
-- `federation_modules`, and the host shell resolves its remotes from the
-- federation manifest, i.e. from THAT table, not from the ConfigMap. Every
-- registration is an UNCONDITIONAL Liquibase changeset in the SEPARATE
-- hugmesh-federation-api repo seeding enabled = true, so the build-time selection
-- had no say at all.
--
-- WHY A POST-SEED UPDATE AND NOT AN ADDITIVE CHANGESET. The registration
-- changesets (022/023/024/025/031/033 + the character-* ones) live in the
-- hugmesh-federation-api repo's Liquibase changelog, NOT in this generator repo —
-- see specs/cluster/manifests/character-forge/FEDERATION-REGISTRATION-TODO.md.
-- The generator therefore cannot add a changeset at all, let alone edit an
-- already-applied one (which would break Liquibase's checksum on every existing
-- mesh). A post-seed UPDATE run from the GitOps tree is the only lane the
-- generator owns. It is also the SAME shape the local-mesh lane already uses:
-- tests/stack/seed-e2e.sh leg 4 UPDATEs these exact rows from the Studio's
-- HUGMESH_FEDERATION_ENABLE / _DISABLE pair.
--
-- THE SLUGS ARE MODULE SLUGS, NOT CATALOGUE SLUGS. phpbb's federation module is
-- `forum`. The mapping is declared per-service in optional-services.yaml's
-- `federationModule: { slug: ... }` field (until this file existed, NOTHING read
-- that field) and the builders' _opt_render_federation_modules() parses it there
-- rather than carrying a second copy of the mapping.
--
-- ⚠ THIS FILE'S BUILD-TIME RENDER IS INERT ON A DEVICE TODAY — and the REASON
-- changed on 2026-08-26, while the conclusion did not. It used to be "bootstrap.sh
-- applies app-of-apps.yaml ONLY, so no child Application is ever retargeted". That
-- is no longer true: bootstrap.sh now applies every baked apps/*.yaml directly (the
-- device-syncs-pruned-apps keystone), apps/29b included. What is STILL true is
-- narrower and is what keeps this render inert: apply_baked_app() rewrites repoURL
-- and targetRevision and NOTHING ELSE. `source.path:
-- specs/cluster/manifests/federation-modules-gate` is untouched, so ArgoCD's
-- repo-server still clones a GIT repo and generates the gate ConfigMap from the
-- COMMITTED copy of this file, never from the USB's rendered copy. A USB built with
-- `--exclude-services akkoma` bakes enabled = false here and the cluster still
-- applies enabled = true. THE OBSERVED BUG IS NOT YET FIXED ON A DEVICE: this is
-- the mechanism and the guard. Closing it needs the gate's Application to source
-- the device's baked tree — a PRUNED SOURCE, which the keystone deliberately did
-- not attempt for anything under manifests/.
--
-- ⚠ AND EVEN THEN, UI HALF ONLY. Flipping enabled=false hides the MENU ENTRY; the
-- Deployment keeps running. The workload half needs the device to sync from a
-- PRUNED tree. (The APPLICATION SET is pruned now — bootstrap.sh applies the baked
-- apps/ — but each surviving Application still pulls its manifests from
-- the GIT repo, so a baked edit under manifests/ still does not reach the cluster.)
--
-- ⚠ RENDERED FILE. Each row below is rewritten in place by
-- _opt_render_federation_modules() in the SHARED scripts/_optional-services-lib.sh
-- (sourced by both stage4 builders) from the resolved OPTIONAL_SERVICES selection. The
-- line shape is the renderer's ANCHOR — keep it exactly:
--     UPDATE federation_modules SET enabled = <true|false> WHERE slug = '<module>';
-- The committed values are the DEFAULT-INCLUSION baseline from
-- optional-services.yaml (akkoma/tuwunel/phpbb default: on; the rest default: off),
-- so an unrendered tree still says something true.
--
-- Idempotent, and safe on a mesh whose federation-api has not run its changelog
-- yet: the guard below turns the whole script into a no-op when the table is
-- absent, and the Job retries.

\set ON_ERROR_STOP on

DO $gate$
BEGIN
  IF to_regclass('public.federation_modules') IS NULL THEN
    RAISE EXCEPTION 'federation_modules does not exist yet (federation-api Liquibase has not run) — retrying';
  END IF;
END
$gate$;

-- ── akkoma (Mastodon) — catalogue slug: akkoma ───────────────────────────────
UPDATE federation_modules SET enabled = true WHERE slug = 'akkoma';
-- ── tuwunel (Matrix) — catalogue slug: tuwunel ───────────────────────────────
UPDATE federation_modules SET enabled = true WHERE slug = 'tuwunel';
-- ── phpBB forum — catalogue slug: phpbb (MODULE slug differs: forum) ─────────
UPDATE federation_modules SET enabled = true WHERE slug = 'forum';
-- ── games — catalogue slug: games ────────────────────────────────────────────
UPDATE federation_modules SET enabled = false WHERE slug = 'games';
-- ── LocalTube — catalogue slug: tube ─────────────────────────────────────────
UPDATE federation_modules SET enabled = false WHERE slug = 'tube';
-- ── Owncast — catalogue slug: owncast ────────────────────────────────────────
UPDATE federation_modules SET enabled = false WHERE slug = 'owncast';
-- ── Character Studio (2D VN) — catalogue slug: character-studio ──────────────
UPDATE federation_modules SET enabled = false WHERE slug = 'character-studio';
-- ── Character Forge (3D) — catalogue slug: character-forge ───────────────────
UPDATE federation_modules SET enabled = false WHERE slug = 'character-forge';

-- Read the registry BACK into the Job log rather than trusting the UPDATEs — a
-- silent no-op here is a menu entry that never appears (or one that never goes
-- away), and that is exactly the class of failure this file exists for.
SELECT slug || '=' || enabled AS federation_registry
  FROM federation_modules
 ORDER BY slug;
