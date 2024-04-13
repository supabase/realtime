defmodule RealtimeWeb.BroadcastControllerTest do
  use RealtimeWeb.ConnCase, async: false

  import Mock

  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias RealtimeWeb.Endpoint

  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE1MTYyMzkwMjIsInJvbGUiOiJmb28iLCJleHAiOiJiYXIifQ.Ret2CevUozCsPhpgW2FMeFL7RooLgoOvfQzNpLBj5ak"

  describe "broadcast" do
    setup %{conn: conn} do
      start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
      start_supervised(Realtime.RateCounter.DynamicSupervisor)
      start_supervised(Realtime.GenCounter.DynamicSupervisor)
      tenant = tenant_fixture()

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{@token}")
        |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})

      {:ok, conn: conn, tenant: tenant}
    end

    test "returns 202 when batch of messages is broadcasted", %{conn: conn, tenant: tenant} do
      events_key = Tenants.events_per_second_key(tenant)

      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end}
      ] do
        sub_topic_1 = "sub_topic_1"
        sub_topic_2 = "sub_topic_2"
        topic_1 = Tenants.tenant_topic(tenant, sub_topic_1)
        topic_2 = Tenants.tenant_topic(tenant, sub_topic_2)

        payload_1 = %{"data" => "data"}
        payload_2 = %{"data" => "data"}
        event_1 = "event_1"
        event_2 = "event_2"

        conn =
          post(conn, Routes.broadcast_path(conn, :broadcast), %{
            "messages" => [
              %{"topic" => sub_topic_1, "payload" => payload_2, "event" => event_1},
              %{"topic" => sub_topic_2, "payload" => payload_2, "event" => event_2}
            ]
          })

        assert_called(
          Endpoint.broadcast_from(:_, topic_1, "broadcast", %{
            "payload" => payload_1,
            "event" => event_1,
            "type" => "broadcast"
          })
        )

        assert_called(
          Endpoint.broadcast_from(
            :_,
            topic_2,
            "broadcast",
            %{"payload" => payload_2, "event" => event_2, "type" => "broadcast"}
          )
        )

        assert_called_exactly(GenCounter.add(events_key), 2)
        assert conn.status == 202
      end
    end

    test "returns 422 when batch of messages includes badly formed messages", %{
      conn: conn,
      tenant: tenant
    } do
      with_mock Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end do
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
                "payload" => %{"data" => "data"},
                "event" => "event"
              }
            ]
          })

        assert Jason.decode!(conn.resp_body) == %{
                 "errors" => %{
                   "messages" => [
                     %{"payload" => ["can't be blank"], "event" => ["can't be blank"]},
                     %{"topic" => ["can't be blank"], "event" => ["can't be blank"]},
                     %{}
                   ]
                 }
               }

        assert_not_called(Endpoint.broadcast_from(:_, :_, :_, :_))

        assert conn.status == 422

        # Wait for counters to increment
        :timer.sleep(1000)
        {:ok, rate_counter} = RateCounter.get(Tenants.requests_per_second_key(tenant))
        assert rate_counter.avg != 0.0

        {:ok, rate_counter} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert rate_counter.avg == 0.0
      end
    end
  end

  describe "too many requests" do
    setup %{conn: conn} do
      start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
      start_supervised(Realtime.RateCounter.DynamicSupervisor)
      start_supervised(Realtime.GenCounter.DynamicSupervisor)

      tenant = tenant_fixture(%{"max_events_per_second" => 1})
      GenCounter.new(Tenants.events_per_second_key(tenant.external_id))

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{@token}")
        |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})

      {:ok, conn: conn, tenant: tenant}
    end

    test "batch will exceed rate limit", %{conn: conn, tenant: tenant} do
      conn =
        post(conn, Routes.broadcast_path(conn, :broadcast), %{
          "messages" =>
            Stream.repeatedly(fn ->
              %{
                "topic" => Tenants.tenant_topic(tenant, "sub_topic"),
                "payload" => %{"data" => "data"},
                "event" => "event"
              }
            end)
            |> Enum.take(10)
        })

      assert conn.status == 429

      assert conn.resp_body ==
               Jason.encode!(%{
                 message: "Too many messages to broadcast, please reduce the batch size"
               })
    end

    test "user has hit the rate limit", %{conn: conn, tenant: tenant} do
      events_key = Tenants.events_per_second_key(tenant)
      requests_key = Tenants.requests_per_second_key(tenant)

      with_mocks [
        {RateCounter, [], new: fn _, _ -> :ok end},
        {RateCounter, [],
         get: fn
           ^requests_key -> {:ok, %RateCounter{avg: 0}}
           ^events_key -> {:ok, %RateCounter{avg: 10}}
         end}
      ] do
        conn =
          post(conn, Routes.broadcast_path(conn, :broadcast), %{
            "messages" => [
              %{
                "topic" => Tenants.tenant_topic(tenant, "sub_topic"),
                "payload" => %{"data" => "data"},
                "event" => "event"
              }
            ]
          })

        assert conn.status == 429

        assert conn.resp_body ==
                 Jason.encode!(%{
                   message: "You have exceeded your rate limit"
                 })
      end
    end
  end

  describe "unauthorized" do
    test "invalid token returns 401", %{conn: conn} do
      tenant = tenant_fixture()

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("x-api-key", "potato")
        |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})

      conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{})
      assert conn.status == 401
    end

    test "invalid tenant returns 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("x-api-key", "potato")
        |> then(&%{&1 | host: "potato.supabase.com"})

      conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{})
      assert conn.status == 401
    end
  end
end
