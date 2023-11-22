defmodule Realtime.Repo do
  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query

  def with_dynamic_repo(config, callback) do
    default_dynamic_repo = get_dynamic_repo()
    {:ok, repo} = [name: nil, pool_size: 2] |> Keyword.merge(config) |> Realtime.Repo.start_link()

    try do
      put_dynamic_repo(repo)
      callback.(repo)
    after
      put_dynamic_repo(default_dynamic_repo)
      Supervisor.stop(repo)
    end
  end

  @doc """
  Lists all records for a given query and converts them into a given struct
  """
  @spec all(DBConnection.conn(), Ecto.Queryable.t(), module()) ::
          {:ok, list(struct())} | {:error, any()}
  def all(conn, query, result_struct) do
    conn
    |> run_all_query(query)
    |> result_to_structs(result_struct)
  end

  @doc """
  Fetches one record for a given query and converts it into a given struct
  """
  @spec one(DBConnection.conn(), Ecto.Query.t(), module()) ::
          {:ok, struct()} | {:ok, nil} | {:error, any()}
  def one(conn, query, result_struct) do
    conn
    |> run_all_query(query)
    |> result_to_single_struct(result_struct)
  end

  @doc """
  Inserts a given changeset into the database and converts the result into a given struct
  """
  @spec insert(DBConnection.conn(), Ecto.Changeset.t(), module()) ::
          {:ok, struct()} | {:error, any()} | Ecto.Changeset.t()
  def insert(conn, changeset, result_struct) do
    with {:ok, {query, args}} <- insert_query_from_changeset(changeset) do
      conn
      |> Postgrex.query(query, args)
      |> result_to_single_struct(result_struct)
    end
  end

  @doc """
  Deletes records for a given query and returns the number of deleted records
  """
  @spec del(DBConnection.conn(), Ecto.Queryable.t()) ::
          {:ok, non_neg_integer()} | {:error, any()}
  def del(conn, query) do
    with {:ok, %Postgrex.Result{num_rows: num_rows}} <- run_delete_query(conn, query) do
      {:ok, num_rows}
    end
  end

  @doc """
  Updates an entry based on the changeset and returns the updated entry
  """
  @spec update(DBConnection.conn(), Ecto.Changeset.t(), module()) ::
          {:ok, struct()} | {:error, any()} | Ecto.Changeset.t()
  def update(conn, changeset, result_struct) do
    with {:ok, {query, args}} <- update_query_from_changeset(changeset) do
      conn
      |> Postgrex.query(query, args)
      |> result_to_single_struct(result_struct)
    end
  end

  defp result_to_single_struct({:error, _} = error, _), do: error

  defp result_to_single_struct({:ok, %Postgrex.Result{rows: []}}, _), do: {:error, :not_found}

  defp result_to_single_struct({:ok, %Postgrex.Result{rows: [row], columns: columns}}, struct) do
    {:ok, load(struct, Enum.zip(columns, row))}
  end

  defp result_to_single_struct({:ok, %Postgrex.Result{num_rows: num_rows}}, _) do
    raise("expected at most one result but got #{num_rows} in result")
  end

  defp result_to_structs({:error, _} = error, _), do: error

  defp result_to_structs({:ok, %Postgrex.Result{rows: rows, columns: columns}}, struct) do
    {:ok, Enum.map(rows, &load(struct, Enum.zip(columns, &1)))}
  end

  defp insert_query_from_changeset(%{valid?: false} = changeset), do: {:error, changeset}

  defp insert_query_from_changeset(changeset) do
    schema = changeset.data.__struct__
    source = schema.__schema__(:source)
    prefix = schema.__schema__(:prefix)
    acc = %{header: [], rows: []}

    %{header: header, rows: rows} =
      Enum.reduce(changeset.changes, acc, fn {field, row}, %{header: header, rows: rows} ->
        %{
          header: [Atom.to_string(field) | header],
          rows: [row | rows]
        }
      end)

    table = "\"#{prefix}\".\"#{source}\""
    header = "(#{header |> Enum.map(&"\"#{&1}\"") |> Enum.join(",")})"

    arg_index =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {_, index} -> "$#{index}" end)
      |> Enum.join(",")

    {:ok, {"INSERT INTO #{table} #{header} VALUES (#{arg_index}) RETURNING *", rows}}
  end

  defp update_query_from_changeset(%{valid?: false} = changeset), do: {:error, changeset}

  defp update_query_from_changeset(changeset) do
    %Ecto.Changeset{data: %{id: id, __struct__: struct}, changes: changes} = changeset
    changes = Keyword.new(changes)
    query = from(c in struct, where: c.id == ^id, select: c, update: [set: ^changes])
    {:ok, to_sql(:update_all, query)}
  end

  defp run_all_query(conn, query) do
    {query, args} = to_sql(:all, query)
    Postgrex.query(conn, query, args)
  end

  defp run_delete_query(conn, query) do
    {query, args} = to_sql(:delete_all, query)
    Postgrex.query(conn, query, args)
  end
end
