defmodule Realtime.Repo.Migrations.EncryptJwtSecretEncrypted do
  use Ecto.Migration
  import Ecto.Query
  import Ecto.Changeset
  alias Realtime.{Repo, Api.Tenant, Api.Extensions}
  import Realtime.Helpers, only: [encrypt!: 2]

  def change do
    secure_key = System.get_env("DB_ENC_KEY")

    Repo.transaction(fn ->
      from(t in Realtime.Api.Tenant, select: t)
      |> Realtime.Repo.all()
      |> Enum.each(fn e ->
        %{
          Realtime.Api.Tenant.changeset(e, %{})
          | action: :update,
            changes: %{jwt_secret: encrypt!(e.jwt_secret, secure_key)}
        }
        |> Realtime.Repo.update()
      end)
      |> case do
        {:error, reason} ->
          raise(reason)

        _ ->
          :ok
      end
    end)
  end
end
