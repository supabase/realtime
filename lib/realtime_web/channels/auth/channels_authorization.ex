defmodule RealtimeWeb.ChannelsAuthorization do
  @moduledoc """
  Check connection is authorized to access channel
  """
  require Logger

  def authorize(token, secret, signing_method) when is_binary(token) do
    token
    |> clean_token()
    |> RealtimeWeb.JwtVerification.verify(secret, signing_method)
  end

  def authorize(_token, _secret, _signing_method), do: :error

  defp clean_token(token) do
    Regex.replace(~r/\s|\n/, URI.decode(token), "")
  end

  def authorize_conn(token, secret, signing_method) do
    case authorize(token, secret, signing_method) do
      {:ok, claims} ->
        required = MapSet.new(["role", "exp"])
        claims_keys = Map.keys(claims) |> MapSet.new()

        if MapSet.subset?(required, claims_keys) do
          {:ok, claims}
        else
          {:error, "Fields `role` and `exp` are required in JWT"}
        end

      {:error, reason} ->
        {:error, reason}

      error ->
        Logger.error("Unknown connection authorization error: #{inspect(error)}")
        {:error, :unknown}
    end
  end
end
