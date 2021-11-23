defmodule Realtime.RLS.Subscriptions do
  import Ecto.Query, only: [from: 2]

  alias Ecto.{Changeset, Multi}
  alias Realtime.RLS.Repo
  alias Realtime.RLS.Subscriptions.Subscription

  @spec create_topic_subscriber(%{topic: String.t(), user_id: Ecto.UUID.raw(), email: String.t()}) ::
          {:ok, term()} | {:error, term()}
  def create_topic_subscriber(params) do
    Multi.new()
    |> Multi.put(:params_list, [params])
    |> fetch_publication_tables()
    |> enrich_subscription_params()
    |> generate_topic_subscriptions()
    |> insert_topic_subscriptions()
    |> Repo.transaction()
  end

  @spec delete_topic_subscriber(map()) :: {integer(), nil | [term()]}
  def delete_topic_subscriber(%{
        entities: [_ | _] = oids,
        filters: filters,
        user_id: user_id,
        email: email
      }) do
    from(s in Subscription,
      where:
        s.user_id == ^user_id and s.email == ^email and s.filters == ^filters and
          s.entity in ^oids
    )
    |> Repo.delete_all()
  end

  def delete_topic_subscriber(_), do: {0, nil}

  def sync_subscriptions(params_list) do
    Multi.new()
    |> Ecto.Multi.delete_all(:delete_all, Subscription)
    |> Multi.put(:params_list, params_list)
    |> fetch_publication_tables()
    |> enrich_subscription_params()
    |> generate_topic_subscriptions()
    |> insert_topic_subscriptions()
    |> Repo.transaction()
  end

  defp fetch_publication_tables(%Multi{} = multi) do
    Multi.run(multi, :publication_entities, fn _, _ ->
      Repo.query(
        "select
          schemaname,
          tablename,
          format('%I.%I', schemaname, tablename)::regclass as oid
        from pg_publication_tables
        where pubname = $1",
        ["supabase_realtime"]
      )
      |> case do
        {:ok,
         %Postgrex.Result{
           columns: ["schemaname", "tablename", "oid"] = columns,
           num_rows: num_rows,
           rows: rows
         }}
        when num_rows > 0 ->
          publication_entities =
            Enum.reduce(rows, %{}, fn row, acc ->
              [{"schemaname", schema}, {"tablename", table}, {"oid", oid}] =
                Enum.zip(columns, row)

              acc
              |> Map.put({schema, table}, [oid])
              |> Map.update({schema}, [oid], fn oids -> [oid | oids] end)
              |> Map.update({"*"}, [oid], fn oids -> [oid | oids] end)
            end)

          {:ok, publication_entities}

        _ ->
          {:ok, %{}}
      end
    end)
  end

  defp enrich_subscription_params(%Multi{} = multi) do
    Multi.run(multi, :enriched_subscription_params, fn _,
                                                       %{
                                                         params_list: params_list,
                                                         publication_entities: oids
                                                       } ->
      enriched_params =
        case params_list do
          [_ | _] ->
            Enum.reduce(params_list, [], fn %{topic: topic, user_id: user_id, email: email},
                                            acc ->
              topic
              |> String.split(":")
              |> case do
                [schema, table, filters] ->
                  filters
                  |> String.split(~r/(\=|\.)/)
                  |> case do
                    [_, "eq", _] = filters ->
                      [
                        %{
                          entities: Map.get(oids, {schema, table}, []),
                          filters: filters,
                          topic: topic,
                          user_id: user_id,
                          email: email
                        }
                        | acc
                      ]

                    _ ->
                      [
                        %{
                          entities: [],
                          filters: filters,
                          topic: topic,
                          user_id: user_id,
                          email: email
                        }
                        | acc
                      ]
                  end

                [schema, table] ->
                  [
                    %{
                      entities: Map.get(oids, {schema, table}, []),
                      filters: [],
                      topic: topic,
                      user_id: user_id,
                      email: email
                    }
                    | acc
                  ]

                [schema] ->
                  [
                    %{
                      entities: Map.get(oids, {schema}, []),
                      filters: [],
                      topic: topic,
                      user_id: user_id,
                      email: email
                    }
                    | acc
                  ]
              end
            end)

          _ ->
            []
        end

      {:ok, enriched_params}
    end)
  end

  defp generate_topic_subscriptions(%Multi{} = multi) do
    Multi.run(multi, :valid_topic_subscriptions, fn _,
                                                    %{
                                                      enriched_subscription_params:
                                                        enriched_subscription_params
                                                    } ->
      topic_subs =
        case enriched_subscription_params do
          [_ | _] ->
            Enum.reduce(enriched_subscription_params, [], fn %{
                                                               entities: entities,
                                                               filters: filters,
                                                               user_id: user_id,
                                                               email: email
                                                             },
                                                             acc ->
              case entities do
                [_ | _] ->
                  [
                    Enum.reduce(entities, [], fn oid, i_acc ->
                      %Subscription{}
                      |> Subscription.changeset(%{
                        user_id: user_id,
                        email: email,
                        entity: oid,
                        filters: filters
                      })
                      |> case do
                        %Changeset{changes: topic_sub, valid?: true} -> [topic_sub | i_acc]
                        _ -> i_acc
                      end
                    end)
                    | acc
                  ]

                _ ->
                  acc
              end
            end)
            |> List.flatten()

          _ ->
            []
        end

      {:ok, topic_subs}
    end)
  end

  defp insert_topic_subscriptions(%Multi{} = multi) do
    Multi.run(multi, :insert_topic_subscriptions, fn _,
                                                     %{
                                                       valid_topic_subscriptions: valid_subs
                                                     } ->
      total_inserts =
        valid_subs
        |> Enum.uniq()
        |> Enum.chunk_every(20_000)
        |> Enum.reduce(0, fn batch_subs, acc ->
          {inserts, nil} =
            Repo.insert_all(Subscription, batch_subs,
              on_conflict: {:replace_all_except, [:id]},
              conflict_target: [:entity, :user_id, :filters]
            )

          inserts + acc
        end)

      {:ok, {total_inserts, nil}}
    end)
  end
end
