defmodule RealtimeWeb.BroadcastControllerTest do
  use RealtimeWeb.ConnCase, async: false

  import Mock
  alias RealtimeWeb.JwtVerification
  alias RealtimeWeb.Endpoint
  setup [:create_tenant]

  setup %{conn: conn, tenant: tenant} do
    new_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )
      |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})

    {:ok, conn: new_conn}
  end

  describe "broadcast" do
    test "returns 202 when batch of messages is broadcasted", %{conn: conn, tenant: tenant} do
      with_mocks [
        {JwtVerification, [], verify: fn _token, _secret -> {:ok, %{}} end},
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end}
      ] do
        sub_topic_1 = "sub_topic"
        sub_topic_2 = "sub_topic"
        topic_1 = tenant.external_id <> ":" <> sub_topic_1
        topic_2 = tenant.external_id <> ":" <> sub_topic_2

        payload_1 = %{"data" => "data"}
        payload_2 = %{"data" => "data"}

        conn =
          post(conn, Routes.broadcast_path(conn, :broadcast), %{
            "messages" => [
              %{
                "topic" => sub_topic_1,
                "payload" => payload_2
              },
              %{
                "topic" => sub_topic_2,
                "payload" => payload_2
              }
            ]
          })

        assert_called(Endpoint.broadcast_from(:_, topic_1, "broadcast", payload_1))
        assert_called(Endpoint.broadcast_from(:_, topic_2, "broadcast", payload_2))

        assert conn.status == 202
      end
    end

    test "returns 422 when batch of messages includes badly formed messages", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn =
          post(conn, Routes.broadcast_path(conn, :broadcast), %{
            "messages" => [
              %{
                "topic" => "topic"
              },
              %{
                "payload" => %{"data" => "data"}
              },
              %{
                "topic" => "topic",
                "payload" => %{"data" => "data"}
              }
            ]
          })

        assert Jason.decode!(conn.resp_body) == %{
                 "errors" => %{
                   "messages" => [
                     %{"payload" => ["can't be blank"]},
                     %{"topic" => ["can't be blank"]},
                     %{}
                   ]
                 }
               }

        assert conn.status == 422
      end
    end
  end

  defp create_tenant(_context) do
    %{tenant: tenant_fixture()}
  end
end
