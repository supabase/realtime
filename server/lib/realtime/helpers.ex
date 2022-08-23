defmodule Realtime.Helpers do
  alias Phoenix.Socket.Broadcast
  alias Realtime.{MessageDispatcher, PubSub}

  # key1=value1:key2=value2 to [{"key1", "value1"}, {"key2", "value2"}]}
  @spec env_kv_to_list(String.t() | nil, list() | []) :: {:ok, [{binary(), binary()}]} | :error
  def env_kv_to_list("", _), do: :error

  def env_kv_to_list(env_val, def_list) when is_binary(env_val) do
    parsed = parse_kv(env_val, :maps.from_list(def_list))

    if is_map(parsed) do
      {:ok, Map.to_list(parsed)}
    else
      :error
    end
  end

  def env_kv_to_list(_, _), do: :error

  @spec parse_kv(String.t(), map() | %{}) :: map() | nil
  def parse_kv(kv, default) do
    String.split(kv, ":")
    |> Enum.reduce(default, fn
      _, nil ->
        nil

      x, acc ->
        case String.split(x, "=", parts: 2) do
          [key, value] ->
            Map.put(acc, key, value)

          _ ->
            nil
        end
    end)
  end

  def broadcast_change(topic, %{type: event} = change) do
    broadcast = %Broadcast{
      topic: topic,
      event: event,
      payload: change
    }

    Phoenix.PubSub.broadcast_from(PubSub, self(), topic, broadcast, MessageDispatcher)
  end
end
