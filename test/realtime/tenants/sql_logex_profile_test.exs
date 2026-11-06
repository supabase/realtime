Code.require_file("../../../sql_logex/test/support/realtime_profile.ex", __DIR__)

defmodule Realtime.Tenants.SqlLogexProfileTest do
  # The sql_logex tests cannot depend on Realtime, so they use a copy of this profile. This test
  # keeps the copy equal to the profile that Realtime ships, while both live in this repository.
  use ExUnit.Case, async: true

  alias Realtime.Tenants.SqlLogexProfile

  test "the sql_logex tests use the profile that Realtime ships" do
    assert SqlLogex.Test.RealtimeProfile.profile() == SqlLogexProfile.profile()
  end
end
