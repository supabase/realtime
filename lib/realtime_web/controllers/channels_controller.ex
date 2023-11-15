defmodule RealtimeWeb.ChannelsController do
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Realtime.Channels
  alias RealtimeWeb.OpenApiSchemas.ChannelResponseList
  alias Realtime.Tenants.Connect
  action_fallback(RealtimeWeb.FallbackController)

  operation(:index,
    summary: "List user channels",
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
    responses: %{
      200 => ChannelResponseList.response()
    }
  )

  def index(%{assigns: %{tenant: tenant}} = conn, _params) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         {:ok, channels} <- Channels.list_channels(db_conn) do
      json(conn, channels)
    end
  end
end
