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

  embedded_schema do
    embeds_many :messages, Message do
      field :event, :string
      field :topic, :string
      field :payload, :map
      field :private, :boolean, default: false
    end
  end

  @type result :: :ok | {:error, term()} | {:error, atom(), String.t()}

  @doc """
  Broadcasts a batch of messages.

  Returns `{result, outcomes}`. `result` is what the API answers with. `outcomes` has one outcome for
  each message, because the API answers `:ok` even when it drops the messages of a private topic.
  The messages of a topic whose authorization gives no answer are dropped without an outcome.
  """
  @spec broadcast(
          auth_params :: map() | nil,
          tenant :: Tenant.t(),
          messages :: %{
            messages: list(%{id: String.t(), topic: String.t(), payload: map(), event: String.t(), private: boolean()})
          },
          super_user :: boolean()
        ) :: {result(), [RequestMetrics.outcome()]}
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

  def broadcast(_auth_params, %Tenant{suspend: true}, messages, _super_user) do
    with_outcome({:error, :forbidden, "Tenant is suspended"}, :tenant_suspended, messages)
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
      public_outcomes =
        events
        |> Map.get(false, [])
        |> Enum.map(fn message ->
          send_message_and_count(tenant, events_per_second_rate, message, true)
          :success
        end)

      # Handle events for private channel. Each topic is authorized once, and all of its messages
      # get the outcome of that check.
      private_outcomes =
        events
        |> Map.get(true, [])
        |> Enum.group_by(fn event -> Map.get(event, :topic) end)
        |> Enum.flat_map(fn {topic, events} ->
          outcome = authorize_topic(tenant, auth_params, topic, super_user)

          if outcome == :success do
            Enum.each(events, fn message -> send_message_and_count(tenant, events_per_second_rate, message, false) end)
          end

          outcome_per_message(outcome, events)
        end)

      {:ok, public_outcomes ++ private_outcomes}
    else
      %Ecto.Changeset{valid?: false} = changeset ->
        {{:error, changeset}, changeset_outcomes(changeset)}

      {:error, :too_many_requests, _} = error ->
        with_outcome(error, :rate_limit_exceeded, messages)
    end
  end

  def broadcast(_, nil, _, _), do: {{:error, :tenant_not_found}, []}

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
      _ -> add_error(changeset, :payload, "Payload size exceeds tenant limit", validation: :payload_size)
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

  # Every message gets the same outcome. `params` is what the client sent, so the count comes from it.
  defp with_outcome(result, error_code, params) do
    outcome = RequestMetrics.classify_broadcast_error(error_code)
    {result, List.duplicate(outcome, message_count(params))}
  end

  defp message_count(%{"messages" => messages}), do: message_count(messages)
  defp message_count(%{messages: messages}), do: message_count(messages)
  defp message_count(messages) when is_list(messages), do: length(messages)
  # No list of messages, so the whole request counts once
  defp message_count(_params), do: 1

  # Super users are not authorized per topic. A nil outcome means there is no answer to count, so the
  # messages of that topic are dropped without an outcome.
  defp authorize_topic(_tenant, _auth_params, _topic, true), do: :success

  defp authorize_topic(tenant, auth_params, topic, false) do
    case permissions_for_message(tenant, auth_params, topic) do
      %Policies{broadcast: %BroadcastPolicies{write: true}} -> :success
      %Policies{broadcast: %BroadcastPolicies{}} -> RequestMetrics.classify_broadcast_error(:unauthorized)
      {:error, _} = error -> RequestMetrics.classify_broadcast_error(authorization_error_code(error))
      {:error, _, _} = error -> RequestMetrics.classify_broadcast_error(authorization_error_code(error))
      _ -> nil
    end
  end

  defp outcome_per_message(nil, _events), do: []
  defp outcome_per_message(outcome, events), do: List.duplicate(outcome, length(events))

  defp authorization_error_code({:error, :tenant_database_unavailable}), do: :unable_to_connect_to_project

  defp authorization_error_code({:error, reason})
       when reason in [:initializing, :tenant_database_connection_initializing],
       do: :initializing_project_connection

  defp authorization_error_code({:error, :tenant_db_too_many_connections}), do: :database_lack_of_connections
  defp authorization_error_code({:error, :connect_rate_limit_reached}), do: :database_connection_rate_limit_reached
  defp authorization_error_code({:error, :increase_connection_pool}), do: :increase_connection_pool
  defp authorization_error_code({:error, :missing_partition}), do: :missing_partition
  defp authorization_error_code({:error, :rpc_error, _}), do: :unable_to_handle_broadcast
  defp authorization_error_code({:error, :rls_policy_error, _}), do: :rls_policy_error
  defp authorization_error_code({:error, :query_canceled, _}), do: :query_canceled
  defp authorization_error_code(_error), do: :unable_to_set_policies

  # An invalid message rejects the whole batch, but each message gets its own reason. Without message
  # changesets (`messages` is missing or not a list), the whole request counts once.
  defp changeset_outcomes(changeset) do
    case get_change(changeset, :messages) do
      [_ | _] = message_changesets -> Enum.map(message_changesets, &message_outcome/1)
      _ -> [RequestMetrics.classify_broadcast_error(:invalid_request)]
    end
  end

  # A valid message is only dropped because of the others in its batch
  defp message_outcome(%Ecto.Changeset{valid?: true}), do: RequestMetrics.classify_broadcast_error(:batch_rejected)

  defp message_outcome(%Ecto.Changeset{errors: errors}) do
    # A payload size error names the cause, even when the message has other errors
    if Enum.any?(errors, &payload_size_error?/1) do
      RequestMetrics.classify_broadcast_error(:payload_size_exceeded)
    else
      RequestMetrics.classify_broadcast_error(:invalid_request)
    end
  end

  defp payload_size_error?({field, {_message, opts}}), do: field == :payload and opts[:validation] == :payload_size
end
