defmodule Realtime.Messages do
  @moduledoc """
  Handles `realtime.messages` table operations

  ## Persistence

  `persist/6` writes messages in batches, with one `GenStage` pipeline per tenant database connection, on
  the node that owns it. Senders on other nodes reach it through `Realtime.Messages.Router`.

      [Producer] -> [Consumer]

  `Realtime.Messages.Producer` queues messages and emits each batch as one event.
  `Realtime.Messages.Consumer` writes each batch with `insert_batch/5`, then sends demand upstream for the
  next one. A batch is emitted as soon as it reaches `:max_batch_size` messages or `:max_batch_bytes`,
  and otherwise once `:flush_interval_ms` passed since the previous one. Idle stages hibernate after
  `:hibernate_after`. A pipeline that stopped is started again by the next message.

  The guardrails below are all read from `config :realtime, Realtime.Messages`.

    * `:max_pending` and `:max_pending_bytes` - messages, and their bytes, queued or being written
    * `:breaker_threshold` and `:breaker_cooldown_ms` - consecutive failed batches after which the
      consumer stops asking for events, and for how long. The producer buffers messages meanwhile, up to
      `:max_pending`
    * `:max_queue_ms` - how long a broadcast with `ack` waits for earlier batches, see `ack_timeout/0`

  A message over a limit is not persisted, and `persist/6` returns the error, or sends it to `:reply_to`.
  Messages that are not persisted are logged once per reason every `:drops_report_interval_ms` with their
  number, as `PersistenceLimitReached` when a limit was reached and as `UnableToPersistMessage` otherwise.

  Persisted messages per socket are limited before they reach the producer, by
  `RealtimeWeb.RealtimeChannel.BroadcastHandler`, which fails them with `persistence_rate_limit`.
  """
  use Realtime.Logs

  alias Realtime.Api.Message
  alias Realtime.Messages.Producer
  alias Realtime.Messages.Router
  alias Realtime.Telemetry

  import Ecto.Query, only: [from: 2]

  @default_timeout 5_000
  @registry Realtime.Registry.Unique
  @supervisor Producer.DynamicSupervisor

  @persist_defaults [
    max_batch_size: 200,
    max_batch_bytes: 8 * 1024 * 1024,
    flush_interval_ms: 10,
    max_pending: 5_000,
    max_pending_bytes: 64 * 1024 * 1024,
    breaker_threshold: 3,
    breaker_cooldown_ms: 5_000,
    max_queue_ms: 2_000,
    drops_report_interval_ms: 1_000,
    query_timeout: 5_000,
    hibernate_after: 15_000
  ]

  # The janitor drops partitions older than 72 hours, so nothing can outlive that.
  @max_ttl_seconds 72 * 60 * 60

  @doc """
  The longest a message can be kept, in seconds.
  """
  @spec max_ttl_seconds() :: pos_integer()
  def max_ttl_seconds, do: @max_ttl_seconds

  @typedoc """
  What the sender asked for, once parsed. `nil` means they did not ask to save the message.
  """
  @type persist :: %{ttl: pos_integer()} | nil

  @doc """
  Parses what the sender asked for into the options we honor, or refuses it.

  `nil` means the sender did not ask to save the message, and a map means they did. One value carries
  both facts, so nothing downstream needs a separate flag.

  The options live inside the map rather than beside it, so adding one is a new key here and no
  signature downstream changes shape. `true` and `%{}` both ask for the defaults.

  Seconds arrive as an integer over WebSocket and as a string on the HTTP query string, so both are
  accepted. A ttl longer than the maximum is refused rather than clamped, so a sender asking for more
  than we keep finds out.
  """
  @spec parse_persist(term()) :: {:ok, persist()} | {:error, :invalid_ttl}
  def parse_persist(%{"ttl" => seconds}) when is_integer(seconds) and seconds > 0 and seconds <= @max_ttl_seconds,
    do: {:ok, %{ttl: seconds}}

  def parse_persist(%{"ttl" => seconds} = persist) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} -> parse_persist(%{persist | "ttl" => seconds})
      _not_an_integer -> {:error, :invalid_ttl}
    end
  end

  def parse_persist(%{"ttl" => nil}), do: {:ok, %{ttl: @max_ttl_seconds}}
  def parse_persist(%{"ttl" => _invalid}), do: {:error, :invalid_ttl}
  def parse_persist(persist) when is_map(persist), do: {:ok, %{ttl: @max_ttl_seconds}}
  def parse_persist(persist) when persist in [true, "true"], do: {:ok, %{ttl: @max_ttl_seconds}}
  def parse_persist(persist) when persist in [nil, false, "false"], do: {:ok, nil}
  def parse_persist(_persist), do: {:error, :invalid_ttl}

  @doc """
  The deadline a `ttl` in seconds lands on. Stored instead of the ttl, so replay compares two timestamps.
  """
  @spec expires_at(pos_integer()) :: NaiveDateTime.t()
  def expires_at(seconds), do: NaiveDateTime.utc_now() |> NaiveDateTime.add(seconds, :second)

  @type payload :: {:json, term()} | {:binary, binary()}

  @type persist_error ::
          :persistence_buffer_full
          | :persistence_rate_limit
          | :persistence_unavailable
          | :persistence_timeout
          | :persistence_failed

  @typedoc """
  Who gets the result of a message, a `:reply_to` or `nil` for no one.
  """
  @type caller :: {pid(), term()} | nil
  @type reply :: {caller, {:ok, String.t()} | {:error, persist_error}}

  @typedoc """
  A message waiting to be written. `json` is the encoded payload, kept as iodata so it can be sent to
  another node, and `bytes` is the size of the payload.
  """
  @type entry :: %{
          id: String.t(),
          topic: String.t(),
          event: String.t(),
          json: iodata() | nil,
          binary: binary() | nil,
          bytes: non_neg_integer(),
          expires_at: NaiveDateTime.t() | nil
        }

  @doc """
  The persistence config, with `config :realtime, Realtime.Messages` merged into the defaults.
  """
  @spec config() :: keyword()
  def config, do: Keyword.merge(@persist_defaults, Application.get_env(:realtime, __MODULE__, []))

  @doc """
  How long a broadcast with `ack` waits for its message to be written, see
  `RealtimeWeb.RealtimeChannel.BroadcastHandler`. It is the flush interval, plus up to `:max_queue_ms`
  waiting for earlier batches, plus `:query_timeout` for the write.

  A broadcast that stops waiting gets `persistence_timeout`, and its message may still be written.
  """
  @spec ack_timeout() :: pos_integer()
  def ack_timeout do
    config = config()
    flush_interval_ms = Keyword.fetch!(config, :flush_interval_ms)
    max_queue_ms = Keyword.fetch!(config, :max_queue_ms)
    query_timeout = Keyword.fetch!(config, :query_timeout)
    flush_interval_ms + max_queue_ms + query_timeout
  end

  @doc """
  Persists a broadcast for `topic`, either sent over WebSocket or through the single broadcast API.

  Only called after the sender's `persistence` policy authorized it, so the persisted row is always private.
  Bypasses RLS because that authorization already happened on the broadcast.

  Check `:persistence` authorization to define if message is persisted,
  but store with `:broadcast` extension, like any other broadcasted message.

  Set `skip_broadcast` because the message was already delivered to the subscribers, so it must not be
  broadcast again when it appears on the replication stream.

  Writes are batched, see "Persistence" in the moduledoc. Returns `:ok` once the message is queued, or its
  error when it is over a limit or the connection stopped. It returns `persistence_timeout` when the
  producer does not reply within a second, and the message may still be written. Over RPC it returns `:ok`
  without waiting, or `persistence_unavailable` when the node of the connection is not connected. It
  accepts the options below.

    * `:reply_to` - `{pid, tag}` that gets `{tag, {:ok, id}}` or `{tag, {:error, reason}}` once the message
      is written or dropped. Its errors are sent there too, and `persist/6` returns `:ok`. `pid` can be on
      another node
    * `:expires_at` - when the message stops being replayed, see `expires_at/1`

  Automatically uses RPC if the database connection is not on the same node.
  """
  @spec persist(
          conn :: DBConnection.conn(),
          tenant_id :: String.t(),
          topic :: String.t(),
          event :: String.t(),
          payload :: payload(),
          opts :: keyword()
        ) :: :ok | {:error, persist_error}
  def persist(conn, tenant_id, topic, event, payload, opts \\ [])

  def persist(conn, tenant_id, topic, event, payload, opts) when node(conn) == node() do
    caller = Keyword.get(opts, :reply_to)
    entry = %{entry(topic, event, payload) | expires_at: Keyword.get(opts, :expires_at)}

    with {:ok, pid} <- lookup_or_start_producer(conn, tenant_id),
         :ok <- call(pid, tenant_id, entry, caller) do
      :ok
    else
      error when caller != nil -> reply([{caller, error}])
      error -> error
    end
  end

  def persist(conn, tenant_id, topic, event, payload, opts) do
    caller = Keyword.get(opts, :reply_to)
    conn_node = node(conn)

    if conn_node in Node.list() do
      entry = %{entry(topic, event, payload) | expires_at: Keyword.get(opts, :expires_at)}
      Realtime.GenRpc.abcast([conn_node], Router.name(topic), {:persist, conn, tenant_id, entry, caller}, key: topic)
    else
      # The connection's node left the cluster, but syn on this node still returns that connection
      emit_dropped(tenant_id, :persistence_unavailable, 1)
      error = {:error, :persistence_unavailable}
      if caller, do: reply([{caller, error}]), else: error
    end
  end

  # Runs in a `Realtime.Messages.Router`, so it sends to the producer instead of waiting on it
  @doc false
  @spec enqueue(pid(), String.t(), entry, caller) :: :ok
  def enqueue(conn, tenant_id, entry, caller) do
    case lookup_or_start_producer(conn, tenant_id) do
      {:ok, pid} -> send(pid, {:persist, entry, caller})
      error -> reply([{caller, error}])
    end

    :ok
  end

  @doc false
  @spec emit_dropped(String.t(), persist_error, pos_integer()) :: :ok
  def emit_dropped(tenant_id, reason, count) do
    Telemetry.execute([:realtime, :tenants, :persist, :dropped], %{count: count}, %{tenant: tenant_id, reason: reason})
  end

  @doc false
  @spec log_dropped(String.t(), persist_error, pos_integer()) :: :ok
  def log_dropped(code, reason, 1) do
    log_error(code, "1 message was broadcast but not persisted: #{reason}")
  end

  def log_dropped(code, reason, count) do
    log_error(code, "#{count} messages were broadcast but not persisted: #{reason}")
  end

  @doc false
  @spec reply([reply]) :: :ok
  def reply(replies) do
    Enum.each(replies, fn
      {nil, _result} -> :ok
      {{pid, tag}, result} -> send(pid, {tag, result})
    end)
  end

  defp entry(topic, event, {:json, payload}) do
    iodata = Jason.encode_to_iodata!(payload)
    %{new_entry(topic, event) | json: iodata, bytes: IO.iodata_length(iodata)}
  end

  defp entry(topic, event, {:binary, payload}) do
    %{new_entry(topic, event) | binary: payload, bytes: byte_size(payload)}
  end

  defp new_entry(topic, event) do
    %{
      id: Ecto.UUID.generate(),
      topic: topic,
      event: event,
      json: nil,
      binary: nil,
      bytes: 0,
      expires_at: nil
    }
  end

  defp lookup_or_start_producer(conn, tenant_id) do
    case Registry.lookup(@registry, {Producer, conn}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        # Guard against a race condition: syn can still return the connection of a Connect that stopped
        if Process.alive?(conn) do
          start_producer(conn, tenant_id)
        else
          emit_dropped(tenant_id, :persistence_unavailable, 1)
          {:error, :persistence_unavailable}
        end
    end
  end

  defp start_producer(conn, tenant_id) do
    opts = [db_conn: conn, tenant_id: tenant_id]

    case DynamicSupervisor.start_child({:via, PartitionSupervisor, {@supervisor, tenant_id}}, {Producer, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        log_error("UnableToStartMessagesProducer", reason, external_id: tenant_id, project: tenant_id)
        emit_dropped(tenant_id, :persistence_unavailable, 1)
        {:error, :persistence_unavailable}
    end
  end

  defp call(pid, tenant_id, entry, caller) do
    GenStage.call(pid, {:persist, entry, caller}, 1_000)
  catch
    :exit, {:timeout, _} ->
      {:error, :persistence_timeout}

    # The producer stopped before it read the message
    :exit, _ ->
      emit_dropped(tenant_id, :persistence_unavailable, 1)
      {:error, :persistence_unavailable}
  end

  @doc """
  Writes `entries` with one `INSERT` after `last_inserted_at`, and returns the result of each entry, in
  order, with the last `inserted_at` it wrote.

  `inserted_at` is strictly increasing. The batch starts at the later of now and `last_inserted_at` plus
  1 microsecond, and each entry adds 1 microsecond, so messages written in the same microsecond keep their
  send order on replay.

  A batch that fails with a data exception (SQLSTATE class 22, e.g. invalid JSON) is written one entry at
  a time, so only the bad entries fail. Any other error fails the whole batch.
  """
  @spec insert_batch(pid(), String.t(), [entry, ...], NaiveDateTime.t() | nil, timeout()) ::
          {:ok, [{:ok, String.t()} | {:error, :persistence_failed}], NaiveDateTime.t() | nil}
          | {:error, :persistence_failed}
  def insert_batch(conn, tenant_id, entries, last_inserted_at, timeout) do
    count = length(entries)
    start = System.monotonic_time()

    {inserted, result} =
      case insert(conn, entries, last_inserted_at, timeout) do
        {:ok, last_inserted_at} ->
          {count, {:ok, Enum.map(entries, &{:ok, &1.id}), last_inserted_at}}

        {:error, %Postgrex.Error{postgres: %{pg_code: "22" <> _}}} ->
          {:ok, results, _last_inserted_at} = result = insert_one_by_one(conn, entries, last_inserted_at, timeout)
          {Enum.count(results, &match?({:ok, _}, &1)), result}

        {:error, error} ->
          log_error("UnableToPersistMessage", error)
          {0, {:error, :persistence_failed}}
      end

    duration = System.monotonic_time() - start

    Telemetry.execute(
      [:realtime, :tenants, :persist, :flush],
      %{count: count, inserted: inserted, bytes: Enum.sum_by(entries, & &1.bytes), duration: duration},
      %{tenant: tenant_id}
    )

    result
  end

  defp insert_one_by_one(conn, entries, last_inserted_at, timeout) do
    {results, last_inserted_at} =
      Enum.map_reduce(entries, last_inserted_at, fn entry, last ->
        case insert(conn, [entry], last, timeout) do
          {:ok, last} ->
            {{:ok, entry.id}, last}

          {:error, error} ->
            log_error("UnableToPersistMessage", error)
            {{:error, :persistence_failed}, last}
        end
      end)

    {:ok, results, last_inserted_at}
  end

  defp insert(conn, entries, last_inserted_at, timeout) do
    first = first_inserted_at(last_inserted_at)
    inserted_ats = Enum.with_index(entries, fn _entry, i -> NaiveDateTime.add(first, i, :microsecond) end)

    query = """
    INSERT INTO realtime.messages
      (id, topic, event, payload, binary_payload, expires_at, inserted_at, updated_at, extension, private, skip_broadcast)
    SELECT *, inserted_at, 'broadcast', true, true
    FROM unnest($1::uuid[], $2::text[], $3::text[], $4::jsonb[], $5::bytea[], $6::timestamp[], $7::timestamp[])
      AS m(id, topic, event, payload, binary_payload, expires_at, inserted_at)
    """

    params = [
      Enum.map(entries, &Ecto.UUID.dump!(&1.id)),
      Enum.map(entries, & &1.topic),
      Enum.map(entries, & &1.event),
      Enum.map(entries, &(&1.json && Jason.Fragment.new(&1.json))),
      Enum.map(entries, & &1.binary),
      Enum.map(entries, & &1.expires_at),
      inserted_ats
    ]

    case Postgrex.query(conn, query, params, timeout: timeout) do
      {:ok, _result} -> {:ok, List.last(inserted_ats)}
      {:error, _} = error -> error
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp first_inserted_at(nil), do: NaiveDateTime.utc_now(:microsecond)

  defp first_inserted_at(last_inserted_at) do
    now = NaiveDateTime.utc_now(:microsecond)
    next = NaiveDateTime.add(last_inserted_at, 1, :microsecond)
    if NaiveDateTime.after?(next, now), do: next, else: now
  end

  @doc """
  Fetch last `limit ` messages for a given `topic` inserted after `since`

  `limit` is clamped between 1 and `BROADCAST_REPLAY_MAX_MESSAGES` (200 by default)

  Automatically uses RPC if the database connection is not in the same node

  Only allowed for private channels
  """
  @spec replay(pid, String.t(), String.t(), non_neg_integer, non_neg_integer) ::
          {:ok, Message.t(), [String.t()]} | {:error, term} | {:error, :rpc_error, term}
  def replay(conn, tenant_id, topic, since, limit)
      when node(conn) == node() and is_integer(since) and is_integer(limit) do
    limit =
      limit
      |> min(Application.fetch_env!(:realtime, :broadcast_replay_max_messages))
      |> max(1)

    with {:ok, since} <- DateTime.from_unix(since, :millisecond),
         {:ok, messages} <- messages(conn, tenant_id, topic, since, limit) do
      {:ok, Enum.reverse(messages), MapSet.new(messages, & &1.id)}
    else
      {:error, :postgrex_exception} -> {:error, :failed_to_replay_messages}
      {:error, :invalid_unix_time} -> {:error, :invalid_replay_params}
      error -> error
    end
  end

  def replay(conn, tenant_id, topic, since, limit) when is_integer(since) and is_integer(limit) do
    Realtime.GenRpc.call(node(conn), __MODULE__, :replay, [conn, tenant_id, topic, since, limit],
      key: topic,
      tenant_id: tenant_id
    )
  end

  def replay(_, _, _, _, _), do: {:error, :invalid_replay_params}

  defp messages(conn, tenant_id, topic, since, limit) do
    query = replay_query(topic, DateTime.to_naive(since), NaiveDateTime.utc_now(), limit)

    {latency, value} =
      :timer.tc(Realtime.Tenants.Repo, :all, [conn, query, Message, [timeout: @default_timeout]], :millisecond)

    :telemetry.execute([:realtime, :broadcast, :replay], %{latency: latency, messages: replayed_count(value)}, %{
      tenant: tenant_id
    })

    value
  end

  defp replayed_count({:ok, messages}), do: length(messages)
  defp replayed_count(_), do: 0

  @doc false
  @spec replay_query(String.t(), NaiveDateTime.t(), NaiveDateTime.t(), pos_integer()) :: Ecto.Query.t()
  def replay_query(topic, since, now, limit) do
    # We want to avoid searching partitions in the future as they should be empty
    # so we limit to 1 minute in the future to account for any potential drift
    now_plus_1m = NaiveDateTime.add(now, 1, :minute)

    # COALESCE matches the messages_replay_index expression, so expired rows are skipped in the index.
    # `is_nil(m.expires_at) or m.expires_at > ^now` can't use the index and reads every expired row.
    from m in Message,
      where:
        m.topic == ^topic and
          m.private == true and
          m.extension == :broadcast and
          m.inserted_at >= ^since and
          m.inserted_at < ^now_plus_1m and
          fragment("COALESCE(?, 'infinity'::timestamp) > ?", m.expires_at, ^now),
      limit: ^limit,
      order_by: [desc: m.inserted_at]
  end

  @doc """
  Deletes messages older than 72 hours for a given tenant connection
  """
  @spec delete_old_messages(pid()) :: :ok
  def delete_old_messages(conn) do
    limit =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-72, :hour)
      |> NaiveDateTime.to_date()

    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT child.relname
        FROM pg_inherits
        JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
        JOIN pg_class child ON pg_inherits.inhrelid = child.oid
        JOIN pg_namespace nmsp_parent ON nmsp_parent.oid = parent.relnamespace
        JOIN pg_namespace nmsp_child ON nmsp_child.oid = child.relnamespace
        WHERE parent.relname = 'messages'
        AND nmsp_child.nspname = 'realtime'
        """,
        []
      )

    rows
    |> Enum.filter(fn ["messages_" <> date] ->
      date |> String.replace("_", "-") |> Date.from_iso8601!() |> Date.compare(limit) == :lt
    end)
    |> Enum.each(&Postgrex.query!(conn, "DROP TABLE IF EXISTS realtime.#{&1}", []))

    :ok
  end
end
