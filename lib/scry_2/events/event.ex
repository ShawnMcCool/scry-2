defprotocol Scry2.Events.Event do
  @moduledoc """
  Protocol implemented by every domain event struct under `Scry2.Events.*`.

  Domain events are the unit of communication between the ingestion
  subsystem (stages 01–08) and projectors / real-time consumers (stage 09+).
  Each struct represents a single thing that happened in the user's MTGA
  domain, translated from raw MTGA events by `Scry2.Events.Translator`.

  This protocol exposes the two pieces of metadata the persistence and
  replay machinery needs without requiring projectors to know about the
  Ecto schema:

    * `type_slug/1` — a stable string used as the `domain_events.event_type`
      column value. NEVER rename; historical rows reference these slugs.
    * `mtga_timestamp/1` — when the event happened in MTGA time, or nil.
      Used to order events during replay and for display.

  Projectors and other consumers destructure the struct directly — they
  never need the protocol. It exists purely for persistence + replay.

  ## Adding a new domain event

  1. Create `lib/scry_2/events/<name>.ex` with `defstruct`, `@enforce_keys`,
     and `@type t :: ...`.
  2. Implement `Scry2.Events.Event` inside that file via `defimpl`.
  3. Pick a stable slug and document it at the top of the module.
  4. Add a translator clause in `Scry2.Events.Translator` that produces
     the struct from a raw MTGA event.
  5. Add a projector handler in whichever context owns the projection.

  See ADR-017 (event sourcing) and ADR-018 (anti-corruption layer) for
  the architectural rationale.
  """

  @doc """
  Returns the stable slug string for this event type, used as the
  `event_type` column in the `domain_events` table. NEVER change the
  slug for an existing event — historical rows will stop resolving.
  """
  @spec type_slug(t) :: String.t()
  def type_slug(event)

  @doc """
  Returns the MTGA-side timestamp of when the event happened, or `nil`
  if the source MTGA event did not carry one.
  """
  @spec mtga_timestamp(t) :: DateTime.t() | nil
  def mtga_timestamp(event)
end
