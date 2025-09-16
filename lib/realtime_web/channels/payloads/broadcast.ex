defmodule RealtimeWeb.Channels.Payloads.Broadcast do
  @moduledoc """
  Validate broadcast field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Join

  embedded_schema do
    field :ack, :boolean, default: false
    field :self, :boolean, default: false
    embeds_one :replay, RealtimeWeb.Channels.Payloads.Broadcast.Replay
  end

  def changeset(broadcast, attrs) do
    cast(broadcast, attrs, [:ack, :self], message: &Join.error_message/2)
    |> cast_embed(:replay, invalid_message: "unable to parse, expected a map")
  end
end
