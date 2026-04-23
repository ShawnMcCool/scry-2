defmodule Scry2.Service.Backend do
  @moduledoc """
  Behaviour every Service backend must implement. The `Scry2.Service`
  facade dispatches to a single backend based on runtime detection.

  Every callback accepts an opts keyword list — backends use this for
  test-injected `:cmd_fn`, `:env_fn`, etc. Backends that need no
  injection can ignore the opts.
  """

  @type capabilities :: %{
          can_restart: boolean(),
          can_stop: boolean(),
          can_status: boolean()
        }

  @callback name(opts :: keyword()) :: String.t()
  @callback state(opts :: keyword()) :: map()
  @callback capabilities() :: capabilities()
  @callback restart(opts :: keyword()) :: :ok | {:error, term()} | :not_supported
  @callback stop(opts :: keyword()) :: :ok | {:error, term()} | :not_supported
end
