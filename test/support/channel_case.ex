defmodule RealtimeWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use RealtimeWeb.ChannelCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import Generators
      import TenantConnection
      import TestHelpers

      # The `TestHelpers` module provides backward-compatible versions of `assert_eventually/2` and
      # `refute_eventually/2`, which provide the same default timeout and interval values as the
      # old `retries: 50, sleep: 100` behavior that this test suite relied on before switching to
      # `wait_for_it`. Any options passed to these functions will override the defaults.
      import WaitForIt.Test,
        except: [assert_eventually: 1, assert_eventually: 2, refute_eventually: 1, refute_eventually: 2]

      require WaitForIt

      # The default endpoint for testing
      @endpoint RealtimeWeb.Endpoint
    end
  end

  setup tags do
    Realtime.DataCase.setup_sandbox(tags)
  end
end
