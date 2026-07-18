defmodule Scry2Web.BuildChangeVerifyFlow do
  @moduledoc """
  Pure state machine for the build-change banner's verify flow (ADR-013),
  shared by every LiveView that hosts `Scry2Web.Collection.BuildChangeBanner`
  (the Collection and Settings pages).

  The state is a plain map whose keys are the banner's assigns —
  `%{verify_state, verify_detail, verify_attempt_hint}` — so hosts merge it
  straight into the socket with `assign(socket, verify)`.

  Flow: `idle` → `start/1` (`:running`, remembering which build the attempt
  targets) → promoted by `classify_snapshot/2` when a fresh collection
  snapshot lands (`:ok` on a walker read of the attempted build, `:fallback`
  on a fallback scan) or demoted by `classify_failure/2` / `timeout/1`.
  `failed/1` is the unconditional failure constructor for a refresh that
  cannot even be enqueued; `verified/0` the terminal ok state.
  """

  alias Scry2.MtgaMemory.WalkError

  @type t :: %{
          verify_state: :idle | :running | :ok | :fallback | :failed | :mtga_not_running,
          verify_detail: String.t() | nil,
          verify_attempt_hint: String.t() | nil
        }

  @spec idle() :: t()
  def idle, do: %{verify_state: :idle, verify_detail: nil, verify_attempt_hint: nil}

  @spec verified() :: t()
  def verified, do: %{verify_state: :ok, verify_detail: nil, verify_attempt_hint: nil}

  @doc "A running verification, remembering which build the attempt targets."
  @spec start(term()) :: t()
  def start(build_change_status) do
    %{
      verify_state: :running,
      verify_detail: nil,
      verify_attempt_hint: attempt_hint(build_change_status)
    }
  end

  defp attempt_hint({:changed, _previous, current}), do: current
  defp attempt_hint(_status), do: nil

  @doc """
  Promote a running verification from the latest snapshot: a walker read of
  the attempted build verifies; a fallback scan means the walker is broken
  on this build. Anything else (no snapshot, stale build) stays running.
  """
  @spec classify_snapshot(t(), map() | nil) :: t()
  def classify_snapshot(%{verify_state: :running} = verify, %{} = snapshot) do
    cond do
      snapshot.reader_confidence == "walker" and
          (is_nil(verify.verify_attempt_hint) or
             snapshot.mtga_build_hint == verify.verify_attempt_hint) ->
        %{verify | verify_state: :ok, verify_detail: nil}

      snapshot.reader_confidence == "fallback_scan" ->
        %{verify | verify_state: :fallback, verify_detail: nil}

      true ->
        verify
    end
  end

  def classify_snapshot(verify, _snapshot), do: verify

  @doc "Unconditional failure — a refresh that could not run at all."
  @spec failed(term()) :: t()
  def failed(:mtga_not_running) do
    %{verify_state: :mtga_not_running, verify_detail: nil, verify_attempt_hint: nil}
  end

  def failed(reason) do
    %{
      verify_state: :failed,
      verify_detail: WalkError.translate(reason),
      verify_attempt_hint: nil
    }
  end

  @doc "Fail a running verification; background failures never flip an idle banner."
  @spec classify_failure(t(), term()) :: t()
  def classify_failure(%{verify_state: :running}, reason), do: failed(reason)
  def classify_failure(verify, _reason), do: verify

  @doc "A running verification that outlived its patience."
  @spec timeout(t()) :: t()
  def timeout(%{verify_state: :running} = verify) do
    %{
      verify
      | verify_state: :failed,
        verify_detail: "Verification took longer than expected — check Diagnostics for details"
    }
  end

  def timeout(verify), do: verify
end
