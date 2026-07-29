# SPDX-License-Identifier: AGPL-3.0-only
# HugMesh Systems — custom Akkoma MRF (Message Rewrite Facility) policy.
#
# AGPL NOTICE: Akkoma is AGPL-3.0. This module is COMPILED INTO a derived Akkoma
# image (see manifests/akkoma/Dockerfile) and therefore the whole image is a
# derivative work whose complete corresponding source MUST be published (the AGPL
# §13 network-use clause: anyone interacting with the running server over a network
# is an AGPL recipient). This file IS that source contribution; the build also
# publishes the pinned upstream Akkoma source ref + this overlay. See
# docs/DOMAIN-LOCK.md "AGPL source publication".
#
# ─────────────────────────────── WHAT IT DOES ─────────────────────────────────
# This is the AUTHORITATIVE Mastodon-side leg of domain-lock (ROLE_MASTODON_DOMAINLOCKED
# -> "Mastodon local-only"). For any LOCAL actor in the force-local set, it makes
# the actor genuinely non-federating by FILTERING THE OUTBOUND DELIVERY RECIPIENT
# SET TO LOCAL INBOXES ONLY — for ALL activity types and ALL visibilities, NOT
# merely rewriting as:Public -> #Public (which would still leak followers-only/DM/
# boosts/replies/profile-Update/Follow to remote inboxes).
#
# Concretely, when the ACTOR of an outbound activity is force-local, this policy
# strips every NON-LOCAL recipient from `to`/`cc`/`bto`/`bcc`/`audience` (and the
# embedded object's addressing) so Akkoma's federation publisher enqueues NO remote
# delivery job. This covers, by construction (recipient-set filtering is
# type-agnostic), every leak vector the design enumerates:
#   - public / unlisted / followers-only / direct  (all visibilities)
#   - Announce (boosts) of remote posts
#   - replies to remote threads
#   - profile Update (Person object) propagation
#   - outbound Follow / Accept / Reject / Undo
#   - Like / EmojiReact / Delete / Move
# Inbound activities (actor is REMOTE) are passed through untouched — domain-lock
# constrains the locked user's OUTBOUND footprint, it does not break their ability
# to RECEIVE/READ locally.
#
# ─────────────────────────── HOW THE SET IS READ ──────────────────────────────
# The force-local set is materialized LIVE by the akkoma-domainlock-sync Job
# (manifests/akkoma/domainlock-sync-job.yaml) from Casdoor ROLE_MASTODON_DOMAINLOCKED
# membership into a small DB-backed allowlist the module reads at delivery time (no
# per-change recompile / no app restart). The lookup seam is `force_local?/1`.
#
# ──────────────────────────────── GATED / DARK ────────────────────────────────
# This policy only takes effect when it is listed in `:mrf, policies` in the Akkoma
# config AND the force-local set is non-empty. The deploy gates that on
# homeserver.domainlock.enabled (manifests/akkoma/akkoma.yaml only adds it to the
# :mrf policies list when enabled). With the gate off, a plain akkoma:stable runs
# and federation is unchanged. Even compiled-in, an EMPTY force-local set is a
# no-op for every actor — so the module is safe-by-default.
#
# !!! SKELETON: the Pleroma/Akkoma MRF behaviour callbacks + the exact addressing
# !!! field names are version-sensitive. This is a working scaffold modelled on the
# !!! upstream SimplePolicy (Pleroma.Web.ActivityPub.MRF.SimplePolicy) shape —
# !!! VALIDATE the callback arity, the `Pleroma.Web.ActivityPub.MRF.Policy`
# !!! behaviour, and `Pleroma.Web.ActivityPub.Utils`/`Visibility` helpers against
# !!! the PINNED Akkoma source ref before relying on it in production.
defmodule Pleroma.Web.ActivityPub.MRF.ForceLocalForUsersPolicy do
  @moduledoc "Force a configured set of LOCAL actors to deliver to LOCAL inboxes only (domain-lock / no-federation)."
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  alias Pleroma.Web.ActivityPub.MRF

  # Local instance host — recipients on this host (or the local shared inbox /
  # #Public) are kept; everything else is stripped for a force-local actor.
  defp local_host, do: Pleroma.Web.Endpoint.host()

  @public "https://www.w3.org/ns/activitystreams#Public"

  # ── force-local lookup seam ──────────────────────────────────────────────────
  # Reads the live allowlist materialized by akkoma-domainlock-sync. Implemented
  # here as a config/cachex lookup against a set of local nicknames/actor-ids; the
  # sync Job writes that set. Returns true if THIS actor must be forced local.
  @spec force_local?(String.t() | nil) :: boolean()
  defp force_local?(nil), do: false

  defp force_local?(actor) when is_binary(actor) do
    # The sync Job materializes the set into Pleroma config key
    # {:mrf_force_local, :forced_actors} (a MapSet of local actor AP-ids) and/or a
    # Cachex cache the Job refreshes. Config read is the simple, restart-free seam;
    # swap to a Cachex/DB read if the deployment prefers a hot path.
    forced =
      Pleroma.Config.get([:mrf_force_local, :forced_actors], MapSet.new())

    local_actor?(actor) and MapSet.member?(forced, actor)
  end

  # Only LOCAL actors can be domain-locked; a remote actor is never in our set.
  defp local_actor?(actor) when is_binary(actor),
    do: String.contains?(actor, "://" <> local_host())

  defp local_actor?(_), do: false

  # ── recipient filtering ──────────────────────────────────────────────────────
  # Keep ONLY local recipients (same host) plus the magic local addressing. Drop
  # #Public (it implies remote fan-out) and every remote inbox/follower address.
  defp keep_local(recipients) when is_list(recipients) do
    host = local_host()

    Enum.filter(recipients, fn r ->
      is_binary(r) and r != @public and String.contains?(r, "://" <> host)
    end)
  end

  defp keep_local(_), do: []

  # Filter every addressing field on a map (activity or embedded object).
  defp filter_addressing(map) when is_map(map) do
    map
    |> filter_field("to")
    |> filter_field("cc")
    |> filter_field("bto")
    |> filter_field("bcc")
    |> filter_field("audience")
  end

  defp filter_field(map, field) do
    case Map.get(map, field) do
      nil -> map
      list when is_list(list) -> Map.put(map, field, keep_local(list))
      one -> Map.put(map, field, keep_local([one]))
    end
  end

  # ── MRF behaviour ────────────────────────────────────────────────────────────
  @impl true
  def filter(%{"actor" => actor} = activity) do
    if force_local?(actor) do
      filtered =
        activity
        |> filter_addressing()
        |> update_in_object()

      {:ok, filtered}
    else
      {:ok, activity}
    end
  end

  # Activities with no top-level actor (rare) pass through untouched.
  @impl true
  def filter(activity), do: {:ok, activity}

  # Mirror the recipient filtering into the embedded object so a Create/Update
  # carrying its own to/cc cannot re-introduce a remote recipient downstream.
  defp update_in_object(%{"object" => object} = activity) when is_map(object),
    do: Map.put(activity, "object", filter_addressing(object))

  defp update_in_object(activity), do: activity

  # describe/0 surfaces the policy in /nodeinfo so the e2e self-check can assert the
  # custom image is actually running (a mock/plain image would NOT list it).
  @impl true
  def describe do
    {:ok,
     %{
       mrf_force_local: %{
         forced_actor_count:
           Pleroma.Config.get([:mrf_force_local, :forced_actors], MapSet.new())
           |> MapSet.size()
       }
     }}
  end

  @impl true
  def config_description do
    %{
      key: :mrf_force_local,
      related_policy: "Pleroma.Web.ActivityPub.MRF.ForceLocalForUsersPolicy",
      label: "MRF Force-Local (domain-lock)",
      description:
        "Forces the configured set of LOCAL actors to deliver to LOCAL inboxes only " <>
          "(no federation). The set is materialized live from Casdoor " <>
          "ROLE_MASTODON_DOMAINLOCKED by akkoma-domainlock-sync.",
      children: [
        %{
          key: :forced_actors,
          type: {:list, :string},
          description: "AP actor-ids of local users forced to local-only delivery."
        }
      ]
    }
  end
end
