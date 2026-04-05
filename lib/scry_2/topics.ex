defmodule Scry2.Topics do
  @moduledoc """
  Central registry of Phoenix.PubSub topic strings.

  All cross-context communication flows through these topics. No module
  should hard-code a topic string — always use the helpers here. See the
  Bounded Contexts section in CLAUDE.md for the ownership model.
  """

  @pubsub Scry2.PubSub

  # ── MtgaLogs ─────────────────────────────────────────────────────────────
  @doc "Parsed log events broadcast after persistence to `mtga_logs_events`."
  def mtga_logs_events, do: "mtga_logs:events"

  @doc "Watcher state changes (running, paused, path_not_found, detailed_logs_warning)."
  def mtga_logs_status, do: "mtga_logs:status"

  # ── Matches ──────────────────────────────────────────────────────────────
  @doc "Match/game/deck upserts."
  def matches_updates, do: "matches:updates"

  # ── Drafts ───────────────────────────────────────────────────────────────
  @doc "Draft/pick upserts."
  def drafts_updates, do: "drafts:updates"

  # ── Cards ────────────────────────────────────────────────────────────────
  @doc "Card reference data refreshed (17lands import ran)."
  def cards_updates, do: "cards:updates"

  # ── Settings ─────────────────────────────────────────────────────────────
  @doc "Runtime configuration changed."
  def settings_updates, do: "settings:updates"

  # ── Helpers ──────────────────────────────────────────────────────────────
  @doc "Subscribe the calling process to `topic`."
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @doc "Broadcast `message` to `topic`."
  def broadcast(topic, message) when is_binary(topic) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
  end
end
