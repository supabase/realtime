defmodule MultiplayerWeb.BroadcastControllerTest do
  use MultiplayerWeb.ConnCase
  use MultiplayerWeb.ChannelCase
  alias Multiplayer.Api

  @event %{
    "columns" => [
      %{"flags" => ["key"],"name" => "id","type" => "int8","type_modifier" => 4294967295},
      %{"flags" => [],"name" => "value","type" => "text","type_modifier" => 4294967295},
      %{"flags" => [],"name" => "value2","type" => "varchar","type_modifier" => 4294967295}
    ],
    "commit_timestamp" => "2021-06-25T16:50:09Z",
    "record" => %{"id" => "34199929","value" => "1", "value2" => nil},
    "schema" => "public",
    "table" => "stress",
    "type" => "INSERT"
  }
  @req_json %{
    "broadcast" => %{
      "changes" => [@event],
      "project_id" => "",
      "topic" => "realtime:*",
      "commit_timestamp" => "2021-06-25T16:50:09Z"
    }
  }

  test "POST /api/broadcast with params", %{conn: conn} do
    conn = post(conn, "/api/broadcast",  @req_json)
    assert conn.status == 200
  end

  test "POST /api/broadcast no params", %{conn: conn} do
    conn = post(conn, "/api/broadcast")
    assert conn.status == 400
  end

  test "send changes to the channel", %{conn: conn} do
    {:ok, project} = Api.create_project(%{name: "project1", secret: "secret"})
    {:ok, scope} = Api.create_scope(%{host: "localhost", project_id: project.id})
    MultiplayerWeb.UserSocket
      |> socket("user_id", %{scope: project.id, params: %{user_id: "user1"}})
      |> subscribe_and_join(MultiplayerWeb.RealtimeChannel, "realtime:*")

    %{"broadcast" => broadcast} = @req_json
    updated = %{"broadcast" => %{broadcast | "project_id" => project.id}}
    post(conn, "/api/broadcast",  updated)
    assert_push "INSERT", @event
  end

end
