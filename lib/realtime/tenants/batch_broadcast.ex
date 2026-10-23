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

  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.RequestMetrics
  alias RealtimeWeb.TenantBroadcaster

  @payload_size_exceeded_error "Payload size exceeds tenant limit"

  embedded_schema do
    embeds_many :messages, Message do
      field :event, :string
      field :topic, :string
      field :payload, :map
      field :private, :boolean, default: false
    end
  end

  @spec broadcast(
          auth_params :: map() | nil,
          tenant :: Tenant.t(),
          messages :: %{
            messages: list(%{id: String.t(), topic: String.t(), payload: map(), event: String.t(), private: boolean()})
          },
          super_user :: boolean()
        ) :: :ok | {:error, atom() | Ecto.Changeset.t()}
  def broadcast(auth_params, tenant, messages, super_user \\ false)

  def broadcast(%Plug.Conn{} = conn, %Tenant{} = tenant, messages, super_user) do
    auth_params = %{
      tenant_id: tenant.external_id,
      headers: conn.req_headers,
      claims: conn.assigns.claims,
      role: conn.assigns.role,
      sub: conn.assigns.sub
    }

    broadcast(auth_params, %Tenant{} = tenant, messages, super_user)
  end

  def broadcast(_auth_params, %Tenant{suspend: true} = tenant, messages, _super_user) do
    record_outcome_per_message(tenant, messages, :tenant_suspended)
    {:error, :forbidden, "Tenant is suspended"}
  end

  def broadcast(auth_params, %Tenant{} = tenant, messages, super_user) do
    with %Ecto.Changeset{valid?: true} = changeset <- changeset(%__MODULE__{}, messages, tenant),
         %Ecto.Changeset{changes: %{messages: messages}} = changeset,
         events_per_second_rate = Tenants.events_per_second_rate(tenant),
         :ok <- check_rate_limit(events_per_second_rate, tenant, length(messages)) do
      events =
        messages
        |> Enum.map(fn %{changes: event} -> event end)
        |> Enum.group_by(fn event -> Map.get(event, :private, false) end)

      # Handle events for public channel
      events
      |> Map.get(false, [])
      |> Enum.each(fn message ->
        send_message_and_count(tenant, events_per_second_rate, message, true)
      end)

      # Handle events for private channel
      events
      |> Map.get(true, [])
      |> Enum.group_by(fn event -> Map.get(event, :topic) end)
      |> Enum.each(fn {topic, events} ->
        if super_user do
          Enum.each(events, fn message -> send_message_and_count(tenant, events_per_second_rate, message, false) end)
        else
          case permissions_for_message(tenant, auth_params, topic) do
            %Policies{broadcast: %BroadcastPolicies{write: true}} ->
              Enum.each(events, fn message -> send_message_and_count(tenant, events_per_second_rate, message, false) end)

            %Policies{broadcast: %BroadcastPolicies{}} ->
              record_outcome_per_message(tenant, events, :unauthorized)

            {:error, :tenant_database_unavailable} ->
              record_outcome_per_message(tenant, events, :unable_to_connect_to_project)

            {:error, init_error} when init_error in [:initializing, :tenant_database_connection_initializing] ->
              record_outcome_per_message(tenant, events, :initializing_project_connection)

            {:error, :tenant_db_too_many_connections} ->
              record_outcome_per_message(tenant, events, :database_lack_of_connections)

            {:error, :connect_rate_limit_reached} ->
              record_outcome_per_message(tenant, events, :database_connection_rate_limit_reached)

            {:error, :rpc_error, _} ->
              record_outcome_per_message(tenant, events, :unable_to_handle_broadcast)

            {:error, :rls_policy_error, _} ->
              record_outcome_per_message(tenant, events, :rls_policy_error)

            {:error, :query_canceled, _} ->
              record_outcome_per_message(tenant, events, :query_canceled)

            {:error, :increase_connection_pool} ->
              record_outcome_per_message(tenant, events, :increase_connection_pool)

            {:error, :missing_partition} ->
              record_outcome_per_message(tenant, events, :missing_partition)

            {:error, _} ->
              record_outcome_per_message(tenant, events, :unable_to_set_policies)

            _ ->
              nil
          end
        end
      end)

      :ok
    else
      %Ecto.Changeset{valid?: false} = changeset ->
        record_outcome_per_message(tenant, messages, changeset)
        {:error, changeset}

      {:error, :too_many_requests, _} = error ->
        record_outcome_per_message(tenant, messages, :rate_limit_exceeded)
        error
    end
  end

  def broadcast(_, nil, _, _), do: {:error, :tenant_not_found}

  defp changeset(payload, attrs, tenant) do
    payload
    |> cast(attrs, [])
    |> cast_embed(:messages, required: true, with: fn message, attrs -> message_changeset(message, tenant, attrs) end)
  end

  defp message_changeset(message, tenant, attrs) do
    message
    |> cast(attrs, [:id, :topic, :payload, :event, :private])
    |> maybe_put_private_change()
    |> validate_required([:topic, :payload, :event])
    |> validate_payload_size(tenant)
  end

  defp maybe_put_private_change(changeset) do
    case get_change(changeset, :private) do
      nil -> put_change(changeset, :private, false)
      _ -> changeset
    end
  end

  defp validate_payload_size(changeset, tenant) do
    payload = get_change(changeset, :payload)

    case Tenants.validate_payload_size(tenant, payload) do
      :ok -> changeset
      _ -> add_error(changeset, :payload, @payload_size_exceeded_error)
    end
  end

  @event_type "broadcast"
  defp send_message_and_count(tenant, events_per_second_rate, message, public?) do
    tenant_topic = Tenants.tenant_topic(tenant, message.topic, public?)

    payload = %{"payload" => message.payload, "event" => message.event, "type" => "broadcast"}

    payload =
      if message[:id],
        do: Map.put(payload, "meta", %{"id" => message.id}),
        else: payload

    broadcast = %Phoenix.Socket.Broadcast{topic: message.topic, event: @event_type, payload: payload}

    GenCounter.add(events_per_second_rate.id)

    TenantBroadcaster.pubsub_broadcast(
      tenant.external_id,
      tenant_topic,
      broadcast,
      RealtimeChannel.MessageDispatcher,
      :broadcast
    )

    record_outcome(tenant, :success)
  end

  defp permissions_for_message(_, nil, _), do: nil

  defp permissions_for_message(tenant, auth_params, topic) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id) do
      auth_params =
        auth_params
        |> Map.put(:topic, topic)
        |> Authorization.build_authorization_params()

      case Authorization.get_write_authorizations(db_conn, auth_params, :broadcast) do
        {:ok, policies} -> policies
        {:error, :not_found} -> nil
        error -> error
      end
    end
  end

  defp check_rate_limit(events_per_second_rate, %Tenant{} = tenant, total_messages_to_broadcast) do
    %{max_events_per_second: max_events_per_second} = tenant
    {:ok, %{avg: events_per_second}} = RateCounter.get(events_per_second_rate)

    cond do
      events_per_second > max_events_per_second ->
        {:error, :too_many_requests, "You have exceeded your rate limit"}

      total_messages_to_broadcast + events_per_second > max_events_per_second ->
        {:error, :too_many_requests, "Too many messages to broadcast, please reduce the batch size"}

      true ->
        :ok
    end
  end

  defp record_outcome(tenant, :success) do
    RequestMetrics.record(:broadcast, :http, tenant.external_id, :success)
  end

  defp record_outcome(tenant, error_code) do
    RequestMetrics.record(:broadcast, :http, tenant.external_id, RequestMetrics.classify_broadcast_error(error_code))
  end

  # Record one outcome per message, with the reason derived from the changeset errors.
  # For an invalid changeset, check if any message error is a payload size error,
  # else use :invalid_request.
  defp record_outcome_per_message(tenant, _messages, %Ecto.Changeset{valid?: false} = changeset) do
    case get_change(changeset, :messages) do
      [_ | _] = message_changesets ->
        for message_changeset <- message_changesets do
          cond do
            message_changeset.valid? ->
              # This message was dropped because of its siblings, so it is recorded as a batch rejection.
              record_outcome(tenant, :batch_rejected)

            Enum.find(message_changeset.errors, fn {field, {error, _}} ->
              field == :payload and error == @payload_size_exceeded_error
            end) ->
              record_outcome(tenant, :payload_size_exceeded)

            true ->
              record_outcome(tenant, :invalid_request)
          end
        end

      _ ->
        # If there are no message changesets, record one outcome for the whole request.
        record_outcome(tenant, :invalid_request)
    end
  end

  # Record one outcome per message, with the same reason for all of them.
  defp record_outcome_per_message(tenant, %{"messages" => messages}, error_code) do
    record_outcome_per_message(tenant, messages, error_code)
  end

  # Record one outcome per message, with the same reason for all of them.
  defp record_outcome_per_message(tenant, messages, error_code) when is_list(messages) do
    Enum.each(messages, fn _ -> record_outcome(tenant, error_code) end)
  end

  # We don't have a list of messages, so just record one outcome for the whole request.
  defp record_outcome_per_message(tenant, _messages, error_code) do
    record_outcome(tenant, error_code)
  end
end
