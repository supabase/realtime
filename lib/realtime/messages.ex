defmodule Realtime.Messages do
  @moduledoc """
  Handles `realtime.messages` table operations
  """

  alias Realtime.Api.Message
  alias Realtime.Tenants.Repo

  import Ecto.Query, only: [from: 2]

  @hard_limit 25
  @default_timeout 5_000

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

  @doc """
  Persists a broadcast for `topic`, either sent over WebSocket or through the single broadcast API.

  Only called after the sender's `persistence` policy authorized it, so the persisted row is always private.
  Bypasses RLS because that authorization already happened on the broadcast.

  Check `:persistence` authorization to define if message is persisted,
  but store with `:broadcast` extension, like any other broadcasted message.

  Set `skip_broadcast` because the message was already delivered to the subscribers, so it must not be
  broadcast again when it appears on the replication stream.

  Automatically uses RPC if the database connection is not on the same node.
  """
  @spec persist(
          conn :: DBConnection.conn(),
          tenant_id :: String.t(),
          topic :: String.t(),
          event :: String.t(),
          payload :: map() | binary(),
          expires_at :: NaiveDateTime.t() | nil
        ) :: {:ok, binary()} | {:error, any()} | {:error, :rpc_error, term}
  def persist(conn, tenant_id, topic, event, payload, expires_at \\ nil)

  def persist(conn, _tenant_id, topic, event, payload, expires_at) when node(conn) == node() do
    insert(conn, topic, event, payload, expires_at)
  end

  def persist(conn, tenant_id, topic, event, payload, expires_at) do
    Realtime.GenRpc.call(
      node(conn),
      __MODULE__,
      :persist,
      [conn, tenant_id, topic, event, payload, expires_at],
      key: topic,
      tenant_id: tenant_id
    )
  end

  defp insert(conn, topic, event, payload, expires_at) do
    attrs = %{
      topic: topic,
      extension: :broadcast,
      event: event,
      private: true,
      skip_broadcast: true,
      expires_at: expires_at
    }

    changeset = Message.changeset(%Message{}, Map.merge(attrs, payload_attr(payload)))

    case Repo.insert(conn, changeset, Message) do
      {:ok, %Message{id: id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload_attr(payload) when is_binary(payload), do: %{binary_payload: payload}
  defp payload_attr(payload), do: %{payload: payload}

  @doc """
  Fetch last `limit ` messages for a given `topic` inserted after `since`

  Automatically uses RPC if the database connection is not in the same node

  Only allowed for private channels
  """
  @spec replay(pid, String.t(), String.t(), non_neg_integer, non_neg_integer) ::
          {:ok, Message.t(), [String.t()]} | {:error, term} | {:error, :rpc_error, term}
  def replay(conn, tenant_id, topic, since, limit)
      when node(conn) == node() and is_integer(since) and is_integer(limit) do
    limit = max(min(limit, @hard_limit), 1)

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
    since = DateTime.to_naive(since)
    now = NaiveDateTime.utc_now()

    # We want to avoid searching partitions in the future as they should be empty
    # so we limit to 1 minute in the future to account for any potential drift
    now_plus_1m = NaiveDateTime.utc_now() |> NaiveDateTime.add(1, :minute)

    query =
      from m in Message,
        where:
          m.topic == ^topic and
            m.private == true and
            m.extension == :broadcast and
            m.inserted_at >= ^since and
            m.inserted_at < ^now_plus_1m and
            (is_nil(m.expires_at) or m.expires_at > ^now),
        limit: ^limit,
        order_by: [desc: m.inserted_at]

    {latency, value} =
      :timer.tc(Realtime.Tenants.Repo, :all, [conn, query, Message, [timeout: @default_timeout]], :millisecond)

    :telemetry.execute([:realtime, :tenants, :replay], %{latency: latency}, %{tenant: tenant_id})
    value
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
