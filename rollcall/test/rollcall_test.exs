defmodule RollcallTest do
  use ExUnit.Case
  doctest Rollcall

  test "greets the world" do
    assert Rollcall.hello() == :world
  end
end
