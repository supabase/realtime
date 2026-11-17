defmodule PolicyEval.KnownFunction do
  @moduledoc """
  Builds the known functions of a profile (`PolicyEval.Profile`). A known function is a function
  definition that the library can inline: a SQL function without arguments, in a platform
  schema, with an exact body.

  `new/5` takes the schema, the name and the return type of the function, the source that the
  definition in the database must match (see `PolicyEval.Catalog`), and the body as a tree. The
  other functions build that tree. Each one stands for one Postgres construct, so a profile does not
  depend on the internal form of `PolicyEval.IR`.

  For example, this is the body `select nullif(current_setting('app.team', true), '')::text`:

      nullif(setting("app.team"), text(""))

  The builders do not check types, and nothing in the library checks that the tree does what the
  source does. The profile that builds a known function is responsible for both.
  """

  alias PolicyEval.IR
  alias PolicyEval.Jsonb
  alias PolicyEval.Value

  @type t :: %{
          schema: String.t(),
          name: String.t(),
          return_type: String.t(),
          type: PolicyEval.Catalog.type(),
          source: String.t(),
          ir: IR.t()
        }

  # The return types a known function can have, by the name Postgres prints.
  @types %{"text" => :text, "uuid" => :uuid, "jsonb" => :jsonb}

  @doc """
  A known function. `return_type` is the name that Postgres prints, `text`, `uuid` or `jsonb`.
  """
  @spec new(String.t(), String.t(), String.t(), String.t(), IR.t()) :: t
  def new(schema, name, return_type, source, body)
      when is_binary(schema) and is_binary(name) and is_map_key(@types, return_type) and is_binary(source) do
    %{schema: schema, name: name, return_type: return_type, type: @types[return_type], source: source, ir: body}
  end

  @doc "`current_setting(name, true)`."
  @spec setting(String.t()) :: IR.t()
  def setting(name) when is_binary(name), do: {:setting, name}

  @doc "The text literal `'value'`."
  @spec text(String.t()) :: IR.t()
  def text(value) when is_binary(value), do: {:lit, {:text, value}}

  @doc "`NULL`."
  @spec null() :: IR.t()
  def null, do: {:lit, nil}

  @doc "`nullif(left, right)` for two texts."
  @spec nullif(IR.t(), IR.t()) :: IR.t()
  def nullif(left, right), do: {:apply, Value, :nullif, [left, right]}

  @doc "`coalesce(arg, ...)`, see `PolicyEval.Value.coalesce/1`."
  @spec coalesce([IR.t()]) :: IR.t()
  def coalesce([_ | _] = args), do: {:coalesce, args}

  @doc "The text `text` cast to uuid, `text::uuid`."
  @spec to_uuid(IR.t()) :: IR.t()
  def to_uuid(text), do: {:apply, Value, :uuid_in, [text]}

  @doc "The text `text` cast to jsonb, `text::jsonb`."
  @spec to_jsonb(IR.t()) :: IR.t()
  def to_jsonb(text), do: {:apply, Jsonb, :parse, [text]}

  @doc "The field `key` of `jsonb` as text, `jsonb ->> 'key'`."
  @spec field_text(IR.t(), String.t()) :: IR.t()
  def field_text(jsonb, key) when is_binary(key), do: {:apply, Jsonb, :object_field_text, [jsonb, text(key)]}
end
