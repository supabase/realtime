defmodule MultiplayerWeb.BroadcastControllerTest do
  use MultiplayerWeb.ConnCase
  use MultiplayerWeb.ChannelCase
  alias Multiplayer.Api

  @event %{
    "columns" => [
      %{"flags" => ["key"], "name" => "id", "type" => "int8", "type_modifier" => 4_294_967_295},
      %{"flags" => [], "name" => "value", "type" => "text", "type_modifier" => 4_294_967_295},
      %{"flags" => [], "name" => "value2", "type" => "varchar", "type_modifier" => 4_294_967_295}
    ],
    "commit_timestamp" => "2021-06-25T16:50:09Z",
    "record" => %{"id" => "34199929", "value" => "1", "value2" => nil},
    "schema" => "public",
    "table" => "stress",
    "type" => "INSERT"
  }
  @req_json %{
    "changes" => [@event],
    "commit_timestamp" => "2021-06-25T16:50:09Z"
  }

  test "POST /api/broadcast with params", %{conn: conn} do
    {:ok, _project} = Api.create_project(%{name: "test_name", secret: "test_secret"})

    conn =
      conn
      |> put_req_header("multiplayer-project-name", "test_name")

    conn = post(conn, "/api/broadcast", @req_json)
    assert conn.status == 200
  end

  test "POST /api/broadcast no params", %{conn: conn} do
    conn = post(conn, "/api/broadcast")
    assert conn.status == 400
  end

  test "send changes to the channel", %{conn: conn} do
    {:ok, project} = Api.create_project(%{name: "test_name", secret: "test_secret"})
    {:ok, scope} = Api.create_scope(%{host: "localhost", project_id: project.id})

    MultiplayerWeb.UserSocket
    |> socket("user_id", %{scope: project.id, params: %{user_id: "user1"}})
    |> subscribe_and_join(MultiplayerWeb.RealtimeChannel, "realtime:*")

    conn =
      conn
      |> put_req_header("multiplayer-project-name", "test_name")

    post(conn, "/api/broadcast", @req_json)
    assert_push "INSERT", @event
  end
end
