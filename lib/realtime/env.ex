defmodule Realtime.Env do
  @moduledoc false
  # Internal module used to load and validate env vars.

  @spec get_integer(binary(), integer() | nil) :: integer() | nil
  def get_integer(env, default \\ nil)

  def get_integer(env, default) when is_integer(default) or is_nil(default) do
    value = System.get_env(env)

    if value do
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> raise ArgumentError, "env #{env} expected a Integer, got #{inspect(value)}"
      end
    else
      default
    end
  end

  def get_integer(env, default) do
    raise ArgumentError,
          "expected either Integer or empty (nil) as default value for env #{env}, got #{inspect(default)}"
  end

  @spec get_charlist(binary(), charlist()) :: charlist()
  def get_charlist(env, default) when is_list(default) do
    value = System.get_env(env)
    if value, do: String.to_charlist(value), else: default
  end

  def get_charlist(env, default) do
    raise ArgumentError,
          "expected a charlist as default value for env #{env}, got #{inspect(default)}"
  end

  # accepts true/1 for truthy values and false/0 for falsy values, otherwise raise ArgumentError
  @spec get_boolean(binary(), boolean()) :: boolean()
  def get_boolean(env, default) when is_boolean(default) do
    value = System.get_env(env)

    if value do
      value = value |> String.trim() |> String.downcase()

      cond do
        value in ["true", "1"] -> true
        value in ["false", "0"] -> false
        :else -> raise ArgumentError, "env #{env} expected a boolean or 0/1 values, got #{inspect(value)}"
      end
    else
      default
    end
  end

  def get_boolean(env, default) do
    raise ArgumentError,
          "expected a boolean as default value for env #{env}, got #{inspect(default)}"
  end

  @spec get_binary(binary(), binary() | (-> binary())) :: binary()
  def get_binary(env, default) when is_function(default, 0) do
    value = System.get_env(env)
    if value, do: value, else: default.()
  end

  def get_binary(env, default), do: System.get_env(env, default)

  @spec get_list(binary(), [binary()]) :: [binary()]
  def get_list(env, default) when is_list(default) do
    value = System.get_env(env)

    if value do
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
    else
      default
    end
  end
end
