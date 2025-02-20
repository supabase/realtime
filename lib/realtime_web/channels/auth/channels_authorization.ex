defmodule RealtimeWeb.ChannelsAuthorization do
  @moduledoc """
  Check connection is authorized to access channel
  """
  require Logger

  @doc """
  Authorize connection to access channel
  """
  @spec authorize(binary(), binary(), binary() | nil) ::
          {:ok, map()} | {:error, any()} | {:error, :expired_token, String.t()}
  def authorize(token, jwt_secret, jwt_jwks) when is_binary(token) do
    token
    |> clean_token()
    |> RealtimeWeb.JwtVerification.verify(jwt_secret, jwt_jwks)
  end

  def authorize(_token, _jwt_secret, _jwt_jwks), do: {:error, :invalid_token}

  def authorize_conn(token, jwt_secret, jwt_jwks) do
    case authorize(token, jwt_secret, jwt_jwks) do
      {:ok, claims} ->
        required = MapSet.new(["role", "exp"])
        claims_keys = claims |> Map.keys() |> MapSet.new()

        if MapSet.subset?(required, claims_keys) do
          {:ok, claims}
        else
          {:error, :missing_claims}
        end

      {:error, [message: validation_timer, claim: "exp", claim_val: claim_val]}
      when is_integer(validation_timer) ->
        msg = "Token has expired #{validation_timer - claim_val} seconds ago"
        {:error, :expired_token, msg}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clean_token(token), do: Regex.replace(~r/\s|\n/, URI.decode(token), "")
end
