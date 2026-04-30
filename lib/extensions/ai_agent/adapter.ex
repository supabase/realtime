defmodule Extensions.AiAgent.Adapter do
  @moduledoc """
  Behaviour for AI provider adapters.

  An adapter receives resolved settings and a message history, makes a
  streaming HTTP request to the provider, and sends `Extensions.AiAgent.Event`
  structs to the caller process as `{:ai_event, event}` messages.

  The caller is expected to be a `Extensions.AiAgent.Session` GenServer that
  runs the adapter in a `Task` so it can handle cancellation via `Task.shutdown`.
  """

  alias Extensions.AiAgent.Types.Event

  @callback stream(settings :: map(), messages :: list(map()), caller :: pid()) ::
              :ok | {:error, term()}

  @spec emit(pid(), Event.t()) :: :ok
  def emit(caller, %Event{} = event) do
    send(caller, {:ai_event, event})
    :ok
  end

  @spec maybe_put(map(), String.t(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_prepend(list(), String.t(), term()) :: list()
  def maybe_prepend(list, _item, nil), do: list
  def maybe_prepend(list, item, value), do: [{item, value} | list]
end
