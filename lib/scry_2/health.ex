defmodule Scry2.Health do
  @moduledoc """
  Runtime health facade — answers "is the system working?"

  This module collects data from the rest of the system (watcher status,
  event counts, card import timestamps, projector watermarks, config
  values) and passes it through pure check functions under
  `Scry2.Health.Checks.*`, returning a `%Report{}`.

  It also exposes `auto_fix/1` to remediate failing checks where possible
  (e.g. reload the watcher, enqueue a card import), and `setup_ready?/0`
  which the first-run tour uses to auto-dismiss.

  ## Architecture

  The category check modules (`Checks.Ingestion`, `Checks.CardData`,
  `Checks.Processing`, `Checks.Config`) are **pure** — they take their
  inputs as arguments and return `%Check{}` without touching the DB,
  GenServers, or file system (except for the explicit file-path probes
  in `Checks.Config`).

  This facade is where all the real side-effects live. Tests target the
  pure check functions directly with `async: true`; this facade gets
  covered by a resource test.
  """

  alias Scry2.Cards
  alias Scry2.Config, as: AppConfig
  alias Scry2.Events
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.ProjectorRegistry
  alias Scry2.Health.Check
  alias Scry2.Health.Checks.{CardData, Config, Ingestion, Processing}
  alias Scry2.Health.Report
  alias Scry2.MtgaLogIngestion
  alias Scry2.MtgaLogIngestion.LocateLogFile
  alias Scry2.MtgaLogIngestion.Watcher
  alias Scry2.Workers.PeriodicallyBackfillArenaIds
  alias Scry2.Workers.PeriodicallyUpdateCards

  @doc """
  Runs every check and returns a `%Report{}` snapshot of system health.
  """
  @spec run_all() :: Report.t()
  def run_all do
    checks =
      List.flatten([
        run_category(:ingestion),
        run_category(:card_data),
        run_category(:processing),
        run_category(:config)
      ])

    Report.new(checks)
  end

  @doc """
  Runs the checks for a single category and returns a list of
  `%Check{}` results.
  """
  @spec run_category(Check.category()) :: [Check.t()]
  def run_category(:ingestion) do
    locate_result = LocateLogFile.resolve()
    watcher_status = Watcher.status()
    total_raw = MtgaLogIngestion.count_all()
    events_by_type = MtgaLogIngestion.count_by_type()
    known_types = IdentifyDomainEvents.known_event_types()

    [
      Ingestion.player_log_locatable(locate_result),
      Ingestion.watcher_running(watcher_status),
      Ingestion.structured_events_seen(total_raw, events_by_type, known_types)
    ]
  end

  def run_category(:card_data) do
    timestamps = Cards.import_timestamps()
    lands17_count = Cards.count()
    scryfall_count = Cards.scryfall_count()

    [
      CardData.lands17_present(lands17_count),
      CardData.lands17_fresh(timestamps.lands17_updated_at),
      CardData.scryfall_present(scryfall_count),
      CardData.scryfall_fresh(timestamps.scryfall_updated_at)
    ]
  end

  def run_category(:processing) do
    error_count = MtgaLogIngestion.count_errors()
    events_by_type = MtgaLogIngestion.count_by_type()
    known_types = IdentifyDomainEvents.known_event_types()
    projector_statuses = ProjectorRegistry.status_all()

    [
      Processing.low_error_count(error_count),
      Processing.projectors_caught_up(projector_statuses),
      Processing.no_unrecognized_backlog(events_by_type, known_types)
    ]
  end

  def run_category(:config) do
    [
      Config.database_writable(AppConfig.get(:database_path)),
      Config.data_dirs_exist(
        cache_dir: AppConfig.get(:cache_dir),
        image_cache_dir: AppConfig.get(:image_cache_dir)
      )
    ]
  end

  @doc """
  Returns `true` when the derived signals indicate a successful first-run
  setup:

    * `Player.log` is locatable
    * At least one 17lands card is in the DB
    * At least one domain event has been persisted (i.e. events have
      actually flowed through the pipeline)

  Used by `Scry2.SetupFlow.required?/0` to auto-dismiss the tour once
  everything is actually working, regardless of the persisted flag.
  """
  @spec setup_ready?() :: boolean()
  def setup_ready? do
    with {:ok, _path} <- LocateLogFile.resolve(),
         cards_count when cards_count > 0 <- Cards.count(),
         max_event_id when max_event_id > 0 <- Events.max_event_id() do
      true
    else
      _ -> false
    end
  end

  @doc """
  Attempts to fix a failing check via one of the supported auto-fix tags.
  Called from `Scry2Web.HealthLive` when the user (or the periodic
  self-heal tick) asks to remediate a specific check.

  Returns `{:ok, description}` when the fix was attempted, or
  `{:error, reason}` when the tag isn't actionable (e.g. `:manual`).
  """
  @spec auto_fix(Check.fix()) :: {:ok, String.t()} | {:error, term()}
  def auto_fix(:reload_watcher) do
    Watcher.reload_path()
    {:ok, "Watcher path reload requested"}
  end

  def auto_fix(:enqueue_lands17) do
    case Oban.insert(PeriodicallyUpdateCards.new(%{})) do
      {:ok, _job} -> {:ok, "17lands import enqueued"}
      {:error, reason} -> {:error, reason}
    end
  end

  def auto_fix(:enqueue_scryfall) do
    case Oban.insert(PeriodicallyBackfillArenaIds.new(%{})) do
      {:ok, _job} -> {:ok, "Scryfall backfill enqueued"}
      {:error, reason} -> {:error, reason}
    end
  end

  def auto_fix(:manual), do: {:error, :requires_human_action}
  def auto_fix(nil), do: {:error, :no_fix_available}
end
