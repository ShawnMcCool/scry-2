defmodule Scry2.Collection.Reader.Discovery do
  @moduledoc """
  Locates the running MTGA process via the `Scry2.Collection.Mem`
  backend. Cross-platform: the predicate is applied to every candidate
  process, so Linux `/proc` iteration, Windows `CreateToolhelp32Snapshot`,
  and the test fixture all funnel through the same entry point.

  Further validation (mono runtime loaded, UnityPlayer mapped, PE
  header readable) lives in `Scry2.Collection.Reader.SelfCheck` —
  discovery is strictly "is MTGA there".
  """

  @mtga_process_name "MTGA.exe"

  @doc """
  Returns `{:ok, pid}` for the first MTGA process found, or a tagged
  error. `mem` is a module implementing `Scry2.Collection.Mem`.
  """
  @spec find_mtga(module()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def find_mtga(mem) do
    case mem.find_process(&mtga_candidate?/1) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> {:error, :mtga_not_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mtga_candidate?(%{name: name}), do: name == @mtga_process_name
end
