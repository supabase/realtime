# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

defmodule Realtime.Replication do
  defmodule(State,
    do:
      defstruct(
        config: [],
        connection: nil,
        conn_retry_delays: [],
        subscribers: [],
        transaction: nil,
        relations: %{},
        types: %{}
      )
  )

  use GenServer
  require Logger

  alias Realtime.Adapters.Changes.{
    Transaction,
    NewRecord,
    UpdatedRecord,
    DeletedRecord,
    TruncatedRelation
  }

  alias Realtime.Decoder.Messages.{
    Begin,
    Commit,
    Relation,
    Insert,
    Update,
    Delete,
    Truncate,
    Type
  }

  alias Realtime.SubscribersNotification
  alias Retry.DelayStreams

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    config =
      config
      |> Keyword.update!(:conn_retry_initial_delay, &String.to_integer(&1))
      |> Keyword.update!(:conn_retry_maximum_delay, &String.to_integer(&1))
      |> Keyword.update!(:conn_retry_jitter, &(String.to_integer(&1) / 100))

    {:ok, %State{config: config}, {:continue, :init_db_conn}}
  end

  @impl true
  def handle_continue(:init_db_conn, %State{config: config} = state) do
    # Database adapter's exit signal will be converted to {:EXIT, From, Reason}
    # message when, for example, there's a database connection error.
    Process.flag(:trap_exit, true)

    case adapter_impl(config).init(config) do
      {:ok, epgsql_pid} ->
        {:noreply, %State{state | connection: epgsql_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:epgsql, _pid, {:x_log_data, _start_lsn, _end_lsn, binary_msg}}, state) do
    decoded = Realtime.Decoder.decode_message(binary_msg)
    Logger.debug("Received binary message: #{inspect(binary_msg, limit: :infinity)}")
    Logger.debug("Decoded message: " <> inspect(decoded, limit: :infinity))

    {:noreply, process_message(decoded, state)}
  end

  @doc """

  Receives {:EXIT, From, Reason} message created by Process.flag(:trap_exit, true)
  when database adapter's process shuts down.

  Database connection retries happen here.

  """
  @impl true
  def handle_info({:EXIT, _, _}, %State{config: config} = state) do
    {retry_delay, new_state} = get_retry_delay(state)

    :timer.sleep(retry_delay)

    new_state =
      case adapter_impl(config).init(config) do
        {:ok, epgsql_pid} ->
          new_state
          |> reset_retry_delay()
          |> Map.put(:connection, epgsql_pid)

        _ ->
          new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end

  def get_retry_delay(%State{conn_retry_delays: [delay | delays]} = state) do
    {delay, %State{state | conn_retry_delays: delays}}
  end

  @doc """

  Initial delay is 0 milliseconds for immediate connection attempt.

  Future delays are generated and saved to state.

    * Begin with initial_delay and increase by a factor of 2
    * Each is randomly adjusted with jitter's value
    * Capped at maximum_delay

    Example

      initial_delay: 500     # Half a second
      maximum_delay: 300_000 # Five minutes
      jitter: 0.1            # Within 10% of a delay's value

      [486, 918, 1931, 4067, 7673, 15699, 31783, 64566, 125929, 251911, 300000]

  """
  def get_retry_delay(
        %State{
          conn_retry_delays: [],
          config: config
        } = state
      ) do
    initial_delay = Keyword.get(config, :conn_retry_initial_delay)
    maximum_delay = Keyword.get(config, :conn_retry_maximum_delay)
    jitter = Keyword.get(config, :conn_retry_jitter)

    delays =
      DelayStreams.exponential_backoff(initial_delay)
      |> DelayStreams.randomize(jitter)
      |> DelayStreams.expiry(maximum_delay)
      |> Enum.to_list()

    {0, %State{state | conn_retry_delays: delays}}
  end

  def reset_retry_delay(state) do
    %State{state | conn_retry_delays: []}
  end

  defp process_message(%Begin{} = msg, state) do
    %{
      state
      | transaction:
          {msg.final_lsn, %Transaction{changes: [], commit_timestamp: msg.commit_timestamp}}
    }
  end

  # This will notify subscribers once the transaction has completed
  # FYI: this will be the last function called before returning to the client
  defp process_message(
         %Commit{lsn: commit_lsn, end_lsn: end_lsn},
         %State{transaction: {current_txn_lsn, _txn}} = state
       )
       when commit_lsn == current_txn_lsn do
    # To show how the updated columns look like before being returned
    # Feel free to delete after testing
    Logger.debug("Final Update of Columns " <> inspect(state.relations, limit: :infinity))

    notify_subscribers(state)
    :ok = adapter_impl(state.config).acknowledge_lsn(state.connection, end_lsn)

    %{state | transaction: nil}
  end

  # Any unknown types will now be populated into state.types
  # This will be utilised later on when updating unidentified data types
  defp process_message(%Type{} = msg, state) do
    %{state | types: Map.put(state.types, msg.id, msg.name)}
  end

  defp process_message(%Relation{} = msg, state) do
    updated_columns =
      Enum.map(msg.columns, fn message ->
        if Map.has_key?(state.types, message.type) do
          %{message | type: state.types[message.type]}
        else
          message
        end
      end)

    updated_relations = %{msg | columns: updated_columns}

    %{state | relations: Map.put(state.relations, msg.id, updated_relations)}
  end

  defp process_message(%Insert{} = msg, state) do
    relation = Map.get(state.relations, msg.relation_id)

    data = data_tuple_to_map(relation.columns, msg.tuple_data)

    new_record = %NewRecord{
      type: "INSERT",
      schema: relation.namespace,
      table: relation.name,
      columns: relation.columns,
      record: data
    }

    {lsn, txn} = state.transaction
    %{state | transaction: {lsn, %{txn | changes: Enum.reverse([new_record | txn.changes])}}}
  end

  defp process_message(%Update{} = msg, state) do
    relation = Map.get(state.relations, msg.relation_id)

    old_data = data_tuple_to_map(relation.columns, msg.old_tuple_data)
    data = data_tuple_to_map(relation.columns, msg.tuple_data)

    updated_record = %UpdatedRecord{
      type: "UPDATE",
      schema: relation.namespace,
      table: relation.name,
      columns: relation.columns,
      old_record: old_data,
      record: data
    }

    {lsn, txn} = state.transaction
    %{state | transaction: {lsn, %{txn | changes: Enum.reverse([updated_record | txn.changes])}}}
  end

  defp process_message(%Delete{} = msg, state) do
    relation = Map.get(state.relations, msg.relation_id)

    data =
      data_tuple_to_map(
        relation.columns,
        msg.old_tuple_data || msg.changed_key_tuple_data
      )

    deleted_record = %DeletedRecord{
      type: "DELETE",
      schema: relation.namespace,
      table: relation.name,
      columns: relation.columns,
      old_record: data
    }

    {lsn, txn} = state.transaction
    %{state | transaction: {lsn, %{txn | changes: Enum.reverse([deleted_record | txn.changes])}}}
  end

  defp process_message(%Truncate{} = msg, state) do
    truncated_relations =
      for truncated_relation <- msg.truncated_relations do
        relation = Map.get(state.relations, truncated_relation)

        %TruncatedRelation{
          type: "TRUNCATE",
          schema: relation.namespace,
          table: relation.name
        }
      end

    {lsn, txn} = state.transaction

    %{
      state
      | transaction: {lsn, %{txn | changes: Enum.reverse(truncated_relations ++ txn.changes)}}
    }
  end

  # TODO: Typecast to meaningful Elixir types here later
  defp data_tuple_to_map(_columns, nil), do: %{}

  defp data_tuple_to_map(columns, tuple_data) do
    for {column, index} <- Enum.with_index(columns, 1),
        do: {column.name, :erlang.element(index, tuple_data)},
        into: %{}
  end

  defp adapter_impl(config) do
    Keyword.get(config, :postgres_adapter, Realtime.Adapters.Postgres.EpgsqlImplementation)
  end

  defp notify_subscribers(%State{transaction: {_current_txn_lsn, txn}}) do
    SubscribersNotification.notify(txn)
  end
end
