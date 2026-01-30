defmodule Realtime.Tenants.SingleBroadcast do
  @moduledoc """
  Handles single broadcast messages via the /api/broadcast/:topic/:event API.

  This module supports both JSON and binary payloads via Content-Type header:
  - application/json: Sends Phoenix.Socket.Broadcast with JSON payload
  - application/octet-stream: Sends RealtimeWeb.Socket.UserBroadcast with binary payload

  Unlike the batch API, this API:
  - Takes topic and event from URL path (not body)
  - Sends single message (no batching)
  - No message ID tracking
  - Simpler validation
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
  alias RealtimeWeb.Socket.UserBroadcast
  alias RealtimeWeb.TenantBroadcaster

  @primary_key false
  embedded_schema do
    field :topic, :string
    field :event, :string
    field :payload, :any, virtual: true  # map for JSON, binary for binary
    field :private, :boolean, default: false
    field :content_type, :string  # "json" or "binary"
  end

  @type content_type :: :json | :binary

  @doc """
  Broadcasts a single message to the specified topic.

  ## Parameters
  - `conn` - Plug.Conn or auth_params map containing JWT claims
  - `tenant` - Tenant struct
  - `topic` - Channel topic from URL (e.g., "room:123")
  - `event` - Event name from URL (e.g., "message")
  - `private` - Whether this is a private broadcast (requires authorization)
  - `payload` - Message payload (map for JSON, binary for binary)
  - `content_type` - :json or :binary

  ## Returns
  - `:ok` on success
  - `{:error, term()}` on failure
  """
  @spec broadcast(
          Plug.Conn.t() | map(),
          Tenant.t(),
          String.t(),
          String.t(),
          boolean(),
          any(),
          content_type()
        ) :: :ok | {:error, term()}
  def broadcast(conn, tenant, topic, event, private, payload, content_type)

  def broadcast(%Plug.Conn{} = conn, %Tenant{} = tenant, topic, event, private, payload, content_type) do
    auth_params = %{
      tenant_id: tenant.external_id,
      headers: conn.req_headers,
      claims: conn.assigns.claims,
      role: conn.assigns.role,
      sub: conn.assigns.sub
    }

    broadcast(auth_params, tenant, topic, event, private, payload, content_type)
  end

  def broadcast(auth_params, %Tenant{} = tenant, topic, event, private, payload, content_type) do
    with %Ecto.Changeset{valid?: true} <- validate_message(topic, event, private, payload, content_type, tenant),
         events_per_second_rate = Tenants.events_per_second_rate(tenant),
         :ok <- check_rate_limit(events_per_second_rate, tenant) do
      if private do
        handle_private_message(tenant, auth_params, topic, event, payload, content_type, events_per_second_rate)
      else
        send_message_and_count(tenant, events_per_second_rate, topic, event, payload, content_type, true)
        :ok
      end
    else
      %Ecto.Changeset{valid?: false} = changeset -> {:error, changeset}
      error -> error
    end
  end

  def broadcast(_, nil, _, _, _, _, _), do: {:error, :tenant_not_found}

  defp validate_message(topic, event, private, payload, content_type, tenant) do
    %__MODULE__{}
    |> cast(%{topic: topic, event: event, private: private, content_type: to_string(content_type)}, [
      :topic,
      :event,
      :private,
      :content_type
    ])
    |> put_change(:payload, payload)
    |> validate_required([:topic, :event, :content_type])
    |> validate_payload_present(content_type, payload)
    |> validate_inclusion(:content_type, ["json", "binary"])
    |> validate_payload_size(tenant, content_type)
  end

  defp validate_payload_present(changeset, content_type, payload) do
    case {content_type, payload} do
      # Binary payloads: <<>> is valid, nil is not
      {:binary, payload} when is_binary(payload) ->
        changeset

      {:binary, nil} ->
        add_error(changeset, :payload, "can't be blank")

      # JSON payloads: any value (including nil map) is acceptable if present
      {:json, nil} ->
        add_error(changeset, :payload, "can't be blank")

      {:json, _} ->
        changeset

      _ ->
        changeset
    end
  end

  defp validate_payload_size(changeset, tenant, content_type) do
    payload = get_change(changeset, :payload)

    if is_nil(payload) do
      changeset
    else
      case content_type do
        :json ->
          case Tenants.validate_payload_size(tenant, payload) do
            :ok -> changeset
            _ -> add_error(changeset, :payload, "Payload size exceeds tenant limit")
          end

        :binary when is_binary(payload) ->
          # For binary, we check the actual byte size plus overhead
          # to match the behavior of validate_payload_size which uses erlang.external_size
          # Binary external size is byte_size + some overhead for the term encoding
          max_payload_size = tenant.max_payload_size_in_kb * 1000 + 500
          payload_size = :erlang.external_size(payload)

          if payload_size > max_payload_size do
            add_error(changeset, :payload, "Payload size exceeds tenant limit")
          else
            changeset
          end

        :binary ->
          # Not a binary, will fail validation
          changeset
      end
    end
  end

  defp handle_private_message(tenant, auth_params, topic, event, payload, content_type, rate_counter) do
    case permissions_for_message(tenant, auth_params, topic) do
      %Policies{broadcast: %BroadcastPolicies{write: true}} ->
        send_message_and_count(tenant, rate_counter, topic, event, payload, content_type, false)
        :ok

      _ ->
        # Silently fail unauthorized (same as batch API)
        :ok
    end
  end

  defp permissions_for_message(_, nil, _), do: nil

  defp permissions_for_message(tenant, auth_params, topic) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id) do
      auth_params =
        auth_params
        |> Map.put(:topic, topic)
        |> Authorization.build_authorization_params()

      case Authorization.get_write_authorizations(db_conn, auth_params) do
        {:ok, policies} -> policies
        {:error, :not_found} -> nil
        error -> error
      end
    end
  end

  defp check_rate_limit(events_per_second_rate, %Tenant{} = tenant) do
    %{max_events_per_second: max_events_per_second} = tenant
    {:ok, %{avg: events_per_second}} = RateCounter.get(events_per_second_rate)

    if events_per_second >= max_events_per_second do
      {:error, :too_many_requests, "You have exceeded your rate limit"}
    else
      :ok
    end
  end

  @event_type "broadcast"
  defp send_message_and_count(tenant, events_per_second_rate, topic, event, payload, content_type, public?) do
    tenant_topic = Tenants.tenant_topic(tenant, topic, public?)

    broadcast =
      case content_type do
        :json ->
          build_json_broadcast(topic, event, payload)

        :binary ->
          build_binary_broadcast(topic, event, payload)
      end

    GenCounter.add(events_per_second_rate.id)

    TenantBroadcaster.pubsub_broadcast(
      tenant.external_id,
      tenant_topic,
      broadcast,
      RealtimeChannel.MessageDispatcher,
      :broadcast
    )
  end

  defp build_json_broadcast(topic, event, payload) do
    formatted_payload = %{
      "payload" => payload,
      "event" => event,
      "type" => "broadcast"
    }

    %Phoenix.Socket.Broadcast{
      topic: topic,
      event: @event_type,
      payload: formatted_payload
    }
  end

  defp build_binary_broadcast(topic, event, binary) do
    %UserBroadcast{
      topic: topic,
      user_event: event,
      user_payload: binary,
      user_payload_encoding: :binary,
      metadata: nil
    }
  end
end
