defmodule Realtime.Tenants.BatchBroadcast do
  @moduledoc """
  Virtual schema with a representation of a batched broadcast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    embeds_many :messages, Message do
      field(:topic, :string)
      field(:payload, :map)
    end
  end

  def changeset(payload, attrs) do
    payload
    |> cast(attrs, [])
    |> cast_embed(:messages, required: true, with: &message_changeset/2)
  end

  def message_changeset(message, attrs) do
    message
    |> cast(attrs, [:topic, :payload])
    |> validate_required([:topic, :payload])
  end
end
