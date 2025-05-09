defmodule Realtime.Adapters.Postgres.ProtocolTest do
  use ExUnit.Case, async: true
  alias Realtime.Adapters.Postgres.Protocol

  test "defguard is_write/1" do
    require Protocol
    assert Protocol.is_write("w")
    refute Protocol.is_write("k")
  end

  test "defguard is_keep_alive/1" do
    require Protocol
    assert Protocol.is_keep_alive("k")
    refute Protocol.is_keep_alive("w")
  end
end
