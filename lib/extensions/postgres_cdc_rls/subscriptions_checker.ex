defmodule Extensions.PostgresCdcRls.SubscriptionsChecker do
  @moduledoc false
  use GenServer
  require Logger

  alias Extensions.PostgresCdcRls, as: Rls
  alias Rls.Subscriptions

  alias Realtime.Helpers, as: H

  @timeout 120_000

  defmodule State do
    @moduledoc false
    defstruct [:id, :conn, :check_active_pids, :subscribers_tid]

    @type t :: %__MODULE__{
            id: String.t(),
            conn: Postgrex.conn(),
            check_active_pids: reference(),
            subscribers_tid: :ets.tid()
          }
  end

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(args) do
    %{
      "id" => id,
      "db_host" => host,
      "db_port" => port,
      "db_name" => name,
      "db_user" => user,
      "db_password" => pass,
      "db_socket_opts" => socket_opts,
      "subscribers_tid" => subscribers_tid
    } = args

    {:ok, conn} = H.connect_db(host, port, name, user, pass, socket_opts, 1)

    state = %State{
      id: id,
      conn: conn,
      check_active_pids: check_active_pids(),
      subscribers_tid: subscribers_tid
    }

    {:ok, state}
  end

  @impl true
  def handle_info(
        :check_active_pids,
        %State{check_active_pids: ref, subscribers_tid: tid} = state
      ) do
    H.cancel_timer(ref)

    ids =
      fn {pid, postgres_id, _ref}, acc ->
        case :rpc.call(node(pid), Process, :alive?, [pid]) do
          true ->
            acc

          _ ->
            Logger.error("Detected phantom subscriber")
            :ets.delete(tid, pid)
            [UUID.string_to_binary!(postgres_id) | acc]
        end
      end
      |> :ets.foldl([], tid)

    if length(ids) > 0 do
      Subscriptions.delete_multi(state.conn, ids)
    end

    new_ref =
      if :ets.info(tid, :size) == 0 do
        Logger.debug("Cancel check_active_pids")
        Rls.handle_stop(state.id, 15_000)
        nil
      else
        check_active_pids()
      end

    {:noreply, %{state | check_active_pids: new_ref}}
  end

  ## Internal functions

  defp check_active_pids() do
    Process.send_after(
      self(),
      :check_active_pids,
      @timeout
    )
  end
end
