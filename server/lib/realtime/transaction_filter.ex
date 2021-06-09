defmodule Realtime.TransactionFilter do
  alias Realtime.Adapters.Changes.Transaction

  defmodule(Filter, do: defstruct([:schema, :table, :condition]))

  require Logger

  @doc """
  Predicate to check if the filter matches the transaction.

  ## Options

   * `:strict` - The `filter` needs to match exactly on the specified schemas and tables.
     If the filter catches all changes on a schema or table, and the table is in the strict list (either because the
     schema or the table are in the strict list), then this function returns `false`.

  ## Examples

      iex> txn = %Transaction{changes: [
      ...>   %Realtime.Adapters.Changes.NewRecord{
      ...>     columns: [
      ...>       %Realtime.Adapters.Postgres.Decoder.Messages.Relation.Column{flags: [:key], name: "id", type: "int8", type_modifier: 4294967295},
      ...>       %Realtime.Adapters.Postgres.Decoder.Messages.Relation.Column{flags: [], name: "details", type: "text", type_modifier: 4294967295},
      ...>       %Realtime.Adapters.Postgres.Decoder.Messages.Relation.Column{flags: [], name: "user_id", type: "int8", type_modifier: 4294967295}
      ...>     ],
      ...>     commit_timestamp: nil,
      ...>     record: %{"details" => "The SCSI system is down, program the haptic microchip so we can back up the SAS circuit!", "id" => "14", "user_id" => "1"},
      ...>     schema: "public",
      ...>     table: "todos",
      ...>     type: "INSERT"
      ...>   }
      ...> ]}
      iex> matches?(%{event: "*", relation: "*"}, txn)
      true
      iex> matches?(%{event: "INSERT", relation: "*"}, txn)
      true
      iex> matches?(%{event: "UPDATE", relation: "*"}, txn)
      false
      iex> matches?(%{event: "INSERT", relation: "public"}, txn)
      true
      iex> matches?(%{event: "INSERT", relation: "myschema"}, txn)
      false
      iex> matches?(%{event: "INSERT", relation: "public:todos"}, txn)
      true
      iex> matches?(%{event: "INSERT", relation: "myschema:users"}, txn)
      false
      iex> matches?(%{event: "INSERT", relation: "public:todos"}, txn, strict: ["public:todos"])
      true
      iex> matches?(%{event: "INSERT", relation: "*"}, txn, strict: ["public:todos"])
      false
      iex> matches?(%{event: "INSERT", relation: "*"}, txn, strict: ["myschema:todos"])
      true
      iex> matches?(%{event: "INSERT", relation: "public"}, txn, strict: ["public"])
      false
      iex> matches?(%{event: "INSERT", relation: "public"}, txn, strict: ["*"])
      false

  """
  def matches?(filter, txn, opts \\ []), do: do_matches?(filter, txn, opts)

  defp do_matches?(%{event: event, relation: relation}, %Transaction{changes: changes}, opts) do
    case parse_relation_filter(relation) do
      {:ok, filter} ->
        Enum.any?(changes, fn change -> change_matches(event, filter, change, opts) end)
      {:error, msg} ->
        Logger.warn("Could not parse relation filter: #{inspect msg}")
        false
    end

  end
  # malformed filter or txn. Should not match.
  defp do_matches?(_filter, _txn, _opts), do: false

  defp change_matches(event, _filter, %{type: type}, _opts) when event != type and event != "*" do
    false
  end

  defp change_matches(_event, filter, change, opts) do
    strict_changes = Keyword.get(opts, :strict, [])
    strict_changes =
      for strict_filter <- strict_changes,
          {:ok, strict_filter} = parse_relation_filter(strict_filter) do
        strict_filter
      end
    strict? =
      strict_changes
      |> Enum.any?(fn strict_filter -> filter_matches_change(strict_filter, change) end)
    filter_matches_change(filter, change, strict?)
  end

  defp filter_matches_change(filter, change),
       do: filter_matches_change(filter, change, false)

  defp filter_matches_change(filter, change, strict?) do
    name_matches(filter.schema, change.schema, strict?) and
    name_matches(filter.table, change.table, strict?)
  end


  @doc """
  Parse a string representing a relation filter to a `Filter` struct.

  ## Examples

      iex> parse_relation_filter("public:users")
      {:ok, %Filter{schema: "public", table: "users", condition: nil}}

      iex> parse_relation_filter("public")
      {:ok, %Filter{schema: "public", table: nil, condition: nil}}


      iex> parse_relation_filter("")
      {:ok, %Filter{schema: nil, table: nil, condition: nil}}

      iex> parse_relation_filter("public:users:bad")
      {:error, "malformed relation filter"}

  """
  def parse_relation_filter(relation) do
    # We do a very loose validation here.
    # When the relation filter format is well defined we can do
    # proper parsing and validation.
    case String.split(relation, ":") do
      [""] -> {:ok, %Filter{schema: nil, table: nil, condition: nil}}
      ["*"] -> {:ok, %Filter{schema: nil, table: nil, condition: nil}}
      [schema] -> {:ok, %Filter{schema: schema, table: nil, condition: nil}}
      [schema, table] -> {:ok, %Filter{schema: schema, table: table, condition: nil}}
      _ -> {:error, "malformed relation filter"}
    end
  end

  defp name_matches(nil, _change_name, true), do: false # in strict mode, catch-all should not match
  defp name_matches(nil, _change_name, false), do: true
  defp name_matches(filter_name, change_name, _strict) do
    filter_name == change_name
  end
end
