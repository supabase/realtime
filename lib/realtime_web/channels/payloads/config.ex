defmodule RealtimeWeb.Channels.Payloads.Config do
  @moduledoc """
  Validate config field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Join
  alias RealtimeWeb.Channels.Payloads.Broadcast
  alias RealtimeWeb.Channels.Payloads.Presence
  alias RealtimeWeb.Channels.Payloads.PostgresChange

  embedded_schema do
    embeds_one :broadcast, Broadcast
    embeds_one :presence, Presence
    embeds_many :postgres_changes, PostgresChange
    field :private, :boolean, default: false
  end

  def changeset(config, attrs) do
    attrs =
      attrs
      |> Enum.map(fn
        {k, v} when is_list(v) -> {k, Enum.filter(v, fn v -> v != nil end)}
        {k, v} -> {k, v}
      end)
      |> Map.new()

    config
    |> cast(attrs, [:private], message: &Join.error_message/2)
    |> cast_embed(:broadcast, invalid_message: "unable to parse, expected a map")
    |> cast_embed(:presence, invalid_message: "unable to parse, expected a map")
    |> cast_embed(:postgres_changes, invalid_message: "unable to parse, expected an array of maps")
  end
end
