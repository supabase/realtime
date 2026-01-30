defmodule RealtimeWeb.BroadcastSingleControllerTest do
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants

  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.Endpoint

  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE1MTYyMzkwMjIsInJvbGUiOiJmb28iLCJleHAiOiJiYXIifQ.Ret2CevUozCsPhpgW2FMeFL7RooLgoOvfQzNpLBj5ak"
  @expired_token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MjEwNzMyOTAsImlhdCI6MTYyNzg4NjQ0MCwicm9sZSI6ImFub24ifQ.AHmuaydSU3XAxwoIFhd3gwGwjnBIKsjFil0JQEOLtRw"

  setup %{conn: conn} do
    tenant = Containers.checkout_tenant(run_migrations: true)
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Realtime.Tenants.Cache.update_cache(tenant)

    conn = generate_conn(conn, tenant)

    {:ok, conn: conn, tenant: tenant}
  end

  defp subscribe(tenant_topic, topic) do
    fastlane =
      RealtimeChannel.MessageDispatcher.fastlane_metadata(
        self(),
        Phoenix.Socket.V1.JSONSerializer,
        topic,
        :error,
        "tenant_id"
      )

    Endpoint.subscribe(tenant_topic, metadata: fastlane)
  end

  defp subscribe_v2(tenant_topic, topic) do
    fastlane =
      RealtimeChannel.MessageDispatcher.fastlane_metadata(
        self(),
        RealtimeWeb.Socket.V2Serializer,
        topic,
        :error,
        "tenant_id"
      )

    Endpoint.subscribe(tenant_topic, metadata: fastlane)
  end

  defp assert_receive_message do
    assert_receive {:socket_push, :text, data}

    data
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  describe "JSON broadcast" do
    test "returns 202 when JSON message is broadcasted", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      sub_topic = "room:123"
      event = "message"
      topic = Tenants.tenant_topic(tenant, sub_topic)
      payload = %{"text" => "hello", "user" => "alice"}

      subscribe(topic, sub_topic)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), payload)

      assert conn.status == 202

      message = assert_receive_message()

      assert message == %{
               "event" => "broadcast",
               "payload" => %{
                 "payload" => payload,
                 "event" => event,
                 "type" => "broadcast"
               },
               "ref" => nil,
               "topic" => sub_topic
             }

      refute_receive {:socket_push, _, _}
    end

    test "handles empty JSON payload", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      sub_topic = "room:456"
      event = "empty"
      topic = Tenants.tenant_topic(tenant, sub_topic)

      subscribe(topic, sub_topic)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), %{})

      assert conn.status == 202

      message = assert_receive_message()

      assert message["payload"]["payload"] == %{}
    end

    test "handles topics with colons", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      sub_topic = "room:lobby:main"
      event = "message"
      topic = Tenants.tenant_topic(tenant, sub_topic)

      subscribe(topic, sub_topic)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), %{"data" => "test"})

      assert conn.status == 202
    end

    test "handles private=true query param", %{conn: conn, tenant: tenant} do
      request_events_key = Tenants.requests_per_second_key(tenant)

      # Only expect request counter, not broadcast counter (since it will fail authorization silently)
      expect(GenCounter, :add, fn ^request_events_key -> :ok end)

      sub_topic = "private:room"
      event = "secret"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event) <> "?private=true", %{
          "secret" => "data"
        })

      # Returns 202 even if unauthorized (silently fails)
      assert conn.status == 202
    end

    test "handles private=false query param (default)", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      sub_topic = "public:room"
      event = "message"
      topic = Tenants.tenant_topic(tenant, sub_topic)

      subscribe(topic, sub_topic)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event) <> "?private=false", %{
          "data" => "public"
        })

      assert conn.status == 202
    end

    test "returns 422 when JSON payload exceeds size limit", %{conn: conn, tenant: tenant} do
      request_events_key = Tenants.requests_per_second_key(tenant)

      expect(GenCounter, :add, fn ^request_events_key -> :ok end)

      sub_topic = "room:large"
      event = "message"
      large_payload = %{"data" => String.duplicate("a", tenant.max_payload_size_in_kb * 1024)}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), large_payload)

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["errors"]["payload"] == ["Payload size exceeds tenant limit"]

      {:ok, rate_counter} = RateCounterHelper.tick!(Tenants.events_per_second_rate(tenant))
      assert rate_counter.avg == 0.0
    end

    test "returns 401 when JWT is expired", %{conn: conn, tenant: _tenant} do
      sub_topic = "room:123"
      event = "message"

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@expired_token}")
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), %{"data" => "test"})

      assert conn.status == 401
    end

    test "returns 401 when JWT is missing", %{conn: conn, tenant: _tenant} do
      sub_topic = "room:123"
      event = "message"

      conn =
        conn
        |> delete_req_header("authorization")
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), %{"data" => "test"})

      assert conn.status == 401
    end
  end

  describe "Binary broadcast" do
    test "returns 202 when binary message is broadcasted", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      sub_topic = "binary:room"
      event = "data"
      topic = Tenants.tenant_topic(tenant, sub_topic)
      binary_payload = <<1, 2, 3, 4, 5>>

      # Subscribe with V2Serializer to receive binary messages
      subscribe_v2(topic, sub_topic)

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), binary_payload)

      assert conn.status == 202

      # Assert binary message received with V2Serializer format
      assert_receive {:socket_push, :binary, data}

      # Verify V2 binary format:
      # Header: [type(1), topic_size(1), event_size(1), metadata_size(1), encoding(1)]
      # Body: [topic, event, metadata?, payload]
      topic_size = byte_size(sub_topic)
      event_size = byte_size(event)

      assert data == <<
        # user broadcast type = 4
        4::size(8),
        # sizes
        topic_size::size(8),
        event_size::size(8),
        # metadata_size = 0 (no metadata)
        0::size(8),
        # binary encoding = 0
        0::size(8),
        # topic and event strings
        sub_topic::binary,
        event::binary,
        # binary payload
        binary_payload::binary
      >>
    end

    test "handles empty binary payload", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      sub_topic = "binary:empty"
      event = "empty"

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), <<>>)

      assert conn.status == 202
    end

    test "returns 422 when binary payload exceeds size limit", %{conn: conn, tenant: tenant} do
      request_events_key = Tenants.requests_per_second_key(tenant)

      expect(GenCounter, :add, fn ^request_events_key -> :ok end)

      sub_topic = "binary:large"
      event = "data"
      large_binary = :crypto.strong_rand_bytes(tenant.max_payload_size_in_kb * 1024 + 1)

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), large_binary)

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["errors"]["payload"] == ["Payload size exceeds tenant limit"]

      {:ok, rate_counter} = RateCounterHelper.tick!(Tenants.events_per_second_rate(tenant))
      assert rate_counter.avg == 0.0
    end

    test "returns 401 when JWT is expired for binary", %{conn: conn, tenant: _tenant} do
      sub_topic = "binary:room"
      event = "data"

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@expired_token}")
        |> put_req_header("content-type", "application/octet-stream")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), <<1, 2, 3>>)

      assert conn.status == 401
    end
  end

  describe "Content-Type handling" do
    test "returns 415 for unsupported content type", %{conn: conn, tenant: _tenant} do
      sub_topic = "room:123"
      event = "message"

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), "plain text")

      assert conn.status == 415
      assert Jason.decode!(conn.resp_body)["error"] =~ "Unsupported Media Type"
    end

    test "handles application/json with charset", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      sub_topic = "room:charset"
      event = "message"

      conn =
        conn
        |> put_req_header("content-type", "application/json; charset=utf-8")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), %{"data" => "test"})

      assert conn.status == 202
    end
  end

  describe "Rate limiting" do
    test "returns 429 when rate limit is exceeded", %{conn: conn, tenant: tenant} do
      request_events_key = Tenants.requests_per_second_key(tenant)
      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      expect(GenCounter, :add, fn ^request_events_key -> :ok end)

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn rate ->
        case rate do
          ^events_per_second_rate ->
            {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}}

          _ ->
            {:ok, %RateCounter{avg: 0}}
        end
      end)

      sub_topic = "room:rate-limited"
      event = "message"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), %{"data" => "test"})

      assert conn.status == 429
    end
  end

  describe "URL parameter extraction" do
    test "correctly extracts topic and event from URL", %{conn: conn, tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      request_events_key = Tenants.requests_per_second_key(tenant)

      GenCounter
      |> expect(:add, fn ^request_events_key -> :ok end)
      |> expect(:add, fn ^broadcast_events_key -> :ok end)

      # Test with URL-encoded topic
      sub_topic = "room:test"
      event = "my-event"
      topic = Tenants.tenant_topic(tenant, sub_topic)

      subscribe(topic, sub_topic)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.broadcast_single_path(conn, :broadcast, sub_topic, event), %{"msg" => "test"})

      assert conn.status == 202

      message = assert_receive_message()
      assert message["payload"]["event"] == event
      assert message["topic"] == sub_topic
    end
  end

  defp generate_conn(conn, tenant) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{@token}")
    |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})
  end
end
