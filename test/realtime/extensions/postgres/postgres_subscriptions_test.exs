defmodule Realtime.Extensions.PostgresSubscriptionsTest do
  use RealtimeWeb.ChannelCase
  alias Extensions.Postgres.Subscriptions

  @oids %{{"public", "some_table"} => [1]}
  @realtime_config %{"schema" => "public", "table" => "some_table"}
  @realtime_config_undef_table %{"schema" => "public", "table" => "some_undef_table"}

  describe "transform_to_oid_view/2" do
    test "existing table", %{} do
      assert [1] =
               @oids
               |> Subscriptions.transform_to_oid_view(@realtime_config)
    end

    test "response with filter", %{} do
      assert [{1, [{"name", "eq", "some_name"}]}] =
               @oids
               |> Subscriptions.transform_to_oid_view(%{
                 "schema" => "public",
                 "table" => "some_table",
                 "filter" => "name=eq.some_name"
               })
    end

    test "non existing table", %{} do
      assert match?(
               nil,
               @oids
               |> Subscriptions.transform_to_oid_view(@realtime_config_undef_table)
             )
    end
  end
end
