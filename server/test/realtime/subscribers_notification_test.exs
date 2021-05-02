defmodule Realtime.SubscribersNotificationTest do
  use ExUnit.Case

  import Mock

  alias Realtime.Adapters.Changes.{
    NewRecord,
    DeletedRecord,
    Transaction,
    TruncatedRelation,
    UpdatedRecord
  }

  alias Realtime.Configuration.{Configuration, Webhook, WebhookEndpoint}
  alias Realtime.{ConfigurationManager, SubscribersNotification, WebhookConnector}
  alias Realtime.Adapters.Postgres.Decoder.Messages.Relation
  alias RealtimeWeb.RealtimeChannel

  @commit_timestamp %DateTime{
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
  }
  @columns [
    %Relation.Column{
      flags: [:key],
      name: "id",
      type: "int8",
      type_modifier: 4_294_967_295
    },
    %Relation.Column{
      flags: [],
      name: "name",
      type: "text",
      type_modifier: 4_294_967_295
    }
  ]
  @new_record_public %NewRecord{
    columns: @columns,
    commit_timestamp: @commit_timestamp,
    record: %{"id" => "1", "name" => "Thomas Shelby"},
    schema: "public",
    table: "users",
    type: "INSERT"
  }
  @new_record_auth %NewRecord{
    columns: @columns,
    commit_timestamp: @commit_timestamp,
    record: %{"id" => "2", "name" => "Arthur Shelby"},
    schema: "auth",
    table: "auth_users",
    type: "INSERT"
  }

  setup do
    get_mocks = fn realtime_config, webhooks_config ->
      [
        {
          ConfigurationManager,
          [],
          [
            get_config: fn ->
              {:ok, %Configuration{realtime: realtime_config, webhooks: webhooks_config}}
            end
          ]
        },
        {
          RealtimeChannel,
          [],
          [
            handle_realtime_transaction: fn _topic, _change -> :ok end
          ]
        },
        {
          WebhookConnector,
          [],
          [
            notify: fn _txn, _config -> :ok end
          ]
        }
      ]
    end

    {:ok, get_mocks: get_mocks}
  end

  test "notify/1 when transaction changes is nil" do
    assert :ok =
             %Transaction{changes: nil}
             |> SubscribersNotification.notify()
  end

  test "notify/1 when transaction changes is an empty list" do
    assert :ok =
             %Transaction{changes: []}
             |> SubscribersNotification.notify()
  end

  test "notify/1 when realtime config is an empty list" do
    with_mock ConfigurationManager,
      get_config: fn -> {:ok, %Configuration{realtime: []}} end do
      assert :ok =
               %Transaction{changes: []}
               |> SubscribersNotification.notify()

      assert :ok =
               %Transaction{changes: [%NewRecord{}]}
               |> SubscribersNotification.notify()
    end
  end

  test "notify/1 calls WebhookConnector.notify/2", %{get_mocks: get_mocks} do
    webhooks_config = [
      %Webhook{
        event: "*",
        relation: "*",
        config: %WebhookEndpoint{endpoint: "https://webhooktest.site"}
      }
    ]

    get_mocks.([], webhooks_config)
    |> with_mocks do
      txn = %Transaction{changes: [%NewRecord{}]}

      SubscribersNotification.notify(txn)

      assert called(WebhookConnector.notify(txn, webhooks_config))
    end
  end

  test "notify/1 broadcasts for schema match - INSERT", %{get_mocks: get_mocks} do
    [
      %Realtime.Configuration.Realtime{
        relation: "auth",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "public",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "public",
        events: ["BAD_EVENT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "bad_schema",
        events: ["INSERT"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      txn = %Transaction{changes: [@new_record_public, @new_record_auth]}

      SubscribersNotification.notify(txn)

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:public", @new_record_public)
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:auth", @new_record_auth)
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 2)
    end
  end

  test "notify/1 broadcasts for schema (*) special case - INSERT", %{get_mocks: get_mocks} do
    [
      %Realtime.Configuration.Realtime{
        relation: "*",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "*",
        events: ["BAD_EVENT"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      txn = %Transaction{changes: [@new_record_public, @new_record_auth]}

      SubscribersNotification.notify(txn)

      assert_called(RealtimeChannel.handle_realtime_transaction("realtime:*", @new_record_public))

      assert_called(RealtimeChannel.handle_realtime_transaction("realtime:*", @new_record_auth))

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:public", @new_record_public)
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:auth", @new_record_auth)
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 4)
    end
  end

  test "notify/1 broadcasts for table match - INSERT", %{get_mocks: get_mocks} do
    [
      %Realtime.Configuration.Realtime{
        relation: "public:users",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "auth:auth_users",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "bad_schema:bad_table",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "auth:auth_users",
        events: ["BAD_EVENT"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      txn = %Transaction{changes: [@new_record_public, @new_record_auth]}

      SubscribersNotification.notify(txn)

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:public:users", @new_record_public)
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:auth:auth_users", @new_record_auth)
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 2)
    end
  end

  test "notify/1 broadcasts for schema (*) and table (*) special case combinations - INSERT", %{
    get_mocks: get_mocks
  } do
    [
      %Realtime.Configuration.Realtime{
        relation: "*:*",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "public:*",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "*:users",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "*:*",
        events: ["BAD_EVENT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "bad_schema:*",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "*:bad_table",
        events: ["INSERT"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      txn = %Transaction{changes: [@new_record_public, @new_record_auth]}

      SubscribersNotification.notify(txn)

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:public:users", @new_record_public)
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:auth:auth_users", @new_record_auth)
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 2)
    end
  end

  test "notify/1 broadcasts for column value match - INSERT", %{get_mocks: get_mocks} do
    [
      %Realtime.Configuration.Realtime{
        relation: "public:users:name",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "auth:auth_users:name",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "public:users:name",
        events: ["BAD_EVENT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "auth:auth_users:name",
        events: ["BAD_EVENT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "public:users:bad_column",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "auth:auth_users:bad_column",
        events: ["INSERT"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      txn = %Transaction{changes: [@new_record_public, @new_record_auth]}

      SubscribersNotification.notify(txn)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          @new_record_public
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users:name=eq.Arthur Shelby",
          @new_record_auth
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 2)
    end
  end

  test "notify/1 broadcasts for schema (*), table (*), and column (*) special cases - INSERT", %{
    get_mocks: get_mocks
  } do
    [
      %Realtime.Configuration.Realtime{
        relation: "*:*:*",
        events: ["INSERT"]
      },
      %Realtime.Configuration.Realtime{
        relation: "*:*:*",
        events: ["BAD_EVENT"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      txn = %Transaction{changes: [@new_record_public, @new_record_auth]}

      SubscribersNotification.notify(txn)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          @new_record_public
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:id=eq.1",
          @new_record_public
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users:name=eq.Arthur Shelby",
          @new_record_auth
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users:id=eq.2",
          @new_record_auth
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 4)
    end
  end

  test "notify/1 broadcasts for column value match - UPDATE", %{get_mocks: get_mocks} do
    [
      %Realtime.Configuration.Realtime{
        relation: "public:users:name",
        events: ["UPDATE"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      record = %UpdatedRecord{
        columns: @columns,
        commit_timestamp: @commit_timestamp,
        record: %{"id" => "1", "name" => "Thomas Shelby"},
        schema: "public",
        table: "users",
        type: "UPDATE"
      }

      txn = %Transaction{changes: [record]}

      SubscribersNotification.notify(txn)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          record
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 1)
    end
  end

  test "notify/1 broadcasts for column value match - DELETE", %{get_mocks: get_mocks} do
    [
      %Realtime.Configuration.Realtime{
        relation: "public:users:name",
        events: ["DELETE"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      old_record = %DeletedRecord{
        columns: @columns,
        commit_timestamp: @commit_timestamp,
        old_record: %{"id" => "1", "name" => "Thomas Shelby"},
        schema: "public",
        table: "users",
        type: "DELETE"
      }

      txn = %Transaction{changes: [old_record]}

      SubscribersNotification.notify(txn)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          old_record
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 1)
    end
  end

  test "notify/1 does not broadcast - TRUNCATE", %{get_mocks: get_mocks} do
    [
      %Realtime.Configuration.Realtime{
        relation: "public:users:name",
        events: ["TRUNCATE"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      truncated_relation = %TruncatedRelation{
        commit_timestamp: @commit_timestamp,
        schema: "public",
        table: "users",
        type: "TRUNCATE"
      }

      txn = %Transaction{changes: [truncated_relation]}

      SubscribersNotification.notify(txn)

      assert_not_called(RealtimeChannel.handle_realtime_transaction(:_, :_))
    end
  end

  test "notify/1 broadcasts for column value match when notification key is valid - INSERT", %{
    get_mocks: get_mocks
  } do
    [
      %Realtime.Configuration.Realtime{
        relation: "public:users:name",
        events: ["INSERT"]
      }
    ]
    |> get_mocks.([])
    |> with_mocks do
      valid_notification_key = String.duplicate("W", 99)

      valid_notification_record = %NewRecord{
        columns: @columns,
        commit_timestamp: @commit_timestamp,
        record: %{"id" => "1", "name" => valid_notification_key},
        schema: "public",
        table: "users",
        type: "INSERT"
      }

      txn = %Transaction{
        changes: [
          valid_notification_record,
          %NewRecord{
            columns: @columns,
            commit_timestamp: @commit_timestamp,
            record: %{"id" => "2", "name" => String.duplicate("W", 100)},
            schema: "public",
            table: "users",
            type: "INSERT"
          },
          %NewRecord{
            columns: @columns,
            commit_timestamp: @commit_timestamp,
            record: %{"id" => "3", "name" => nil},
            schema: "public",
            table: "users",
            type: "INSERT"
          },
          %NewRecord{
            columns: @columns,
            commit_timestamp: @commit_timestamp,
            record: %{"id" => "4", "name" => :unchanged_toast},
            schema: "public",
            table: "users",
            type: "INSERT"
          }
        ]
      }

      SubscribersNotification.notify(txn)

      ["realtime:public:users:name=eq.", valid_notification_key]
      |> IO.iodata_to_binary()
      |> RealtimeChannel.handle_realtime_transaction(valid_notification_record)
      |> assert_called()

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_), 1)
    end
  end
end
