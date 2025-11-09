defmodule RealtimeWeb.RealtimeChannel.MessageDispatcher do
  @moduledoc """
  Inspired by Phoenix.Channel.Server.dispatch/3
  """

  require Logger
  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.Socket.UserBroadcast

  def fastlane_metadata(fastlane_pid, serializer, topic, log_level, tenant_id, replayed_message_ids \\ MapSet.new()) do
    {:rc_fastlane, fastlane_pid, serializer, topic, log_level, tenant_id, replayed_message_ids}
  end

  @presence_diff "presence_diff"

  @doc """
  This dispatch function caches encoded messages if fastlane is used
  It also sends  an :update_rate_counter to the subscriber and it can conditionally log

  fastlane_pid is the actual socket transport pid
  """
  @spec dispatch(list, pid, Broadcast.t() | UserBroadcast.t()) :: :ok
  def dispatch(subscribers, from, %Broadcast{event: @presence_diff} = msg) do
    {_cache, count} =
      Enum.reduce(subscribers, {%{}, 0}, fn
        {pid, _}, {cache, count} when pid == from ->
          {cache, count}

        {_pid, {:rc_fastlane, fastlane_pid, serializer, join_topic, log_level, tenant_id, _replayed_message_ids}},
        {cache, count} ->
          maybe_log(log_level, join_topic, msg, tenant_id)

          cache = do_dispatch(msg, fastlane_pid, serializer, join_topic, cache, tenant_id, log_level)
          {cache, count + 1}

        {pid, _}, {cache, count} ->
          send(pid, msg)
          {cache, count}
      end)

    tenant_id = tenant_id(subscribers)
    increment_presence_counter(tenant_id, msg.event, count)

    :ok
  end

  def dispatch(subscribers, from, msg) do
    message_id = message_id(msg)

    _ =
      Enum.reduce(subscribers, %{}, fn
        {pid, _}, cache when pid == from ->
          cache

        {pid, {:rc_fastlane, fastlane_pid, serializer, join_topic, log_level, tenant_id, replayed_message_ids}},
        cache ->
          if already_replayed?(message_id, replayed_message_ids) do
            # skip already replayed message
            cache
          else
            send(pid, :update_rate_counter)

            maybe_log(log_level, join_topic, msg, tenant_id)

            do_dispatch(msg, fastlane_pid, serializer, join_topic, cache, tenant_id, log_level)
          end

        {pid, _}, cache ->
          send(pid, msg)
          cache
      end)

    :ok
  end

  defp maybe_log(:info, join_topic, msg, tenant_id) when is_struct(msg) do
    log = "Received message on #{join_topic} with payload: #{inspect(msg, pretty: true)}"
    Logger.info(log, external_id: tenant_id, project: tenant_id)
  end

  defp maybe_log(:info, join_topic, msg, tenant_id) when is_binary(msg) do
    log = "Received message on #{join_topic}. #{msg}"
    Logger.info(log, external_id: tenant_id, project: tenant_id)
  end

  defp maybe_log(_level, _join_topic, _msg, _tenant_id), do: :ok

  defp do_dispatch(msg, fastlane_pid, serializer, join_topic, cache, tenant_id, log_level) do
    case cache do
      %{^serializer => {:ok, encoded_msg}} ->
        send(fastlane_pid, encoded_msg)
        cache

      %{^serializer => {:error, _reason}} ->
        # We do nothing at this stage. It has been already logged depending on the log level
        cache

      %{} ->
        # Use the original topic that was joined without the external_id
        msg = %{msg | topic: join_topic}

        result =
          case fastlane!(serializer, msg) do
            {:ok, encoded_msg} ->
              send(fastlane_pid, encoded_msg)
              {:ok, encoded_msg}

            {:error, reason} ->
              maybe_log(log_level, join_topic, reason, tenant_id)
          end

        Map.put(cache, serializer, result)
    end
  end

  # We have to convert because V1 does not know how to process UserBroadcast
  defp fastlane!(Phoenix.Socket.V1.JSONSerializer = serializer, %UserBroadcast{} = msg) do
    with {:ok, msg} <- UserBroadcast.convert_to_json_broadcast(msg) do
      {:ok, serializer.fastlane!(msg)}
    end
  end

  defp fastlane!(serializer, msg), do: {:ok, serializer.fastlane!(msg)}

  defp tenant_id([{_pid, {:rc_fastlane, _, _, _, _, tenant_id, _}} | _]), do: tenant_id
  defp tenant_id(_), do: nil

  defp increment_presence_counter(tenant_id, "presence_diff", count) when is_binary(tenant_id) do
    tenant_id
    |> Realtime.Tenants.presence_events_per_second_key()
    |> Realtime.GenCounter.add(count)
  end

  defp increment_presence_counter(_tenant_id, _event, _count), do: :ok

  defp message_id(%Broadcast{payload: %{"meta" => %{"id" => id}}}), do: id
  defp message_id(_), do: nil

  defp already_replayed?(nil, _replayed_message_ids), do: false
  defp already_replayed?(message_id, replayed_message_ids), do: MapSet.member?(replayed_message_ids, message_id)
end
