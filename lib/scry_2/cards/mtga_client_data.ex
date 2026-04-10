defmodule Scry2.Cards.MtgaClientData do
  @moduledoc """
  Imports card identity data from the MTGA client's local
  `Raw_CardDatabase` SQLite file.

  The MTGA client stores a complete card database as a SQLite file at
  `MTGA_Data/Downloads/Raw/Raw_CardDatabase_*.mtga`. This module reads
  it directly and upserts every card into `cards_mtga_cards`.

  ## Usage

      MtgaClientData.run()
      # => {:ok, %{imported: 24413}}

  Safe to re-run after MTGA updates — upserts by `arena_id`.

  ## Auto-discovery

  The database filename includes a content hash that changes with MTGA
  updates (e.g., `Raw_CardDatabase_3496a613c4c9f4416ca8d7aa5b8bd47a.mtga`).
  `find_database_path/1` scans the Raw directory for the current file.
  """

  alias Scry2.Cards
  alias Scry2.Config

  require Scry2.Log, as: Log

  @default_raw_dir "/home/shawn/.local/share/Steam/steamapps/common/MTGA/MTGA_Data/Downloads/Raw"

  @type run_result :: {:ok, %{imported: non_neg_integer()}} | {:error, term()}

  @doc """
  Imports all cards from the MTGA client database.

  Options:
    * `:database_path` — override the path to the Raw_CardDatabase file
  """
  @spec run(keyword()) :: run_result()
  def run(opts \\ []) do
    db_path =
      Keyword.get_lazy(opts, :database_path, fn ->
        data_dir = Config.get(:mtga_data_dir) || @default_raw_dir
        find_database_path(data_dir)
      end)

    case db_path do
      nil -> {:error, :database_not_found}
      path -> import_from(path)
    end
  end

  @doc """
  Finds the `Raw_CardDatabase_*.mtga` file in the given directory.
  Returns the full path, or nil if not found.
  """
  @spec find_database_path(String.t()) :: String.t() | nil
  def find_database_path(dir) do
    case Path.wildcard(Path.join(dir, "Raw_CardDatabase_*.mtga")) do
      [path | _] -> path
      [] -> nil
    end
  end

  defp import_from(db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

    try do
      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, """
        SELECT
          c.GrpId,
          l.Loc,
          c.ExpansionCode,
          c.CollectorNumber,
          c.Rarity,
          c.Colors,
          c.Types,
          c.IsToken,
          c.IsDigitalOnly,
          c.ArtId,
          c.Power,
          c.Toughness,
          c.Order_CMCWithXLast
        FROM Cards c
        LEFT JOIN Localizations_enUS l
          ON c.TitleId = l.LocId AND l.Formatted = 1
        """)

      count = import_rows(conn, statement, 0)

      Log.info(:importer, "MTGA client data: imported #{count} cards")
      {:ok, %{imported: count}}
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp import_rows(conn, statement, count) do
    case Exqlite.Sqlite3.step(conn, statement) do
      {:row, row} ->
        row |> row_to_attrs() |> Cards.upsert_mtga_card!()
        import_rows(conn, statement, count + 1)

      :done ->
        count
    end
  end

  defp row_to_attrs([
         arena_id,
         name,
         expansion_code,
         collector_number,
         rarity,
         colors,
         types,
         is_token,
         is_digital_only,
         art_id,
         power,
         toughness,
         cmc
       ]) do
    %{
      arena_id: arena_id,
      name: name || "Unknown (#{arena_id})",
      expansion_code: expansion_code || "",
      collector_number: collector_number || "",
      rarity: rarity,
      colors: colors || "",
      types: types || "",
      is_token: is_token == 1,
      is_digital_only: is_digital_only == 1,
      art_id: art_id,
      power: power || "",
      toughness: toughness || "",
      mana_value: cmc || 0
    }
  end
end
