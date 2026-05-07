defmodule Scry2.Collection.EnvironmentInfo do
  @moduledoc """
  Pure helpers for the memory-read MTGA environment record (spike 23).

  Carries no DB or runtime state — just the parsing of `fd_host` into
  the build-version segment that's embedded in MTGA's front-door
  hostname (e.g. `"frontdoor-mtga-production-2026-58-30-2.w2.mtgarena.com"`
  → `"2026-58-30-2"`).

  The build version surfaced here is complementary to the existing
  `mtga_build_hint` (the GUID from `boot.config`):

  - `mtga_build_hint` is the cryptographic build identity — opaque,
    great for "did this change?" detection. Already exposed via
    `Scry2.Collection.BuildChange`.
  - The version segment from `fd_host` is the human-readable
    release identifier — looks like `2026-58-30-2`, suitable for
    surfacing as "Build 2026-58-30-2" in the UI.

  Both round-trip independently from snapshot to snapshot. The build
  GUID is per-process; the front-door host is per-MTGA-release.
  """

  # `frontdoor-mtga-<env>-<build-version>.<region>.mtgarena.com`
  # Captured `<build-version>` is dot-free between the env and the
  # first dot. Anchoring on the literal `frontdoor-mtga-` prefix
  # avoids false matches against any other DNS name MTGA might
  # contact in the future.
  @fd_host_regex ~r/^frontdoor-mtga-[a-z0-9]+-(?<build>[0-9][0-9a-z\-]*)\.[a-z0-9]+\.mtgarena\.com$/i

  @doc """
  Extracts the MTGA build-version segment from a front-door hostname.

  Returns `nil` if the hostname doesn't match the
  `frontdoor-mtga-<env>-<build>.<region>.mtgarena.com` shape — covering
  pre-bootstrap (`fd_host` was nil), build-format changes, or talking
  to a non-production environment with a different naming convention.
  """
  @spec parse_build_version(String.t() | nil) :: String.t() | nil
  def parse_build_version(nil), do: nil

  def parse_build_version(host) when is_binary(host) do
    case Regex.named_captures(@fd_host_regex, host) do
      %{"build" => build} -> build
      nil -> nil
    end
  end

  @doc """
  Maps the i32 `host_platform` enum onto a human-readable string.
  Observed: `1` = Steam. Other integer values pass through as
  `"Platform <n>"` so the UI keeps rendering even after MTGA adds
  a new host. `nil` → `nil`.
  """
  @spec host_platform_label(integer() | nil) :: String.t() | nil
  def host_platform_label(nil), do: nil
  def host_platform_label(1), do: "Steam"
  def host_platform_label(n) when is_integer(n), do: "Platform #{n}"
end
