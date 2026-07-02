defmodule RealtimeWeb.Channels.Payloads.State do
  @moduledoc """
  Validate the `state` field of the join payload.

  Opts the channel into a session-local, channel-scoped temporary state store backed by a
  PostgreSQL `TEMP TABLE`. See `Realtime.Tenants.TempStateStore`.

  Only honoured on private channels: it opens a dedicated session against the tenant database, so
  enabling it on a public (unauthenticated) channel is ignored to avoid abuse.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Join
  alias RealtimeWeb.Channels.Payloads.FlexibleBoolean

  embedded_schema do
    field :enabled, FlexibleBoolean, default: false
  end

  def changeset(state, attrs) do
    cast(state, attrs, [:enabled], message: &Join.error_message/2)
  end
end
