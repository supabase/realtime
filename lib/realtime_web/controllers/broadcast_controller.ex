defmodule RealtimeWeb.BroadcastController do
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
  alias Realtime.Channels
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Realtime.Api.Tenant
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.BatchBroadcast
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.OpenApiSchemas.EmptyResponse
  alias RealtimeWeb.OpenApiSchemas.TenantBatchParams
  alias RealtimeWeb.OpenApiSchemas.TooManyRequestsResponse
  alias RealtimeWeb.OpenApiSchemas.UnprocessableEntityResponse

  action_fallback(RealtimeWeb.FallbackController)

  operation(:broadcast,
    summary: "Broadcasts a batch of messages",
    parameters: [
      token: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ]
    ],
    request_body: TenantBatchParams.params(),
    responses: %{
      202 => EmptyResponse.response(),
      403 => EmptyResponse.response(),
      422 => UnprocessableEntityResponse.response(),
      429 => TooManyRequestsResponse.response()
    }
  )

  def broadcast(%{assigns: %{tenant: tenant}} = conn, attrs) do
    with %Ecto.Changeset{valid?: true} = changeset <-
           BatchBroadcast.changeset(%BatchBroadcast{}, attrs),
         %Ecto.Changeset{changes: %{messages: messages}} = changeset,
         events_per_second_key = Tenants.events_per_second_key(tenant),
         :ok <- check_rate_limit(events_per_second_key, tenant, length(messages)),
         {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id) do
      for %{changes: %{topic: sub_topic, payload: payload, event: event}} <- messages do
        case permissions_for_channel(db_conn, conn, sub_topic) do
          nil ->
            send_message_and_count(tenant, sub_topic, event, payload)

          %Policies{
            channel: %ChannelPolicies{read: true},
            broadcast: %BroadcastPolicies{write: true}
          } ->
            send_message_and_count(tenant, sub_topic, event, payload)

          _ ->
            nil
        end
      end

      send_resp(conn, :accepted, "")
    end
  end

  defp send_message_and_count(tenant, sub_topic, event, payload) do
    events_per_second_key = Tenants.events_per_second_key(tenant)
    tenant_topic = Tenants.tenant_topic(tenant, sub_topic)
    payload = %{"payload" => payload, "event" => event, "type" => "broadcast"}

    GenCounter.add(events_per_second_key)
    Endpoint.broadcast_from(self(), tenant_topic, "broadcast", payload)
  end

  defp permissions_for_channel(db_conn, conn, sub_topic) do
    params = %{
      headers: conn.req_headers,
      jwt: conn.assigns.jwt,
      claims: conn.assigns.claims,
      role: conn.assigns.role
    }

    with {:ok, channel} <- Channels.get_channel_by_name(sub_topic, db_conn),
         params = Map.put(params, :channel, channel),
         params = Map.put(params, :channel_name, channel.name),
         params = Authorization.build_authorization_params(params),
         %Policies{} = policies <- Authorization.get_authorizations(db_conn, params) do
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
