defmodule Extensions.AiAgent.Types.ToolCallBuffer do
  @moduledoc """
  Accumulates streaming tool call chunks from AI provider SSE streams.

  Arguments are stored as an iolist and joined only at `finish`/`finish_all`
  to avoid O(n²) binary concatenation across streaming chunks.

  `start/4` upserts an entry without overwriting an already-set id/name, which
  handles both Anthropic (id+name on `content_block_start`) and OpenAI
  (id+name on the first delta chunk).
  """

  alias Extensions.AiAgent.Adapter
  alias Extensions.AiAgent.Types.Event

  @type entry :: %{id: String.t() | nil, name: String.t() | nil, arguments: iodata()}
  @type t :: %{non_neg_integer() => entry()}

  @spec new() :: t()
  def new, do: %{}

  @spec start(t(), non_neg_integer(), String.t() | nil, String.t() | nil) :: t()
  def start(buffer, idx, id, name) do
    Map.update(buffer, idx, %{id: id, name: name, arguments: []}, fn entry ->
      %{entry | id: entry.id || id, name: entry.name || name}
    end)
  end

  @spec append_args(t(), non_neg_integer(), String.t(), pid()) :: t()
  def append_args(buffer, _idx, "", _caller), do: buffer

  def append_args(buffer, idx, args_delta, caller) do
    entry = Map.get(buffer, idx, %{id: nil, name: nil, arguments: []})
    updated = %{entry | arguments: [entry.arguments | [args_delta]]}

    Adapter.emit(caller, %Event{
      type: :tool_call_delta,
      payload: %{tool_call_id: updated.id, name: updated.name, arguments_delta: args_delta}
    })

    Map.put(buffer, idx, updated)
  end

  @spec finish(t(), non_neg_integer(), pid()) :: t()
  def finish(buffer, idx, caller) do
    case Map.pop(buffer, idx) do
      {nil, buffer} ->
        buffer

      {tc, buffer} ->
        Adapter.emit(caller, %Event{
          type: :tool_call_done,
          payload: %{tool_call_id: tc.id, name: tc.name, arguments: IO.iodata_to_binary(tc.arguments)}
        })

        buffer
    end
  end

  @spec finish_all(t(), pid()) :: t()
  def finish_all(buffer, caller) do
    Enum.each(buffer, fn {_idx, tc} ->
      Adapter.emit(caller, %Event{
        type: :tool_call_done,
        payload: %{tool_call_id: tc.id, name: tc.name, arguments: IO.iodata_to_binary(tc.arguments)}
      })
    end)

    new()
  end
end
