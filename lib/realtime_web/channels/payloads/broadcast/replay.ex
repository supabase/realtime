defmodule RealtimeWeb.Channels.Payloads.Broadcast.Replay do
  @moduledoc """
  Validate broadcast replay field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Join

  embedded_schema do
    field :limit, :integer, default: 10
    field :since, :integer, default: 0
  end

  def changeset(broadcast, attrs) do
    cast(broadcast, attrs, [:limit, :since], message: &Join.error_message/2)
  end
end
