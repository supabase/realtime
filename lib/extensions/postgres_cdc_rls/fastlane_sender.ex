# This file draws from https://github.com/phoenixframework/phoenix/blob/9941711736c8464b27b40914a4d954ed2b4f5958/lib/phoenix/channel/server.ex
# License: https://github.com/phoenixframework/phoenix/blob/518a4640a70aa4d1370a64c2280d598e5b928168/LICENSE.md

defmodule Extensions.PostgresCdcRls.FastlaneSender do
  @moduledoc """
  `Phoenix.PubSub.Sender` for postgres_changes fastlane subscriptions.

  Subscribe with `sender/1`. `Phoenix.PubSub` calls `send/4` once for each subscription in a Registry
  partition. The state caches the encoded message, so each `{serializer, topic, ids}` group is encoded
  once per partition.
  """

  @behaviour Phoenix.PubSub.Sender

  alias Phoenix.Socket.Broadcast

  @doc """
  Returns the `:sender` subscription option that delivers through this module.
  """
  @spec sender(tuple()) :: {module(), tuple()}
  def sender(metadata), do: {__MODULE__, metadata}

  @impl Phoenix.PubSub.Sender
  def send(pid, metadata, {_type, payload, _sub_ids} = message, nil),
    do: send(pid, metadata, message, {Jason.Fragment.new(payload), %{}})

  def send(
        _pid,
        {:subscriber_fastlane, fastlane_pid, serializer, ids, join_topic, is_new_api},
        {type, _payload, sub_ids},
        {data, cache}
      ) do
    for {bin_id, id} <- ids, reduce: [] do
      acc ->
        if MapSet.member?(sub_ids, bin_id) do
          [id | acc]
        else
          acc
        end
    end
    |> case do
      [_ | _] = valid_ids ->
        cache_key =
          if is_new_api do
            {serializer, join_topic, valid_ids}
          else
            {serializer, join_topic}
          end

        {data, broadcast_message(cache, cache_key, fastlane_pid, type, data)}

      _ ->
        {data, cache}
    end
  end

  defp broadcast_message(cache, cache_key, fastlane_pid, type, data) do
    case cache do
      %{^cache_key => {:ok, encoded_msg}} ->
        Kernel.send(fastlane_pid, encoded_msg)
        cache

      %{^cache_key => {:error, _reason}} ->
        cache

      %{} ->
        result = encode(cache_key, type, data)
        with {:ok, encoded_msg} <- result, do: Kernel.send(fastlane_pid, encoded_msg)
        Map.put(cache, cache_key, result)
    end
  end

  defp encode(cache_key, type, data) do
    serializer = elem(cache_key, 0)
    {:ok, serializer.fastlane!(broadcast(cache_key, type, data))}
  rescue
    error -> {:error, error}
  end

  defp broadcast({_serializer, join_topic, valid_ids}, _type, data),
    do: %Broadcast{topic: join_topic, event: "postgres_changes", payload: %{ids: valid_ids, data: data}}

  defp broadcast({_serializer, join_topic}, type, data),
    do: %Broadcast{topic: join_topic, event: type, payload: data}
end
