defmodule Scry2.Repo.Migrations.RevealedCardsLocalRole do
  @moduledoc """
  ADR-047 follow-up. GRE `ownerSeatId` is a per-match seat NUMBER, and the
  local player alternates seats — seat 1 is the local player in only ~75%
  of real matches. Labelling seat 1 as "You" was therefore wrong a quarter
  of the time. Store the resolved role alongside the factual seat.
  """
  use Ecto.Migration

  def change do
    alter table(:matches_revealed_cards) do
      add :is_local, :boolean
    end

    create index(:matches_revealed_cards, [:mtga_match_id, :is_local])
  end
end
