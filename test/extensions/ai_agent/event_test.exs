defmodule Extensions.AiAgent.Types.EventTest do
  use ExUnit.Case, async: true

  alias Extensions.AiAgent.Types.Event

  describe "broadcast_event/1" do
    test "prefixes type with agent_" do
      assert Event.broadcast_event(%Event{type: :text_delta, payload: %{}}) == "agent_text_delta"
      assert Event.broadcast_event(%Event{type: :done, payload: %{}}) == "agent_done"
      assert Event.broadcast_event(%Event{type: :error, payload: %{}}) == "agent_error"
      assert Event.broadcast_event(%Event{type: :tool_call_done, payload: %{}}) == "agent_tool_call_done"
      assert Event.broadcast_event(%Event{type: :session_started, payload: %{}}) == "agent_session_started"
    end
  end
end
