defmodule Realtime.RlsSubscriptionsTest do
  use ExUnit.Case
  alias Realtime.RLS.Subscriptions

  @user_id "bbb51e4e-f371-4463-bf0a-af8f56dc9a71"
  @user_email "user@test.com"

  setup_all do
    start_supervised(Realtime.RLS.Repo)
    :ok
  end

  test "create_topic_subscriber/1" do
    params = %{topic: "topic_test", user_id: bin_user_id(), email: @user_email}

    case Subscriptions.create_topic_subscriber(params) do
      {:ok, response} ->
        esp = [Map.merge(params, %{entities: [], filters: []})]

        assert response.enriched_subscription_params == esp
        assert response.params_list == [params]

        entities = [
          {"*"},
          {"auth"},
          {"realtime"},
          {"public"},
          {"auth", "audit_log_entries"},
          {"auth", "instances"},
          {"auth", "refresh_tokens"},
          {"auth", "schema_migrations"},
          {"auth", "users"},
          {"realtime", "subscription"},
          {"public", "todos"}
        ]

        Map.keys(response.publication_entities)
        |> Enum.each(fn e ->
          assert Enum.member?(entities, e)
        end)

      other ->
        assert match?({:ok, _}, other)
    end
  end

  defp bin_user_id() do
    {_, bin} = Ecto.UUID.dump(@user_id)
    bin
  end
end
