defmodule Realtime.RLS.Subscriptions do
  import Ecto.Query, only: [from: 2]

  alias Ecto.{Changeset, Multi}
  alias Realtime.RLS.Repo
  alias Realtime.RLS.Subscriptions.Subscription

  @spec create_topic_subscriber(%{topic: String.t(), id: Ecto.UUID.raw(), claims: map()}) ::
          {:ok, term()}
          | {:error, term()}
          | {:error, Ecto.Multi.name(), term(), %{required(Ecto.Multi.name()) => term()}}
  def create_topic_subscriber(params) do
    Multi.new()
    |> Multi.put(:params_list, [params])
    |> fetch_database_roles()
    |> fetch_publication_tables()
    |> enrich_subscription_params()
    |> generate_topic_subscriptions()
    |> insert_topic_subscriptions()
    |> Repo.transaction()
  end

  @spec delete_topic_subscriber(map()) :: {integer(), nil | [term()]}
  def delete_topic_subscriber(%{
        id: id,
        entities: [_ | _] = oids,
        filters: filters
      }) do
    from(s in Subscription,
      where: s.subscription_id == ^id and s.entity in ^oids and s.filters == ^filters
    )
    |> Repo.delete_all()
  end

  def delete_topic_subscriber(_), do: {0, nil}

  def sync_subscriptions(params_list) do
    Multi.new()
    |> truncate_subscriptions()
    |> Multi.put(:params_list, params_list)
    |> fetch_database_roles()
    |> fetch_publication_tables()
    |> enrich_subscription_params()
    |> generate_topic_subscriptions()
    |> insert_topic_subscriptions()
    |> Repo.transaction()
  end

  defp fetch_database_roles(%Multi{} = multi) do
    Multi.run(multi, :database_roles, fn _, _ ->
      Repo.query(
        "select rolname from pg_authid",
        []
      )
      |> case do
        {:ok, %Postgrex.Result{columns: ["rolname"], rows: rows}} ->
          {:ok, rows |> List.flatten() |> MapSet.new()}

        _ ->
          {:ok, MapSet.new()}
      end
    end)
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

  defp truncate_subscriptions(%Multi{} = multi) do
    Multi.run(multi, :truncate_subscriptions, fn _, _ ->
      Repo.query(
        "truncate realtime.subscription restart identity",
        []
      )
      |> case do
        {:ok, %Postgrex.Result{command: command}} -> {:ok, command}
        {:error, error} -> {:error, inspect(error)}
      end
    end)
  end

  defp enrich_subscription_params(%Multi{} = multi) do
    Multi.run(multi, :enriched_subscription_params, fn _,
                                                       %{
                                                         database_roles: database_roles,
                                                         params_list: params_list,
                                                         publication_entities: oids
                                                       } ->
      enriched_params =
        case params_list do
          [_ | _] ->
            Enum.reduce(params_list, [], fn %{id: id, claims: claims, topic: topic}, acc ->
              claims_role = claims["role"]

              claims_role =
                if MapSet.member?(database_roles, claims_role) do
                  claims_role
                else
                  nil
                end

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
                          id: id,
                          claims: claims,
                          claims_role: claims_role,
                          entities: Map.get(oids, {schema, table}, []),
                          filters: filters,
                          topic: topic
                        }
                        | acc
                      ]

                    _ ->
                      [
                        %{
                          id: id,
                          claims: claims,
                          claims_role: claims_role,
                          entities: [],
                          filters: filters,
                          topic: topic
                        }
                        | acc
                      ]
                  end

                [schema, table] ->
                  [
                    %{
                      id: id,
                      claims: claims,
                      claims_role: claims_role,
                      entities: Map.get(oids, {schema, table}, []),
                      filters: [],
                      topic: topic
                    }
                    | acc
                  ]

                [schema] ->
                  [
                    %{
                      id: id,
                      claims: claims,
                      claims_role: claims_role,
                      entities: Map.get(oids, {schema}, []),
                      filters: [],
                      topic: topic
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
                                                               id: id,
                                                               claims: claims,
                                                               claims_role: claims_role,
                                                               entities: entities,
                                                               filters: filters
                                                             },
                                                             acc ->
              case entities do
                [_ | _] ->
                  [
                    Enum.reduce(entities, [], fn oid, i_acc ->
                      %Subscription{}
                      |> Subscription.changeset(%{
                        subscription_id: id,
                        entity: oid,
                        filters: filters,
                        claims: claims,
                        claims_role: claims_role
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
              on_conflict: {:replace, [:claims]},
              conflict_target: [:subscription_id, :entity, :filters]
            )

          inserts + acc
        end)

      {:ok, {total_inserts, nil}}
    end)
  end
end
