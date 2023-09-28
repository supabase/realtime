defmodule RealtimeWeb.BroadcastController do
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Realtime.Api.Tenant
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.BatchBroadcast
  alias RealtimeWeb.Endpoint

  alias RealtimeWeb.OpenApiSchemas.EmptyResponse
  alias RealtimeWeb.OpenApiSchemas.TenantBatchParams
  alias RealtimeWeb.OpenApiSchemas.UnprocessableEntityResponse
  alias RealtimeWeb.OpenApiSchemas.TooManyRequestsResponse

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
         %Ecto.Changeset{changes: %{messages: messages}} <- changeset,
         events_per_second_key <- Tenants.events_per_second_key(tenant),
         :ok <- check_rate_limit(events_per_second_key, tenant, length(messages)) do
      for %{changes: %{topic: sub_topic, payload: payload, event: event}} <- messages do
        tenant_topic = Tenants.tenant_topic(tenant, sub_topic)
        payload = %{"payload" => payload, "event" => event, "type" => "broadcast"}

        Endpoint.broadcast_from(self(), tenant_topic, "broadcast", payload)

        GenCounter.add(events_per_second_key)
      end

      send_resp(conn, :accepted, "")
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
