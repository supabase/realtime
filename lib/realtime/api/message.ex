defmodule Realtime.Api.Message do
  @moduledoc """
  Defines the Message schema to be used to check RLS authorization policies
  """
  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "realtime"

  schema "messages" do
    field :uuid, :string, default: Ecto.UUID.generate()
    field :topic, :string
    field :extension, Ecto.Enum, values: [:broadcast, :presence]
    field :payload, :map
    field :event, :string
    field :private, :boolean

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:topic, :extension, :payload, :event, :private])
    |> validate_required([:topic, :extension])
    |> put_timestamp(:updated_at)
    |> maybe_put_timestamp(:inserted_at)
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
