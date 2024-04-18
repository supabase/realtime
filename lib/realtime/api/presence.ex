defmodule Realtime.Api.Presence do
  @moduledoc """
  Defines the Presence schema
  """
  use Ecto.Schema
  import Ecto.Changeset
  @derive {Jason.Encoder, only: [:inserted_at, :updated_at, :id, :channel_id]}

  @type t :: %__MODULE__{}

  @schema_prefix "realtime"
  schema "presences" do
    timestamps()

    belongs_to(:channel, Realtime.Api.Channel)
  end

  def changeset(broadcast, attrs) do
    broadcast
    |> cast(attrs, [:inserted_at, :updated_at, :channel_id])
    |> put_timestamp(:updated_at)
    |> maybe_put_timestamp(:inserted_at)
  end

  def check_changeset(broadcast, attrs) do
    broadcast
    |> change()
    |> put_change(:updated_at, attrs[:updated_at])
  end

  defp put_timestamp(changeset, field) do
    put_change(changeset, field, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end

  defp maybe_put_timestamp(changeset, field) do
    case Map.get(changeset.data, field, nil) do
      nil -> put_timestamp(changeset, field)
      _ -> changeset
    end
  end
end
