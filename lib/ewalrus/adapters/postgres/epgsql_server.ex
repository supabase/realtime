# This file draws from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

defmodule Realtime.Adapters.Postgres.EpgsqlServer do
  defmodule(State,
    do:
      defstruct(
        epgsql_params: nil,
        delays: [0],
        publication_name: nil,
        epgsql_replication_pid: nil,
        epgsql_select_pid: nil,
        slot_config: nil,
        wal_position: nil,
        max_replication_lag_in_mb: 0
      )
  )

  use GenServer

  require Logger

  alias Realtime.Replication
  alias Retry.DelayStreams

  # 500 milliseconds
  @initial_delay 500
  # 5 minutes
  @maximum_delay 300_000
  # Within 10% of a delay's value
  @jitter 0.1

  def start_link(config) when is_list(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def acknowledge_lsn(lsn) do
    GenServer.call(__MODULE__, {:ack_lsn, lsn})
  end

  @impl true
  def init(
        epgsql_params: epgsql_params,
        publications: publications,
        slot_name: slot_name,
        wal_position: {xlog, offset} = wal_position,
        max_replication_lag_in_mb: max_replication_lag_in_mb
      )
      when is_map(epgsql_params) and is_list(publications) and
             (is_binary(slot_name) or is_atom(slot_name)) and is_binary(xlog) and
             is_binary(offset) and is_number(max_replication_lag_in_mb) do
    Process.flag(:trap_exit, true)

    state = %State{
      epgsql_params: epgsql_params,
      wal_position: wal_position,
      max_replication_lag_in_mb: max_replication_lag_in_mb
    }

    with publication_name when is_binary(publication_name) <-
           generate_publication_name(publications),
         {slot_name, create_replication_command} <- prepare_slot(slot_name) do
      {:ok,
       %{
         state
         | publication_name: publication_name,
           slot_config: {slot_name, create_replication_command}
       }, {:continue, :db_connect}}
    else
      error -> {:stop, error, state}
    end
  end

  @impl true
  def init(_config) do
    {:stop, :bad_config, %State{}}
  end

  @impl true
  def handle_continue(:db_connect, %State{epgsql_params: epgsql_params} = state) do
    epgsql_replication_config = Map.put(epgsql_params, :replication, "database")
    epgsql_select_config = Map.delete(epgsql_replication_config, :replication)

    epgsql_pids =
      Enum.map([epgsql_replication_config, epgsql_select_config], fn epgsql_config ->
        case :epgsql.connect(epgsql_config) do
          {:ok, epgsql_pid} -> epgsql_pid
          {:error, _} -> nil
        end
      end)

    [epgsql_replication_pid, epgsql_select_pid] = epgsql_pids

    with true <- Enum.all?(epgsql_pids, &is_pid(&1)),
         updated_state <- %{
           state
           | epgsql_replication_pid: epgsql_replication_pid,
             epgsql_select_pid: epgsql_select_pid
         },
         :ok <- check_replication_lag_size(updated_state),
         {:ok, updated_state} <- start_replication(updated_state) do
      {:noreply, updated_state}
    else
      {:error, :replication_lag_exceeds_set_limit} = error ->
        is_pid(epgsql_replication_pid) && :epgsql.close(epgsql_replication_pid)

        is_pid(epgsql_select_pid) &&
          maybe_drop_replication_slot(%{state | epgsql_select_pid: epgsql_select_pid}) &&
          :epgsql.close(epgsql_select_pid)

        {:stop, error, state}

      error ->
        Enum.each(epgsql_pids, &(is_pid(&1) && :epgsql.close(&1)))

        {:stop, error, state}
    end
  end

  @impl true
  def handle_call(
        {:ack_lsn, {xlog, offset}},
        _from,
        %{epgsql_replication_pid: epgsql_replication_pid} = state
      )
      when is_integer(xlog) and is_integer(offset) do
    with <<last_processed_lsn::integer-64>> <- <<xlog::integer-32, offset::integer-32>>,
         :ok <-
           :epgsql.standby_status_update(
             epgsql_replication_pid,
             last_processed_lsn,
             last_processed_lsn
           ) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:ack_lsn, _}, _from, state), do: {:reply, :error, state}

  @impl true
  def handle_info(
        :start_replication,
        %State{
          epgsql_replication_pid: epgsql_replication_pid,
          epgsql_select_pid: epgsql_select_pid
        } = state
      ) do
    case start_replication(state) do
      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, error} ->
        :epgsql.close(epgsql_replication_pid)
        :epgsql.close(epgsql_select_pid)
        {:stop, error, state}
    end
  end

  @impl true
  def handle_info(
        {:EXIT, _pid,
         {:error,
          {:error, :error, "42704", :undefined_object, _error_msg,
           [
             file: _file,
             line: _line,
             routine: "GetPublicationByName",
             severity: "ERROR",
             where: _where_msg
           ]}}} = msg,
        %{
          epgsql_replication_pid: epgsql_replication_pid,
          epgsql_select_pid: epgsql_select_pid
        } = state
      ) do
    :epgsql.close(epgsql_replication_pid)
    maybe_drop_replication_slot(state)
    :epgsql.close(epgsql_select_pid)

    {:stop, msg, state}
  end

  @doc """

  Removes the existing replication slot when epgsql replication process crashes due to
  database deleting WAL segment when Realtime server has fallen too far behind.

  ## Example process exit message

    {:EXIT, #PID<0.2324.0>,
     {:error,
      {:error, :error, "58P01", :undefined_file,
       "requested WAL segment 00000001000000000000007F has already been removed",
       [file: "walsender.c", line: "2447", routine: "XLogRead", severity: "ERROR"]}}}

  """
  @impl true
  def handle_info(
        {:EXIT, _pid,
         {:error,
          {:error, :error, "58P01", :undefined_file, error_msg,
           [file: "walsender.c", line: _line, routine: "XLogRead", severity: "ERROR"]}}} = msg,
        %{
          epgsql_replication_pid: epgsql_replication_pid,
          epgsql_select_pid: epgsql_select_pid
        } = state
      )
      when is_binary(error_msg) do
    :epgsql.close(epgsql_replication_pid)

    stop_msg =
      case String.split(error_msg) do
        ["requested", "WAL", "segment", _, "has", "already", "been", "removed"] ->
          maybe_drop_replication_slot(state)
          {:error, {error_msg, :replication_slot_dropped}}

        _ ->
          msg
      end

    :epgsql.close(epgsql_select_pid)

    {:stop, stop_msg, state}
  end

  @impl true
  def handle_info(
        msg,
        %{
          epgsql_replication_pid: epgsql_replication_pid,
          epgsql_select_pid: epgsql_select_pid
        } = state
      ) do
    :epgsql.close(epgsql_replication_pid)
    :epgsql.close(epgsql_select_pid)
    {:stop, msg, state}
  end

  defp check_replication_lag_size(%State{
         epgsql_select_pid: epgsql_select_pid,
         max_replication_lag_in_mb: max_replication_lag_in_mb,
         slot_config: {expected_slot_name, _}
       })
       when is_pid(epgsql_select_pid) and max_replication_lag_in_mb > 0 do
    case :epgsql.squery(
           epgsql_select_pid,
           "SELECT slot_name, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) FROM pg_replication_slots"
         ) do
      {:ok, _, results} ->
        case Enum.find(results, fn {slot_name, _} -> slot_name == expected_slot_name end) do
          nil ->
            :ok

          {_, lag_in_bytes} ->
            if String.to_integer(lag_in_bytes) / 1_000_000 <= max_replication_lag_in_mb do
              :ok
            else
              {:error, :replication_lag_exceeds_set_limit}
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_replication_lag_size(%State{max_replication_lag_in_mb: max_replication_lag_in_mb})
       when max_replication_lag_in_mb == 0,
       do: :ok

  defp check_replication_lag_size(_), do: {:error, :check_replication_lag_size_error}

  defp generate_publication_name(publications) when is_list(publications) do
    with true <- Enum.all?(publications, fn pub -> is_binary(pub) end),
         publication_name when publication_name != "" <-
           publications
           |> Enum.intersperse(",")
           |> IO.iodata_to_binary()
           |> String.replace("'", "\\'") do
      publication_name
    else
      _ -> :bad_publications
    end
  end

  defp generate_publication_name(_publications) do
    :bad_publications
  end

  defp prepare_slot(slot_name) when is_binary(slot_name) and slot_name != "" do
    escaped_slot_name = slot_name |> String.replace("'", "\\'") |> String.downcase()

    {escaped_slot_name,
     ["CREATE_REPLICATION_SLOT ", escaped_slot_name, " LOGICAL pgoutput NOEXPORT_SNAPSHOT"]
     |> IO.iodata_to_binary()}
  end

  defp prepare_slot(_slot_name) do
    temp_slot_name =
      ["temp_slot", Integer.to_string(:rand.uniform(9_999))] |> IO.iodata_to_binary()

    {temp_slot_name,
     ["CREATE_REPLICATION_SLOT ", temp_slot_name, " TEMPORARY LOGICAL pgoutput NOEXPORT_SNAPSHOT"]
     |> IO.iodata_to_binary()}
  end

  defp start_replication(
         %State{
           publication_name: publication_name,
           epgsql_replication_pid: epgsql_replication_pid,
           slot_config: {slot_name, _command},
           wal_position: {xlog, offset}
         } = state
       ) do
    case does_publication_exist(state) do
      true ->
        with :ok <- maybe_create_replication_slot(state),
             replication_server_pid when is_pid(replication_server_pid) <-
               Process.whereis(Replication),
             :ok <-
               :epgsql.start_replication(
                 epgsql_replication_pid,
                 slot_name,
                 replication_server_pid,
                 [],
                 '#{xlog}/#{offset}',
                 'proto_version \'1\', publication_names \'#{publication_name}\''
               ) do
          {:ok, reset_delays(state)}
        else
          error -> {:error, error}
        end

      false ->
        maybe_drop_replication_slot(state)
        {delay, updated_state} = get_delay(state)
        Process.send_after(__MODULE__, :start_replication, delay)
        {:ok, updated_state}

      {:error, error} ->
        {:error, error}
    end
  end

  defp reset_delays(state) do
    %{state | delays: [0]}
  end

  defp get_delay(%State{delays: [delay | delays]} = state) do
    {delay, %{state | delays: delays}}
  end

  defp get_delay(%State{delays: []} = state) do
    [delay | delays] =
      DelayStreams.exponential_backoff(@initial_delay)
      |> DelayStreams.randomize(@jitter)
      |> DelayStreams.expiry(@maximum_delay)
      |> Enum.to_list()

    {delay, %{state | delays: delays}}
  end

  defp maybe_create_replication_slot(
         %State{
           epgsql_replication_pid: epgsql_replication_pid,
           slot_config: {_slot_name, create_replication_command}
         } = state
       ) do
    case does_replication_slot_exist(state) do
      true ->
        :ok

      false ->
        case :epgsql.squery(epgsql_replication_pid, create_replication_command) do
          {:ok, _, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp maybe_drop_replication_slot(%State{
         epgsql_select_pid: epgsql_select_pid,
         slot_config: {slot_name, _command}
       }) do
    drop_replication_slot_command =
      ["SELECT pg_drop_replication_slot('", slot_name, "')"] |> IO.iodata_to_binary()

    case :epgsql.squery(epgsql_select_pid, drop_replication_slot_command) do
      {:ok, _, _} -> :ok
      {:error, _error} -> :ok
    end
  end

  defp does_publication_exist(%State{
         publication_name: publication_name,
         epgsql_select_pid: epgsql_select_pid
       }) do
    publication_query =
      ["SELECT COUNT(*) = 1 FROM pg_publication WHERE pubname = '", publication_name, "'"]
      |> IO.iodata_to_binary()

    case :epgsql.squery(epgsql_select_pid, publication_query) do
      {:ok, _, [{"t"}]} -> true
      {:ok, _, [{"f"}]} -> false
      {:error, error} -> {:error, error}
    end
  end

  defp does_replication_slot_exist(%State{
         epgsql_select_pid: epgsql_select_pid,
         slot_config: {slot_name, _command}
       }) do
    replication_slot_query =
      ["SELECT COUNT(*) >= 1 FROM pg_replication_slots WHERE slot_name = '", slot_name, "'"]
      |> IO.iodata_to_binary()

    case :epgsql.squery(epgsql_select_pid, replication_slot_query) do
      {:ok, _, [{"t"}]} -> true
      {:ok, _, [{"f"}]} -> false
      {:error, error} -> {:error, error}
    end
  end
end
