defmodule Realtime.Messages do
  @moduledoc """
  Handles `realtime.messages` table operations
  """

  alias Realtime.Api.Message

  import Ecto.Query, only: [from: 2]

  @hard_limit 25

  @doc """
  Fetch last `limit ` messages for a given `topic` inserted after `since`

  Automatically uses RPC if the database connection is not in the same node
  """
  @spec replay(pid, String.t(), boolean, non_neg_integer, non_neg_integer) ::
          {:ok, Message.t(), [String.t()]} | {:error, term} | {:error, :rpc_error, term}
  def replay(conn, topic, private?, since, limit)
      when node(conn) == node() and is_boolean(private?) and is_integer(since) and is_integer(limit) do
    limit = max(min(limit, @hard_limit), 1)

    since =
      DateTime.from_unix!(since, :millisecond)
      |> DateTime.to_naive()

    # FIXME need an index for this query
    query =
      from m in Message,
        where: m.topic == ^topic and m.private == ^private? and m.inserted_at >= ^since and m.extension == :broadcast,
        limit: ^limit,
        order_by: [desc: m.inserted_at]

    with {:ok, messages} <- Realtime.Repo.all(conn, query, Message) do
      {:ok, Enum.reverse(messages), MapSet.new(messages, & &1.id)}
    else
      {:error, :postgrex_exception} -> {:error, :failed_to_replay_messages}
      error -> error
    end
  end

  def replay(conn, topic, private?, since, limit) when is_integer(since) and is_integer(limit) do
    Realtime.GenRpc.call(node(conn), __MODULE__, :replay, [conn, topic, private?, since, limit], key: topic)
  end

  def replay(_, _, _, _, _), do: {:error, :invalid_replay_params}

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
