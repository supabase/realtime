defmodule Realtime.Messages do
  @moduledoc """
  Handles `realtime.messages` table operations
  """

  alias Realtime.Api.Message

  import Ecto.Query, only: [from: 2]

  @hard_limit 25
  @default_timeout 5_000

  @doc """
  Fetch last `limit ` messages for a given `topic` inserted after `since`

  Automatically uses RPC if the database connection is not in the same node

  Only allowed for private channels
  """
  @spec replay(pid, String.t(), non_neg_integer, non_neg_integer) ::
          {:ok, Message.t(), [String.t()]} | {:error, term} | {:error, :rpc_error, term}
  def replay(conn, topic, since, limit) when node(conn) == node() and is_integer(since) and is_integer(limit) do
    limit = max(min(limit, @hard_limit), 1)

    with {:ok, since} <- DateTime.from_unix(since, :millisecond),
         {:ok, messages} <- messages(conn, topic, since, limit) do
      {:ok, Enum.reverse(messages), MapSet.new(messages, & &1.id)}
    else
      {:error, :postgrex_exception} -> {:error, :failed_to_replay_messages}
      {:error, :invalid_unix_time} -> {:error, :invalid_replay_params}
      error -> error
    end
  end

  def replay(conn, topic, since, limit) when is_integer(since) and is_integer(limit) do
    Realtime.GenRpc.call(node(conn), __MODULE__, :replay, [conn, topic, since, limit], key: topic)
  end

  def replay(_, _, _, _), do: {:error, :invalid_replay_params}

  defp messages(conn, topic, since, limit) do
    since = DateTime.to_naive(since)
    # We want to avoid searching partitions in the future as they should be empty
    # so we limit to 1 minute in the future to account for any potential drift
    now = NaiveDateTime.utc_now() |> NaiveDateTime.add(1, :minute)

    query =
      from m in Message,
        where:
          m.topic == ^topic and
            m.private == true and
            m.extension == :broadcast and
            m.inserted_at >= ^since and
            m.inserted_at < ^now,
        limit: ^limit,
        order_by: [desc: m.inserted_at]

    Realtime.Repo.all(conn, query, Message, timeout: @default_timeout)
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
