defmodule Realtime.SubscriptionManager do
  use GenServer
  require Logger

  alias Realtime.RLS.Subscriptions
  alias RealtimeWeb.Endpoint

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    case Keyword.fetch!(opts, :replication_mode) do
      "RLS" = mode ->
        sync_interval = Keyword.fetch!(opts, :subscription_sync_interval)

        Endpoint.broadcast_from!(self(), "subscription_manager", "sync_subscription", nil)

        ref =
          Process.send_after(
            self(),
            :sync_subscription,
            sync_interval
          )

        {:ok,
         %{
           replication_mode: mode,
           sync_ref: ref,
           sync_interval: sync_interval,
           subscription_params: %{}
         }}

      "STREAM" = mode ->
        {:ok, %{replication_mode: mode}}
    end
  end

  @spec track_topic_subscribers(
          list(%{
            channel_pid: pid(),
            topic: String.t(),
            id: Ecto.UUID.raw(),
            claims: map()
          })
        ) :: :ok | :error
  def track_topic_subscribers(topic_subs) do
    GenServer.call(__MODULE__, {:track_topic_subscribers, topic_subs}, 15_000)
  end

  def handle_call(
        {
          :track_topic_subscribers,
          topic_subs
        },
        _from,
        %{replication_mode: "RLS", subscription_params: sub_params} = state
      ) do
    try do
      topic_subs
      |> Enum.map(&Map.drop(&1, [:channel_pid]))
      |> Subscriptions.create_topic_subscribers()
    catch
      :error, error ->
        error |> inspect() |> Logger.error()
        :error
    end
    |> case do
      {:ok, %{enriched_subscription_params: [enriched_params]}} ->
        [%{channel_pid: channel_pid} | _] = topic_subs

        if sub_params |> Map.get(channel_pid) |> is_nil() do
          Process.monitor(channel_pid)
        end

        new_state = Kernel.put_in(state, [:subscription_params, channel_pid], enriched_params)

        {:reply, :ok, new_state}

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call({:track_topic_subscribers, _}, _from, %{replication_mode: "STREAM"} = state),
    do: {:reply, :ok, state}

  def handle_info(
        :sync_subscription,
        %{sync_ref: ref, sync_interval: interval, subscription_params: sub_params} = state
      ) do
    Process.cancel_timer(ref)

    try do
      sub_params
      |> Map.values()
      |> Subscriptions.sync_subscriptions()
    catch
      :error, error -> error |> inspect() |> Logger.error()
    end

    new_ref =
      Process.send_after(
        self(),
        :sync_subscription,
        interval
      )

    {:noreply, %{state | sync_ref: new_ref}}
  end

  def handle_info(
        {:DOWN, _ref, :process, channel_pid, _reason},
        %{subscription_params: sub_params} = state
      ) do
    new_sub_params =
      sub_params
      |> Map.pop(channel_pid)
      |> case do
        {nil, sub_params} ->
          sub_params

        {sub_params, new_sub_params} ->
          try do
            Subscriptions.delete_topic_subscriber(sub_params)
          catch
            :error, error -> error |> inspect() |> Logger.error()
          end

          new_sub_params
      end

    {:noreply, %{state | subscription_params: new_sub_params}}
  end
end
