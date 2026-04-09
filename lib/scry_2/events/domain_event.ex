defmodule Scry2.Events.DomainEvent do
  @moduledoc """
  Behaviour implemented by every domain event module.

  Provides `from_payload/1` for deserializing a raw JSON payload map
  (string keys) into the typed event struct. Called by `Scry2.Events.rehydrate/1`
  via the `@slug_to_module` registry — adding a new event type to the registry
  without implementing this callback produces a compile-time warning.
  """

  @callback from_payload(payload :: map()) :: struct()
end
