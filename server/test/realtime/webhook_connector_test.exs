defmodule Realtime.WebhookConnectorTest do
  use ExUnit.Case

  import Mock

  alias Realtime.Adapters.Changes.Transaction
  alias Realtime.Configuration.{Webhook, WebhookEndpoint}
  alias Realtime.Adapters.Postgres.Decoder.Messages.Relation.Column
  alias Realtime.WebhookConnector

  @test_endpoint "https://webhooktest.site"
  @type_modifier 4_294_967_295
  @txn %Transaction{
    changes: [
      %Realtime.Adapters.Changes.NewRecord{
        columns: [
          %Column{
            flags: [:key],
            name: "id",
            type: "int8",
            type_modifier: @type_modifier
          },
          %Column{
            flags: [],
            name: "details",
            type: "text",
            type_modifier: @type_modifier
          },
          %Column{
            flags: [],
            name: "user_id",
            type: "int8",
            type_modifier: @type_modifier
          }
        ],
        commit_timestamp: %DateTime{
          calendar: Calendar.ISO,
          day: 22,
          hour: 05,
          microsecond: {0, 0},
          minute: 22,
          month: 2,
          second: 19,
          std_offset: 0,
          time_zone: "Etc/UTC",
          utc_offset: 0,
          year: 2021,
          zone_abbr: "UTC"
        },
        record: %{
          "details" =>
            "The SCSI system is down, program the haptic microchip so we can back up the SAS circuit!",
          "id" => "14",
          "user_id" => "1"
        },
        schema: "public",
        table: "todos",
        type: "INSERT"
      }
    ]
  }
  @serialized_txn Jason.encode!(@txn)
  @webhooks_config [
    # will match
    %Webhook{
      event: "*",
      relation: "*",
      config: %WebhookEndpoint{endpoint: @test_endpoint}
    },
    # will match
    %Webhook{
      event: "INSERT",
      relation: "public:todos",
      config: %WebhookEndpoint{endpoint: @test_endpoint}
    },
    # won't match
    %Webhook{
      event: "UPDATE",
      relation: "public:todos",
      config: %WebhookEndpoint{endpoint: @test_endpoint}
    },
    # bad endpoint
    %Webhook{
      event: "UPDATE",
      relation: "public:todos",
      config: %WebhookEndpoint{}
    }
  ]
  @request_headers [{"Content-Type", "application/json"}]

  test "notify/1 when webhook POST requests are successful" do
    with_mock HTTPoison,
      post: fn @test_endpoint, @serialized_txn, @request_headers ->
        {:ok, %{status_code: 200}}
      end do
      assert :ok = WebhookConnector.notify(@txn, @webhooks_config)

      assert_called_exactly(
        HTTPoison.post(@test_endpoint, @serialized_txn, @request_headers),
        2
      )
    end
  end

  test "notify/1 when webhook POST requests return non success status codes" do
    with_mock HTTPoison,
      post: fn @test_endpoint, @serialized_txn, @request_headers ->
        {:ok, %{status_code: 500}}
      end do
      assert :ok = WebhookConnector.notify(@txn, @webhooks_config)

      assert_called_exactly(
        HTTPoison.post(@test_endpoint, @serialized_txn, @request_headers),
        2
      )
    end
  end

  test "notify/1 when webhook POST requests fail" do
    with_mock HTTPoison,
      post: fn @test_endpoint, @serialized_txn, @request_headers ->
        {:error, %HTTPoison.Error{id: nil, reason: :econnrefused}}
      end do
      assert :ok = WebhookConnector.notify(@txn, @webhooks_config)

      assert_called_exactly(
        HTTPoison.post(@test_endpoint, @serialized_txn, @request_headers),
        2
      )
    end
  end

  test "notify/1 when webhook POST requests take longer than Task.yield_many/2 timeout" do
    with_mock HTTPoison,
      post: fn @test_endpoint, @serialized_txn, @request_headers ->
        # Task.yield_many/2 timeout set to default 5_000 (@timestamp) in Realtime.WebhookConnector
        :timer.sleep(6_000)
        {:ok, %{status_code: 200}}
      end do
      assert :ok = WebhookConnector.notify(@txn, @webhooks_config)

      assert_not_called(HTTPoison.post(@test_endpoint, @serialized_txn, @request_headers))
    end
  end

  test "notify/1 when webhook POST request Tasks return exit" do
    # find a good way to test this
  end
end
