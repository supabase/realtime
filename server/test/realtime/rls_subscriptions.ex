defmodule Realtime.RlsReplicationsTest do
  use ExUnit.Case
  alias Ecto.{Changeset, Multi}
  alias Realtime.RLS.Repo
  import Realtime.RLS.Subscriptions

  @user_id "bbb51e4e-f371-4463-bf0a-af8f56dc9a71"

  setup_all do
    start_supervised(Realtime.RLS.Repo)
    :ok
  end

  test "create_topic_subscriber/1, no existing users" do
    params = %{topic: "topic_test", user_id: bin_user_id()}
    Repo.query("delete from auth.users where id=$1", [bin_user_id()])

    expected =
      {:error, :confirm_user, nil,
       %{
         existing_users: MapSet.new(),
         params_list: [params]
       }}

    assert expected == create_topic_subscriber(params)
  end

  test "create_topic_subscriber/1, user exist" do
    params = %{topic: "topic_test", user_id: bin_user_id()}
    Repo.query("insert into auth.users (id) values ($1)", [bin_user_id()])

    case create_topic_subscriber(params) do
      {:ok, response} ->
        assert response.confirm_user == bin_user_id()

        esp = [Map.merge(params, %{entities: [], filters: []})]

        assert response.enriched_subscription_params == esp
        assert response.existing_users == MapSet.new([bin_user_id()])
        assert response.params_list == [params]

        entities = [
          {"*"},
          {"auth"},
          {"cdc"},
          {"public"},
          {"auth", "audit_log_entries"},
          {"auth", "instances"},
          {"auth", "refresh_tokens"},
          {"auth", "schema_migrations"},
          {"auth", "users"},
          {"cdc", "subscription"},
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
