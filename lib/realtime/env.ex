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

  @spec get_float(binary(), float() | nil) :: float() | nil
  def get_float(env, default \\ nil)

  def get_float(env, default) when is_float(default) or is_nil(default) do
    value = System.get_env(env)

    if value do
      case Float.parse(value) do
        {float, ""} -> float
        _ -> raise ArgumentError, "env #{env} expected a Float, got #{inspect(value)}"
      end
    else
      default
    end
  end

  def get_float(env, default) do
    raise ArgumentError,
          "expected either Float or empty (nil) as default value for env #{env}, got #{inspect(default)}"
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

  @spec get_non_empty_binary(binary()) :: binary() | nil
  def get_non_empty_binary(env) do
    case System.get_env(env) do
      nil ->
        nil

      value ->
        value = String.trim(value)

        if value in ["", "''", ~s("")] do
          nil
        else
          value
        end
    end
  end

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

  @doc """
  Parses comma-separated key=value pairs, e.g. "region=us-east-1,env=prod".
  """
  @spec get_key_value_list(binary()) :: [{binary(), binary()}]
  def get_key_value_list(env) do
    case System.get_env(env, "") do
      "" ->
        []

      value ->
        value
        |> String.split(",")
        |> Enum.flat_map(&parse_key_value_pair/1)
    end
  end

  @doc """
  Parses comma-separated key=integer pairs, e.g. "us-east-1=2,eu-west-1=2".

  Unlike `get_key_value_list/1`, raises on a malformed pair, a value that isn't a positive integer, or a repeated key.
  """
  @spec get_key_positive_integer_list(binary()) :: [{binary(), pos_integer()}]
  def get_key_positive_integer_list(env) do
    value = env |> System.get_env("") |> String.trim()

    pairs =
      if value == "" do
        []
      else
        value
        |> String.split(",")
        |> Enum.map(&parse_key_positive_integer_pair!(env, &1))
      end

    case pairs -- Enum.uniq_by(pairs, &elem(&1, 0)) do
      [] -> pairs
      [{key, _} | _] -> raise ArgumentError, "env #{env} repeats key #{inspect(key)}"
    end
  end

  @doc """
  Can a listener still bind this port?

  Probes the wildcard address with the same `reuseaddr` the real listeners use, so a port left
  in `TIME_WAIT` reads as available while a live listener does not.

  Inherently a snapshot: whoever binds next may lose the race.
  """
  @spec port_available?(:inet.port_number()) :: boolean()
  def port_available?(port) do
    case :gen_tcp.listen(port, [:inet, ip: {0, 0, 0, 0}, reuseaddr: true, active: false]) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _reason} -> false
    end
  end

  @doc """
  A port with nothing behind it.

  Lets the OS pick a free one and hands it back closed, for callers that want an address no
  connection can succeed against.
  """
  @spec unused_port() :: :inet.port_number()
  def unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:inet, ip: {0, 0, 0, 0}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp parse_key_value_pair(pair) do
    with [k, v] <- String.split(pair, "=", parts: 2),
         k = String.trim(k),
         true <- k != "" do
      [{k, String.trim(v)}]
    else
      _ -> []
    end
  end

  defp parse_key_positive_integer_pair!(env, pair) do
    with [k, v] <- String.split(pair, "=", parts: 2),
         k = String.trim(k),
         true <- k != "",
         {int, ""} when int > 0 <- v |> String.trim() |> Integer.parse() do
      {k, int}
    else
      _ -> raise ArgumentError, "env #{env} expected key=positive integer pairs, got #{inspect(String.trim(pair))}"
    end
  end
end
