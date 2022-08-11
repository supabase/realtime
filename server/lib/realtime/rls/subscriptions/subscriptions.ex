defmodule Realtime.RLS.Subscriptions do
  import Ecto.Query, only: [from: 2]

  alias Realtime.RLS.Repo
  alias Realtime.RLS.Subscriptions.Subscription

  @spec create_topic_subscribers(list(%{id: Ecto.UUID.t(), claims: map(), params: map()})) ::
          {:ok, any()}
          | {:error, any()}
          | {:error, Ecto.Multi.name(), any(), %{required(Ecto.Multi.name()) => any()}}
  def create_topic_subscribers(params_list) do
    query = "with sub_tables as (
		    select
			    rr.entity
		    from
			    pg_publication_tables pub,
			    lateral (
				    select
					    format('%I.%I', pub.schemaname, pub.tablename)::regclass entity
			    ) rr
		    where
			    pub.pubname = $1
			  and pub.schemaname like (case $2 when '*' then '%' else $2 end)
			  and pub.tablename like (case $3 when '*' then '%' else $3 end)
	    )
	    insert into realtime.subscription as x(
		    subscription_id,
		    entity,
        filters,
        claims
      )
      select
        $4::text::uuid,
        sub_tables.entity,
        $6,
        $5
      from
        sub_tables
        on conflict
        (subscription_id, entity, filters)
        do update set
        claims = excluded.claims,
        created_at = now()
      returning
         id"

    Repo.transaction(fn ->
      params_list
      |> Enum.map(fn %{
                       id: id,
                       claims: claims,
                       params: params
                     } ->
        with [schema, table, filters] <-
               (case params do
                  %{"schema" => schema, "table" => table, "filter" => filter} ->
                    with [col, rest] <- String.split(filter, "=", parts: 2),
                         [filter_type, value] <- String.split(rest, ".", parts: 2) do
                      [schema, table, [{col, filter_type, value}]]
                    else
                      _ -> []
                    end

                  %{"schema" => schema, "table" => table} ->
                    [schema, table, []]

                  %{"schema" => schema} ->
                    [schema, "*", []]

                  _ ->
                    []
                end) do
          Ecto.Adapters.SQL.query!(
            Repo,
            query,
            [
              Application.get_env(:realtime, :publications) |> Jason.decode!() |> List.first(),
              schema,
              table,
              id,
              claims,
              filters
            ]
          )
        else
          _ -> Repo.rollback("malformed postgres params")
        end
      end)
    end)
  end

  @spec delete_topic_subscriber(Ecto.UUID.t()) :: {integer(), nil | [term()]}
  def delete_topic_subscriber(id) do
    from(s in Subscription,
      where: s.subscription_id == ^id
    )
    |> Repo.delete_all()
  end

  @spec sync_subscriptions(list(%{id: Ecto.UUID.t(), claims: map(), params: map()})) ::
          {:ok, any()}
          | {:error, any()}
          | {:error, Ecto.Multi.name(), any(), %{required(Ecto.Multi.name()) => any()}}
  def sync_subscriptions(params_list) do
    Repo.transaction(fn ->
      Repo.delete_all(Subscription)
      create_topic_subscribers(params_list)
    end)
  end
end
