defmodule Scry2.Events.ProjectorRegistry do
  @moduledoc """
  Compile-time registry of all domain event projectors.

  Eliminates hardcoded projector lists throughout the codebase.
  Every module that `use Scry2.Events.Projector` should be listed here.
  """

  @projectors [
    Scry2.Matches.UpdateFromEvent,
    Scry2.Drafts.UpdateFromEvent,
    Scry2.Mulligans.UpdateFromEvent,
    Scry2.MatchListing.UpdateFromEvent
  ]

  @doc "Returns all projector modules."
  def all, do: @projectors

  @doc """
  Returns a status snapshot for every projector: name, claimed slugs,
  watermark position, max event id, and lag.
  """
  def status_all do
    max_id = Scry2.Events.max_event_id()

    Enum.map(@projectors, fn mod ->
      name = mod.projector_name()
      watermark = Scry2.Events.get_watermark(name)

      %{
        module: mod,
        name: name,
        claimed_slugs: mod.claimed_slugs(),
        watermark: watermark,
        max_event_id: max_id,
        lag: max_id - watermark
      }
    end)
  end
end
