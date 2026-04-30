defmodule Extensions.AiAgent.Adapter.SSEStream do
  @moduledoc """
  Shared SSE streaming scaffold for AI provider adapters.

  Handles the Finch request, HTTP status/header chunks, SSE line parsing, and
  JSON decoding. Each adapter supplies a `process_event/3` function that
  translates provider-specific event shapes into `Extensions.AiAgent.Event`
  structs and updates the `ToolCallBuffer` accumulator.
  """

  alias Extensions.AiAgent.Adapter
  alias Extensions.AiAgent.Types.Event
  alias Extensions.AiAgent.Types.ToolCallBuffer

  @receive_timeout :timer.minutes(5)

  @type process_event_fn :: (map(), ToolCallBuffer.t(), pid() -> ToolCallBuffer.t())

  @spec run(Finch.Request.t(), process_event_fn(), pid()) :: :ok | {:error, term()}
  def run(request, process_event_fn, caller) do
    acc = {"", ToolCallBuffer.new()}
    handler = &handle_chunk(&1, &2, caller, process_event_fn)

    case Finch.stream(request, AiAgent.Finch, acc, handler, receive_timeout: @receive_timeout) do
      {:ok, _} -> :ok
      {:error, reason, _acc} -> {:error, reason}
    end
  end

  defp handle_chunk({:status, status}, acc, caller, _process_event_fn) when status >= 400 do
    Adapter.emit(caller, %Event{type: :error, payload: %{reason: "HTTP #{status}"}})
    acc
  end

  defp handle_chunk({:status, _}, acc, _, _), do: acc
  defp handle_chunk({:headers, _}, acc, _, _), do: acc

  defp handle_chunk({:data, chunk}, {buffer, tool_calls}, caller, process_event_fn) do
    {lines, remaining} = parse_sse_lines(buffer <> chunk)

    tool_calls =
      Enum.reduce(lines, tool_calls, fn line, acc ->
        case Jason.decode(line) do
          {:ok, data} -> process_event_fn.(data, acc, caller)
          {:error, _} -> acc
        end
      end)

    {remaining, tool_calls}
  end

  defp parse_sse_lines(buffer) do
    case String.split(buffer, "\n\n") do
      [incomplete] ->
        {[], incomplete}

      parts ->
        {complete, [incomplete]} = Enum.split(parts, -1)

        lines =
          complete
          |> Enum.flat_map(&String.split(&1, "\n"))
          |> Enum.flat_map(fn
            "data: [DONE]" -> []
            "data: " <> data -> [data]
            _ -> []
          end)

        {lines, incomplete}
    end
  end
end
