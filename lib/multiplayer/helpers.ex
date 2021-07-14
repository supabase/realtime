defmodule Multiplayer.Helpers do
  require Logger
  alias Multiplayer.Api

  def make_fake_data(num) do
    Enum.each(1..num, fn e ->
      str = Integer.to_string(e)
      {:ok, project} = Api.create_project(%{
        name: "project_" <> str,
        external_id: str,
        jwt_secret: "secret_" <> str})
      attrs = Map.put(%{host: "scope_#{str}.multiplayer.red" }, :project_id, project.id)
      {:ok, scope} = Api.create_scope(attrs)
    end)
  end

  def csv2cahce() do
    path = "./priv/static/db.csv"
    |> File.stream!
    |> Stream.map(&String.trim(&1, "\n"))
    |> Stream.map(&String.replace(&1, ~s(\"), ""))
    |> Stream.map(&String.split(&1, ","))
    |> Enum.each(fn [_, host, project_id, _, _] ->
         :ets.insert(:host_cache, {host, project_id})
     end)
  end

end
