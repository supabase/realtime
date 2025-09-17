defmodule RealtimeWeb.RealtimeChannel.MessageDispatcher do
  @moduledoc """
  Inspired by Phoenix.Channel.Server.dispatch/3
  """

  require Logger

  def fastlane_metadata(fastlane_pid, serializer, topic, log_level, tenant_id, replayed_message_ids \\ MapSet.new())

  def fastlane_metadata(fastlane_pid, serializer, topic, :info, tenant_id, replayed_message_ids) do
    {:rc_fastlane, fastlane_pid, serializer, topic, {:log, tenant_id}, replayed_message_ids}
  end

  def fastlane_metadata(fastlane_pid, serializer, topic, _log_level, _tenant_id, replayed_message_ids) do
    {:rc_fastlane, fastlane_pid, serializer, topic, replayed_message_ids}
  end

  @doc """
  This dispatch function caches encoded messages if fastlane is used
  It also sends  an :update_rate_counter to the subscriber and it can conditionally log
  """
  @spec dispatch(list, pid, Phoenix.Socket.Broadcast.t()) :: :ok
  def dispatch(subscribers, from, %Phoenix.Socket.Broadcast{} = msg) do
    # fastlane_pid is the actual socket transport pid
    # This reduce caches the serialization and bypasses the channel process going straight to the
    # transport process

    message_id = message_id(msg.payload)

    # Credo doesn't like that we don't use the result aggregation
    _ =
      Enum.reduce(subscribers, %{}, fn
        {pid, _}, cache when pid == from ->
          cache

        {pid, {:rc_fastlane, fastlane_pid, serializer, join_topic, replayed_message_ids}}, cache ->
          if already_replayed?(message_id, replayed_message_ids) do
            # skip already replayed message
            cache
          else
            send(pid, :update_rate_counter)
            do_dispatch(msg, fastlane_pid, serializer, join_topic, cache)
          end

        {pid, {:rc_fastlane, fastlane_pid, serializer, join_topic, {:log, tenant_id}, replayed_message_ids}}, cache ->
          if already_replayed?(message_id, replayed_message_ids) do
            # skip already replayed message
            cache
          else
            send(pid, :update_rate_counter)
            log = "Received message on #{join_topic} with payload: #{inspect(msg, pretty: true)}"
            Logger.info(log, external_id: tenant_id, project: tenant_id)

            do_dispatch(msg, fastlane_pid, serializer, join_topic, cache)
          end

        {pid, _}, cache ->
          send(pid, msg)
          cache
      end)

    :ok
  end

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
        encoded_msg = serializer.fastlane!(msg)
        send(fastlane_pid, encoded_msg)
        Map.put(cache, serializer, encoded_msg)
    end
  end
end
