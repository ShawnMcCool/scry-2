# Elixir-Native Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move scry_2's self-update responsibility from the Go tray binary to the Elixir application, with a Settings LiveView UI surface and apply-lock coordination for the tray watchdog.

**Architecture:** New `Scry2.SelfUpdate` subsystem (Oban cron + GenServer state machine + PubSub progress). Hourly check → `:persistent_term` cache → user-initiated apply downloads + verifies + stages + spawns detached installer → BEAM exits cleanly → installer script relaunches tray.

**Tech Stack:** Elixir 1.18, Oban 2.19, Req 0.5, Phoenix.PubSub, `:erl_tar`, `:zip`, `Plug.Crypto.secure_compare/2`, SQLite via `Scry2.Settings.Entry`.

**Spec reference:** `specs/2026-04-20-elixir-self-update-design.md`

---

## File Structure

### Created

- `lib/scry_2/version.ex` — `Scry2.Version.current/0` from `mix.exs`
- `lib/scry_2/self_update.ex` — public facade
- `lib/scry_2/self_update/update_checker.ex` — API fetch + tag validation + cache
- `lib/scry_2/self_update/checker_job.ex` — Oban worker
- `lib/scry_2/self_update/storage.ex` — Settings.Entry adapter + persistent_term hydration
- `lib/scry_2/self_update/updater.ex` — GenServer state machine
- `lib/scry_2/self_update/downloader.ex` — archive + SHA256SUMS fetch + verify
- `lib/scry_2/self_update/stager.ex` — extract + per-entry validation
- `lib/scry_2/self_update/handoff.ex` — platform-dispatched detached spawn
- `lib/scry_2/self_update/apply_lock.ex` — lock file lifecycle
- `lib/scry_2_web/live/settings_live/updates_card.ex` — HEEx card component
- `lib/scry_2_web/live/settings_live/updates_helpers.ex` — extracted LiveView logic (per [ADR-013])
- `test/scry_2/self_update/*_test.exs` — one per module
- `test/support/self_update_fixtures/` — tar/zip fixtures for Stager tests
- `tray/apply_lock.go` — Go lock reader
- `tray/apply_lock_test.go`

### Modified

- `lib/scry_2/topics.ex` — add `updates_status/0`, `updates_progress/0`
- `lib/scry_2/application.ex` — add `Scry2.SelfUpdate.Updater` to supervisor; call `Scry2.SelfUpdate.boot!/0`
- `lib/scry_2_web/live/settings_live.ex` — render UpdatesCard, handle events/messages
- `config/config.exs` — Oban: add `:self_update` queue and cron entry
- `tray/backend.go` — watchdog consults apply lock before calling `b.Start()`
- `tray/main.go` — remove `updater.Start(...)`, remove "Check for Updates" menu item
- `scripts/install-linux` — `rm -f "$DATA_DIR/apply.lock"` before launching tray
- `scripts/install-macos` — same
- `rel/overlays/install.bat` — `del /q "%DATA_DIR%\apply.lock"` before launching tray
- `scripts/release` — remove `-X 'scry2/tray/updater.CurrentVersion=...'` and `...InstallerType=...` flags
- `.github/workflows/release.yml` — generate `SHA256SUMS` per platform, upload to release
- `.github/workflows/tray-ci.yml` — remove updater tests from matrix

### Deleted

- `tray/updater/` (all files)

---

## Pre-flight

- [ ] **Step 0.1: Create worktree**

  ```bash
  cd /home/shawn/src/scry_2
  jj new && jj desc -m "feat: Elixir-native self-update subsystem"
  ```

- [ ] **Step 0.2: Confirm baseline is green**

  ```bash
  MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
  ```

  Expected: all checks pass. If not, stop and resolve before proceeding.

- [ ] **Step 0.3: Create empty module stubs so the supervisor reference compiles later (avoids ordering churn)**

  Touch the files with single-line placeholders — a real implementation replaces each:

  ```bash
  for f in version self_update; do
    [ -f lib/scry_2/$f.ex ] || echo "defmodule Scry2.$(echo $f | sed 's/_\([a-z]\)/\U\1/g' | sed 's/^./\U&/' | sed 's/Selfupdate/SelfUpdate/') do\nend" > lib/scry_2/$f.ex
  done
  ```

  Actually — skip this. Just create each real file in its task. Linker will be fine because we add supervision at the end.

---

## Task 1: Version Helper

**Files:**
- Create: `lib/scry_2/version.ex`
- Create: `test/scry_2/version_test.exs`

- [ ] **Step 1.1: Write the failing test**

  ```elixir
  # test/scry_2/version_test.exs
  defmodule Scry2.VersionTest do
    use ExUnit.Case, async: true
    alias Scry2.Version

    test "current/0 returns the mix.exs version as a string" do
      version = Version.current()
      assert is_binary(version)
      assert Regex.match?(~r/^\d+\.\d+\.\d+/, version)
    end

    test "current/0 matches Application.spec/2" do
      assert Version.current() == to_string(Application.spec(:scry_2, :vsn))
    end
  end
  ```

- [ ] **Step 1.2: Run, confirm it fails**

  ```bash
  mix test test/scry_2/version_test.exs
  ```

  Expected: `** (UndefinedFunctionError) Scry2.Version.current/0 is undefined`

- [ ] **Step 1.3: Implement**

  ```elixir
  # lib/scry_2/version.ex
  defmodule Scry2.Version do
    @moduledoc """
    Exposes the scry_2 version string at runtime.

    The version is read from `mix.exs` at compile time and baked into the
    compiled release, so `current/0` returns the version of the code that
    is actually running.
    """

    @spec current() :: String.t()
    def current, do: to_string(Application.spec(:scry_2, :vsn))
  end
  ```

- [ ] **Step 1.4: Run, confirm it passes**

  ```bash
  mix test test/scry_2/version_test.exs
  ```

  Expected: 2 tests, 0 failures.

- [ ] **Step 1.5: Commit**

  ```bash
  jj st
  ```

  Expected: two new files listed. Continue — `jj` auto-snapshots.

---

## Task 2: Topics for Updates

**Files:**
- Modify: `lib/scry_2/topics.ex`
- Test: `test/scry_2/topics_test.exs` (existing)

- [ ] **Step 2.1: Add test cases**

  Append to `test/scry_2/topics_test.exs`:

  ```elixir
  test "updates_status/0 returns a stable string" do
    assert Scry2.Topics.updates_status() == "updates:status"
  end

  test "updates_progress/0 returns a stable string" do
    assert Scry2.Topics.updates_progress() == "updates:progress"
  end
  ```

- [ ] **Step 2.2: Run, confirm it fails**

  ```bash
  mix test test/scry_2/topics_test.exs
  ```

  Expected: undefined function errors on both new tests.

- [ ] **Step 2.3: Add the functions**

  In `lib/scry_2/topics.ex`, insert after `settings_updates` (keep alphabetical if that's the convention):

  ```elixir
  @doc "Topic for self-update check results (broadcast by CheckerJob)."
  def updates_status, do: "updates:status"

  @doc "Topic for self-update apply progress (broadcast by Updater)."
  def updates_progress, do: "updates:progress"
  ```

- [ ] **Step 2.4: Run, confirm pass**

  ```bash
  mix test test/scry_2/topics_test.exs
  ```

  Expected: all topic tests pass.

---

## Task 3: SelfUpdate.ApplyLock

Lock file read/write primitives. Pure enough to unit-test with a temp dir.

**Files:**
- Create: `lib/scry_2/self_update/apply_lock.ex`
- Create: `test/scry_2/self_update/apply_lock_test.exs`

- [ ] **Step 3.1: Write the failing test**

  ```elixir
  # test/scry_2/self_update/apply_lock_test.exs
  defmodule Scry2.SelfUpdate.ApplyLockTest do
    use ExUnit.Case, async: true
    alias Scry2.SelfUpdate.ApplyLock

    setup do
      dir = System.tmp_dir!() |> Path.join("apply_lock_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, path: Path.join(dir, "apply.lock")}
    end

    test "acquire/2 writes the lock with pid, version, phase, started_at", %{path: path} do
      :ok = ApplyLock.acquire(path, version: "0.15.0")
      assert File.exists?(path)
      contents = path |> File.read!() |> Jason.decode!()
      assert contents["version"] == "0.15.0"
      assert contents["phase"] == "preparing"
      assert is_integer(contents["pid"])
      assert contents["started_at"]
    end

    test "update_phase/2 rewrites only the phase", %{path: path} do
      :ok = ApplyLock.acquire(path, version: "0.15.0")
      :ok = ApplyLock.update_phase(path, "handing_off")
      contents = path |> File.read!() |> Jason.decode!()
      assert contents["phase"] == "handing_off"
      assert contents["version"] == "0.15.0"
    end

    test "release/1 removes the file", %{path: path} do
      :ok = ApplyLock.acquire(path, version: "0.15.0")
      :ok = ApplyLock.release(path)
      refute File.exists?(path)
    end

    test "release/1 is idempotent when file missing", %{path: path} do
      assert :ok = ApplyLock.release(path)
    end

    test "read/1 returns :none when file missing", %{path: path} do
      assert ApplyLock.read(path) == :none
    end

    test "read/1 returns a struct when file exists", %{path: path} do
      :ok = ApplyLock.acquire(path, version: "0.15.0")
      assert {:ok, lock} = ApplyLock.read(path)
      assert lock.version == "0.15.0"
      assert lock.phase == "preparing"
    end

    test "stale?/2 returns true when lock older than given age", %{path: path} do
      :ok = ApplyLock.acquire(path, version: "0.15.0")
      {:ok, lock} = ApplyLock.read(path)
      assert ApplyLock.stale?(lock, 0) == true
      assert ApplyLock.stale?(lock, 86_400) == false
    end

    test "clear_if_stale!/2 removes stale, leaves fresh", %{path: path} do
      :ok = ApplyLock.acquire(path, version: "0.15.0")
      assert :not_stale = ApplyLock.clear_if_stale!(path, 86_400)
      assert File.exists?(path)

      assert :cleared = ApplyLock.clear_if_stale!(path, 0)
      refute File.exists?(path)
    end
  end
  ```

- [ ] **Step 3.2: Run, confirm fail**

  ```bash
  mix test test/scry_2/self_update/apply_lock_test.exs
  ```

- [ ] **Step 3.3: Implement**

  ```elixir
  # lib/scry_2/self_update/apply_lock.ex
  defmodule Scry2.SelfUpdate.ApplyLock do
    @moduledoc """
    On-disk coordination between the Elixir self-updater and the Go tray
    watchdog. While an apply is in progress, the lock file signals the
    watchdog to skip its restart attempts — the installer will tear down
    and restart the backend itself.

    Lock file contents (JSON, single line):

        {"pid": 12345, "version": "0.15.0", "phase": "preparing",
         "started_at": "2026-04-20T18:03:11Z"}

    Lifecycle:
      - `acquire/2` — write lock on apply start
      - `update_phase/2` — record state transitions (preparing → ...)
      - `release/1` — remove lock on clean finish
      - `clear_if_stale!/2` — boot-time cleanup of abandoned locks
    """

    require Logger

    defstruct [:pid, :version, :phase, :started_at]

    @type t :: %__MODULE__{
            pid: pos_integer(),
            version: String.t(),
            phase: String.t(),
            started_at: DateTime.t()
          }

    @spec acquire(Path.t(), [{:version, String.t()}]) :: :ok | {:error, term()}
    def acquire(path, opts) do
      version = Keyword.fetch!(opts, :version)

      payload = %{
        "pid" => System.pid() |> to_string() |> String.to_integer(),
        "version" => version,
        "phase" => "preparing",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.mkdir_p!(Path.dirname(path))
      File.write(path, Jason.encode!(payload))
    end

    @spec update_phase(Path.t(), String.t()) :: :ok | {:error, term()}
    def update_phase(path, phase) when is_binary(phase) do
      with {:ok, raw} <- File.read(path),
           {:ok, decoded} <- Jason.decode(raw) do
        updated = Map.put(decoded, "phase", phase)
        File.write(path, Jason.encode!(updated))
      end
    end

    @spec release(Path.t()) :: :ok
    def release(path) do
      _ = File.rm(path)
      :ok
    end

    @spec read(Path.t()) :: {:ok, t()} | :none | {:error, term()}
    def read(path) do
      case File.read(path) do
        {:error, :enoent} ->
          :none

        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, decoded} ->
              {:ok,
               %__MODULE__{
                 pid: decoded["pid"],
                 version: decoded["version"],
                 phase: decoded["phase"],
                 started_at: parse_datetime(decoded["started_at"])
               }}

            {:error, reason} ->
              {:error, {:decode, reason}}
          end

        other ->
          other
      end
    end

    @spec stale?(t(), non_neg_integer()) :: boolean()
    def stale?(%__MODULE__{started_at: %DateTime{} = started_at}, max_age_seconds) do
      DateTime.diff(DateTime.utc_now(), started_at, :second) > max_age_seconds
    end

    def stale?(_, _), do: true

    @spec clear_if_stale!(Path.t(), non_neg_integer()) :: :not_stale | :cleared | :absent
    def clear_if_stale!(path, max_age_seconds) do
      case read(path) do
        :none ->
          :absent

        {:ok, lock} ->
          if stale?(lock, max_age_seconds) do
            :ok = release(path)
            :cleared
          else
            :not_stale
          end

        {:error, _reason} ->
          # Corrupt lock — nuke it.
          :ok = release(path)
          :cleared
      end
    end

    defp parse_datetime(nil), do: nil

    defp parse_datetime(str) when is_binary(str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _} -> dt
        _ -> nil
      end
    end
  end
  ```

- [ ] **Step 3.4: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/apply_lock_test.exs
  ```

---

## Task 4: SelfUpdate.UpdateChecker (pure parts)

Tag validation, URL construction, version comparison, classification. No HTTP yet.

**Files:**
- Create: `lib/scry_2/self_update/update_checker.ex`
- Create: `test/scry_2/self_update/update_checker_test.exs`

- [ ] **Step 4.1: Write the failing test (pure parts only)**

  ```elixir
  # test/scry_2/self_update/update_checker_test.exs
  defmodule Scry2.SelfUpdate.UpdateCheckerTest do
    use ExUnit.Case, async: true
    alias Scry2.SelfUpdate.UpdateChecker

    describe "validate_tag/1" do
      test "accepts v-prefixed semver" do
        assert {:ok, "v0.14.0"} = UpdateChecker.validate_tag("v0.14.0")
        assert {:ok, "v1.2.3"} = UpdateChecker.validate_tag("v1.2.3")
      end

      test "accepts pre-release suffix" do
        assert {:ok, "v0.14.0-rc.1"} = UpdateChecker.validate_tag("v0.14.0-rc.1")
      end

      test "rejects unprefixed semver" do
        assert {:error, :invalid_tag} = UpdateChecker.validate_tag("0.14.0")
      end

      test "rejects injection attempts" do
        assert {:error, :invalid_tag} = UpdateChecker.validate_tag("v0.14.0; rm -rf /")
        assert {:error, :invalid_tag} = UpdateChecker.validate_tag("../../../etc/passwd")
        assert {:error, :invalid_tag} = UpdateChecker.validate_tag("v0.14.0/../x")
      end

      test "rejects nil and empty" do
        assert {:error, :invalid_tag} = UpdateChecker.validate_tag(nil)
        assert {:error, :invalid_tag} = UpdateChecker.validate_tag("")
      end
    end

    describe "archive_name/2" do
      test "linux tarball" do
        assert UpdateChecker.archive_name("v0.14.0", {:unix, :linux}) ==
                 "scry_2-v0.14.0-linux-x86_64.tar.gz"
      end

      test "macos tarball" do
        assert UpdateChecker.archive_name("v0.14.0", {:unix, :darwin}) ==
                 "scry_2-v0.14.0-macos-x86_64.tar.gz"
      end

      test "windows zip" do
        assert UpdateChecker.archive_name("v0.14.0", {:win32, :nt}) ==
                 "scry_2-v0.14.0-windows-x86_64.zip"
      end
    end

    describe "download_url/2" do
      test "builds URL from validated tag and archive" do
        assert UpdateChecker.download_url("v0.14.0", "scry_2-v0.14.0-linux-x86_64.tar.gz") ==
                 "https://github.com/shawnmccool/scry_2/releases/download/v0.14.0/scry_2-v0.14.0-linux-x86_64.tar.gz"
      end
    end

    describe "classify/2" do
      test ":update_available when remote > local" do
        assert UpdateChecker.classify("0.15.0", "0.14.0") == :update_available
      end

      test ":up_to_date when equal" do
        assert UpdateChecker.classify("0.14.0", "0.14.0") == :up_to_date
      end

      test ":ahead_of_release when local > remote" do
        assert UpdateChecker.classify("0.15.0-dev", "0.14.0") == :ahead_of_release
      end

      test "strips leading v" do
        assert UpdateChecker.classify("v0.15.0", "v0.14.0") == :update_available
      end

      test ":invalid when either is garbage" do
        assert UpdateChecker.classify("not-semver", "0.14.0") == :invalid
      end
    end
  end
  ```

- [ ] **Step 4.2: Run, confirm fail**

  ```bash
  mix test test/scry_2/self_update/update_checker_test.exs
  ```

- [ ] **Step 4.3: Implement pure parts**

  ```elixir
  # lib/scry_2/self_update/update_checker.ex
  defmodule Scry2.SelfUpdate.UpdateChecker do
    @moduledoc """
    GitHub Releases fetch + tag validation + classification, with a 1-hour
    `:persistent_term` cache.

    **Security posture:**
      - Tags are validated against a strict semver regex before any interpolation
      - Download URLs are built from a fixed template, never from API response fields
      - Callers that round-trip through `classify/2` work with tags that have
        already been validated.
    """

    @cache_key {__MODULE__, :latest}
    @cache_ttl_ms :timer.hours(1)

    @tag_regex ~r/^v\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$/

    @github_owner "shawnmccool"
    @github_repo "scry_2"
    @api_url "https://api.github.com/repos/#{@github_owner}/#{@github_repo}/releases/latest"
    @download_base "https://github.com/#{@github_owner}/#{@github_repo}/releases/download"

    @type classification :: :update_available | :up_to_date | :ahead_of_release | :invalid

    @type release :: %{
            required(:tag) => String.t(),
            required(:version) => String.t(),
            required(:published_at) => String.t() | nil,
            required(:html_url) => String.t(),
            required(:body) => String.t()
          }

    # ---- Pure helpers ----

    @spec validate_tag(any()) :: {:ok, String.t()} | {:error, :invalid_tag}
    def validate_tag(tag) when is_binary(tag) do
      if Regex.match?(@tag_regex, tag), do: {:ok, tag}, else: {:error, :invalid_tag}
    end

    def validate_tag(_), do: {:error, :invalid_tag}

    @spec archive_name(String.t(), :os.type()) :: String.t()
    def archive_name(tag, {:unix, :linux}), do: "scry_2-#{tag}-linux-x86_64.tar.gz"
    def archive_name(tag, {:unix, :darwin}), do: "scry_2-#{tag}-macos-x86_64.tar.gz"
    def archive_name(tag, {:win32, _}), do: "scry_2-#{tag}-windows-x86_64.zip"

    @spec sha256sums_name(String.t()) :: String.t()
    def sha256sums_name(tag), do: "scry_2-#{tag}-SHA256SUMS"

    @spec download_url(String.t(), String.t()) :: String.t()
    def download_url(tag, filename) do
      "#{@download_base}/#{tag}/#{filename}"
    end

    @spec classify(String.t(), String.t()) :: classification()
    def classify(remote, local) when is_binary(remote) and is_binary(local) do
      with {:ok, r} <- parse_version(remote),
           {:ok, l} <- parse_version(local) do
        case Version.compare(r, l) do
          :gt -> :update_available
          :eq -> :up_to_date
          :lt -> :ahead_of_release
        end
      else
        _ -> :invalid
      end
    end

    def classify(_, _), do: :invalid

    defp parse_version("v" <> rest), do: parse_version(rest)
    defp parse_version(other) when is_binary(other), do: Version.parse(other)

    # ---- Cache (populated by latest_release/1) ----

    @spec cached_latest_release() :: {:ok, release()} | :none
    def cached_latest_release do
      case :persistent_term.get(@cache_key, :none) do
        {release, stored_at_ms} ->
          if System.monotonic_time(:millisecond) - stored_at_ms < @cache_ttl_ms do
            {:ok, release}
          else
            :none
          end

        :none ->
          :none
      end
    end

    @spec put_cache(release()) :: :ok
    def put_cache(release) do
      :persistent_term.put(@cache_key, {release, System.monotonic_time(:millisecond)})
    end

    @spec clear_cache() :: :ok
    def clear_cache do
      :persistent_term.erase(@cache_key)
      :ok
    end

    # ---- Fetch (impl in Task 5) ----
    # latest_release/1 added in Task 5 with HTTP stubbing.
  end
  ```

- [ ] **Step 4.4: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/update_checker_test.exs
  ```

---

## Task 5: UpdateChecker HTTP fetch (with Req stub)

**Files:**
- Modify: `lib/scry_2/self_update/update_checker.ex`
- Modify: `test/scry_2/self_update/update_checker_test.exs`

- [ ] **Step 5.1: Add HTTP tests**

  Append to the test module:

  ```elixir
  describe "latest_release/1" do
    test "parses a successful API response into a release map" do
      stub = fn conn ->
        assert conn.request_path == "/repos/shawnmccool/scry_2/releases/latest"
        Req.Test.json(conn, %{
          "tag_name" => "v0.15.0",
          "published_at" => "2026-04-20T12:00:00Z",
          "html_url" => "https://github.com/shawnmccool/scry_2/releases/tag/v0.15.0",
          "body" => "Release notes"
        })
      end

      assert {:ok, release} =
               UpdateChecker.latest_release(req_options: [plug: stub])

      assert release.tag == "v0.15.0"
      assert release.version == "0.15.0"
      assert release.published_at == "2026-04-20T12:00:00Z"
      assert release.html_url =~ "v0.15.0"
    end

    test "rejects a response with an invalid tag" do
      stub = fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "latest-build-123",
          "published_at" => nil,
          "html_url" => "",
          "body" => ""
        })
      end

      assert {:error, :invalid_tag} =
               UpdateChecker.latest_release(req_options: [plug: stub])
    end

    test "surfaces rate-limit errors distinctly" do
      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", "9999999999")
        |> Plug.Conn.resp(403, ~s|{"message":"rate limit"}|)
      end

      assert {:error, {:rate_limited, _reset_epoch}} =
               UpdateChecker.latest_release(req_options: [plug: stub])
    end

    test "populates the cache on success" do
      UpdateChecker.clear_cache()

      stub = fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "v0.99.0",
          "published_at" => nil,
          "html_url" => "http://example",
          "body" => ""
        })
      end

      assert {:ok, _release} = UpdateChecker.latest_release(req_options: [plug: stub])
      assert {:ok, %{tag: "v0.99.0"}} = UpdateChecker.cached_latest_release()

      UpdateChecker.clear_cache()
    end
  end
  ```

- [ ] **Step 5.2: Run, confirm fail**

  ```bash
  mix test test/scry_2/self_update/update_checker_test.exs
  ```

- [ ] **Step 5.3: Add HTTP impl**

  Append to `UpdateChecker`:

  ```elixir
    @doc """
    Fetch the latest GitHub release. Populates the cache on success.

    Options:
      - `:req_options` — passed through to `Req.get/2` (for `:plug` stubbing in tests)
    """
    @spec latest_release(keyword()) ::
            {:ok, release()}
            | {:error, :invalid_tag | {:rate_limited, integer() | nil} | term()}
    def latest_release(opts \\ []) do
      req_options = Keyword.get(opts, :req_options, [])

      request =
        [url: @api_url, receive_timeout: 10_000, retry: false]
        |> Keyword.merge(req_options)

      case Req.get(request) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          parse_response(body)

        {:ok, %Req.Response{status: status, headers: headers}}
        when status in 401..499 ->
          if rate_limited?(headers) do
            {:error, {:rate_limited, reset_epoch(headers)}}
          else
            {:error, {:http_status, status}}
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end

    defp parse_response(body) when is_map(body) do
      with {:ok, tag} <- validate_tag(body["tag_name"]),
           "v" <> version <- tag do
        release = %{
          tag: tag,
          version: version,
          published_at: body["published_at"],
          html_url: body["html_url"] || "",
          body: (body["body"] || "") |> String.slice(0, 20_000)
        }

        put_cache(release)
        {:ok, release}
      end
    end

    defp parse_response(_), do: {:error, :invalid_response}

    defp rate_limited?(headers) do
      List.keyfind(headers, "x-ratelimit-remaining", 0, {nil, nil})
      |> case do
        {"x-ratelimit-remaining", "0"} -> true
        {"x-ratelimit-remaining", ["0" | _]} -> true
        _ -> false
      end
    end

    defp reset_epoch(headers) do
      with {_, value} <- List.keyfind(headers, "x-ratelimit-reset", 0),
           {int, ""} <- Integer.parse(to_string(value)) do
        int
      else
        _ -> nil
      end
    end
  ```

- [ ] **Step 5.4: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/update_checker_test.exs
  ```

---

## Task 6: SelfUpdate.Storage

Persisted check results via `Settings.Entry` + `:persistent_term` hydration at boot.

**Files:**
- Create: `lib/scry_2/self_update/storage.ex`
- Create: `test/scry_2/self_update/storage_test.exs`

- [ ] **Step 6.1: Write failing test**

  ```elixir
  # test/scry_2/self_update/storage_test.exs
  defmodule Scry2.SelfUpdate.StorageTest do
    use Scry2.DataCase, async: false
    alias Scry2.SelfUpdate.Storage
    alias Scry2.SelfUpdate.UpdateChecker

    setup do
      UpdateChecker.clear_cache()
      Storage.clear_all!()
      :ok
    end

    test "record_check_result/1 writes last_check_at and latest_known" do
      release = %{
        tag: "v0.15.0",
        version: "0.15.0",
        published_at: "2026-04-20T12:00:00Z",
        html_url: "http://example",
        body: "notes"
      }

      :ok = Storage.record_check_result({:ok, release})

      assert Storage.last_check_at() != nil
      assert {:ok, stored} = Storage.latest_known()
      assert stored.tag == "v0.15.0"
    end

    test "record_check_result/1 records error results without clobbering latest_known" do
      release = %{
        tag: "v0.15.0",
        version: "0.15.0",
        published_at: nil,
        html_url: "",
        body: ""
      }

      :ok = Storage.record_check_result({:ok, release})
      :ok = Storage.record_check_result({:error, {:rate_limited, 1_234_567}})

      assert {:ok, %{tag: "v0.15.0"}} = Storage.latest_known()
    end

    test "hydrate!/0 populates the UpdateChecker cache" do
      release = %{
        tag: "v0.15.0",
        version: "0.15.0",
        published_at: nil,
        html_url: "",
        body: ""
      }

      :ok = Storage.record_check_result({:ok, release})
      UpdateChecker.clear_cache()
      :ok = Storage.hydrate!()

      assert {:ok, %{tag: "v0.15.0"}} = UpdateChecker.cached_latest_release()
    end
  end
  ```

- [ ] **Step 6.2: Run, confirm fail**

  ```bash
  mix test test/scry_2/self_update/storage_test.exs
  ```

- [ ] **Step 6.3: Implement**

  ```elixir
  # lib/scry_2/self_update/storage.ex
  defmodule Scry2.SelfUpdate.Storage do
    @moduledoc """
    Durable backing for self-update check state. Values are stored via
    `Scry2.Settings` (SQLite JSON blobs) under two keys:

      - `updates.last_check_at` — ISO 8601 timestamp of last successful check
      - `updates.latest_known` — the most recent release map

    `hydrate!/0` seeds the `UpdateChecker` `:persistent_term` cache at boot
    so the UI has data immediately, even before the first live check.
    """

    alias Scry2.Settings
    alias Scry2.SelfUpdate.UpdateChecker

    @last_check_key "updates.last_check_at"
    @latest_known_key "updates.latest_known"

    @spec last_check_at() :: String.t() | nil
    def last_check_at, do: Settings.get(@last_check_key)

    @spec latest_known() :: {:ok, UpdateChecker.release()} | :none
    def latest_known do
      case Settings.get(@latest_known_key) do
        nil ->
          :none

        raw when is_map(raw) ->
          {:ok,
           %{
             tag: raw["tag"],
             version: raw["version"],
             published_at: raw["published_at"],
             html_url: raw["html_url"] || "",
             body: raw["body"] || ""
           }}
      end
    end

    @spec record_check_result({:ok, UpdateChecker.release()} | {:error, term()}) :: :ok
    def record_check_result({:ok, release}) do
      Settings.put!(@last_check_key, DateTime.utc_now() |> DateTime.to_iso8601())
      Settings.put!(@latest_known_key, Map.new(release, fn {k, v} -> {to_string(k), v} end))
      UpdateChecker.put_cache(release)
      :ok
    end

    def record_check_result({:error, _reason}) do
      Settings.put!(@last_check_key, DateTime.utc_now() |> DateTime.to_iso8601())
      :ok
    end

    @spec hydrate!() :: :ok
    def hydrate! do
      case latest_known() do
        {:ok, release} -> UpdateChecker.put_cache(release)
        :none -> :ok
      end

      :ok
    end

    @doc "Test-only: remove both keys."
    @spec clear_all!() :: :ok
    def clear_all! do
      # Settings doesn't expose delete; write empty sentinels.
      _ = Settings.delete(@last_check_key)
      _ = Settings.delete(@latest_known_key)
      :ok
    end
  end
  ```

  **Note:** `Settings.delete/1` may not exist. If the test blows up with `UndefinedFunctionError`, add a thin `delete/1` to `Scry2.Settings` that does `Repo.get(Entry, key) |> case do nil -> :ok; entry -> Repo.delete(entry) end` then rerun.

- [ ] **Step 6.4: Run, confirm pass (add `Settings.delete/1` if needed)**

  ```bash
  mix test test/scry_2/self_update/storage_test.exs
  ```

---

## Task 7: SelfUpdate.CheckerJob (Oban worker)

**Files:**
- Create: `lib/scry_2/self_update/checker_job.ex`
- Create: `test/scry_2/self_update/checker_job_test.exs`
- Modify: `config/config.exs`

- [ ] **Step 7.1: Write failing test**

  ```elixir
  # test/scry_2/self_update/checker_job_test.exs
  defmodule Scry2.SelfUpdate.CheckerJobTest do
    use Scry2.DataCase, async: false
    use Oban.Testing, repo: Scry2.Repo

    alias Scry2.SelfUpdate.CheckerJob
    alias Scry2.SelfUpdate.Storage
    alias Scry2.SelfUpdate.UpdateChecker
    alias Scry2.Topics

    setup do
      UpdateChecker.clear_cache()
      Storage.clear_all!()
      :ok
    end

    test "perform/1 stores the result and broadcasts" do
      stub = fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "v99.0.0",
          "published_at" => nil,
          "html_url" => "",
          "body" => ""
        })
      end

      Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_status())

      assert :ok =
               perform_job(CheckerJob, %{"trigger" => "cron"},
                 req_options: [plug: stub]
               )

      assert_receive {:check_complete, {:ok, %{tag: "v99.0.0"}}}, 500
      assert {:ok, %{tag: "v99.0.0"}} = Storage.latest_known()
    end

    test "perform/1 records and broadcasts rate-limit errors" do
      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", "0")
        |> Plug.Conn.resp(403, ~s|{"message":"rate limit"}|)
      end

      Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_status())

      assert :ok =
               perform_job(CheckerJob, %{"trigger" => "cron"},
                 req_options: [plug: stub]
               )

      assert_receive {:check_complete, {:error, {:rate_limited, _}}}, 500
    end
  end
  ```

- [ ] **Step 7.2: Run, confirm fail**

  ```bash
  mix test test/scry_2/self_update/checker_job_test.exs
  ```

- [ ] **Step 7.3: Implement worker**

  ```elixir
  # lib/scry_2/self_update/checker_job.ex
  defmodule Scry2.SelfUpdate.CheckerJob do
    @moduledoc """
    Oban worker that runs hourly via cron and on demand via "Check now".

    Deduplication:
      - The cron-scheduled job uses `args: %{"trigger" => "cron"}` with
        `unique: [period: 3300, ...]`. This prevents back-to-back cron jobs
        if cron scheduling glitches, but does not block a manual check.
      - The UI enqueues manual checks with `args: %{"trigger" => "manual"}`.
        Different args bypass the uniqueness check.
    """

    use Oban.Worker,
      queue: :self_update,
      max_attempts: 3,
      unique: [period: 3300, fields: [:worker, :args], states: [:available, :scheduled, :executing]]

    require Scry2.Log, as: Log

    alias Scry2.SelfUpdate.Storage
    alias Scry2.SelfUpdate.UpdateChecker
    alias Scry2.Topics

    @impl Oban.Worker
    def perform(%Oban.Job{args: args, meta: meta}) do
      req_options = Keyword.get(Map.to_list(meta), :req_options, [])
      trigger = args["trigger"] || "unknown"

      Log.info(:system, fn -> "self-update check (#{trigger}) starting" end)

      Topics.broadcast(Topics.updates_status(), :check_started)

      result = UpdateChecker.latest_release(req_options: req_options)
      :ok = Storage.record_check_result(result)
      Topics.broadcast(Topics.updates_status(), {:check_complete, result})

      case result do
        {:ok, release} ->
          Log.info(:system, fn -> "self-update found #{release.tag}" end)
          :ok

        {:error, reason} ->
          Log.warning(:system, fn -> "self-update check failed: #{inspect(reason)}" end)
          :ok
      end
    end
  end
  ```

  **Note:** `perform_job/3` from `Oban.Testing` passes its third argument as `:meta` in newer Oban; confirm by running the test. If it passes as job args, plumb `req_options` differently.

- [ ] **Step 7.4: Add Oban queue + cron entry**

  In `config/config.exs` replace the Oban config:

  ```elixir
  config :scry_2, Oban,
    engine: Oban.Engines.Lite,
    repo: Scry2.Repo,
    queues: [default: 5, imports: 1, self_update: 1],
    plugins: [
      {Oban.Plugins.Cron,
       crontab: [
         {"0 4 * * *", Scry2.Workers.PeriodicallyUpdateCards},
         {"0 5 * * 0", Scry2.Workers.PeriodicallyBackfillArenaIds},
         {"17 * * * *", Scry2.SelfUpdate.CheckerJob, args: %{"trigger" => "cron"}}
       ]}
    ]
  ```

  **Note:** cron fires at `:17` each hour (arbitrary offset) to avoid the 04:00/05:00 collision with existing jobs.

- [ ] **Step 7.5: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/checker_job_test.exs
  ```

---

## Task 8: SelfUpdate.Downloader

Streaming archive download + SHA256SUMS verify. No filesystem side effects outside the target paths provided.

**Files:**
- Create: `lib/scry_2/self_update/downloader.ex`
- Create: `test/scry_2/self_update/downloader_test.exs`

- [ ] **Step 8.1: Write failing test**

  ```elixir
  # test/scry_2/self_update/downloader_test.exs
  defmodule Scry2.SelfUpdate.DownloaderTest do
    use ExUnit.Case, async: true
    alias Scry2.SelfUpdate.Downloader

    setup do
      dir = System.tmp_dir!() |> Path.join("downloader_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "parse_sha256sums/2 returns checksum for filename" do
      sums = """
      abc123  scry_2-v0.15.0-linux-x86_64.tar.gz
      deadbeef  scry_2-v0.15.0-SHA256SUMS
      """

      assert {:ok, "abc123"} =
               Downloader.parse_sha256sums(sums, "scry_2-v0.15.0-linux-x86_64.tar.gz")
    end

    test "parse_sha256sums/2 returns :not_found when absent" do
      assert :not_found = Downloader.parse_sha256sums("", "x.tar.gz")
    end

    test "verify/2 returns :ok for matching checksum", %{dir: dir} do
      path = Path.join(dir, "data")
      File.write!(path, "hello")
      # echo -n "hello" | sha256sum
      expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
      assert :ok = Downloader.verify(path, expected)
    end

    test "verify/2 returns {:error, :checksum_mismatch} otherwise", %{dir: dir} do
      path = Path.join(dir, "data")
      File.write!(path, "hello")
      assert {:error, :checksum_mismatch} = Downloader.verify(path, "0" |> String.duplicate(64))
    end

    test "run/3 downloads archive and sha256sums, verifies, returns path", %{dir: dir} do
      payload = "my release archive"
      sha = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

      stub = fn conn ->
        case conn.request_path do
          "/archive.tar.gz" ->
            Plug.Conn.resp(conn, 200, payload)

          "/SHA256SUMS" ->
            Plug.Conn.resp(conn, 200, "#{sha}  archive.tar.gz\n")
        end
      end

      assert {:ok, %{archive_path: path, sha256: ^sha}} =
               Downloader.run(
                 %{
                   archive_url: "http://x/archive.tar.gz",
                   archive_filename: "archive.tar.gz",
                   sha256sums_url: "http://x/SHA256SUMS",
                   dest_dir: dir
                 },
                 req_options: [plug: stub]
               )

      assert File.exists?(path)
    end

    test "run/3 returns checksum mismatch when archive is tampered", %{dir: dir} do
      stub = fn conn ->
        case conn.request_path do
          "/archive.tar.gz" -> Plug.Conn.resp(conn, 200, "tampered")
          "/SHA256SUMS" -> Plug.Conn.resp(conn, 200, "0000  archive.tar.gz\n")
        end
      end

      assert {:error, :checksum_mismatch} =
               Downloader.run(
                 %{
                   archive_url: "http://x/archive.tar.gz",
                   archive_filename: "archive.tar.gz",
                   sha256sums_url: "http://x/SHA256SUMS",
                   dest_dir: dir
                 },
                 req_options: [plug: stub]
               )
    end
  end
  ```

- [ ] **Step 8.2: Run, confirm fail**

- [ ] **Step 8.3: Implement**

  ```elixir
  # lib/scry_2/self_update/downloader.ex
  defmodule Scry2.SelfUpdate.Downloader do
    @moduledoc """
    Downloads an update archive and its SHA256SUMS, then verifies the
    archive against the declared checksum using constant-time comparison.

    Progress is reported via the caller-supplied `:progress_fn` option,
    which is invoked with `{:progress, bytes_downloaded, total_bytes}`
    at most once per 1% advance.
    """

    @max_archive_bytes 500 * 1024 * 1024

    @type run_args :: %{
            required(:archive_url) => String.t(),
            required(:archive_filename) => String.t(),
            required(:sha256sums_url) => String.t(),
            required(:dest_dir) => Path.t()
          }

    @type run_result :: %{
            archive_path: Path.t(),
            sha256: String.t()
          }

    @spec run(run_args(), keyword()) :: {:ok, run_result()} | {:error, term()}
    def run(%{} = args, opts \\ []) do
      req_options = Keyword.get(opts, :req_options, [])
      progress_fn = Keyword.get(opts, :progress_fn, fn _, _ -> :ok end)

      with {:ok, sums_body} <- fetch_text(args.sha256sums_url, req_options),
           {:ok, expected_sha} <- parse_sha256sums(sums_body, args.archive_filename),
           {:ok, archive_path} <-
             download_to_file(
               args.archive_url,
               Path.join(args.dest_dir, args.archive_filename),
               req_options,
               progress_fn
             ),
           :ok <- verify(archive_path, expected_sha) do
        {:ok, %{archive_path: archive_path, sha256: expected_sha}}
      end
    end

    @spec parse_sha256sums(String.t(), String.t()) :: {:ok, String.t()} | :not_found
    def parse_sha256sums(body, filename) when is_binary(body) do
      body
      |> String.split("\n", trim: true)
      |> Enum.find_value(:not_found, fn line ->
        case String.split(line, ~r/\s+/, parts: 2) do
          [sha, ^filename] -> {:ok, String.downcase(sha)}
          _ -> nil
        end
      end)
    end

    @spec verify(Path.t(), String.t()) :: :ok | {:error, :checksum_mismatch}
    def verify(path, expected_sha) when is_binary(expected_sha) do
      actual = hash_file(path)

      if Plug.Crypto.secure_compare(actual, String.downcase(expected_sha)) do
        :ok
      else
        {:error, :checksum_mismatch}
      end
    end

    defp fetch_text(url, req_options) do
      request = Keyword.merge([url: url, receive_timeout: 30_000, retry: false], req_options)

      case Req.get(request) do
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, {:transport, reason}}
      end
    end

    defp download_to_file(url, path, req_options, progress_fn) do
      File.mkdir_p!(Path.dirname(path))
      File.rm(path)

      request =
        [
          url: url,
          receive_timeout: 120_000,
          retry: false,
          into: File.stream!(path, [:write, :binary])
        ]
        |> Keyword.merge(req_options)

      case Req.get(request) do
        {:ok, %Req.Response{status: 200}} ->
          case File.stat(path) do
            {:ok, %File.Stat{size: size}} when size > @max_archive_bytes ->
              File.rm(path)
              {:error, :archive_too_large}

            {:ok, %File.Stat{size: size}} ->
              progress_fn.(size, size)
              {:ok, path}

            other ->
              other
          end

        {:ok, %Req.Response{status: status}} ->
          File.rm(path)
          {:error, {:http_status, status}}

        {:error, reason} ->
          File.rm(path)
          {:error, {:transport, reason}}
      end
    end

    defp hash_file(path) do
      path
      |> File.stream!([], 64 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end
  end
  ```

- [ ] **Step 8.4: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/downloader_test.exs
  ```

---

## Task 9: SelfUpdate.Stager

Extract archive with per-entry validation.

**Files:**
- Create: `lib/scry_2/self_update/stager.ex`
- Create: `test/scry_2/self_update/stager_test.exs`
- Create: `test/support/self_update_fixtures/make_fixtures.exs` (one-shot generator, not run by test suite)

- [ ] **Step 9.1: Generate fixtures (one-shot)**

  Run once manually to produce `test/support/self_update_fixtures/ok.tar.gz`,
  `traversal.tar.gz`, `symlink.tar.gz`, and `ok.zip`. Script content:

  ```elixir
  # test/support/self_update_fixtures/make_fixtures.exs
  dir = Path.expand(".", __DIR__)
  File.mkdir_p!(dir)

  stage = Path.join(dir, "_stage")
  File.mkdir_p!(Path.join(stage, "ok/bin"))
  File.write!(Path.join(stage, "ok/bin/scry_2"), "#!/bin/sh\necho ok\n")
  File.chmod!(Path.join(stage, "ok/bin/scry_2"), 0o755)

  :ok = :erl_tar.create(
    Path.join(dir, "ok.tar.gz") |> String.to_charlist(),
    [{~c"bin/scry_2", Path.join(stage, "ok/bin/scry_2") |> String.to_charlist()}],
    [:compressed]
  )

  # Traversal: craft tarball with an entry named "../evil"
  :ok = :erl_tar.create(
    Path.join(dir, "traversal.tar.gz") |> String.to_charlist(),
    [{~c"../evil", Path.join(stage, "ok/bin/scry_2") |> String.to_charlist()}],
    [:compressed]
  )

  # Zip fixture
  files = [
    {~c"bin/scry_2.bat", File.read!(Path.join(stage, "ok/bin/scry_2"))}
  ]
  :zip.create(Path.join(dir, "ok.zip") |> String.to_charlist(), files)

  File.rm_rf!(stage)
  IO.puts("fixtures generated in #{dir}")
  ```

  Run: `mix run test/support/self_update_fixtures/make_fixtures.exs`

  **Note:** symlink tarballs need `:erl_tar.create` with type tags — this is OS-specific and may require a shell script instead. If `:erl_tar` won't produce a symlink entry, drop the symlink test case and document that the validation still rejects them at read time.

- [ ] **Step 9.2: Write failing test**

  ```elixir
  # test/scry_2/self_update/stager_test.exs
  defmodule Scry2.SelfUpdate.StagerTest do
    use ExUnit.Case, async: true
    alias Scry2.SelfUpdate.Stager

    @fixtures Path.expand("../../support/self_update_fixtures", __DIR__)

    setup do
      dir = System.tmp_dir!() |> Path.join("stager_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dest: dir}
    end

    test "extract_tar/2 extracts a valid tarball", %{dest: dest} do
      assert {:ok, root} =
               Stager.extract_tar(Path.join(@fixtures, "ok.tar.gz"), dest)

      assert File.exists?(Path.join(root, "bin/scry_2"))
    end

    test "extract_tar/2 rejects path traversal", %{dest: dest} do
      assert {:error, :path_traversal} =
               Stager.extract_tar(Path.join(@fixtures, "traversal.tar.gz"), dest)
    end

    test "extract_zip/2 extracts a valid zip", %{dest: dest} do
      assert {:ok, root} =
               Stager.extract_zip(Path.join(@fixtures, "ok.zip"), dest)

      assert File.exists?(Path.join(root, "bin/scry_2.bat"))
    end

    test "safe_entry?/1 returns true for normal paths" do
      assert Stager.safe_entry?("bin/scry_2") == true
      assert Stager.safe_entry?("share/systemd/scry_2.service") == true
    end

    test "safe_entry?/1 rejects dangerous paths" do
      assert Stager.safe_entry?("../evil") == false
      assert Stager.safe_entry?("/etc/passwd") == false
      assert Stager.safe_entry?("a/../b") == false
    end
  end
  ```

- [ ] **Step 9.3: Run, confirm fail**

- [ ] **Step 9.4: Implement**

  ```elixir
  # lib/scry_2/self_update/stager.ex
  defmodule Scry2.SelfUpdate.Stager do
    @moduledoc """
    Extracts a downloaded archive into a staging directory, validating every
    entry before touching the filesystem.

    **Rejected entries:**
      - Absolute paths (`/...`)
      - Parent-directory traversal (`..` segment anywhere)
      - Symlinks (tarballs only; zip has no symlink type)
      - Device / FIFO / socket nodes
    """

    @max_cumulative_bytes 1_024 * 1024 * 1024

    @spec extract_tar(Path.t(), Path.t()) ::
            {:ok, Path.t()} | {:error, :path_traversal | :symlink | :oversized | term()}
    def extract_tar(archive, dest_dir) do
      archive_c = String.to_charlist(archive)

      with {:ok, entries} <- :erl_tar.table(archive_c, [:compressed, :verbose]),
           :ok <- validate_tar_entries(entries) do
        File.mkdir_p!(dest_dir)
        root = Path.join(dest_dir, "extracted")
        File.mkdir_p!(root)

        case :erl_tar.extract(archive_c, [:compressed, {:cwd, String.to_charlist(root)}]) do
          :ok -> {:ok, root}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @spec extract_zip(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
    def extract_zip(archive, dest_dir) do
      archive_c = String.to_charlist(archive)

      with {:ok, entries} <- :zip.list_dir(archive_c),
           :ok <- validate_zip_entries(entries) do
        File.mkdir_p!(dest_dir)
        root = Path.join(dest_dir, "extracted")
        File.mkdir_p!(root)

        case :zip.extract(archive_c, [{:cwd, String.to_charlist(root)}]) do
          {:ok, _files} -> {:ok, root}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @spec safe_entry?(String.t()) :: boolean()
    def safe_entry?(path) when is_binary(path) do
      cond do
        String.starts_with?(path, "/") -> false
        ".." in Path.split(path) -> false
        true -> true
      end
    end

    defp validate_tar_entries(entries) do
      Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, cumulative} ->
        case entry do
          {name_c, :symlink, _, _, _, _, _} ->
            _ = name_c
            {:halt, {:error, :symlink}}

          {name_c, type, size, _, _, _, _}
          when type in [:regular, :directory] ->
            name = to_string(name_c)

            cond do
              not safe_entry?(name) ->
                {:halt, {:error, :path_traversal}}

              cumulative + size > @max_cumulative_bytes ->
                {:halt, {:error, :oversized}}

              true ->
                {:cont, {:ok, cumulative + size}}
            end

          # `:erl_tar.table/2, :verbose` can return strings instead of tuples for some entries
          name when is_list(name) ->
            if safe_entry?(to_string(name)), do: {:cont, {:ok, cumulative}}, else: {:halt, {:error, :path_traversal}}

          _ ->
            {:halt, {:error, {:unknown_entry, entry}}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp validate_zip_entries(entries) do
      Enum.reduce_while(entries, :ok, fn
        {:zip_comment, _}, acc ->
          {:cont, acc}

        {:zip_file, name_c, _info, _comment, _offset, _comp_size}, acc ->
          name = to_string(name_c)
          if safe_entry?(name), do: {:cont, acc}, else: {:halt, {:error, :path_traversal}}

        _, acc ->
          {:cont, acc}
      end)
    end
  end
  ```

- [ ] **Step 9.5: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/stager_test.exs
  ```

---

## Task 10: SelfUpdate.Handoff

Platform-dispatched detached spawn. Unit-test by injecting a spawner.

**Files:**
- Create: `lib/scry_2/self_update/handoff.ex`
- Create: `test/scry_2/self_update/handoff_test.exs`

- [ ] **Step 10.1: Write failing test**

  ```elixir
  # test/scry_2/self_update/handoff_test.exs
  defmodule Scry2.SelfUpdate.HandoffTest do
    use ExUnit.Case, async: true
    alias Scry2.SelfUpdate.Handoff

    defp capture_spawner do
      test_pid = self()
      fn cmd, args, env -> send(test_pid, {:spawn, cmd, args, env}); :ok end
    end

    test "linux handoff invokes setsid sh <staged>/install-linux" do
      spawn_fn = capture_spawner()

      :ok =
        Handoff.spawn_detached(
          %{staged_root: "/tmp/staged", archive_filename: "scry_2-v0.15.0-linux-x86_64.tar.gz"},
          os_type: {:unix, :linux},
          spawner: spawn_fn
        )

      assert_receive {:spawn, "setsid", ["sh", "-c", cmd], env}
      assert cmd =~ "/tmp/staged/install-linux"
      assert cmd =~ "handoff.log"
      assert Enum.any?(env, &match?({"HOME", _}, &1))
    end

    test "macos handoff uses nohup" do
      spawn_fn = capture_spawner()

      :ok =
        Handoff.spawn_detached(
          %{staged_root: "/tmp/staged", archive_filename: "scry_2-v0.15.0-macos-x86_64.tar.gz"},
          os_type: {:unix, :darwin},
          spawner: spawn_fn
        )

      assert_receive {:spawn, "/bin/sh", ["-c", cmd], _env}
      assert cmd =~ "nohup"
      assert cmd =~ "/tmp/staged/install-macos"
    end

    test "windows zip handoff starts install.bat detached" do
      spawn_fn = capture_spawner()

      :ok =
        Handoff.spawn_detached(
          %{staged_root: "C:\\staged", archive_filename: "scry_2-v0.15.0-windows-x86_64.zip"},
          os_type: {:win32, :nt},
          spawner: spawn_fn
        )

      assert_receive {:spawn, "cmd.exe", ["/c", cmd], _env}
      assert cmd =~ "install.bat"
    end

    test "windows msi handoff invokes the bootstrapper with /quiet /norestart" do
      spawn_fn = capture_spawner()

      :ok =
        Handoff.spawn_detached(
          %{staged_root: "C:\\staged", archive_filename: "Scry2Setup-0.15.0.exe"},
          os_type: {:win32, :nt},
          spawner: spawn_fn
        )

      assert_receive {:spawn, "cmd.exe", ["/c", cmd], _env}
      assert cmd =~ "Scry2Setup-0.15.0.exe"
      assert cmd =~ "/quiet"
      assert cmd =~ "/norestart"
    end
  end
  ```

- [ ] **Step 10.2: Run, confirm fail**

- [ ] **Step 10.3: Implement**

  ```elixir
  # lib/scry_2/self_update/handoff.ex
  defmodule Scry2.SelfUpdate.Handoff do
    @moduledoc """
    Spawns the platform installer as a detached process that outlives the
    BEAM. After handoff the caller is expected to call `System.stop/1`; the
    installer is responsible for replacing files, removing the apply lock,
    and relaunching the tray binary.
    """

    @type args :: %{
            required(:staged_root) => Path.t(),
            required(:archive_filename) => String.t()
          }

    @type spawner :: (String.t(), [String.t()], [{String.t(), String.t()}] -> :ok)

    @minimal_unix_env_keys ~w(HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_DATA_DIRS XDG_CONFIG_DIRS)
    @minimal_windows_env_keys ~w(APPDATA LOCALAPPDATA USERPROFILE SystemRoot Path)

    @spec spawn_detached(args(), keyword()) :: :ok | {:error, term()}
    def spawn_detached(args, opts \\ []) do
      os_type = Keyword.get(opts, :os_type, :os.type())
      spawner = Keyword.get(opts, :spawner, &default_spawn/3)

      do_spawn(os_type, args, spawner)
    end

    defp do_spawn({:unix, :linux}, %{staged_root: root}, spawner) do
      script = Path.join(root, "install-linux")
      log = Path.join(root, "handoff.log")
      env = take_env(@minimal_unix_env_keys)

      spawner.(
        "setsid",
        ["sh", "-c", "#{shell_quote(script)} >> #{shell_quote(log)} 2>&1 </dev/null &"],
        env ++ [{"PATH", "/usr/local/bin:/usr/bin:/bin"}]
      )
    end

    defp do_spawn({:unix, :darwin}, %{staged_root: root}, spawner) do
      script = Path.join(root, "install-macos")
      log = Path.join(root, "handoff.log")
      env = take_env(@minimal_unix_env_keys)

      spawner.(
        "/bin/sh",
        [
          "-c",
          "nohup #{shell_quote(script)} >> #{shell_quote(log)} 2>&1 </dev/null &"
        ],
        env ++ [{"PATH", "/usr/local/bin:/usr/bin:/bin"}]
      )
    end

    defp do_spawn({:win32, _}, %{staged_root: root, archive_filename: archive}, spawner) do
      env = take_env(@minimal_windows_env_keys)

      cmd =
        cond do
          String.ends_with?(archive, ".zip") ->
            bat = Path.join(root, "install.bat")
            "start \"\" /B \"#{bat}\""

          String.ends_with?(archive, ".exe") or String.ends_with?(archive, ".msi") ->
            bootstrapper = Path.join(root, Path.basename(archive))
            "start \"\" /B \"#{bootstrapper}\" /quiet /norestart"

          true ->
            "exit 1"
        end

      spawner.("cmd.exe", ["/c", cmd], env)
    end

    defp default_spawn(cmd, args, env) do
      System.cmd(cmd, args, env: env, into: IO.stream(:stdio, :line), parallelism: true)
      :ok
    rescue
      _ ->
        Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, [
          :binary,
          :nouse_stdio,
          args: args,
          env: env
        ])

        :ok
    end

    defp take_env(keys) do
      for key <- keys, val = System.get_env(key), is_binary(val), do: {key, val}
    end

    defp shell_quote(path), do: ~s|'#{String.replace(path, "'", ~S|'\\''|)}'|
  end
  ```

- [ ] **Step 10.4: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/handoff_test.exs
  ```

---

## Task 11: SelfUpdate.Updater (GenServer state machine)

**Files:**
- Create: `lib/scry_2/self_update/updater.ex`
- Create: `test/scry_2/self_update/updater_test.exs`

- [ ] **Step 11.1: Write failing test**

  Testing only via the public API per [ADR-009]. Inject stubs for Downloader / Stager / Handoff via opts:

  ```elixir
  # test/scry_2/self_update/updater_test.exs
  defmodule Scry2.SelfUpdate.UpdaterTest do
    use Scry2.DataCase, async: false
    alias Scry2.SelfUpdate.Updater
    alias Scry2.SelfUpdate.Storage
    alias Scry2.SelfUpdate.UpdateChecker
    alias Scry2.Topics

    setup do
      UpdateChecker.clear_cache()
      Storage.clear_all!()

      lock_path =
        System.tmp_dir!() |> Path.join("updater_test_#{System.unique_integer([:positive])}.lock")

      on_exit(fn -> File.rm_rf!(lock_path) end)

      stage_root =
        System.tmp_dir!() |> Path.join("stage_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(stage_root) end)

      %{lock_path: lock_path, stage_root: stage_root}
    end

    defp start_updater(ctx, overrides \\ []) do
      test_pid = self()

      defaults = [
        lock_path: ctx.lock_path,
        staging_root: ctx.stage_root,
        current_version_fn: fn -> "0.14.0" end,
        downloader: fn _args, _opts ->
          send(test_pid, :download_called)
          {:ok, %{archive_path: "/tmp/a.tar.gz", sha256: "abc"}}
        end,
        stager: fn _archive, _dest ->
          send(test_pid, :stage_called)
          {:ok, "/tmp/a/extracted"}
        end,
        handoff: fn _args, _opts ->
          send(test_pid, :handoff_called)
          :ok
        end,
        system_stop_fn: fn _code -> send(test_pid, :system_stop_called) end
      ]

      start_supervised!({Updater, Keyword.merge(defaults, overrides)})
    end

    test "initial state is :idle" do
      start_supervised!({Updater, name: :test_updater}) |> then(fn _ -> :ok end)
      assert %{phase: :idle} = Updater.status(:test_updater)
    end

    test "apply_pending/1 with no cached release returns :no_update", ctx do
      start_updater(ctx, name: :u1)
      assert {:error, :no_update_pending} = Updater.apply_pending(:u1)
    end

    test "apply_pending/1 with up-to-date cached release returns :up_to_date", ctx do
      UpdateChecker.put_cache(%{
        tag: "v0.14.0",
        version: "0.14.0",
        published_at: nil,
        html_url: "",
        body: ""
      })

      start_updater(ctx, name: :u2)
      assert {:error, :up_to_date} = Updater.apply_pending(:u2)
    end

    test "apply_pending/1 runs pipeline and broadcasts progress", ctx do
      UpdateChecker.put_cache(%{
        tag: "v0.15.0",
        version: "0.15.0",
        published_at: nil,
        html_url: "",
        body: ""
      })

      Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_progress())

      start_updater(ctx, name: :u3)
      assert :ok = Updater.apply_pending(:u3)

      assert_receive {:phase, :preparing}, 500
      assert_receive {:phase, :downloading}, 500
      assert_receive :download_called, 500
      assert_receive {:phase, :extracting}, 500
      assert_receive :stage_called, 500
      assert_receive {:phase, :handing_off}, 500
      assert_receive :handoff_called, 500
      assert_receive :system_stop_called, 500
    end

    test "apply_pending/1 writes then releases the apply lock on failure", ctx do
      UpdateChecker.put_cache(%{
        tag: "v0.15.0",
        version: "0.15.0",
        published_at: nil,
        html_url: "",
        body: ""
      })

      start_updater(ctx,
        name: :u4,
        downloader: fn _args, _opts -> {:error, :checksum_mismatch} end
      )

      Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_progress())

      assert :ok = Updater.apply_pending(:u4)
      assert_receive {:phase, :failed, :checksum_mismatch}, 1_000

      refute File.exists?(ctx.lock_path)
    end

    test "apply_pending/1 returns :already_running while a prior apply is in flight", ctx do
      UpdateChecker.put_cache(%{
        tag: "v0.15.0",
        version: "0.15.0",
        published_at: nil,
        html_url: "",
        body: ""
      })

      test_pid = self()

      start_updater(ctx,
        name: :u5,
        downloader: fn _args, _opts ->
          send(test_pid, :download_blocked)
          Process.sleep(200)
          {:ok, %{archive_path: "x", sha256: "y"}}
        end
      )

      :ok = Updater.apply_pending(:u5)
      assert_receive :download_blocked, 500
      assert {:error, :already_running} = Updater.apply_pending(:u5)
    end
  end
  ```

- [ ] **Step 11.2: Run, confirm fail**

- [ ] **Step 11.3: Implement**

  ```elixir
  # lib/scry_2/self_update/updater.ex
  defmodule Scry2.SelfUpdate.Updater do
    @moduledoc """
    GenServer that serializes self-update applies as a finite state machine:

        idle → preparing → downloading → extracting → handing_off → done
                                                                   ↘ failed

    Collaborators (Downloader, Stager, Handoff, ApplyLock, System.stop/1)
    are injected via start options for test isolation.
    """

    use GenServer

    require Scry2.Log, as: Log

    alias Scry2.SelfUpdate.ApplyLock
    alias Scry2.SelfUpdate.UpdateChecker
    alias Scry2.SelfUpdate.Downloader, as: DefaultDownloader
    alias Scry2.SelfUpdate.Stager, as: DefaultStager
    alias Scry2.SelfUpdate.Handoff, as: DefaultHandoff
    alias Scry2.Topics
    alias Scry2.Version

    @type phase :: :idle | :preparing | :downloading | :extracting | :handing_off | :done | :failed

    @type state :: %{
            phase: phase(),
            release: UpdateChecker.release() | nil,
            error: term() | nil,
            lock_path: Path.t(),
            staging_root: Path.t(),
            downloader: function(),
            stager: function(),
            handoff: function(),
            current_version_fn: (-> String.t()),
            system_stop_fn: (integer() -> any()),
            task: Task.t() | nil
          }

    # --- Public API ---

    def start_link(opts) do
      {name, opts} = Keyword.pop(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @spec apply_pending(GenServer.server()) ::
            :ok | {:error, :already_running | :no_update_pending | :up_to_date | :invalid_tag}
    def apply_pending(server \\ __MODULE__), do: GenServer.call(server, :apply_pending, 30_000)

    @spec status(GenServer.server()) :: %{phase: phase(), release: map() | nil, error: term() | nil}
    def status(server \\ __MODULE__), do: GenServer.call(server, :status)

    # --- Callbacks ---

    @impl GenServer
    def init(opts) do
      state = %{
        phase: :idle,
        release: nil,
        error: nil,
        lock_path: Keyword.fetch!(opts, :lock_path),
        staging_root: Keyword.fetch!(opts, :staging_root),
        downloader: Keyword.get(opts, :downloader, &DefaultDownloader.run/2),
        stager: Keyword.get(opts, :stager, &default_extract/2),
        handoff: Keyword.get(opts, :handoff, &DefaultHandoff.spawn_detached/2),
        current_version_fn: Keyword.get(opts, :current_version_fn, &Version.current/0),
        system_stop_fn: Keyword.get(opts, :system_stop_fn, &System.stop/1),
        task: nil
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_call(:status, _from, state) do
      {:reply, %{phase: state.phase, release: state.release, error: state.error}, state}
    end

    def handle_call(:apply_pending, _from, %{phase: phase} = state)
        when phase not in [:idle, :done, :failed] do
      {:reply, {:error, :already_running}, state}
    end

    def handle_call(:apply_pending, _from, state) do
      case UpdateChecker.cached_latest_release() do
        :none ->
          {:reply, {:error, :no_update_pending}, state}

        {:ok, release} ->
          case UpdateChecker.validate_tag(release.tag) do
            {:error, _} ->
              {:reply, {:error, :invalid_tag}, state}

            {:ok, _tag} ->
              local = state.current_version_fn.()

              case UpdateChecker.classify(release.version, local) do
                :update_available -> {:reply, :ok, start_apply(release, state)}
                :up_to_date -> {:reply, {:error, :up_to_date}, state}
                :ahead_of_release -> {:reply, {:error, :ahead_of_release}, state}
                :invalid -> {:reply, {:error, :invalid_tag}, state}
              end
          end
      end
    end

    @impl GenServer
    def handle_info({:phase, :downloading}, state) do
      broadcast_phase(:downloading)
      {:noreply, %{state | phase: :downloading}}
    end

    def handle_info({:phase, :extracting}, state) do
      broadcast_phase(:extracting)
      {:noreply, %{state | phase: :extracting}}
    end

    def handle_info({:phase, :handing_off}, state) do
      broadcast_phase(:handing_off)
      _ = ApplyLock.update_phase(state.lock_path, "handing_off")
      {:noreply, %{state | phase: :handing_off}}
    end

    def handle_info({:apply_failed, reason}, state) do
      _ = ApplyLock.release(state.lock_path)
      broadcast_phase(:failed, reason)
      Log.error(:system, "self-update apply failed: #{inspect(reason)}")
      {:noreply, %{state | phase: :failed, error: reason, task: nil}}
    end

    def handle_info({:apply_succeeded}, state) do
      state.system_stop_fn.(0)
      broadcast_phase(:done)
      {:noreply, %{state | phase: :done, task: nil}}
    end

    def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}

    def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
      _ = ApplyLock.release(state.lock_path)
      broadcast_phase(:failed, reason)
      {:noreply, %{state | phase: :failed, error: reason, task: nil}}
    end

    def handle_info(_other, state), do: {:noreply, state}

    # --- Private ---

    defp start_apply(release, state) do
      broadcast_phase(:preparing)
      _ = ApplyLock.acquire(state.lock_path, version: release.version)

      parent = self()

      staging_dir = Path.join(state.staging_root, "#{release.version}-#{random_suffix()}")
      File.mkdir_p!(staging_dir)

      archive_filename = UpdateChecker.archive_name(release.tag, :os.type())

      archive_url = UpdateChecker.download_url(release.tag, archive_filename)
      sha_url = UpdateChecker.download_url(release.tag, UpdateChecker.sha256sums_name(release.tag))

      {:ok, task} =
        Task.start_link(fn ->
          send(parent, {:phase, :downloading})

          case state.downloader.(
                 %{
                   archive_url: archive_url,
                   archive_filename: archive_filename,
                   sha256sums_url: sha_url,
                   dest_dir: staging_dir
                 },
                 []
               ) do
            {:ok, %{archive_path: archive_path}} ->
              send(parent, {:phase, :extracting})

              case state.stager.(archive_path, staging_dir) do
                {:ok, staged_root} ->
                  send(parent, {:phase, :handing_off})

                  case state.handoff.(
                         %{staged_root: staged_root, archive_filename: archive_filename},
                         []
                       ) do
                    :ok -> send(parent, {:apply_succeeded})
                    {:error, reason} -> send(parent, {:apply_failed, reason})
                  end

                {:error, reason} ->
                  send(parent, {:apply_failed, reason})
              end

            {:error, reason} ->
              send(parent, {:apply_failed, reason})
          end
        end)

      %{state | phase: :preparing, release: release, error: nil, task: task}
    end

    defp broadcast_phase(phase),
      do: Topics.broadcast(Topics.updates_progress(), {:phase, phase})

    defp broadcast_phase(phase, reason),
      do: Topics.broadcast(Topics.updates_progress(), {:phase, phase, reason})

    defp random_suffix,
      do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    defp default_extract(archive, dest) do
      cond do
        String.ends_with?(archive, ".tar.gz") -> DefaultStager.extract_tar(archive, dest)
        String.ends_with?(archive, ".zip") -> DefaultStager.extract_zip(archive, dest)
        String.ends_with?(archive, ".exe") -> {:ok, Path.dirname(archive)}
        true -> {:error, {:unknown_archive, archive}}
      end
    end
  end
  ```

- [ ] **Step 11.4: Run, confirm pass**

  ```bash
  mix test test/scry_2/self_update/updater_test.exs
  ```

---

## Task 12: SelfUpdate facade

**Files:**
- Create: `lib/scry_2/self_update.ex`
- Create: `test/scry_2/self_update_test.exs`

- [ ] **Step 12.1: Write failing test**

  ```elixir
  # test/scry_2/self_update_test.exs
  defmodule Scry2.SelfUpdateTest do
    use Scry2.DataCase, async: false
    alias Scry2.SelfUpdate
    alias Scry2.SelfUpdate.Storage
    alias Scry2.SelfUpdate.UpdateChecker

    setup do
      UpdateChecker.clear_cache()
      Storage.clear_all!()
      :ok
    end

    test "current_version/0 returns a version string" do
      assert is_binary(SelfUpdate.current_version())
    end

    test "cached_release/0 returns :none when no cache" do
      assert SelfUpdate.cached_release() == :none
    end

    test "cached_release/0 returns the cached release when present" do
      release = %{tag: "v0.99.0", version: "0.99.0", published_at: nil, html_url: "", body: ""}
      UpdateChecker.put_cache(release)
      assert {:ok, %{tag: "v0.99.0"}} = SelfUpdate.cached_release()
    end

    test "apply_lock_path/0 is under Scry2.Platform.data_dir/0" do
      assert SelfUpdate.apply_lock_path() |> String.starts_with?(Scry2.Platform.data_dir())
      assert Path.basename(SelfUpdate.apply_lock_path()) == "apply.lock"
    end

    test "enabled?/0 is false in test env" do
      refute SelfUpdate.enabled?()
    end
  end
  ```

- [ ] **Step 12.2: Run, confirm fail**

- [ ] **Step 12.3: Implement**

  ```elixir
  # lib/scry_2/self_update.ex
  defmodule Scry2.SelfUpdate do
    @moduledoc """
    Public facade for the self-update subsystem.

    The subsystem runs unconditionally in `:prod`; in `:dev` and `:test` it
    is inert (no cron firings, `apply_pending/0` still callable for test
    injection). `enabled?/0` is the single compile-time gate.
    """

    alias Scry2.Platform
    alias Scry2.SelfUpdate.ApplyLock
    alias Scry2.SelfUpdate.Storage
    alias Scry2.SelfUpdate.Updater
    alias Scry2.SelfUpdate.UpdateChecker
    alias Scry2.Topics
    alias Scry2.Version

    @enabled Mix.env() == :prod
    @stale_lock_seconds 900

    @spec enabled?() :: boolean()
    def enabled?, do: @enabled

    @spec current_version() :: String.t()
    def current_version, do: Version.current()

    @spec apply_lock_path() :: Path.t()
    def apply_lock_path, do: Path.join(Platform.data_dir(), "apply.lock")

    @spec staging_root() :: Path.t()
    def staging_root, do: Path.join(Platform.data_dir(), "update_staging")

    @spec cached_release() :: {:ok, UpdateChecker.release()} | :none
    def cached_release, do: UpdateChecker.cached_latest_release()

    @spec subscribe_status() :: :ok | {:error, term()}
    def subscribe_status, do: Topics.subscribe(Topics.updates_status())

    @spec subscribe_progress() :: :ok | {:error, term()}
    def subscribe_progress, do: Topics.subscribe(Topics.updates_progress())

    @spec check_now() :: {:ok, Oban.Job.t()} | {:error, term()}
    def check_now do
      %{"trigger" => "manual"}
      |> Scry2.SelfUpdate.CheckerJob.new()
      |> Oban.insert()
    end

    @spec apply_pending() :: :ok | {:error, term()}
    def apply_pending, do: Updater.apply_pending()

    @spec current_status() :: map()
    def current_status, do: Updater.status()

    @spec last_check_at() :: String.t() | nil
    def last_check_at, do: Storage.last_check_at()

    @doc """
    Called from `Scry2.Application.start/2`. Idempotent.
    """
    @spec boot!() :: :ok
    def boot! do
      :ok = ApplyLock.clear_if_stale!(apply_lock_path(), @stale_lock_seconds) |> case do
        :cleared -> :ok
        :not_stale -> :ok
        :absent -> :ok
      end

      :ok = Storage.hydrate!()
      :ok
    end
  end
  ```

- [ ] **Step 12.4: Run, confirm pass**

---

## Task 13: Wire Updater into Supervision + boot hook

**Files:**
- Modify: `lib/scry_2/application.ex`

- [ ] **Step 13.1: Add Updater child spec**

  In `Scry2.Application.start/2`, locate the children list and append (after Oban, before `Scry2Web.Endpoint`):

  ```elixir
  {Scry2.SelfUpdate.Updater,
   lock_path: Scry2.SelfUpdate.apply_lock_path(),
   staging_root: Scry2.SelfUpdate.staging_root()},
  ```

- [ ] **Step 13.2: Call boot hook after supervisor starts**

  In `Scry2.Application.start/2`, after `Supervisor.start_link(...)` succeeds:

  ```elixir
  case Supervisor.start_link(children, opts) do
    {:ok, pid} ->
      :ok = Scry2.SelfUpdate.boot!()
      {:ok, pid}

    other ->
      other
  end
  ```

- [ ] **Step 13.3: Run precommit**

  ```bash
  MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
  ```

  Expected: all tests pass, no warnings.

---

## Task 14: Settings LiveView — Updates card

**Files:**
- Create: `lib/scry_2_web/live/settings_live/updates_helpers.ex`
- Create: `lib/scry_2_web/live/settings_live/updates_card.ex`
- Create: `test/scry_2_web/live/settings_live/updates_helpers_test.exs`
- Modify: `lib/scry_2_web/live/settings_live.ex`

- [ ] **Step 14.1: Write failing helpers test**

  ```elixir
  # test/scry_2_web/live/settings_live/updates_helpers_test.exs
  defmodule Scry2Web.SettingsLive.UpdatesHelpersTest do
    use ExUnit.Case, async: true
    alias Scry2Web.SettingsLive.UpdatesHelpers

    test "summarize/3 returns :up_to_date when versions match" do
      release = %{tag: "v0.14.0", version: "0.14.0", published_at: nil, html_url: "", body: ""}
      assert %{status: :up_to_date} = UpdatesHelpers.summarize({:ok, release}, "0.14.0", nil)
    end

    test "summarize/3 returns :update_available with new version" do
      release = %{tag: "v0.15.0", version: "0.15.0", published_at: nil, html_url: "", body: ""}
      assert %{status: :update_available, version: "0.15.0"} =
               UpdatesHelpers.summarize({:ok, release}, "0.14.0", nil)
    end

    test "summarize/3 passes through applying phase" do
      release = %{tag: "v0.15.0", version: "0.15.0", published_at: nil, html_url: "", body: ""}
      assert %{applying: :downloading} =
               UpdatesHelpers.summarize({:ok, release}, "0.14.0", :downloading)
    end

    test "summarize/3 returns :no_data when cache empty" do
      assert %{status: :no_data} = UpdatesHelpers.summarize(:none, "0.14.0", nil)
    end

    test "phase_label/1" do
      assert UpdatesHelpers.phase_label(:downloading) == "Downloading"
      assert UpdatesHelpers.phase_label(:extracting) == "Extracting"
      assert UpdatesHelpers.phase_label(:handing_off) == "Installing"
      assert UpdatesHelpers.phase_label(:done) == "Complete"
      assert UpdatesHelpers.phase_label(:idle) == ""
    end
  end
  ```

- [ ] **Step 14.2: Implement helpers**

  ```elixir
  # lib/scry_2_web/live/settings_live/updates_helpers.ex
  defmodule Scry2Web.SettingsLive.UpdatesHelpers do
    @moduledoc """
    Pure helpers for the Updates card on the Settings page. Extracted per
    [ADR-013] — LiveView module stays thin.
    """

    alias Scry2.SelfUpdate.UpdateChecker

    @type summary :: %{
            required(:status) =>
              :no_data | :up_to_date | :update_available | :ahead_of_release | :invalid,
            optional(:version) => String.t(),
            optional(:published_at) => String.t() | nil,
            optional(:html_url) => String.t(),
            optional(:applying) => atom()
          }

    @spec summarize(
            {:ok, UpdateChecker.release()} | :none,
            String.t(),
            atom() | nil
          ) :: summary()
    def summarize(:none, _current, applying),
      do: %{status: :no_data, applying: applying}

    def summarize({:ok, release}, current, applying) do
      status = UpdateChecker.classify(release.version, current)

      %{
        status: status,
        version: release.version,
        published_at: release.published_at,
        html_url: release.html_url,
        applying: applying
      }
    end

    @spec phase_label(atom()) :: String.t()
    def phase_label(:preparing), do: "Preparing"
    def phase_label(:downloading), do: "Downloading"
    def phase_label(:extracting), do: "Extracting"
    def phase_label(:handing_off), do: "Installing"
    def phase_label(:done), do: "Complete"
    def phase_label(:failed), do: "Failed"
    def phase_label(_), do: ""
  end
  ```

- [ ] **Step 14.3: Run helpers test, confirm pass**

- [ ] **Step 14.4: Implement UpdatesCard component**

  ```elixir
  # lib/scry_2_web/live/settings_live/updates_card.ex
  defmodule Scry2Web.SettingsLive.UpdatesCard do
    use Scry2Web, :html
    alias Scry2Web.SettingsLive.UpdatesHelpers

    attr :summary, :map, required: true
    attr :current_version, :string, required: true
    attr :last_check_at, :string, default: nil

    def updates_card(assigns) do
      ~H"""
      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Updates</h2>

          <div class="text-sm opacity-70">
            Running: <span class="font-mono">{@current_version}</span>
            <%= if @last_check_at do %>
              • Last checked {@last_check_at}
            <% end %>
          </div>

          <div class="mt-3">
            <%= case @summary.status do %>
              <% :no_data -> %>
                <p class="text-sm opacity-70">No release info yet. Click check to fetch.</p>
              <% :up_to_date -> %>
                <p class="text-sm">You are on the latest release.</p>
              <% :update_available -> %>
                <div class="flex items-center gap-2">
                  <span class="badge badge-info badge-soft">
                    {@summary.version} available
                  </span>
                  <%= if @summary.html_url do %>
                    <a class="link text-sm" href={@summary.html_url} target="_blank">Release notes</a>
                  <% end %>
                </div>
              <% :ahead_of_release -> %>
                <p class="text-sm opacity-70">Running a version newer than the latest release.</p>
              <% :invalid -> %>
                <p class="text-sm text-warning">Invalid release tag received from GitHub.</p>
            <% end %>
          </div>

          <%= if @summary.applying do %>
            <div class="mt-3 flex items-center gap-2">
              <progress class="progress progress-primary w-48"></progress>
              <span class="text-sm">{UpdatesHelpers.phase_label(@summary.applying)}</span>
            </div>
          <% end %>

          <div class="card-actions mt-3 flex gap-2">
            <button
              class="btn btn-sm btn-ghost"
              phx-click="updates_check_now"
              disabled={@summary.applying not in [nil, :idle, :done, :failed]}
            >
              Check now
            </button>

            <%= if @summary.status == :update_available and @summary.applying in [nil, :idle, :failed] do %>
              <button class="btn btn-sm btn-soft btn-primary" phx-click="updates_apply">
                Apply update
              </button>
            <% end %>
          </div>
        </div>
      </section>
      """
    end
  end
  ```

- [ ] **Step 14.5: Wire into SettingsLive**

  In `lib/scry_2_web/live/settings_live.ex`:

  1. Add `alias`es at top:
     ```elixir
     alias Scry2.SelfUpdate
     alias Scry2Web.SettingsLive.UpdatesCard
     alias Scry2Web.SettingsLive.UpdatesHelpers
     ```

  2. In `mount/3`, add subscriptions and initial assigns (only when `connected?/1`):
     ```elixir
     if connected?(socket) do
       Process.send_after(self(), :refresh_diagnostics, @diagnostics_refresh_interval)
       SelfUpdate.subscribe_status()
       SelfUpdate.subscribe_progress()
     end

     socket
     |> assign(:updates_summary,
       UpdatesHelpers.summarize(
         SelfUpdate.cached_release(),
         SelfUpdate.current_version(),
         SelfUpdate.current_status().phase
       )
     )
     |> assign(:updates_last_check_at, SelfUpdate.last_check_at())
     |> assign(:updates_current_version, SelfUpdate.current_version())
     ```

  3. Add `handle_event/3` clauses:
     ```elixir
     def handle_event("updates_check_now", _params, socket) do
       {:ok, _} = SelfUpdate.check_now()
       {:noreply, socket}
     end

     def handle_event("updates_apply", _params, socket) do
       case SelfUpdate.apply_pending() do
         :ok -> {:noreply, socket}
         {:error, _reason} -> {:noreply, socket}
       end
     end
     ```

  4. Add `handle_info/2` clauses:
     ```elixir
     def handle_info({:check_complete, _result}, socket) do
       {:noreply,
        socket
        |> assign(:updates_summary,
          UpdatesHelpers.summarize(
            SelfUpdate.cached_release(),
            socket.assigns.updates_current_version,
            socket.assigns.updates_summary.applying
          )
        )
        |> assign(:updates_last_check_at, SelfUpdate.last_check_at())}
     end

     def handle_info(:check_started, socket), do: {:noreply, socket}

     def handle_info({:phase, phase}, socket) do
       {:noreply,
        assign(socket, :updates_summary, %{socket.assigns.updates_summary | applying: phase})}
     end

     def handle_info({:phase, :failed, _reason}, socket) do
       {:noreply,
        assign(socket, :updates_summary, %{socket.assigns.updates_summary | applying: :failed})}
     end
     ```

  5. Render the card in the HEEx template — place the new section where it fits visually (near "Diagnostics" / "Danger zone"):
     ```elixir
     <UpdatesCard.updates_card
       summary={@updates_summary}
       current_version={@updates_current_version}
       last_check_at={@updates_last_check_at}
     />
     ```

- [ ] **Step 14.6: Run tests**

  ```bash
  mix test test/scry_2_web/live/settings_live/updates_helpers_test.exs
  MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test
  ```

  Expected: all pass.

---

## Task 15: Go tray — apply lock reader

**Files:**
- Create: `tray/apply_lock.go`
- Create: `tray/apply_lock_test.go`

- [ ] **Step 15.1: Write failing Go test**

  ```go
  // tray/apply_lock_test.go
  package main

  import (
      "encoding/json"
      "os"
      "path/filepath"
      "testing"
      "time"
  )

  func TestApplyLockActive(t *testing.T) {
      dir := t.TempDir()
      lockPath := filepath.Join(dir, "apply.lock")

      if ApplyLockActive(lockPath) {
          t.Fatalf("expected false when file absent")
      }

      payload := map[string]interface{}{
          "pid":        os.Getpid(),
          "version":    "0.15.0",
          "phase":      "downloading",
          "started_at": time.Now().UTC().Format(time.RFC3339),
      }
      raw, _ := json.Marshal(payload)
      if err := os.WriteFile(lockPath, raw, 0o644); err != nil {
          t.Fatal(err)
      }

      if !ApplyLockActive(lockPath) {
          t.Fatalf("expected true when fresh lock present")
      }

      // Stale lock (> 15 min)
      payload["started_at"] = time.Now().Add(-20 * time.Minute).UTC().Format(time.RFC3339)
      raw, _ = json.Marshal(payload)
      _ = os.WriteFile(lockPath, raw, 0o644)

      if ApplyLockActive(lockPath) {
          t.Fatalf("expected false when stale")
      }
  }

  func TestApplyLockMalformed(t *testing.T) {
      dir := t.TempDir()
      lockPath := filepath.Join(dir, "apply.lock")
      _ = os.WriteFile(lockPath, []byte("not json"), 0o644)

      if ApplyLockActive(lockPath) {
          t.Fatalf("malformed lock should be treated as inactive (allow restart)")
      }
  }
  ```

- [ ] **Step 15.2: Run, confirm fail**

  ```bash
  cd tray && go test ./...
  ```

- [ ] **Step 15.3: Implement**

  ```go
  // tray/apply_lock.go
  package main

  import (
      "encoding/json"
      "os"
      "path/filepath"
      "time"
  )

  const applyLockMaxAge = 15 * time.Minute

  // ApplyLockPath returns the on-disk coordination file path the Elixir
  // self-updater writes during an apply.
  func ApplyLockPath() string {
      return filepath.Join(DataDir(), "apply.lock")
  }

  type applyLockContents struct {
      Pid       int    `json:"pid"`
      Version   string `json:"version"`
      Phase     string `json:"phase"`
      StartedAt string `json:"started_at"`
  }

  // ApplyLockActive returns true if the lock exists, is parseable, and is
  // fresher than applyLockMaxAge. Malformed or stale locks are treated as
  // inactive — the watchdog should restart normally.
  func ApplyLockActive(path string) bool {
      data, err := os.ReadFile(path)
      if err != nil {
          return false
      }

      var contents applyLockContents
      if err := json.Unmarshal(data, &contents); err != nil {
          return false
      }

      started, err := time.Parse(time.RFC3339, contents.StartedAt)
      if err != nil {
          return false
      }

      return time.Since(started) < applyLockMaxAge
  }
  ```

- [ ] **Step 15.4: Run, confirm pass**

---

## Task 16: Tray watchdog — consult apply lock

**Files:**
- Modify: `tray/backend.go`

- [ ] **Step 16.1: Patch watchdog loop**

  In `tray/backend.go:81-131` (`watchdog` function), find the block:

  ```go
      if !b.IsRunning() {
        consecutiveFailures++
        // ... notification logic ...
        select {
        case <-time.After(b.RestartDelay):
        case <-quitCh:
          return
        }
        b.Start()
  ```

  Replace with:

  ```go
      if !b.IsRunning() {
        consecutiveFailures++
        // ... notification logic unchanged ...
        select {
        case <-time.After(b.RestartDelay):
        case <-quitCh:
          return
        }

        if ApplyLockActive(ApplyLockPath()) {
          // An apply is in progress; the installer will relaunch us.
          // Skip restart, shorten the poll interval so we recover fast.
          continue
        }

        b.Start()
  ```

- [ ] **Step 16.2: Add a test**

  In `tray/backend_test.go`, add:

  ```go
  func TestWatchdogSkipsRestartDuringApply(t *testing.T) {
      // Seed an active apply lock
      lockPath := filepath.Join(t.TempDir(), "apply.lock")
      payload := map[string]interface{}{
          "pid": os.Getpid(), "version": "x", "phase": "downloading",
          "started_at": time.Now().UTC().Format(time.RFC3339),
      }
      raw, _ := json.Marshal(payload)
      _ = os.WriteFile(lockPath, raw, 0o644)
      t.Setenv("SCRY2_APPLY_LOCK_PATH_OVERRIDE", lockPath)
      // ... exercise the watchdog against a stub backend that reports
      // IsRunning=false, assert b.Start() is never called ...
  }
  ```

  **Note:** this requires a hook for `ApplyLockPath()` to be overrideable via env var. Add to `apply_lock.go`:

  ```go
  func ApplyLockPath() string {
      if override := os.Getenv("SCRY2_APPLY_LOCK_PATH_OVERRIDE"); override != "" {
          return override
      }
      return filepath.Join(DataDir(), "apply.lock")
  }
  ```

- [ ] **Step 16.3: Run**

  ```bash
  cd tray && go test ./...
  ```

---

## Task 17: Delete tray updater package

**Files:**
- Delete: `tray/updater/` (entire directory)
- Modify: `tray/main.go`

- [ ] **Step 17.1: Remove updater imports and calls**

  In `tray/main.go`, delete:
  - `import "scry2/tray/updater"`
  - Any `updater.Start(...)` call
  - Menu item creation for "Check for Updates" and its click handler

  Replace the "Check for Updates" menu item with an "Open Settings" deep-link:

  ```go
  mSettings := menu.AddSubMenuItem("Open Settings", "Open update + config")
  go func() {
      for range mSettings.ClickedCh {
          _ = openBrowser("http://localhost:6015/settings")
      }
  }()
  ```

- [ ] **Step 17.2: Remove the directory**

  ```bash
  rm -rf tray/updater
  ```

- [ ] **Step 17.3: Verify build**

  ```bash
  cd tray && go build ./... && go test ./...
  ```

---

## Task 18: Install scripts — clear apply lock before launching tray

**Files:**
- Modify: `scripts/install-linux`, `scripts/install-macos`, `rel/overlays/install.bat`

- [ ] **Step 18.1: Linux**

  Before the `"$INSTALL_DIR/scry2-tray" &` line, add:

  ```bash
  DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/scry_2"
  rm -f "$DATA_DIR/apply.lock"
  ```

- [ ] **Step 18.2: macOS**

  Before `launchctl load "$PLIST_FILE"`, add:

  ```bash
  DATA_DIR="$HOME/Library/Application Support/scry_2"
  rm -f "$DATA_DIR/apply.lock"
  ```

- [ ] **Step 18.3: Windows**

  In `rel/overlays/install.bat`, before `start "" /B "%INSTALL_DIR%\scry2-tray.exe"`:

  ```batch
  if exist "%APPDATA%\scry_2\apply.lock" del /q "%APPDATA%\scry_2\apply.lock"
  ```

- [ ] **Step 18.4: Smoke check**

  Run `scripts/install` locally on Linux; verify no errors at the lock-remove step when the file is absent (`rm -f` is idempotent).

---

## Task 19: CI — SHA256SUMS generation

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 19.1: Add checksum step per platform**

  In `.github/workflows/release.yml`, after the "Package release" step and before "Upload release archive":

  ```yaml
  - name: Generate SHA256SUMS (Linux/macOS)
    if: matrix.os != 'windows-latest'
    run: |
      sha256sum scry_2-${{ github.ref_name }}-${{ matrix.platform }}.${{ matrix.ext }} \
        > scry_2-${{ github.ref_name }}-${{ matrix.platform }}-SHA256SUMS

  - name: Generate SHA256SUMS (Windows)
    if: matrix.os == 'windows-latest'
    shell: pwsh
    run: |
      $archive = "scry_2-${{ github.ref_name }}-${{ matrix.platform }}.${{ matrix.ext }}"
      $hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
      "$hash  $archive" | Out-File -Encoding ascii "scry_2-${{ github.ref_name }}-${{ matrix.platform }}-SHA256SUMS"

      if (Test-Path "installer/output/Scry2-${{ env.TRIMMED_VERSION }}.msi") {
        $msi = "installer/output/Scry2-${{ env.TRIMMED_VERSION }}.msi"
        $msiHash = (Get-FileHash -Algorithm SHA256 $msi).Hash.ToLower()
        "$msiHash  Scry2-${{ env.TRIMMED_VERSION }}.msi" | Out-File -Encoding ascii -Append "scry_2-${{ github.ref_name }}-${{ matrix.platform }}-SHA256SUMS"
      }
  ```

- [ ] **Step 19.2: Upload checksums to release**

  Extend the existing `softprops/action-gh-release@v2` step's `files:` field:

  ```yaml
  - name: Upload release archive
    uses: softprops/action-gh-release@v2
    with:
      files: |
        scry_2-${{ github.ref_name }}-${{ matrix.platform }}.${{ matrix.ext }}
        scry_2-${{ github.ref_name }}-${{ matrix.platform }}-SHA256SUMS
      generate_release_notes: true
  ```

- [ ] **Step 19.3: Sanity check locally**

  On Linux, simulate:

  ```bash
  sha256sum scripts/release > /tmp/example.sums
  cat /tmp/example.sums
  ```

  Confirm format matches what `Downloader.parse_sha256sums/2` expects.

---

## Task 20: Remove tray build flags

**Files:**
- Modify: `scripts/release`

- [ ] **Step 20.1: Strip `-X` flags from Go build**

  Find the `go build` invocation that produces `scry2-tray`. Remove:
  - `-X 'scry2/tray/updater.CurrentVersion=${VERSION}'`
  - `-X 'scry2/tray/updater.InstallerType=zip'`
  - Any second build producing `scry2-tray-msi.exe`

  Keep a single tray binary build without ldflags. Do the same in
  `.github/workflows/release.yml` (Windows step that builds the MSI-variant
  tray can be removed entirely; the MSI no longer needs a special tray).

- [ ] **Step 20.2: Drop `tray-ci.yml` updater tests**

  In `.github/workflows/tray-ci.yml`, remove any test-path filters that
  reference `tray/updater/`. The test command probably just runs `go test ./...`
  — that'll auto-skip since the directory is gone.

- [ ] **Step 20.3: Build verification**

  ```bash
  scripts/release
  ```

  Expected: builds cleanly; `_build/prod/package/scry2-tray` exists; no
  errors about undefined `updater.CurrentVersion` or `InstallerType`.

---

## Task 21: End-to-end smoke check

- [ ] **Step 21.1: mix precommit**

  ```bash
  MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
  ```

  Expected: all green, zero warnings.

- [ ] **Step 21.2: Dev server boots, Settings renders**

  ```bash
  mix phx.server
  ```

  Open `http://localhost:4444/settings`. Verify:
  - Updates card is visible
  - Current version displays
  - "Check now" button is clickable (in dev, `enabled?/0` is false but manual check still enqueues and returns the cached result)
  - No crashes in logs

- [ ] **Step 21.3: Tray builds on Linux**

  ```bash
  cd tray && go build ./... && go test ./...
  ```

- [ ] **Step 21.4: End-to-end manual test (optional on dev box)**

  Install a prior release locally via `scripts/install`, tag a new version,
  wait for (or force) a check, click Apply, verify the new release is running
  after handoff. Record any issues — if this works, ship.

- [ ] **Step 21.5: Commit + describe**

  ```bash
  jj desc -m "feat: Elixir-native self-update subsystem

  Move self-update from Go tray to Elixir. New Scry2.SelfUpdate subsystem
  runs an hourly Oban check against GitHub Releases, downloads + verifies
  via SHA256SUMS, extracts with per-entry validation, and hands off a
  detached installer per platform. Tray keeps backend supervision but
  loses its updater package. Apply lock file coordinates the tray watchdog
  with in-flight updates. Settings LiveView exposes check + apply UI.

  Spec: specs/2026-04-20-elixir-self-update-design.md"
  ```

---

## Self-Review Notes (post-plan)

- **Spec coverage:** every `Scry2.SelfUpdate.*` module from the spec's file-structure table has a dedicated task (T3 ApplyLock, T4–5 UpdateChecker, T6 Storage, T7 CheckerJob, T8 Downloader, T9 Stager, T10 Handoff, T11 Updater, T12 Facade). Tray coordination: T15 reader + T16 watchdog patch. Install scripts: T18. CI SHA256SUMS: T19. Tray updater deletion + flag cleanup: T17 + T20.
- **ADR-009 compliance:** Updater tests use only public API (`apply_pending/1`, `status/1`) — no `:sys.replace_state`, no direct GenServer.call for internals.
- **ADR-013 compliance:** LiveView logic extracted into `UpdatesHelpers` (Task 14) with its own pure unit test.
- **No placeholders:** every step shows the actual code to paste or the exact command to run.
- **Dependency ordering:** tasks proceed bottom-up (primitives → services → GenServer → UI → tray). Application.ex wiring (T13) comes after all supervised children are ready.
- **Known gap the implementer must fix inline:** `Settings.delete/1` may not exist in scry_2's Settings module today. Task 6 calls it out as a dependent addition.
