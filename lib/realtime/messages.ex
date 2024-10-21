defmodule Realtime.Messages do
  @moduledoc """
  Handles `realtime.messages` table operations
  """
  import Ecto.Query
  alias Realtime.Repo
  alias Realtime.Api.Message

  @doc """
  Deletes messages older than 72 hours for a given tenant connection
  """
  @spec delete_old_messages(pid()) :: {:ok, any()} | {:error, any()}
  def delete_old_messages(conn) do
    limit = NaiveDateTime.utc_now() |> NaiveDateTime.add(-72, :hour)
    query = from m in Message, where: m.inserted_at <= ^limit
    Repo.del(conn, query)
  end
end
