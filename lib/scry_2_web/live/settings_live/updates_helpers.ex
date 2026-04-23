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
          optional(:applying) => atom() | nil,
          optional(:last_error) => String.t() | nil
        }

  @spec summarize(
          {:ok, UpdateChecker.release()} | :none,
          String.t(),
          atom() | nil
        ) :: summary()
  def summarize(cached, current, applying, last_error \\ nil)

  def summarize(:none, _current, applying, last_error),
    do: %{status: :no_data, applying: applying, last_error: last_error}

  def summarize({:ok, release}, current, applying, last_error) do
    status = UpdateChecker.classify(release.version, current)

    %{
      status: status,
      version: release.version,
      published_at: release.published_at,
      html_url: release.html_url,
      applying: applying,
      last_error: last_error
    }
  end

  @spec phase_label(atom() | nil) :: String.t()
  def phase_label(:preparing), do: "Preparing"
  def phase_label(:downloading), do: "Downloading"
  def phase_label(:extracting), do: "Extracting"
  def phase_label(:handing_off), do: "Installing"
  def phase_label(:done), do: "Complete"
  def phase_label(:failed), do: "Failed"
  def phase_label(_), do: ""

  @doc """
  Render an UpdateChecker error tuple as a UI-friendly string.

  - Rate limit errors include the local time at which the limit resets,
    so the user can see whether to wait 5 minutes or an hour.
  - Other tagged errors get short, human-readable labels.
  - Anything unrecognised falls through to `inspect/1`.
  """
  @spec format_error(any(), DateTime.t()) :: String.t() | nil
  def format_error(nil, _now), do: nil
  def format_error(:invalid_response, _now), do: "GitHub returned a malformed response."
  def format_error(:invalid_tag, _now), do: "Release tag failed validation."

  def format_error({:rate_limited, %DateTime{} = reset_at}, now) do
    "GitHub API rate-limited. Retries after #{format_reset(reset_at, now)}."
  end

  def format_error({:rate_limited, _}, _now),
    do: "GitHub API rate-limited. Try again later."

  def format_error({:http_status, status}, _now),
    do: "GitHub returned HTTP #{status}."

  def format_error({:transport, reason}, _now),
    do: "Network error reaching GitHub: #{inspect(reason)}."

  def format_error(other, _now), do: "Update check failed: #{inspect(other)}"

  defp format_reset(%DateTime{} = reset_at, %DateTime{} = now) do
    seconds_remaining = max(0, DateTime.diff(reset_at, now))

    cond do
      seconds_remaining < 60 -> "#{seconds_remaining}s"
      seconds_remaining < 3600 -> "#{div(seconds_remaining, 60)}m"
      true -> "#{div(seconds_remaining, 3600)}h #{div(rem(seconds_remaining, 3600), 60)}m"
    end
  end
end
