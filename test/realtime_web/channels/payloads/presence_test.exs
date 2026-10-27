defmodule RealtimeWeb.Channels.Payloads.PresenceTest do
  use ExUnit.Case, async: true

  alias RealtimeWeb.Channels.Payloads.Presence

  describe "normalize_key/1" do
    for key <- ["user-1", "", 123, 1.5, true, false] do
      test "accepts #{inspect(key)} as is" do
        assert Presence.normalize_key(unquote(key)) == {:ok, unquote(key)}
      end
    end

    for key <- [nil, %{"a" => 1}, ["a", "b"], [%{"a" => 1}], []] do
      test "rejects #{inspect(key)}" do
        assert Presence.normalize_key(unquote(Macro.escape(key))) == :error
      end
    end
  end
end
