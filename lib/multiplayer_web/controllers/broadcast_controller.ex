defmodule MultiplayerWeb.BroadcastController do
  use MultiplayerWeb, :controller
  use PhoenixSwagger
  alias Multiplayer.Api

  swagger_path :post do
    PhoenixSwagger.Path.post "/api/broadcast"
    tag "Broadcast"
    description "Broadcast message to the scope"
    parameters do
      broadcast(:body, Schema.ref(:Broacast), "user attributes", required: true)
    end
    response 200, "No Content - Added Successfully"
    response 400, "When not all required fields"
  end

  @spec post(Plug.Conn.t(), any) :: Plug.Conn.t()
  def post(conn, %{"changes" => changes}) do
    [name] = get_req_header(conn, "multiplayer_project_name")
    case Api.get_project_by_name(name) do
      nil ->
        send_resp(conn, 400, "")
      project ->
        Enum.each(changes, fn event ->
          Phoenix.PubSub.broadcast(
            Multiplayer.PubSub,
            project.id <> ":" <> "realtime:*", #topic,
            {:event, event}
          )
        end)
        send_resp(conn, 200, "")
    end
  end

  def post(conn, _), do: send_resp(conn, 400, "")

  def swagger_definitions do
    %{
      Broacast: swagger_schema do
        title "Broacast"
        description "The messages for broadcasting"
        properties do
          changes    :array, "",  required: true,  example: changes_example()
          project_id :string, "", required: true,  example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19"
          topic      :string, "", required: true,  example: "realtime:*"
          timestamp  :string, "", required: false, example: "2021-06-25T16:50:09Z"
        end
      end
    }
  end

  defp changes_example do
    [%{
      "columns" => [
        %{
          "flags" => ["key"],
          "name" => "id",
          "type" => "int8",
          "type_modifier" => 4294967295
        },
        %{
          "flags" => [],
          "name" => "value",
          "type" => "text",
          "type_modifier" => 4294967295
        },
        %{
          "flags" => [],
          "name" => "value2",
          "type" => "varchar",
          "type_modifier" => 4294967295
        }
      ],
      "commit_timestamp" => "2021-06-25T16:50:09Z",
      "record" => %{"id" => "34199929", "value" => "1", "value2" => nil},
      "schema" => "public",
      "table" => "stress",
      "type" => "INSERT"
    }]
  end

end
