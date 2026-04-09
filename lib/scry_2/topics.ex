defmodule Scry2.Topics do
  @moduledoc """
  Central registry of Phoenix.PubSub topic strings.

  All cross-context communication flows through these topics. No module
  should hard-code a topic string — always use the helpers here. See the
  Bounded Contexts section in CLAUDE.md for the ownership model.
  """

  @pubsub Scry2.PubSub

  # ── MtgaLogIngestion ─────────────────────────────────────────────────────
  @doc "Parsed log events broadcast after persistence to `mtga_logs_events`."
  def mtga_logs_events, do: "mtga_logs:events"

  @doc "Watcher state changes (running, paused, path_not_found, detailed_logs_warning)."
  def mtga_logs_status, do: "mtga_logs:status"

  # ── Matches ─────────────────────────────────────────────────────────
  @doc "Match/game/deck upserts."
  def matches_updates, do: "matches:updates"

  # ── Drafts ─────────────────────────────────────────────────────────
  @doc "Draft/pick upserts."
  def drafts_updates, do: "drafts:updates"

  # ── Players ─────────────────────────────────────────────────────────
  @doc "Player auto-discovered or updated."
  def players_updates, do: "players:updates"

  # ── Ranks ───────────────────────────────────────────────────────────
  @doc "Rank snapshot inserts."
  def ranks_updates, do: "ranks:updates"

  # ── Economy ────────────────────────────────────────────────────────
  @doc "Economy projection updates (event entries, inventory, transactions)."
  def economy_updates, do: "economy:updates"

  # ── Cards ────────────────────────────────────────────────────────────────
  @doc "Card reference data refreshed (17lands import ran)."
  def cards_updates, do: "cards:updates"

  # ── Settings ─────────────────────────────────────────────────────────────
  @doc "Runtime configuration changed."
  def settings_updates, do: "settings:updates"

  # ── Console ──────────────────────────────────────────────────────────────
  @doc """
  Console log events. Subscribers (ConsoleLive, ConsolePageLive) receive:
    * `{:log_entry, %Scry2.Console.Entry{}}` — new entry appended
    * `:buffer_cleared` — buffer emptied by user
    * `{:buffer_resized, new_cap}` — buffer cap changed
    * `{:filter_changed, %Scry2.Console.Filter{}}` — filter updated (cross-tab sync)
  """
  def console_logs, do: "console:logs"

  # ── Operations ───────────────────────────────────────────────────────────
  @doc "Background operation progress (reingest, rebuild, catch-up)."
  def operations, do: "operations:status"

  # ── Events (domain event log) ────────────────────────────────────────────
  @doc """
  Domain events from `Scry2.Events`. Every projector and real-time consumer
  subscribes here. Messages:

    * `{:domain_event, id, type_slug}` — new event appended to the log.
      Consumers load the full struct via `Scry2.Events.get!/1`.

  No downstream context should subscribe to `mtga_logs_events/0` directly —
  domain events are the anti-corruption boundary (see ADR-018). If you need
  MTGA information, it should be modeled as a domain event first.
  """
  def domain_events, do: "domain:events"

  @doc """
  Control signals for projectors. Used to coordinate lifecycle changes that
  affect the entire event store.

  ## Inbound (broadcast by Operations, received by projectors)

    * `:full_rebuild` — domain events cleared and regenerated (reingest).
      All projectors reset watermark to 0, truncate tables, replay from scratch.
    * `:rebuild_all` — explicit rebuild all projections (not from reingest).
      Same truncate-and-replay semantics as `:full_rebuild`.
    * `:catch_up_all` — replay from watermark without truncating.

  ## Outbound (broadcast by projectors on completion)

    * `{:projector_rebuilt, name}` — projector finished `:full_rebuild` or `:rebuild_all`
    * `{:projector_caught_up, name}` — projector finished `:catch_up_all`
    * `{:projector_progress, name, processed, total}` — progress during rebuild or catch-up
  """
  def domain_control, do: "domain:control"

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
