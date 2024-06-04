defmodule Extensions.PostgresCdcRls.SubscriptionsChecker do
  @moduledoc false
  use GenServer
  require Logger

  alias Extensions.PostgresCdcRls, as: Rls

  alias Realtime.Database
  alias Realtime.Helpers
  alias Realtime.Rpc
  alias Realtime.Telemetry

  alias Rls.Subscriptions

  @timeout 120_000
  @max_delete_records 1000

  defmodule State do
    @moduledoc false
    defstruct [:id, :conn, :check_active_pids, :subscribers_tid, :delete_queue]

    @type t :: %__MODULE__{
            id: String.t(),
            conn: Postgrex.conn(),
            check_active_pids: reference(),
            subscribers_tid: :ets.tid(),
            delete_queue: %{
              ref: reference(),
              queue: :queue.queue()
            }
          }
  end

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(args) do
    %{"id" => id, "subscribers_tid" => subscribers_tid} = args

    Logger.metadata(external_id: id, project: id)

    realtime_subscription_checker_settings =
      Database.from_settings(args, "realtime_subscription_checker")

    {:ok, conn} = Database.connect_db(realtime_subscription_checker_settings)

    state = %State{
      id: id,
      conn: conn,
      check_active_pids: check_active_pids(),
      subscribers_tid: subscribers_tid,
      delete_queue: %{
        ref: nil,
        queue: :queue.new()
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_info(
        :check_active_pids,
        %State{check_active_pids: ref, subscribers_tid: tid, delete_queue: delete_queue, id: id} =
          state
      ) do
    Helpers.cancel_timer(ref)

    ids =
      subscribers_by_node(tid)
      |> not_alive_pids_dist()
      |> pop_not_alive_pids(tid, id)

    new_delete_queue =
      if length(ids) > 0 do
        q =
          Enum.reduce(ids, delete_queue.queue, fn id, acc ->
            if :queue.member(id, acc), do: acc, else: :queue.in(id, acc)
          end)

        %{
          ref: check_delete_queue(),
          queue: q
        }
      else
        delete_queue
      end

    {:noreply, %{state | check_active_pids: check_active_pids(), delete_queue: new_delete_queue}}
  end

  def handle_info(:check_delete_queue, %State{delete_queue: %{ref: ref, queue: q}} = state) do
    Helpers.cancel_timer(ref)

    new_queue =
      if !:queue.is_empty(q) do
        {ids, q1} = Helpers.queue_take(q, @max_delete_records)
        Logger.warning("Delete #{length(ids)} phantom subscribers from db")

        case Subscriptions.delete_multi(state.conn, ids) do
          {:ok, _} ->
            q1

          {:error, reason} ->
            Helpers.log_error("UnableToDeletePhantomSubscriptions", reason)

            q
        end
      else
        q
      end

    new_ref = if !:queue.is_empty(new_queue), do: check_delete_queue(), else: ref

    {:noreply, %{state | delete_queue: %{ref: new_ref, queue: new_queue}}}
  end

  ## Internal functions

  @spec pop_not_alive_pids([pid()], :ets.tid(), binary()) :: [Ecto.UUID.t()]
  def pop_not_alive_pids(pids, tid, tenant_id) do
    Enum.reduce(pids, [], fn pid, acc ->
      case :ets.lookup(tid, pid) do
        [] ->
          Telemetry.execute(
            [:realtime, :subscriptions_checker, :pid_not_found],
            %{quantity: 1},
            %{
              tenant_id: tenant_id
            }
          )

          acc

        results ->
          for {^pid, postgres_id, _ref, _node} <- results do
            Telemetry.execute(
              [:realtime, :subscriptions_checker, :phantom_pid_detected],
              %{quantity: 1},
              %{
                tenant_id: tenant_id
              }
            )

            :ets.delete(tid, pid)
            UUID.string_to_binary!(postgres_id)
          end ++ acc
      end
    end)
  end

  @spec subscribers_by_node(:ets.tid()) :: %{node() => MapSet.t(pid())}
  def subscribers_by_node(tid) do
    fn {pid, _postgres_id, _ref, node}, acc ->
      set =
        if Map.has_key?(acc, node) do
          MapSet.put(acc[node], pid)
        else
          MapSet.new([pid])
        end

      Map.put(acc, node, set)
    end
    |> :ets.foldl(%{}, tid)
  end

  @spec not_alive_pids_dist(%{node() => MapSet.t(pid())}) :: [pid()] | []
  def not_alive_pids_dist(pids) do
    Enum.reduce(pids, [], fn {node, pids}, acc ->
      if node == node() do
        acc ++ not_alive_pids(pids)
      else
        case Rpc.call(node, __MODULE__, :not_alive_pids, [pids], timeout: 15_000) do
          {:badrpc, _} = error ->
            Helpers.log_error("UnableToCheckProcessesOnRemoteNode", error)
            acc

          pids ->
            acc ++ pids
        end
      end
    end)
  end

  @spec not_alive_pids(MapSet.t(pid())) :: [pid()] | []
  def not_alive_pids(pids) do
    Enum.reduce(pids, [], fn pid, acc ->
      if Process.alive?(pid) do
        acc
      else
        [pid | acc]
      end
    end)
  end

  defp check_delete_queue() do
    Process.send_after(self(), :check_delete_queue, 1000)
  end

  defp check_active_pids() do
    Process.send_after(self(), :check_active_pids, @timeout)
  end
end
