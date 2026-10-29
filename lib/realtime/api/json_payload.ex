defmodule Realtime.Api.JsonPayload do
  @moduledoc """
  Custom Ecto type for a `jsonb` column that can hold any JSON value.

  `:map` fails to load anything that isn't a JSON object, but `realtime.messages.payload`
  can also hold arrays, strings, numbers and booleans.
  """
  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_map(value) or is_list(value) or is_binary(value) or is_number(value) or is_boolean(value),
    do: {:ok, value}

  def cast(_), do: :error

  @impl true
  def load(value), do: {:ok, value}

  @impl true
  def dump(value), do: cast(value)
end
