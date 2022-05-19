defmodule RealtimeWeb.ChannelsAuthorization do
  @moduledoc """
  Check connection is authorized to access channel
  """
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

      _ ->
        :error
    end
  end
end
