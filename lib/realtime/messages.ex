defmodule Realtime.Messages do
  import Ecto.Query
  alias Realtime.Repo
  alias Realtime.Api.Message

  @spec delete_old_messages(DBConnection.t()) :: {:ok, any()} | {:error, any()}
  def delete_old_messages(conn) do
    limit = NaiveDateTime.utc_now() |> NaiveDateTime.add(-72, :hour)
    query = from m in Message, where: m.inserted_at <= ^limit
    Repo.del(conn, query)
  end
end
