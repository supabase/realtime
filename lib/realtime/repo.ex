defmodule Realtime.Repo do
  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres

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
  Converts a Postgrex.Result into a given struct
  """
  @spec result_to_single_struct({:ok, Postgrex.Result.t()} | {:error, any()}, module()) ::
          {:ok, struct()} | {:ok, nil} | {:error, any()}
  def result_to_single_struct({:ok, %Postgrex.Result{rows: [row], columns: columns}}, struct) do
    {:ok, Realtime.Repo.load(struct, Enum.zip(columns, row))}
  end

  def result_to_single_struct({:ok, %Postgrex.Result{rows: []}}, _),
    do: {:ok, nil}

  def result_to_single_struct({:ok, %Postgrex.Result{rows: rows}}, _),
    do: raise("expected at most one result but got #{length(rows)} in result")

  def result_to_single_struct({:error, _} = error, _), do: error

  @doc """
  Converts a Postgrex.Result into a given struct
  """
  @spec result_to_structs({:ok, Postgrex.Result.t()} | {:error, any()}, module()) ::
          {:ok, list(struct())} | {:error, any()}
  def result_to_structs({:ok, %Postgrex.Result{rows: rows, columns: columns}}, struct) do
    {:ok, Enum.map(rows, &Realtime.Repo.load(struct, Enum.zip(columns, &1)))}
  end

  def result_to_structs({:error, _} = error, _), do: error

  @doc """
  Creates an insert query from a given changeset
  """
  @spec insert_query_from_changeset(Ecto.Changeset.t()) :: {String.t(), [any()]}
  def insert_query_from_changeset(changeset) do
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

    {"INSERT INTO #{table} #{header} VALUES (#{arg_index}) RETURNING *", rows}
  end

  defp run_all_query(conn, query) do
    {query, args} = __MODULE__.to_sql(:all, query)
    Postgrex.query(conn, query, args)
  end
end
