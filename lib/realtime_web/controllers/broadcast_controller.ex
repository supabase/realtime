defmodule RealtimeWeb.BroadcastController do
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger

  alias Realtime.Tenants.BatchBroadcast
  alias RealtimeWeb.OpenApiSchemas.EmptyResponse
  alias RealtimeWeb.OpenApiSchemas.TenantBatchParams
  alias RealtimeWeb.OpenApiSchemas.TooManyRequestsResponse
  alias RealtimeWeb.OpenApiSchemas.UnprocessableEntityResponse
  alias RealtimeWeb.RequestMetrics

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
    result =
      RequestMetrics.track(:broadcast, :http, tenant.external_id, fn ->
        BatchBroadcast.broadcast(conn, tenant, attrs)
      end)

    with :ok <- result, do: send_resp(conn, :accepted, "")
  end
end
