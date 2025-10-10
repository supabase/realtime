defmodule RealtimeWeb.Channels.Payloads.Presence do
  @moduledoc """
  Validate presence field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Join

  embedded_schema do
    field :enabled, :boolean, default: true
    field :key, :any, default: UUID.uuid1(), virtual: true
  end

  def changeset(presence, attrs) do
    cast(presence, attrs, [:enabled, :key], message: &Join.error_message/2)
  end
end
