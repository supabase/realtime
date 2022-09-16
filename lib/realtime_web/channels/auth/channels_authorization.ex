defmodule RealtimeWeb.ChannelsAuthorization do
  @moduledoc """
  Check connection is authorized to access channel
  """
  require Logger

  def authorize(token, secret) when is_binary(token) do
    token
    |> clean_token()
    |> RealtimeWeb.JwtVerification.verify(secret)
  end

  def authorize(_token, _secret), do: :error

  defp clean_token(token) do
    Regex.replace(~r/\s|\n/, URI.decode(token), "")
  end

  def authorize_conn(token, secret) do
    case authorize(token, secret) do
      # TODO: check necessary fields
      {:ok, %{"role" => _} = claims} ->
        {:ok, claims}

      {:error, reason} ->
        {:error, reason}

      error ->
        Logger.error("Unknown connection authorization error: #{inspect(error)}")
        {:error, :unknown}
    end
  end
end
