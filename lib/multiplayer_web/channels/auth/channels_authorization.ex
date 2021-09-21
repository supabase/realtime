defmodule MultiplayerWeb.ChannelsAuthorization do

  def authorize(token, secret) when is_binary(token) do
    token
    |> clean_token()
    |> MultiplayerWeb.JwtVerification.verify(secret)
  end

  def authorize(_token, _secret), do: :error

  defp clean_token(token) do
    Regex.replace(~r/\s|\n/, URI.decode(token), "")
  end
end
