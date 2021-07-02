defmodule MultiplayerWeb.ChannelsAuthorization do

  def authorize(token) when is_binary(token) do
    token
    |> clean_token()
    |> MultiplayerWeb.JwtVerification.verify()
  end

  def authorize(_token), do: :error

  defp clean_token(token) do
    Regex.replace(~r/\s|\n/, URI.decode(token), "")
  end
end
