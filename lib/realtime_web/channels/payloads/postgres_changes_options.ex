defmodule RealtimeWeb.Channels.Payloads.PostgresChangesOptions do
  @moduledoc """
  Validate postgres_changes_options field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.FlexibleBoolean
  alias RealtimeWeb.Channels.Payloads.Join

  @default_timeout :timer.seconds(15)

  embedded_schema do
    field :wait, FlexibleBoolean, default: false
    field :timeout, :integer, default: @default_timeout
  end

  def changeset(postgres_changes_options, attrs) do
    postgres_changes_options
    |> cast(attrs, [:wait, :timeout], message: &Join.error_message/2)
    |> validate_number(:timeout, greater_than: 0)
  end
end
