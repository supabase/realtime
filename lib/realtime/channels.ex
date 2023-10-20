defmodule Realtime.Channels do
  @moduledoc """
  Handles Channel related operations
  """

  alias Realtime.Api.Channel
  alias Realtime.Repo

  import Ecto.Query

  @doc """
  Creates a channel in the tenant database using a given DBConnection
  """
  @spec create_channel(map(), DBConnection.t()) :: :ok
  def create_channel(attrs, db_conection) do
    channel = Channel.changeset(%Channel{}, attrs)
    {query, args} = insert_query(channel)

    Postgrex.query!(db_conection, query, args)
    :ok
  end

  @doc """
  Fetches a channel by name from the tenant database using a given DBConnection
  """
  @spec get_channel_by_name(DBConnection.t(), String.t()) :: Channel.t() | nil
  def get_channel_by_name(db_conection, name) do
    query = from c in Channel, where: c.name == ^name
    {query, args} = Repo.to_sql(:all, query)

    with res <- Postgrex.query!(db_conection, query, args),
         [channel] <- pg_result_to_struct(res, Channel) do
      channel
    else
      [] -> nil
      _ -> raise "Multiple channels with the same name"
    end
  end

  # TODO Maybe move this to Repo module
  defp pg_result_to_struct(%Postgrex.Result{rows: rows, columns: columns}, struct) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()
      |> then(&struct(struct, &1))
    end)
  end

  # TODO Maybe move this to Repo module
  defp insert_query(changeset) do
    schema = changeset.data.__struct__
    source = schema.__schema__(:source)
    prefix = schema.__schema__(:prefix)

    %{header: header, rows: rows} =
      Enum.reduce(changeset.changes, %{header: [], rows: []}, fn {field, row},
                                                                 %{header: header, rows: rows} ->
        %{header: [Atom.to_string(field) | header], rows: [row | rows]}
      end)

    table = "#{prefix}.#{source}"
    header = "(#{Enum.join(header, ",")})"

    arg_index =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {_, index} -> "$#{index}" end)
      |> Enum.join(",")

    {"INSERT INTO #{table} #{header} VALUES (#{arg_index})", rows}
  end
end
