defmodule Scry2.Events.ProjectorRegistry do
  @moduledoc """
  Compile-time registry of all domain event projectors.

  Eliminates hardcoded projector lists throughout the codebase.
  Every module that `use Scry2.Events.Projector` should be listed here.
  """

  @projectors [
    Scry2.Matches.MatchProjection,
    Scry2.Decks.DeckProjection,
    Scry2.Drafts.DraftProjection,
    Scry2.Mulligans.MulliganProjection,
    Scry2.Ranks.RankProjection,
    Scry2.Economy.EconomyProjection
  ]

  @doc "Returns all projector modules."
  def all, do: @projectors

  @doc """
  Returns a status snapshot for every projector: name, claimed slugs,
  watermark position, max event id, and lag.
  """
  def status_all do
    Enum.map(@projectors, fn mod ->
      name = mod.projector_name()
      slugs = mod.claimed_slugs()
      watermark = Scry2.Events.get_watermark(name)
      max_id = Scry2.Events.max_event_id_for_types(slugs)

      %{
        module: mod,
        name: name,
        claimed_slugs: slugs,
        watermark: watermark,
        max_event_id: max_id,
        caught_up: watermark >= max_id,
        row_count: mod.row_count()
      }
    end)
  end
end
