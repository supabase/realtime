defmodule Realtime.Api.Channel do
  @moduledoc """
  Defines the Channel schema
  """
  use Ecto.Schema
  import Ecto.Changeset
  @derive {Jason.Encoder, only: [:name, :inserted_at, :updated_at, :id]}

  @type t :: %__MODULE__{}

  @schema_prefix "realtime"
  schema "channels" do
    field(:name, :string)
    timestamps()
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :inserted_at, :updated_at])
    |> validate_required([:name])
    |> put_timestamp(:updated_at)
    |> maybe_put_timestamp(:inserted_at)
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
