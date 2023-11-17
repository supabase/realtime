defmodule RealtimeWeb.ChannelsController do
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Realtime.Channels
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.OpenApiSchemas.ChannelResponse
  alias RealtimeWeb.OpenApiSchemas.ChannelResponseList
  alias RealtimeWeb.OpenApiSchemas.NotFoundResponse

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

  operation(:show,
    summary: "Show user channel",
    parameters: [
      id: [
        in: :path,
        name: "id",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example: "1"
      ],
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
      200 => ChannelResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def show(%{assigns: %{tenant: tenant}} = conn, %{"id" => id}) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         {:ok, channel} when not is_nil(channel) <- Channels.get_channel_by_id(id, db_conn) do
      json(conn, channel)
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end
end
