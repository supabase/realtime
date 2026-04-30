defmodule Extensions.AiAgent.Adapter.ChatCompletionsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Extensions.AiAgent.Adapter.ChatCompletions
  alias Extensions.AiAgent.Types.Event

  @settings %{
    "model" => "gpt-4o",
    "api_key" => "sk-test",
    "base_url" => "https://api.openai.com/v1"
  }

  @messages [%{"role" => "user", "content" => "hello"}]

  defp sse(json), do: "data: #{Jason.encode!(json)}\n\n"
  defp done_chunk, do: "data: [DONE]\n\n"

  describe "stream/3" do
    test "emits text_delta events from streamed chunks" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        chunk1 = sse(%{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]})
        chunk2 = sse(%{"choices" => [%{"delta" => %{"content" => " world"}, "finish_reason" => nil}]})
        finish = sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})

        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, chunk1}, acc)
        acc = callback.({:data, chunk2}, acc)
        acc = callback.({:data, finish <> done_chunk()}, acc)
        {:ok, acc}
      end)

      assert :ok = ChatCompletions.stream(@settings, @messages, caller)

      assert_receive {:ai_event, %Event{type: :text_delta, payload: %{delta: "Hello"}}}
      assert_receive {:ai_event, %Event{type: :text_delta, payload: %{delta: " world"}}}
      assert_receive {:ai_event, %Event{type: :done, payload: %{stop_reason: "stop"}}}
    end

    test "emits usage event when included in stream" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        finish = sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})
        usage = sse(%{"usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20}})

        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, finish <> usage <> done_chunk()}, acc)
        {:ok, acc}
      end)

      assert :ok = ChatCompletions.stream(@settings, @messages, caller)

      assert_receive {:ai_event, %Event{type: :usage, payload: %{input_tokens: 10, output_tokens: 20}}}
    end

    test "emits error event on HTTP error status" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        acc = callback.({:status, 429}, acc)
        {:ok, acc}
      end)

      ChatCompletions.stream(@settings, @messages, caller)

      assert_receive {:ai_event, %Event{type: :error, payload: %{reason: "HTTP 429"}}}
    end

    test "emits tool_call_delta and tool_call_done for tool calls" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        tc1 =
          sse(%{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_1",
                      "type" => "function",
                      "function" => %{"name" => "get_weather", "arguments" => ""}
                    }
                  ]
                },
                "finish_reason" => nil
              }
            ]
          })

        tc2 =
          sse(%{
            "choices" => [
              %{
                "delta" => %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"city\":"}}]},
                "finish_reason" => nil
              }
            ]
          })

        tc3 =
          sse(%{
            "choices" => [
              %{
                "delta" => %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"NYC\"}"}}]},
                "finish_reason" => nil
              }
            ]
          })

        finish = sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]})

        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, tc1 <> tc2 <> tc3 <> finish <> done_chunk()}, acc)
        {:ok, acc}
      end)

      assert :ok = ChatCompletions.stream(@settings, @messages, caller)

      assert_receive {:ai_event,
                      %Event{type: :tool_call_delta, payload: %{tool_call_id: "call_1", name: "get_weather"}}}

      assert_receive {:ai_event,
                      %Event{
                        type: :tool_call_done,
                        payload: %{tool_call_id: "call_1", name: "get_weather", arguments: "{\"city\":\"NYC\"}"}
                      }}

      assert_receive {:ai_event, %Event{type: :done, payload: %{stop_reason: "tool_calls"}}}
    end

    test "returns error tuple when Finch fails" do
      caller = self()

      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}, acc}
      end)

      assert {:error, _} = ChatCompletions.stream(@settings, @messages, caller)
    end

    test "handles chunks split across multiple data deliveries" do
      caller = self()

      full = sse(%{"choices" => [%{"delta" => %{"content" => "split"}, "finish_reason" => nil}]})
      half1 = binary_part(full, 0, div(byte_size(full), 2))
      half2 = binary_part(full, div(byte_size(full), 2), byte_size(full) - div(byte_size(full), 2))
      finish = sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, half1}, acc)
        acc = callback.({:data, half2}, acc)
        acc = callback.({:data, finish <> done_chunk()}, acc)
        {:ok, acc}
      end)

      assert :ok = ChatCompletions.stream(@settings, @messages, caller)

      assert_receive {:ai_event, %Event{type: :text_delta, payload: %{delta: "split"}}}
      assert_receive {:ai_event, %Event{type: :done, payload: %{stop_reason: "stop"}}}
    end
  end
end
