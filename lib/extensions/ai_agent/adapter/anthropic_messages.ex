defmodule Extensions.AiAgent.Adapter.AnthropicMessages do
  @moduledoc """
  Adapter for the Anthropic `/v1/messages` SSE protocol.
  """

  @behaviour Extensions.AiAgent.Adapter

  alias Extensions.AiAgent.Adapter
  alias Extensions.AiAgent.Adapter.SSEStream
  alias Extensions.AiAgent.Types.Event
  alias Extensions.AiAgent.Types.ToolCallBuffer

  @default_max_tokens 4096
  @default_anthropic_version "2023-06-01"
  @default_anthropic_beta "interleaved-thinking-2025-05-14"

  @impl true
  def stream(settings, messages, caller) do
    url = settings["base_url"] <> "/v1/messages"
    request = Finch.build(:post, url, headers(settings), Jason.encode!(build_body(settings, messages)))
    SSEStream.run(request, &process_event/3, caller)
  end

  defp process_event(%{"type" => "content_block_delta"} = message, buffer, caller) do
    %{"index" => idx, "delta" => delta} = message

    case delta do
      %{"type" => "text_delta", "text" => text} ->
        Adapter.emit(caller, %Event{type: :text_delta, payload: %{delta: text}})
        buffer

      %{"type" => "thinking_delta", "thinking" => text} ->
        Adapter.emit(caller, %Event{type: :thinking_delta, payload: %{delta: text}})
        buffer

      %{"type" => "input_json_delta", "partial_json" => partial} ->
        ToolCallBuffer.append_args(buffer, idx, partial, caller)

      _ ->
        buffer
    end
  end

  defp process_event(
         %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use"}} = message,
         buffer,
         _caller
       ) do
    %{"index" => idx, "content_block" => block} = message
    ToolCallBuffer.start(buffer, idx, block["id"], block["name"])
  end

  defp process_event(%{"type" => "content_block_stop"} = message, buffer, caller) do
    %{"index" => idx} = message
    ToolCallBuffer.finish(buffer, idx, caller)
  end

  defp process_event(%{"type" => "message_delta"} = message, buffer, caller) do
    %{"delta" => delta, "usage" => usage} = message
    Adapter.emit(caller, %Event{type: :usage, payload: %{output_tokens: usage["output_tokens"]}})

    if stop_reason = delta["stop_reason"] do
      Adapter.emit(caller, %Event{type: :done, payload: %{stop_reason: stop_reason}})
    end

    buffer
  end

  defp process_event(%{"type" => "message_start"} = message, buffer, caller) do
    %{"message" => %{"usage" => usage}} = message
    Adapter.emit(caller, %Event{type: :usage, payload: %{input_tokens: usage["input_tokens"]}})
    buffer
  end

  defp process_event(%{"type" => "error"} = message, buffer, caller) do
    %{"error" => error} = message
    Adapter.emit(caller, %Event{type: :error, payload: %{reason: error["message"]}})
    buffer
  end

  defp process_event(_event, buffer, _caller), do: buffer

  defp build_body(settings, messages) do
    %{
      "model" => settings["model"],
      "messages" => messages,
      "max_tokens" => settings["max_tokens"] || @default_max_tokens,
      "stream" => true
    }
    |> Adapter.maybe_put("system", settings["system_prompt"])
    |> Adapter.maybe_put("tools", anthropic_tools(settings["tools"]))
  end

  defp anthropic_tools(nil), do: nil

  defp anthropic_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool["function"]["name"],
        "description" => tool["function"]["description"],
        "input_schema" => tool["function"]["parameters"]
      }
    end)
  end

  defp headers(settings) do
    [
      {"content-type", "application/json"},
      {"x-api-key", settings["api_key"]},
      {"anthropic-version", settings["anthropic_version"] || @default_anthropic_version},
      {"anthropic-beta", settings["anthropic_beta"] || @default_anthropic_beta}
    ]
  end
end
