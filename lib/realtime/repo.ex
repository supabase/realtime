defmodule Realtime.Repo do
  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres

  def with_dynamic_repo(config, callback) do
    default_dynamic_repo = get_dynamic_repo()
    {:ok, repo} = [name: nil, pool_size: 2] |> Keyword.merge(config) |> Realtime.Repo.start_link()

    try do
      Realtime.Repo.put_dynamic_repo(repo)
      callback.(repo)
    after
      Realtime.Repo.put_dynamic_repo(default_dynamic_repo)
      Supervisor.stop(repo)
    end
  end

  @doc """
  Converts a Postgrex.Result into a given struct
  """
  @spec pg_result_to_struct(Postgrex.Result.t(), module()) :: [struct()]
  def pg_result_to_struct(%Postgrex.Result{rows: rows, columns: columns} = res, struct) do
    Enum.map(rows, &Realtime.Repo.load(struct, Enum.zip(columns, &1)))
  end

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

    {"INSERT INTO #{table} #{header} VALUES (#{arg_index})", rows}
  end
end
