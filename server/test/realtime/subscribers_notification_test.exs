defmodule Realtime.SubscribersNotificationTest do
  use ExUnit.Case

  import Mock

  alias Realtime.Adapters.Changes.{NewRecord, Transaction}
  alias Realtime.Adapters.Postgres.Decoder.Messages.Relation
  alias Realtime.Configuration.{Configuration, Webhook, WebhookEndpoint}
  alias Realtime.{ConfigurationManager, SubscribersNotification, WebhookConnector}
  alias Realtime.Replication.State
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
  @relations %{
    123 => %Relation{
      columns: @columns,
      id: 123,
      name: "users",
      namespace: "public",
      replica_identity: :default
    },
    456 => %Relation{
      columns: @columns,
      id: 456,
      name: "auth_users",
      namespace: "auth",
      replica_identity: :default
    }
  }
  @new_record_public {123, "INSERT", {"1", "Thomas Shelby"}, nil}
  @new_record_public_json "{\"columns\":[{\"flags\":[\"key\"],\"name\":\"id\",\"type\":\"int8\",\"type_modifier\":4294967295},{\"flags\":[],\"name\":\"name\",\"type\":\"text\",\"type_modifier\":4294967295}],\"commit_timestamp\":\"2021-02-22T05:22:19Z\",\"record\":{\"id\":\"1\",\"name\":\"Thomas Shelby\"},\"schema\":\"public\",\"table\":\"users\",\"type\":\"INSERT\"}"
  @new_record_auth {456, "INSERT", {"2", "Arthur Shelby"}, nil}
  @new_record_auth_json "{\"columns\":[{\"flags\":[\"key\"],\"name\":\"id\",\"type\":\"int8\",\"type_modifier\":4294967295},{\"flags\":[],\"name\":\"name\",\"type\":\"text\",\"type_modifier\":4294967295}],\"commit_timestamp\":\"2021-02-22T05:22:19Z\",\"record\":{\"id\":\"2\",\"name\":\"Arthur Shelby\"},\"schema\":\"auth\",\"table\":\"auth_users\",\"type\":\"INSERT\"}"
  @default_test_state %State{
    relations: @relations,
    transaction:
      {{0, 0},
       %Transaction{
         changes: [@new_record_public, @new_record_auth],
         commit_timestamp: @commit_timestamp
       }}
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
            handle_realtime_transaction: fn _topic, _type, _change -> :ok end
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
             %State{transaction: {{0, 0}, %Transaction{changes: nil}}}
             |> SubscribersNotification.notify()
  end

  test "notify/1 when transaction changes is an empty list" do
    assert :ok =
             %State{transaction: {{0, 0}, %Transaction{changes: []}}}
             |> SubscribersNotification.notify()
  end

  test "notify/1 when realtime config is an empty list" do
    with_mock ConfigurationManager,
      get_config: fn -> {:ok, %Configuration{realtime: []}} end do
      assert :ok =
               %State{transaction: {{0, 0}, %Transaction{changes: []}}}
               |> SubscribersNotification.notify()

      assert :ok =
               %State{
                 relations: @relations,
                 transaction: {{0, 0}, %Transaction{changes: [@new_record_public]}}
               }
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
      txn = %Transaction{
        changes: [@new_record_public],
        commit_timestamp: @commit_timestamp
      }

      %State{
        relations: @relations,
        transaction: {{0, 0}, txn}
      }
      |> SubscribersNotification.notify()

      assert called(
               WebhookConnector.notify(
                 %Transaction{
                   changes: [
                     %NewRecord{
                       columns: [
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
                       ],
                       commit_timestamp: @commit_timestamp,
                       record: %{"id" => "1", "name" => "Thomas Shelby"},
                       schema: "public",
                       table: "users",
                       type: "INSERT"
                     }
                   ],
                   commit_timestamp: @commit_timestamp
                 },
                 webhooks_config
               )
             )
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
      SubscribersNotification.notify(@default_test_state)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth",
          "INSERT",
          @new_record_auth_json
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 2)
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
      SubscribersNotification.notify(@default_test_state)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:*",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction("realtime:*", "INSERT", @new_record_auth_json)
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth",
          "INSERT",
          @new_record_auth_json
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 4)
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
      SubscribersNotification.notify(@default_test_state)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users",
          "INSERT",
          @new_record_auth_json
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 2)
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
      SubscribersNotification.notify(@default_test_state)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users",
          "INSERT",
          @new_record_auth_json
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 2)
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
      SubscribersNotification.notify(@default_test_state)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users:name=eq.Arthur Shelby",
          "INSERT",
          @new_record_auth_json
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 2)
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
      SubscribersNotification.notify(@default_test_state)

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:id=eq.1",
          "INSERT",
          @new_record_public_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users:name=eq.Arthur Shelby",
          "INSERT",
          @new_record_auth_json
        )
      )

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:auth:auth_users:id=eq.2",
          "INSERT",
          @new_record_auth_json
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 4)
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
      %State{
        relations: @relations,
        transaction:
          {{0, 0},
           %Transaction{
             changes: [{123, "UPDATE", {"1", "Thomas Shelby"}, nil}],
             commit_timestamp: @commit_timestamp
           }}
      }
      |> SubscribersNotification.notify()

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          "UPDATE",
          "{\"columns\":[{\"flags\":[\"key\"],\"name\":\"id\",\"type\":\"int8\",\"type_modifier\":4294967295},{\"flags\":[],\"name\":\"name\",\"type\":\"text\",\"type_modifier\":4294967295}],\"commit_timestamp\":\"2021-02-22T05:22:19Z\",\"old_record\":{},\"record\":{\"id\":\"1\",\"name\":\"Thomas Shelby\"},\"schema\":\"public\",\"table\":\"users\",\"type\":\"UPDATE\"}"
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 1)
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
      %State{
        relations: @relations,
        transaction:
          {{0, 0},
           %Transaction{
             changes: [{123, "DELETE", nil, {"1", "Thomas Shelby"}}],
             commit_timestamp: @commit_timestamp
           }}
      }
      |> SubscribersNotification.notify()

      assert_called(
        RealtimeChannel.handle_realtime_transaction(
          "realtime:public:users:name=eq.Thomas Shelby",
          "DELETE",
          "{\"columns\":[{\"flags\":[\"key\"],\"name\":\"id\",\"type\":\"int8\",\"type_modifier\":4294967295},{\"flags\":[],\"name\":\"name\",\"type\":\"text\",\"type_modifier\":4294967295}],\"commit_timestamp\":\"2021-02-22T05:22:19Z\",\"old_record\":{\"id\":\"1\",\"name\":\"Thomas Shelby\"},\"schema\":\"public\",\"table\":\"users\",\"type\":\"DELETE\"}"
        )
      )

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 1)
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
      %State{
        relations: @relations,
        transaction:
          {{0, 0},
           %Transaction{
             changes: [{123, "TRUNCATE", nil, nil}],
             commit_timestamp: @commit_timestamp
           }}
      }
      |> SubscribersNotification.notify()

      assert_not_called(RealtimeChannel.handle_realtime_transaction(:_, :_, :_))
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

      %State{
        relations: @relations,
        transaction:
          {{0, 0},
           %Transaction{
             changes: [
               {123, "INSERT", {"1", valid_notification_key}, nil},
               {123, "INSERT", {"2", String.duplicate("W", 100)}, nil},
               {123, "INSERT", {"3", nil}, nil},
               {123, "INSERT", {"4", :unchanged_toast}, nil}
             ],
             commit_timestamp: @commit_timestamp
           }}
      }
      |> SubscribersNotification.notify()

      ["realtime:public:users:name=eq.", valid_notification_key]
      |> IO.iodata_to_binary()
      |> RealtimeChannel.handle_realtime_transaction(
        "INSERT",
        "{\"columns\":[{\"flags\":[\"key\"],\"name\":\"id\",\"type\":\"int8\",\"type_modifier\":4294967295},{\"flags\":[],\"name\":\"name\",\"type\":\"text\",\"type_modifier\":4294967295}],\"commit_timestamp\":\"2021-02-22T05:22:19Z\",\"record\":{\"id\":\"1\",\"name\":\"#{
          valid_notification_key
        }\"},\"schema\":\"public\",\"table\":\"users\",\"type\":\"INSERT\"}"
      )
      |> assert_called()

      assert_called_exactly(RealtimeChannel.handle_realtime_transaction(:_, :_, :_), 1)
    end
  end
end
