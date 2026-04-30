defmodule Extensions.AiAgent.Adapter.AnthropicMessagesTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Extensions.AiAgent.Adapter.AnthropicMessages
  alias Extensions.AiAgent.Types.Event

  @settings %{
    "model" => "claude-opus-4-7",
    "api_key" => "sk-ant-test",
    "base_url" => "https://api.anthropic.com"
  }

  @messages [%{"role" => "user", "content" => "hello"}]

  defp sse(type, data), do: "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"

  describe "stream/3" do
    test "emits text_delta events from content_block_delta" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        start_evt =
          sse("message_start", %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 5}}})

        block_start =
          sse("content_block_start", %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text"}
          })

        delta1 =
          sse("content_block_delta", %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          })

        delta2 =
          sse("content_block_delta", %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => " world"}
          })

        msg_delta =
          sse("message_delta", %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 10}
          })

        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, start_evt <> block_start <> delta1 <> delta2 <> msg_delta}, acc)
        {:ok, acc}
      end)

      assert :ok = AnthropicMessages.stream(@settings, @messages, caller)

      assert_receive {:ai_event, %Event{type: :usage, payload: %{input_tokens: 5}}}
      assert_receive {:ai_event, %Event{type: :text_delta, payload: %{delta: "Hello"}}}
      assert_receive {:ai_event, %Event{type: :text_delta, payload: %{delta: " world"}}}
      assert_receive {:ai_event, %Event{type: :usage, payload: %{output_tokens: 10}}}
      assert_receive {:ai_event, %Event{type: :done, payload: %{stop_reason: "end_turn"}}}
    end

    test "emits tool_call events for tool_use content blocks" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        start_evt =
          sse("message_start", %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 5}}})

        tool_start =
          sse("content_block_start", %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "tool_use", "id" => "toolu_01", "name" => "get_weather", "input" => %{}}
          })

        arg_delta =
          sse("content_block_delta", %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"city\":\"NYC\"}"}
          })

        tool_stop = sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0})

        msg_delta =
          sse("message_delta", %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 15}
          })

        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, start_evt <> tool_start <> arg_delta <> tool_stop <> msg_delta}, acc)
        {:ok, acc}
      end)

      assert :ok = AnthropicMessages.stream(@settings, @messages, caller)

      assert_receive {:ai_event,
                      %Event{type: :tool_call_delta, payload: %{tool_call_id: "toolu_01", name: "get_weather"}}}

      assert_receive {:ai_event,
                      %Event{
                        type: :tool_call_done,
                        payload: %{tool_call_id: "toolu_01", name: "get_weather", arguments: "{\"city\":\"NYC\"}"}
                      }}
    end

    test "emits error event on HTTP error status" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        acc = callback.({:status, 401}, acc)
        {:ok, acc}
      end)

      AnthropicMessages.stream(@settings, @messages, caller)

      assert_receive {:ai_event, %Event{type: :error, payload: %{reason: "HTTP 401"}}}
    end

    test "returns error tuple when Finch fails" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts ->
        {:error, %Mint.TransportError{reason: :closed}, acc}
      end)

      assert {:error, _} = AnthropicMessages.stream(@settings, @messages, caller)
    end
  end
end
