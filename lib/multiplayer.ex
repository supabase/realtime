defmodule Multiplayer do
  def extension_module(type) do
    case type do
      "postgres" ->
        Extensions.Postgres

      _ ->
        nil
    end
  end
end
