defmodule Extensions.AiAgent.Adapter.ChatCompletions do
  @moduledoc """
  Adapter for the OpenAI `/v1/chat/completions` SSE protocol.

  Compatible with: OpenAI, OpenRouter, Groq, Together, Fireworks, DeepSeek,
  Mistral, Cerebras, Perplexity, Ollama, vLLM, LM Studio, and custom endpoints.
  """

  @behaviour Extensions.AiAgent.Adapter

  alias Extensions.AiAgent.Adapter
  alias Extensions.AiAgent.Adapter.SSEStream
  alias Extensions.AiAgent.Types.Event
  alias Extensions.AiAgent.Types.ToolCallBuffer

  @impl true
  def stream(settings, messages, caller) do
    url = settings["base_url"] <> "/chat/completions"
    request = Finch.build(:post, url, headers(settings), Jason.encode!(build_body(settings, messages)))
    SSEStream.run(request, &process_delta/3, caller)
  end

  defp process_delta(%{"choices" => [_ | _]} = message, buffer, caller) do
    %{"choices" => [choice | _]} = message
    %{"delta" => delta, "finish_reason" => finish_reason} = choice
    buffer = emit_delta(delta, buffer, caller)
    buffer = accumulate_tool_calls(delta, buffer, caller)
    emit_done(finish_reason, buffer, caller)
  end

  defp process_delta(%{"usage" => usage}, buffer, caller) when not is_nil(usage) do
    Adapter.emit(caller, %Event{
      type: :usage,
      payload: %{input_tokens: usage["prompt_tokens"], output_tokens: usage["completion_tokens"]}
    })

    buffer
  end

  defp process_delta(_data, buffer, _caller), do: buffer

  defp emit_delta(%{"content" => content}, buffer, caller) when is_binary(content) and content != "" do
    Adapter.emit(caller, %Event{type: :text_delta, payload: %{delta: content}})
    buffer
  end

  defp emit_delta(%{"reasoning_content" => content}, buffer, caller) when is_binary(content) and content != "" do
    Adapter.emit(caller, %Event{type: :thinking_delta, payload: %{delta: content}})
    buffer
  end

  defp emit_delta(%{"reasoning" => content}, buffer, caller) when is_binary(content) and content != "" do
    Adapter.emit(caller, %Event{type: :thinking_delta, payload: %{delta: content}})
    buffer
  end

  defp emit_delta(_delta, buffer, _caller), do: buffer

  defp accumulate_tool_calls(%{"tool_calls" => chunks}, buffer, caller) when is_list(chunks) do
    Enum.reduce(chunks, buffer, fn chunk, acc ->
      idx = chunk["index"]
      acc = ToolCallBuffer.start(acc, idx, chunk["id"], get_in(chunk, ["function", "name"]))
      ToolCallBuffer.append_args(acc, idx, get_in(chunk, ["function", "arguments"]) || "", caller)
    end)
  end

  defp accumulate_tool_calls(_delta, buffer, _caller), do: buffer

  defp emit_done("tool_calls", buffer, caller) do
    buffer = ToolCallBuffer.finish_all(buffer, caller)
    Adapter.emit(caller, %Event{type: :done, payload: %{stop_reason: "tool_calls"}})
    buffer
  end

  defp emit_done(reason, buffer, caller) when is_binary(reason) do
    Adapter.emit(caller, %Event{type: :done, payload: %{stop_reason: reason}})
    buffer
  end

  defp emit_done(_reason, buffer, _caller), do: buffer

  defp build_body(settings, messages) do
    %{
      "model" => settings["model"],
      "messages" => messages,
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }
    |> Adapter.maybe_put("tools", settings["tools"])
    |> Adapter.maybe_put("temperature", settings["temperature"])
  end

  defp headers(settings) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{settings["api_key"]}"}
    ]
    |> Adapter.maybe_prepend("HTTP-Referer", settings["http_referer"])
    |> Adapter.maybe_prepend("X-Title", settings["x_title"])
  end
end
