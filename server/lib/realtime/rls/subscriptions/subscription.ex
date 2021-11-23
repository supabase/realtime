defmodule Realtime.RLS.Subscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset
  alias Realtime.RLS.Subscriptions.Subscription.Filters

  @schema_prefix "realtime"
  @primary_key {:id, :id, autogenerate: true}

  schema "subscription" do
    field(:user_id, Ecto.UUID)
    field(:email, :string)
    field(:entity, :integer)
    field(:filters, Filters)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:email, :entity, :user_id, :filters])
    |> validate_required([:email, :entity, :user_id])
  end
end
