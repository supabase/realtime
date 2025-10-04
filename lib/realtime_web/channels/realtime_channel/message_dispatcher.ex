defmodule RealtimeWeb.RealtimeChannel.MessageDispatcher do
  @moduledoc """
  Inspired by Phoenix.Channel.Server.dispatch/3
  """

  alias Phoenix.Socket.Broadcast
  alias Phoenix.Socket.V1
  alias Phoenix.Socket.V2
  require Logger

  def fastlane_metadata(fastlane_pid, serializer, topic, log_level, tenant_id, replayed_message_ids \\ MapSet.new()) do
    {:rc_fastlane, fastlane_pid, serializer, topic, log_level, tenant_id, replayed_message_ids}
  end

  @doc """
  This dispatch function caches encoded messages if fastlane is used
  It also sends  an :update_rate_counter to the subscriber and it can conditionally log
  """
  @spec dispatch(list, pid, Broadcast.t()) :: :ok
  def dispatch(subscribers, from, %Broadcast{event: event} = msg) do
    # fastlane_pid is the actual socket transport pid
    # This reduce caches the serialization and bypasses the channel process going straight to the
    # transport process

    message_id = message_id(msg.payload)

    # Credo doesn't like that we don't use the result aggregation
    {_cache, count} =
      Enum.reduce(subscribers, {%{}, 0}, fn
        {pid, _}, {cache, count} when pid == from ->
          {cache, count}

        {pid, {:rc_fastlane, fastlane_pid, serializer, join_topic, log_level, tenant_id, replayed_message_ids}},
        {cache, count} ->
          if already_replayed?(message_id, replayed_message_ids) do
            # skip already replayed message
            {cache, count}
          else
            if event != "presence_diff", do: send(pid, :update_rate_counter)

            maybe_log(log_level, join_topic, msg, tenant_id)

            cache = do_dispatch(msg, fastlane_pid, serializer, join_topic, cache)
            {cache, count + 1}
          end

        {pid, _}, {cache, count} ->
          send(pid, msg)
          {cache, count}
      end)

    tenant_id = tenant_id(subscribers)
    increment_presence_counter(tenant_id, event, count)

    :ok
  end

  defp increment_presence_counter(tenant_id, "presence_diff", count) when is_binary(tenant_id) do
    tenant_id
    |> Realtime.Tenants.presence_events_per_second_key()
    |> Realtime.GenCounter.add(count)
  end

  defp increment_presence_counter(_tenant_id, _event, _count), do: :ok

  defp maybe_log(:info, join_topic, msg, tenant_id) do
    log = "Received message on #{join_topic} with payload: #{inspect(msg, pretty: true)}"
    Logger.info(log, external_id: tenant_id, project: tenant_id)
  end

  defp maybe_log(_level, _join_topic, _msg, _tenant_id), do: :ok

  defp message_id(%{"meta" => %{"id" => id}}), do: id
  defp message_id(_), do: nil

  defp already_replayed?(nil, _replayed_message_ids), do: false
  defp already_replayed?(message_id, replayed_message_ids), do: MapSet.member?(replayed_message_ids, message_id)

  defp do_dispatch(msg, fastlane_pid, serializer, join_topic, cache) do
    case cache do
      %{^serializer => encoded_msg} ->
        send(fastlane_pid, encoded_msg)
        cache

      %{} ->
        # Use the original topic that was joined without the external_id
        msg = %{msg | topic: join_topic}
        # encoded_msg = serializer.fastlane!(msg)
        encoded_msg = serialize(serializer, msg)
        send(fastlane_pid, encoded_msg)
        Map.put(cache, serializer, encoded_msg)
    end
  end

  defp serialize(V1.JSONSerializer, %Broadcast{payload: {:binary, payload}} = broadcast) do
    case Phoenix.json_library().decode(payload) do
      {:ok, decoded} -> V1.JSONSerializer.fastlane!(%{broadcast | payload: decoded})
      _ -> raise "FIX ME LATTER"
    end
  end

  defp serialize(V1.JSONSerializer, broadcast), do: V1.JSONSerializer.fastlane!(broadcast)

  defp serialize(V2.JSONSerializer, msg), do: V2.JSONSerializer.fastlane!(msg)

  defp tenant_id([{_pid, {:rc_fastlane, _, _, _, _, tenant_id, _}} | _]) do
    tenant_id
  end

  defp tenant_id(_), do: nil
end
