defmodule Integration do
  import Generators

  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient
  alias Phoenix.Socket.V1
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient

  @serializer V1.JSONSerializer
  @secret "secure_jwt_secret"
  @external_id "dev_tenant"
  defp uri(port), do: "ws://#{@external_id}.localhost:#{port}/socket/websocket"
  def token_valid(role, claims \\ %{}), do: generate_token(Map.put(claims, :role, role))
  def token_no_role, do: generate_token()

  def generate_token(claims \\ %{}) do
    claims =
      Map.merge(
        %{
          ref: "localhost",
          iat: System.system_time(:second),
          exp: System.system_time(:second) + 604_800
        },
        claims
      )

    {:ok, generate_jwt_token(@secret, claims)}
  end

  def get_connection(port, role \\ "anon", claims \\ %{}, params \\ %{vsn: "1.0.0", log_level: :warning}) do
    params = Enum.reduce(params, "", fn {k, v}, acc -> "#{acc}&#{k}=#{v}" end)
    uri = "#{uri(port)}?#{params}"

    with {:ok, token} <- token_valid(role, claims),
         {:ok, socket} <-
           WebsocketClient.connect(self(), uri, @serializer, [{"x-api-key", token}]) do
      {socket, token}
    end
  end

  def rls_context(%{tenant: tenant} = context) do
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

    clean_table(db_conn, "realtime", "messages")
    topic = Map.get(context, :topic, random_string())
    message = message_fixture(tenant, %{topic: topic})

    if policies = context[:policies] do
      create_rls_policies(db_conn, policies, message)
    end

    Map.put(context, :topic, message.topic)
  end

  def change_tenant_configuration(limit, value) do
    @external_id
    |> Realtime.Tenants.get_tenant_by_external_id()
    |> Realtime.Api.Tenant.changeset(%{limit => value})
    |> Realtime.Repo.update!()

    Realtime.Tenants.Cache.invalidate_tenant_cache(@external_id)
  end
end
