defmodule RealtimeWeb.BroadcastController do
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger
  import Ecto.Query

  alias Realtime.Api.Channel
  alias Realtime.Api.Tenant
  alias Realtime.GenCounter
  alias Realtime.Helpers
  alias Realtime.RateCounter
  alias Realtime.Repo
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
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
      events =
        Enum.map(messages, fn %{changes: %{topic: sub_topic} = event} -> {sub_topic, event} end)

      channel_names = events |> Enum.map(fn {sub_topic, _} -> sub_topic end) |> MapSet.new()

      if MapSet.size(channel_names) > 1 do
        Logger.warning(
          "This Broadcast is sending to multiple channels. Avoid this as it impact your performance."
        )
      end

      query_to_check = from(c in Channel, where: c.name in ^MapSet.to_list(channel_names))

      channels =
        Helpers.transaction(db_conn, fn transaction_conn ->
          transaction_conn
          |> Repo.all(query_to_check, Channel)
          |> then(fn {:ok, channels} -> channels end)
        end)

      channels_names_to_check =
        channels
        |> Enum.map(& &1.name)
        |> MapSet.new()

      # Handle events without authorization
      MapSet.difference(channel_names, channels_names_to_check)
      |> Enum.each(fn channel_name ->
        events
        |> Enum.filter(fn {sub_topic, _} -> sub_topic == channel_name end)
        |> Enum.each(fn {_, %{topic: sub_topic, payload: payload, event: event}} ->
          send_message_and_count(tenant, sub_topic, event, payload)
        end)
      end)

      # Handle events with authorization
      channels_names_to_check
      |> Enum.reduce([], fn sub_topic, acc ->
        Enum.filter(events, fn
          {^sub_topic, _} -> true
          _ -> false
        end) ++ acc
      end)
      |> Enum.map(fn {_, event} -> event end)
      |> Enum.each(fn %{topic: channel_name, payload: payload, event: event} ->
        Helpers.transaction(db_conn, fn transaction_conn ->
          case permissions_for_channel(conn, transaction_conn, channels, channel_name) do
            %Policies{
              channel: %ChannelPolicies{read: true},
              broadcast: %BroadcastPolicies{write: true}
            } ->
              send_message_and_count(tenant, channel_name, event, payload)

            _ ->
              nil
          end
        end)
      end)

      send_resp(conn, :accepted, "")
    end
  end

  defp send_message_and_count(tenant, channel_name, event, payload) do
    events_per_second_key = Tenants.events_per_second_key(tenant)
    tenant_topic = Tenants.tenant_topic(tenant, channel_name)
    payload = %{"payload" => payload, "event" => event, "type" => "broadcast"}

    GenCounter.add(events_per_second_key)
    Endpoint.broadcast_from(self(), tenant_topic, "broadcast", payload)
  end

  defp permissions_for_channel(conn, db_conn, channels, channel_name) do
    params = %{
      headers: conn.req_headers,
      jwt: conn.assigns.jwt,
      claims: conn.assigns.claims,
      role: conn.assigns.role
    }

    with channel <- Enum.find(channels, &(&1.name == channel_name)),
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
