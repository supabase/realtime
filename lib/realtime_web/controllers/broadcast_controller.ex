defmodule RealtimeWeb.BroadcastController do
  require Logger
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Realtime.GenCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.BatchBroadcast
  alias RealtimeWeb.Endpoint

  alias RealtimeWeb.OpenApiSchemas.EmptyResponse
  alias RealtimeWeb.OpenApiSchemas.TenantBatchParams
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
      422 => UnprocessableEntityResponse.response()
    }
  )

  def broadcast(%{assigns: %{tenant: tenant}} = conn, attrs) do
    with %Ecto.Changeset{valid?: true} = changeset <-
           BatchBroadcast.changeset(%BatchBroadcast{}, attrs),
         %Ecto.Changeset{changes: %{messages: messages}} <- changeset,
         events_per_second_key <- Tenants.events_per_second_key(tenant) do
      for %{changes: %{topic: sub_topic, payload: payload, event: event}} <- messages do
        tenant_topic = Tenants.tenant_topic(tenant, sub_topic)
        payload = %{"payload" => Map.merge(payload, %{"event" => event})}

        Endpoint.broadcast_from(self(), tenant_topic, "broadcast", payload)

        GenCounter.add(events_per_second_key)
        Logger.info("Broadcasted message to using HTTP API: " <> tenant_topic)
      end

      send_resp(conn, :accepted, "")
    end
  end
end
