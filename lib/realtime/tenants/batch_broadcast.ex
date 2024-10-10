defmodule Realtime.Tenants.BatchBroadcast do
  @moduledoc """
  Virtual schema with a representation of a batched broadcast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Realtime.Api.Tenant
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.Endpoint

  embedded_schema do
    embeds_many :messages, Message do
      field :event, :string
      field :topic, :string
      field :payload, :map
      field :private, :boolean, default: false
    end
  end

  def broadcast(auth_params, tenant, messages, super_user \\ false)

  def broadcast(%Plug.Conn{} = conn, %Tenant{} = tenant, messages, super_user) do
    auth_params = %{
      headers: conn.req_headers,
      jwt: conn.assigns.jwt,
      claims: conn.assigns.claims,
      role: conn.assigns.role
    }

    broadcast(auth_params, %Tenant{} = tenant, messages, super_user)
  end

  def broadcast(auth_params, %Tenant{} = tenant, messages, super_user) do
    with %Ecto.Changeset{valid?: true} = changeset <- changeset(%__MODULE__{}, messages),
         %Ecto.Changeset{changes: %{messages: messages}} = changeset,
         events_per_second_key = Tenants.events_per_second_key(tenant),
         :ok <- check_rate_limit(events_per_second_key, tenant, length(messages)) do
      events =
        messages
        |> Enum.map(fn %{changes: event} -> event end)
        |> Enum.group_by(fn event -> Map.get(event, :private, false) end)

      # Handle events for public channel
      events
      |> Map.get(false, [])
      |> Enum.each(fn %{topic: sub_topic, payload: payload, event: event} ->
        send_message_and_count(tenant, sub_topic, event, payload, true)
      end)

      # Handle events for private channel
      events
      |> Map.get(true, [])
      |> Enum.group_by(fn event -> Map.get(event, :topic) end)
      |> Enum.each(fn {topic, events} ->
        tenant_db_conn =
          Connect.lookup_or_start_connection(tenant.external_id)

        if super_user do
          Enum.each(events, fn %{topic: sub_topic, payload: payload, event: event} ->
            send_message_and_count(tenant, sub_topic, event, payload, false)
          end)
        else
          case permissions_for_message(auth_params, tenant_db_conn, topic) do
            %Policies{broadcast: %BroadcastPolicies{write: true}} ->
              Enum.each(events, fn %{topic: sub_topic, payload: payload, event: event} ->
                send_message_and_count(tenant, sub_topic, event, payload, false)
              end)

            _ ->
              nil
          end
        end
      end)

      :ok
    end
  end

  def broadcast(_, nil, _, _), do: {:error, :tenant_not_found}

  def changeset(payload, attrs) do
    payload
    |> cast(attrs, [])
    |> cast_embed(:messages, required: true, with: &message_changeset/2)
  end

  def message_changeset(message, attrs) do
    message
    |> cast(attrs, [:topic, :payload, :event, :private])
    |> maybe_put_private_change()
    |> validate_required([:topic, :payload, :event])
  end

  defp maybe_put_private_change(changeset) do
    case get_change(changeset, :private) do
      nil -> put_change(changeset, :private, false)
      _ -> changeset
    end
  end

  defp send_message_and_count(tenant, topic, event, payload, public?) do
    events_per_second_key = Tenants.events_per_second_key(tenant)
    tenant_topic = Tenants.tenant_topic(tenant, topic, public?)
    payload = %{"payload" => payload, "event" => event, "type" => "broadcast"}

    GenCounter.add(events_per_second_key)
    Endpoint.broadcast_from(self(), tenant_topic, "broadcast", payload)
  end

  defp permissions_for_message(_, {:error, _}, _), do: nil
  defp permissions_for_message(nil, _, _), do: nil

  defp permissions_for_message(auth_params, {:ok, db_conn}, topic) do
    with auth_params = Map.put(auth_params, :topic, topic),
         auth_params = Authorization.build_authorization_params(auth_params),
         {:ok, policies} <- Authorization.get_authorizations(db_conn, auth_params) do
      policies
    else
      {:error, :not_found} -> nil
      error -> error
    end
  end

  defp check_rate_limit(events_per_second_key, %Tenant{} = tenant, total_messages_to_broadcast) do
    %{max_events_per_second: max_events_per_second} = tenant
    {:ok, %{avg: events_per_second}} = RateCounter.get(events_per_second_key)

    cond do
      events_per_second > max_events_per_second ->
        {:error, :too_many_requests, "You have exceeded your rate limit"}

      total_messages_to_broadcast + events_per_second > max_events_per_second ->
        {:error, :too_many_requests,
         "Too many messages to broadcast, please reduce the batch size"}

      true ->
        :ok
    end
  end
end
