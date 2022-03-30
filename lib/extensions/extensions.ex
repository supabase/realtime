defmodule Multiplayer.Extensions do
  def module(type) do
    Application.get_env(:multiplayer, :extensions)
    |> Enum.reduce(nil, fn
      {_, %{key: ^type, module: module}}, _ -> module
      _, acc -> acc
    end)
  end
end
