defmodule Scry2.Repo.Migrations.RenameProjectorWatermarkKeys do
  use Ecto.Migration

  @renames [
    {"Matches.UpdateFromEvent", "Matches.MatchProjection"},
    {"Drafts.UpdateFromEvent", "Drafts.DraftProjection"},
    {"Mulligans.UpdateFromEvent", "Mulligans.MulliganProjection"},
    {"Ranks.UpdateFromEvent", "Ranks.RankProjection"},
    {"Economy.UpdateFromEvent", "Economy.EconomyProjection"}
  ]

  def up do
    for {old, new} <- @renames do
      execute(
        "UPDATE projector_watermarks SET projector_name = '#{new}' WHERE projector_name = '#{old}'"
      )
    end
  end

  def down do
    for {old, new} <- @renames do
      execute(
        "UPDATE projector_watermarks SET projector_name = '#{old}' WHERE projector_name = '#{new}'"
      )
    end
  end
end
