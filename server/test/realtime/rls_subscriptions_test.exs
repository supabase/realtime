defmodule Realtime.RlsSubscriptionsTest do
  use ExUnit.Case
  alias Realtime.RLS.Subscriptions

  @id "bbb51e4e-f371-4463-bf0a-af8f56dc9a71"
  @claims %{"role" => "authenticated"}

  setup_all do
    start_supervised(Realtime.RLS.Repo)
    :ok
  end

  test "create_topic_subscriber/1" do
    params = %{topic: "topic_test", id: bin_id(), claims: @claims}

    case Subscriptions.create_topic_subscriber(params) do
      {:ok, response} ->
        esp = [Map.merge(params, %{entities: [], filters: [], claims_role: "authenticated"})]

        assert response.enriched_subscription_params == esp
        assert response.params_list == [params]

        entities = [
          {"*"},
          {"public"},
          {"realtime"},
          {"public", "todos"},
          {"realtime", "schema_migrations"},
          {"realtime", "subscription"}
        ]

        Map.keys(response.publication_entities)
        |> Enum.each(fn e ->
          assert Enum.member?(entities, e)
        end)

      other ->
        assert match?({:ok, _}, other)
    end
  end

  defp bin_id() do
    {_, bin} = Ecto.UUID.dump(@id)
    bin
  end
end
