defmodule RealtimeWeb.ChannelsController do
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Realtime.Channels
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.OpenApiSchemas.ChannelParams
  alias RealtimeWeb.OpenApiSchemas.ChannelResponse
  alias RealtimeWeb.OpenApiSchemas.ChannelResponseList
  alias RealtimeWeb.OpenApiSchemas.EmptyResponse
  alias RealtimeWeb.OpenApiSchemas.NotFoundResponse
  alias RealtimeWeb.OpenApiSchemas.UnauthorizedResponse

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
      200 => ChannelResponseList.response(),
      401 => UnauthorizedResponse.response()
    }
  )

  def index(
        %{
          assigns: %{
            tenant: tenant,
            policies: %Policies{channel: %ChannelPolicies{read: true}}
          }
        } = conn,
        _params
      ) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         {:ok, channels} <- Channels.list_channels(db_conn) do
      json(conn, channels)
    end
  end

  def index(_conn, _params), do: {:error, :unauthorized}

  operation(:show,
    summary: "Show user channel",
    parameters: [
      id: [
        in: :path,
        name: "name",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example: "channel_name"
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
      401 => UnauthorizedResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def show(
        %{
          assigns: %{
            tenant: tenant,
            policies: %Policies{channel: %ChannelPolicies{read: true}}
          }
        } = conn,
        %{
          "name" => name
        }
      ) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         {:ok, channel} when not is_nil(channel) <- Channels.get_channel_by_name(name, db_conn) do
      json(conn, channel)
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  def show(_conn, _params), do: {:error, :unauthorized}

  operation(:create,
    summary: "Create user channel",
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
    request_body: ChannelParams.params(),
    responses: %{
      201 => ChannelResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def create(
        %{
          assigns: %{
            tenant: tenant,
            policies: %Policies{channel: %ChannelPolicies{write: true}}
          }
        } = conn,
        params
      ) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         {:ok, channel} <- Channels.create_channel(params, db_conn) do
      conn
      |> put_status(:created)
      |> json(channel)
    end
  end

  def create(_conn, _params), do: {:error, :unauthorized}

  operation(:delete,
    summary: "Deletes a channel",
    parameters: [
      id: [
        in: :path,
        name: "name",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example: "channel_name"
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
      202 => EmptyResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def delete(
        %{
          assigns: %{
            tenant: tenant,
            policies: %Policies{channel: %ChannelPolicies{write: true}}
          }
        } = conn,
        %{"name" => name}
      ) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         :ok <- Channels.delete_channel_by_name(name, db_conn) do
      send_resp(conn, :accepted, "")
    end
  end

  def delete(_conn, _params), do: {:error, :unauthorized}

  operation(:update,
    summary: "Update user channel",
    parameters: [
      id: [
        in: :path,
        name: "name",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example: "channel_name"
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
    request_body: ChannelParams.params(),
    responses: %{
      201 => ChannelResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def update(
        %{
          assigns: %{
            tenant: tenant,
            policies: %Policies{channel: %ChannelPolicies{write: true}}
          },
          body_params: body_params
        } = conn,
        %{"name" => name}
      ) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         {:ok, channel} <- Channels.update_channel_by_name(name, body_params, db_conn) do
      conn
      |> put_status(:accepted)
      |> json(channel)
    end
  end

  def update(_conn, _params), do: {:error, :unauthorized}
end
