defmodule Realtime.Workflows.Revision do
  @moduledoc """
  A workflow revision contains an immutable workflow definition.

  Workflow definitions need to be immutable since workflows can run for prolonged period of times,
  a change in the definition would invalidate all workflow executions.
  """
  use Ecto.Schema

  alias Ecto.Changeset

  @schema_prefix Application.get_env(:realtime, :workflows_db_schema)

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @derive {Phoenix.Param, key: :id}

  @required_fields ~w(definition)a

  schema "revisions" do
    field :version, :integer
    field :definition, :map

    timestamps()

    belongs_to :workflow, Realtime.Workflows.Workflow, type: Ecto.UUID
    has_many :executions, Realtime.Workflows.Execution
  end

  @doc false
  def create_changeset(revision, workflow, version, params \\ %{}) do
    revision
    |> Changeset.cast(params, @required_fields)
    |> Changeset.put_change(:version, version)
    |> Changeset.put_change(:workflow_id, workflow.id)
  end
end