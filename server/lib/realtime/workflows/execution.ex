defmodule Realtime.Workflows.Execution do
  @moduledoc """
  A workflow execution, starts the workflow with the given arguments.

  ## Fields

   * `id`: the execution unique id.
   * `arguments`: a JSON dictionary containing the arguments passed to the workflow starting state, or the specified state.
   * `execution_type`: the execution type, either `:persistent` or `:transient`. Persistent executions are guaranteed to
     finish, while transient executions are not.
   * `workflow`: the workflow this execution executed.

  ## Execution Type

  ### Persistent Execution

  Persistent executions are guaranteed to finish (either successfully or with an error), they achieve this by storing
  their events to storage. State can be recovered from the events.
  The tradeoff is that each executions will generate additional load on the database since events need to be persisted
  to storage.

  ### Transient Execution

  Transient executions are not guaranteed to be run to completion. If, for example, the realtime application is
  restarted while the workflow execution is in progress, the execution will not be restarted together with the
  application. The advantage of transient executions is that they do not write additional to the database (except the
  data required to store the execution). Transient executions should be used for low-value or frequent events.
  """
  use Ecto.Schema

  alias Ecto.Changeset

  @schema_prefix Application.get_env(:realtime, :workflows_db_schema)

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @derive {Phoenix.Param, key: :id}

  @required_fields ~w(arguments)a
  @optional_fields ~w(execution_type)a

  @type t :: %__MODULE__{
    id: Ecto.UUID.t()
  }

  schema "executions" do
    field :arguments, :map
    field :execution_type, Ecto.Enum, values: [:persistent, :transient]

    timestamps()

    belongs_to :revision, Realtime.Workflows.Revision, type: Ecto.UUID
  end

  @doc false
  def create_changeset(execution, revision, params \\ %{}) do
    changeset(execution, params)
    |> put_revision(revision)
  end

  @doc """
  Returns a transaction filter that matches this table.
  """
  def transaction_filter do
    "#{%__MODULE__{}.__meta__.prefix}:#{%__MODULE__{}.__meta__.source}"
  end

  ## Private

  defp changeset(execution, params \\ %{}) do
    execution
    |> Changeset.cast(params, @required_fields ++ @optional_fields)
    |> Changeset.validate_required(@required_fields)
  end

  defp put_revision(changeset, revision) do
    changeset
    |> Changeset.change(%{revision_id: revision.id})
  end
end
