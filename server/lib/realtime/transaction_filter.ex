defmodule Realtime.TransactionFilter do
  alias Realtime.Adapters.Changes.Transaction

  defmodule(Filter, do: defstruct([:schema, :table, :condition]))

  require Logger

  @doc """
  Predicate to check if the filter matches the transaction.

  ## Examples

      iex> txn = %Transaction{changes: [
      ...>   %Realtime.Adapters.Changes.NewRecord{
      ...>     columns: [
      ...>       %Realtime.Decoder.Messages.Relation.Column{flags: [:key], name: "id", type: "int8", type_modifier: 4294967295},
      ...>       %Realtime.Decoder.Messages.Relation.Column{flags: [], name: "details", type: "text", type_modifier: 4294967295},
      ...>       %Realtime.Decoder.Messages.Relation.Column{flags: [], name: "user_id", type: "int8", type_modifier: 4294967295}
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

  """
  def matches?(%{event: event, relation: relation}, %Transaction{changes: changes}) do
    case parse_relation_filter(relation) do
      {:ok, filter} ->
	Enum.any?(changes, fn change -> change_matches(event, filter, change) end)
      {:error, msg} ->
	Logger.warn("Could not parse relation filter: #{inspect msg}")
	false
    end

  end
  # malformed filter or txn. Should not match.
  def matches?(_filter, _txn), do: false

  defp change_matches(event, filter, %{type: type} = change) when event != type and event != "*" do
    false
  end

  defp change_matches(event, filter, %{type: ct} = change) do
    name_matches(filter.schema, change.schema) and name_matches(filter.table, change.table)
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

  defp name_matches(nil, change_name), do: true
  defp name_matches(filter_name, change_name) do
    filter_name == change_name
  end
end
