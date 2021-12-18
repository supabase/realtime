defmodule Realtime.RLS.Subscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset
  alias Realtime.RLS.Subscriptions.Subscription.Filters

  @schema_prefix "realtime"
  @primary_key {:id, :id, autogenerate: true}

  schema "subscription" do
    field(:subscription_id, Ecto.UUID)
    field(:entity, :integer)
    field(:filters, Filters)
    field(:claims, :map)
    field(:claims_role, :string, virtual: true)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:subscription_id, :entity, :filters, :claims, :claims_role, :created_at])
    |> validate_required([:subscription_id, :entity, :filters, :claims, :claims_role])
    |> validate_claims_map()
    |> delete_change(:claims_role)
  end

  defp validate_claims_map(%Ecto.Changeset{changes: %{claims: %{"role" => _}}} = changeset),
    do: changeset

  defp validate_claims_map(changeset), do: add_error(changeset, :claims, "claims is missing role")
end
