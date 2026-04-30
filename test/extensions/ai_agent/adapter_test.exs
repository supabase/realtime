defmodule Extensions.AiAgent.AdapterTest do
  use ExUnit.Case, async: true

  alias Extensions.AiAgent.Adapter

  describe "emit/2" do
    test "sends ai_event message to caller" do
      event = %Extensions.AiAgent.Types.Event{type: :text_delta, payload: %{delta: "hello"}}
      Adapter.emit(self(), event)
      assert_receive {:ai_event, ^event}
    end
  end
end
