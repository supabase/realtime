defmodule Realtime.Extensions do
  def db_settings(type) do
    db_settings =
      Application.get_env(:realtime, :extensions)
      |> Enum.reduce(nil, fn
        {_, %{key: ^type, db_settings: db_settings}}, _ -> db_settings
        _, acc -> acc
      end)

    %{
      default: apply(db_settings, :default, []),
      required: apply(db_settings, :required, [])
    }
  end
end
