defmodule Scry2.Repo.Migrations.AddProvenanceToNetdeckingDecks do
  @moduledoc """
  Competitive provenance for netdecks (UIDR-010): pilot, event, and finish
  as structured columns instead of a mashed name string. All nullable —
  sources without competitive metadata (manual paste, local JSON) leave
  them nil, and the UI renders absence as absence.
  """
  use Ecto.Migration

  def change do
    alter table(:netdecking_decks) do
      add :pilot, :string
      add :event_name, :string
      add :event_date, :date
      add :placement, :integer
      add :swiss_rank, :integer
      add :field_size, :integer
      add :wins, :integer
      add :losses, :integer
    end
  end
end
