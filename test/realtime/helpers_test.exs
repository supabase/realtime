defmodule Realtime.HelpersTest do
  use Realtime.DataCase, async: false
  # async: false due to the deletion of the replication slot potentially affecting other tests
  doctest Realtime.Helpers
end
