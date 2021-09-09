defmodule Realtime.Helpers do
  # key1=value1:key2=value2 to [{"key1", "value1"},{"key2", "value2"}]
  @spec env_kv_to_list(String.t() | nil, keyword() | []) :: {:ok, keyword()} | :error
  def env_kv_to_list("", _), do: :error

  def env_kv_to_list(env_val, def_list) when is_binary(env_val) do
    keywords =
      String.split(env_val, ":")
      |> Enum.map(
        &(String.split(&1, "=")
          |> List.to_tuple())
      )
      |> Enum.concat(def_list)

    try do
      # check if keywords is valid
      Keyword.values(keywords)
      {:ok, keywords}
    rescue
      _ -> :error
    end
  end

  def env_kv_to_list(_, _), do: :error
end
