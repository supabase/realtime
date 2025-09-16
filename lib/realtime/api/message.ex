defmodule Realtime.Api.Message do
  @moduledoc """
  Defines the Message schema to be used to check RLS authorization policies
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "realtime"

  @type t :: %__MODULE__{}

  schema "messages" do
    field(:topic, :string)
    field(:extension, Ecto.Enum, values: [:broadcast, :presence])
    field(:payload, :map)
    field(:event, :string)
    field(:private, :boolean)

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :topic,
      :extension,
      :payload,
      :event,
      :private,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([:topic, :extension])
    |> put_timestamp(:updated_at)
    |> maybe_put_timestamp(:inserted_at)
  end

  defp put_timestamp(changeset, field) do
    changeset |> put_change(field, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end

  defp maybe_put_timestamp(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_timestamp(changeset, field)
      _ -> changeset
    end
  end
end
