defmodule MultiplayerWeb.RealtimeChannel do
  use MultiplayerWeb, :channel
  require Logger
  # alias MultiplayerWeb.Presence
  # alias Multiplayer.SessionsHooks

  # intercept(["presence_diff"])
  # @empty_presence_diff %{joins: %{}, leaves: %{}}
  # @timeout_presence_diff 1000
  @mbox_limit 1000
  @wait_time 500
  # @kickout_time 5000

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        _,
        %{assigns: %{tenant: tenant, claims: claims}, transport_pid: pid} = socket
      ) do
    # used for custom monitoring
    channel_stats(pid, tenant, topic)

    Multiplayer.UsersCounter.add(pid, tenant)

    tenant_topic_name = tenant <> ":" <> topic
    make_tenant_topic(socket, tenant_topic_name)

    sub_id = UUID.uuid1()
    # TODO: return sub_id from function
    Ewalrus.subscribe(tenant, sub_id, sub_topic, claims)
    # presence_timer = Process.send_after(self(), :presence_agg, @timeout_presence_diff)

    # Logger.debug("Hooks #{inspect(hooks)}")
    # hook = hooks["session.connected"]
    # SessionsHooks.connected(self(), user_id, hook.type, hook.url)
    # kick_ref = Process.send_after(self(), :kickout_time, @kickout_time)

    Logger.debug("Start channel, #{inspect([sub_id: sub_id], pretty: true)}")

    new_socket =
      update_topic(socket, tenant_topic_name)
      # |> assign(presence_timer: presence_timer)
      # |> assign(kickout_ref: kick_ref)
      |> assign(mq: [])
      # |> assign(presence_diff: @empty_presence_diff)
      |> assign(topic: topic)
      |> assign(subs_id: sub_id)
      |> assign(
        sender: %{
          last: 0,
          size: 0,
          tid: :ets.new(__MODULE__, [:public, :ordered_set])
        }
      )

    # if Application.fetch_env!(:multiplayer, :presence) do
    #   Multiplayer.PresenceNotify.track_me(self(), new_socket)
    # end

    {:ok, new_socket}
  end

  # send presence state to client
  # def handle_info(:presence_state, socket) do
  #   add_message("presence_state", Presence.list(socket) |> :maps.size())
  #   {:noreply, socket}
  # end

  @impl true
  # accumulate messages to the queue
  # def handle_info({:message, msg, event}, %{assigns: %{mq: mq}} = socket) do
  #   send(self(), :check_mq)
  #   {:noreply, socket |> assign(mq: mq ++ [{msg, event}])}
  # end

  # def handle_info(:check_mq, %{assigns: %{mq: []}} = socket) do
  #   {:noreply, socket}
  # end

  # send messages to the transport pid
  def handle_info(
        :check_mq,
        %{transport_pid: pid, assigns: %{sender: sender, topic: topic}} = socket
      ) do
    IO.inspect({0, sender})

    proc_len = mess_len(pid)

    if false or proc_len > @mbox_limit or proc_len == nil do
      Logger.debug("Wait for backlog, #{inspect(proc_len, pretty: true)}")
      Process.send_after(self(), :check_mq, @wait_time)
      {:noreply, socket}
    else
      new_sender =
        case :ets.select(sender.tid, [{:"$1", [], [:"$_"]}], @mbox_limit) do
          {events, next} ->
            events
            |> Enum.each(fn {id, event, msg} ->
              IO.inspect({id, event, msg})
              update_topic(socket, topic) |> push(event, msg)
              true = :ets.delete(sender.tid, id)
            end)

            if next != :"$end_of_table" do
              Logger.debug("End of sender table")
              send(self(), :check_mq)
              %{sender | size: :ets.info(sender.tid)[:size]}
            else
              %{sender | size: 0}
            end

          :"$end_of_table" ->
            Logger.debug("End of sender table on enter")
            %{sender | size: 0}
        end

      # :telemetry.execute([:prom_ex, :plugin, :multiplayer, :msg_sent], %{})
      # send(self(), :check_mq)
      # {:noreply, socket |> assign(mq: mq)}
      {:noreply, assign(socket, sender: new_sender)}
    end
  end

  # # handle the presence diff
  # def handle_info(:presence_agg, %{assigns: %{presence_timer: ref, presence_diff: diff}} = socket) do
  #   Process.cancel_timer(ref)
  #   info = %{joins: diff.joins |> :maps.size(), leaves: diff.leaves |> :maps.size()}

  #   if !Map.equal?(diff, @empty_presence_diff) do
  #     add_message("presence_diff", info)
  #   end

  #   presence_timer = Process.send_after(self(), :presence_agg, @timeout_presence_diff)

  #   {:noreply,
  #    socket
  #    |> assign(presence_timer: presence_timer)
  #    |> assign(presence_diff: @empty_presence_diff)}
  # end

  def handle_info(
        {:event, %{type: type} = event},
        %{transport_pid: pid, assigns: %{sender: sender, topic: topic} = _assigns} = socket
      ) do
    Logger.debug("Got event, #{inspect(event, pretty: true)}")
    # add_message(type, event)
    # new_sender = add_message(sender, type, event)

    proc_len = mess_len(pid)

    if sender.size > 0 or proc_len > @mbox_limit or proc_len == nil do
      Logger.debug("Wait for backlog, #{inspect(proc_len, pretty: true)}")
      Process.send_after(self(), :check_mq, @wait_time)
      {:noreply, socket |> assign(sender: backlog(sender, type, event))}
    else
      update_topic(socket, topic) |> push(type, event)
      {:noreply, socket}
    end

    # {:noreply, Map.put(socket, :assigns, %{assigns | sender: new_sender})}
  end

  def handle_info(:kickout_time, socket) do
    Logger.error("kickout_time")
    {:stop, :normal, socket}
  end

  def handle_info({:rls, :accepted}, %{assigns: %{kickout_ref: ref}} = socket) do
    Process.cancel_timer(ref)
    {:noreply, socket}
  end

  # TODO: implement
  def handle_info(%{event: "access_token"}, socket) do
    {:noreply, socket}
  end

  def handle_info(other, socket) do
    Logger.error("Undefined msg #{inspect(other, pretty: true)}")
    {:noreply, socket}
  end

  def mess_len(pid) do
    case Process.info(pid, :message_queue_len) do
      nil -> nil
      {_, len} -> len
    end
  end

  @impl true
  def handle_out("presence_diff", msg, %{assigns: %{presence_diff: diff}} = socket) do
    new_diff = merge_presence_diff(diff, msg)
    {:noreply, assign(socket, presence_diff: new_diff)}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug(%{terminate: reason})
    :telemetry.execute([:prom_ex, :plugin, :multiplayer, :disconnected], %{})
    :ok
  end

  def merge_presence_diff(old, new) do
    {same, updated_old} = Map.split(old.joins, Map.keys(new.leaves))
    clean_leaves = Map.drop(new.leaves, Map.keys(same))

    %{
      joins: Map.merge(updated_old, new.joins),
      leaves: Map.merge(old.leaves, clean_leaves)
    }
  end

  defp make_tenant_topic(_socket, topic) do
    # Allow sending directly to the transport
    # fastlane = {:fastlane, socket.transport_pid, socket.serializer, ["presence_diff"]}
    # MultiplayerWeb.Endpoint.subscribe(topic, metadata: fastlane)
    MultiplayerWeb.Endpoint.subscribe(topic)
  end

  defp update_topic(socket, topic) do
    Map.put(socket, :topic, topic)
  end

  defp backlog(%{size: _size, last: last, tid: tid}, event, messsage) do
    true = :ets.insert(tid, [{last + 1, event, messsage}])
    %{size: :ets.info(tid)[:size], last: last + 1, tid: tid}
  end

  def channel_stats(pid, tenant, topic) do
    Registry.register(
      Multiplayer.Registry,
      "topics",
      {tenant, topic, System.system_time(:second)}
    )

    Registry.register(
      Multiplayer.Registry.Unique,
      "sessions",
      {pid, System.system_time(:second)}
    )
  end
end
