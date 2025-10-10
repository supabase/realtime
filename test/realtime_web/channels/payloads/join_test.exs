defmodule RealtimeWeb.Channels.Payloads.JoinTest do
  use ExUnit.Case, async: true

  import Generators

  alias RealtimeWeb.Channels.Payloads.Join
  alias RealtimeWeb.Channels.Payloads.Config
  alias RealtimeWeb.Channels.Payloads.Broadcast
  alias RealtimeWeb.Channels.Payloads.Broadcast.Replay
  alias RealtimeWeb.Channels.Payloads.Presence
  alias RealtimeWeb.Channels.Payloads.PostgresChange

  describe "validate/1" do
    test "valid payload allows join" do
      key = random_string()
      access_token = random_string()

      config = %{
        "config" => %{
          "private" => false,
          "broadcast" => %{"ack" => false, "self" => false, "replay" => %{"since" => 1, "limit" => 10}},
          "presence" => %{"enabled" => true, "key" => key},
          "postgres_changes" => [
            %{"event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.1"},
            %{"event" => "DELETE", "schema" => "public", "table" => "users", "filter" => "id=eq.2"},
            %{"event" => "UPDATE", "schema" => "public", "table" => "users", "filter" => "id=eq.3"}
          ]
        },
        "access_token" => access_token
      }

      assert {:ok, %Join{config: config, access_token: ^access_token}} = Join.validate(config)

      assert %Config{
               private: false,
               broadcast: broadcast,
               presence: presence,
               postgres_changes: postgres_changes
             } = config

      assert %Broadcast{ack: false, self: false, replay: replay} = broadcast
      assert %Presence{enabled: true, key: ^key} = presence
      assert %Replay{since: 1, limit: 10} = replay

      assert [
               %PostgresChange{event: "INSERT", schema: "public", table: "users", filter: "id=eq.1"},
               %PostgresChange{event: "DELETE", schema: "public", table: "users", filter: "id=eq.2"},
               %PostgresChange{event: "UPDATE", schema: "public", table: "users", filter: "id=eq.3"}
             ] = postgres_changes
    end

    test "presence key as default" do
      config = %{"config" => %{"presence" => %{"enabled" => true}}}

      assert {:ok, %Join{config: %Config{presence: %Presence{key: key}}}} = Join.validate(config)

      assert key != ""
      assert is_binary(key)
    end

    test "presence key can be number" do
      config = %{"config" => %{"presence" => %{"enabled" => true, "key" => 123}}}

      assert {:ok, %Join{config: %Config{presence: %Presence{key: key}}}} = Join.validate(config)

      assert key == 123
    end

    test "invalid replay" do
      config = %{"config" => %{"broadcast" => %{"replay" => 123}}}

      assert {
               :error,
               :invalid_join_payload,
               %{config: %{broadcast: %{replay: ["unable to parse, expected a map"]}}}
             } =
               Join.validate(config)
    end

    test "missing enabled presence defaults to true" do
      config = %{"config" => %{"presence" => %{}}}

      assert {:ok, %Join{config: %Config{presence: %Presence{enabled: true}}}} = Join.validate(config)
    end

    test "invalid payload returns errors" do
      config = %{"config" => ["test"]}

      assert {:error, :invalid_join_payload, %{config: error}} = Join.validate(config)
      assert error == ["unable to parse, expected a map"]
    end

    test "invalid nested configurations returns errors" do
      config = %{
        "config" => %{
          "broadcast" => %{"ack" => "test"},
          "presence" => %{"enabled" => "test"},
          "postgres_changes" => %{"event" => "test"}
        },
        "access_token" => true,
        "user_token" => true
      }

      assert {:error, :invalid_join_payload, errors} = Join.validate(config)

      assert errors == %{
               config: %{
                 broadcast: %{ack: ["unable to parse, expected boolean"]},
                 presence: %{enabled: ["unable to parse, expected boolean"]},
                 postgres_changes: ["unable to parse, expected an array of maps"]
               },
               access_token: ["unable to parse, expected string"],
               user_token: ["unable to parse, expected string"]
             }
    end

    test "handles postgres changes with nil value in array as empty array" do
      config = %{"config" => %{"postgres_changes" => [nil]}}

      assert {:ok, %Join{config: %Config{postgres_changes: []}}} = Join.validate(config)
    end
  end
end
