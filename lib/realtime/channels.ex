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
    {query, args} = Repo.insert_query_from_changeset(channel)

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
         [channel] <- Repo.pg_result_to_struct(res, Channel) do
      channel
    else
      [] -> nil
      _ -> raise "Multiple channels with the same name"
    end
  end
end
