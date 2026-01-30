defmodule RealtimeWeb.Channels.Payloads.ChangesetNormalizer do
  @moduledoc """
  Functions for normalizing changeset attributes before validation.
  Handles conversion of string boolean representations to actual booleans.
  """

  @doc """
  Normalizes a value that should be a boolean. Accepts:
  - Boolean values (true/false) - returned as-is
  - Strings "true", "True", "TRUE", etc. - converted to true
  - Strings "false", "False", "FALSE", etc. - converted to false
  - Any other value - returned as-is (will fail validation later)
  """
  def normalize_boolean(value) when is_boolean(value), do: value

  def normalize_boolean(value) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> value
    end
  end

  def normalize_boolean(value), do: value

  @doc """
  Normalizes boolean fields in an attrs map for the given field names.
  """
  def normalize_boolean_fields(attrs, field_names) when is_map(attrs) do
    Enum.reduce(field_names, attrs, fn field_name, acc ->
      field_key_string = to_string(field_name)
      field_key_atom = field_name

      acc
      |> maybe_normalize_field(field_key_string)
      |> maybe_normalize_field(field_key_atom)
    end)
  end

  def normalize_boolean_fields(attrs, _field_names), do: attrs

  defp maybe_normalize_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, normalize_boolean(value))
      :error -> attrs
    end
  end
end
