defmodule BeaconTest do
  use ExUnit.Case
  doctest Beacon

  test "greets the world" do
    assert Beacon.hello() == :world
  end
end
