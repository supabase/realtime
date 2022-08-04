defmodule Realtime.Repo.Migrations.EncryptJwtSecret do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Realtime.{Repo, Api.Tenant}

  @batch_size 5_000

  def change do
    stream =
      from(t in Tenant,
        select: t
      )
      |> Repo.stream(max_rows: @batch_size)

    Repo.transaction(fn ->
      stream
      |> Stream.map(fn %Tenant{jwt_secret: jwt_secret} = tenant ->
        tenant
        |> Map.drop([:jwt_secret])
        |> Tenant.changeset(%{jwt_secret: jwt_secret})
        |> case do
          %Changeset{changes: changes, data: data, valid?: true} ->
            data
            |> Map.take([
              :external_id,
              :id,
              :inserted_at,
              :jwt_secret,
              :max_concurrent_users,
              :max_events_per_second,
              :name,
              :updated_at
            ])
            |> Map.put(:updated_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
            |> Map.merge(changes)

          changeset ->
            Repo.rollback(changeset)
        end
      end)
      |> Stream.chunk_every(@batch_size)
      |> Stream.each(
        &Repo.insert_all(Tenant, &1,
          conflict_target: [:id],
          on_conflict: {:replace, [:jwt_secret, :updated_at]}
        )
      )
      |> Enum.to_list()
    end)
    |> case do
      {:error, reason} -> reason |> inspect() |> raise()
      {:error, _, reason, _} -> reason |> inspect() |> raise()
      {:ok, _} -> :ok
    end
  end
end
