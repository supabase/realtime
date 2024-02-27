defmodule Realtime.Api.Broadcast do
  @moduledoc """
  Defines the Channel schema
  """
  use Ecto.Schema
  import Ecto.Changeset
  @derive {Jason.Encoder, only: [:inserted_at, :updated_at, :id, :channel_id]}

  @type t :: %__MODULE__{}

  @schema_prefix "realtime"
  schema "channels" do
    belongs_to(:channel, Realtime.Api.Channel)
    field(:check, :boolean, default: false)
    timestamps()
  end

  def changeset(broadcast, attrs) do
    broadcast
    |> cast(attrs, [:check, :inserted_at, :updated_at])
    |> put_timestamp(:updated_at)
    |> maybe_put_timestamp(:inserted_at)
  end

  def check_changeset(broadcast, attrs) do
    broadcast
    |> change()
    |> put_change(:check, attrs[:check])
  end

  defp put_timestamp(changeset, field) do
    put_change(changeset, field, DateTime.utc_now() |> DateTime.to_naive())
  end

  defp maybe_put_timestamp(changeset, field) do
    case Map.get(changeset.data, field, nil) do
      nil -> put_timestamp(changeset, field)
      _ -> changeset
    end
  end
end
