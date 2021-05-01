defmodule Realtime.Workflows.Workflow do
  @moduledoc """
  Workflows represent a series of steps taken in response to an event.

  Workflows are defined using [Amazon States Language](https://states-language.net/), refer to the spec to understand
  the different types of states available.

  This table does not store the workflow definition, instead definitions are stored in the
  Revision table.

  ## Fields

   * `id`: the unique id of the workflow.
   * `name`: the human-readable name of the workflow.
   * `default_execution_type`: the execution type used when the workflow is started in response to a realtime event.
     Users can override the execution type when starting the workflow manually (for example, to debug it).
   * `revisions`: a list of definitions of this workflow.
  """
  use Ecto.Schema
  alias Ecto.Changeset
  alias Realtime.TransactionFilter

  @schema_prefix Application.get_env(:realtime, :workflows_db_schema)

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @derive {Phoenix.Param, key: :id}
  @required_fields ~w(name trigger default_execution_type)a

  schema "workflows" do
    field :name, :string
    field :trigger, :string
    field :default_execution_type, Ecto.Enum, values: [:persistent, :transient]

    timestamps()

    has_many :revisions, Realtime.Workflows.Revision
  end

  @doc false
  def create_changeset(workflow, params \\ %{}) do
    changeset(workflow, params)
  end

  @doc false
  def update_changeset(workflow, params \\ %{}) do
    changeset(workflow, params)
  end

  @doc """
  Returns a transaction filter that matches this table.
  """
  def transaction_filter do
    "#{%__MODULE__{}.__meta__.prefix}:#{%__MODULE__{}.__meta__.source}"
  end

  @doc """
  Returns the table name.
  """
  def table_name do
    %__MODULE__{}.__meta__.source
  end

  @doc """
  Returns the table schema.
  """
  def table_schema do
    %__MODULE__{}.__meta__.prefix
  end

  defp validate_trigger(field, trigger) do
    case TransactionFilter.parse_relation_filter(trigger) do
      {:ok, _} -> []
      _ -> [{field, "is invalid"}]
    end
  end

  defp changeset(workflow, params) do
    workflow
    |> Changeset.cast(params, @required_fields)
    |> Changeset.validate_required(@required_fields)
    |> Changeset.validate_length(:name, min: 5)
    |> Changeset.unique_constraint(:name)
    |> Changeset.validate_change(:trigger, &validate_trigger/2)
  end
end
