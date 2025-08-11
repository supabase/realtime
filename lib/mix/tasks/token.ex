defmodule Mix.Tasks.Token do
  use Mix.Task
  alias Realtime.Api.Tenant

  @shortdoc "Generates a new token for the application"
  @impl Mix.Task
  def run(_args) do
    # Load the application configuration (including runtime.exs) and start the necessary applications
    Mix.Task.run("app.config")
    Application.ensure_all_started(:realtime)

    tenant = %Tenant{} = Realtime.Repo.get_by(Tenant, external_id: "realtime-dev")
    token = generate_jwt_token(tenant)

    IO.puts("Generated token: #{token}")
  end

  defp generate_jwt_token(secret_or_tenant) do
    claims = %{role: "authenticated", exp: System.system_time(:second) + 100_000}
    generate_jwt_token(secret_or_tenant, claims)
  end

  defp generate_jwt_token(%Tenant{} = tenant, claims) do
    secret = Realtime.Crypto.decrypt!(tenant.jwt_secret)
    generate_jwt_token(secret, claims)
  end

  defp generate_jwt_token(secret, claims) when is_binary(secret) do
    signer = Joken.Signer.create("HS256", secret)
    {:ok, claims} = Joken.generate_claims(%{}, claims)
    {:ok, jwt, _} = Joken.encode_and_sign(claims, signer)
    jwt
  end
end
