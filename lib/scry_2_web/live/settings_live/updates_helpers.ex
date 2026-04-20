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
          optional(:applying) => atom() | nil
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

  @spec phase_label(atom() | nil) :: String.t()
  def phase_label(:preparing), do: "Preparing"
  def phase_label(:downloading), do: "Downloading"
  def phase_label(:extracting), do: "Extracting"
  def phase_label(:handing_off), do: "Installing"
  def phase_label(:done), do: "Complete"
  def phase_label(:failed), do: "Failed"
  def phase_label(_), do: ""
end
