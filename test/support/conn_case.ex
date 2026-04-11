defmodule Scry2Web.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Scry2Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint Scry2Web.Endpoint

      use Scry2Web, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Scry2Web.ConnCase
    end
  end

  setup tags do
    Scry2.DataCase.setup_sandbox(tags)

    # The first-run setup tour redirects every gated route to /setup.
    # Mark it completed by default so existing LiveView tests don't need
    # to care about the gate. Tests that specifically exercise the gate
    # (e.g. Scry2Web.SetupGateTest) call `SetupFlow.reset!/0` to clear
    # this flag.
    :ok = Scry2.SetupFlow.mark_completed!()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
