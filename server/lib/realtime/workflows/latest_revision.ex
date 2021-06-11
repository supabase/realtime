defmodule Realtime.Workflows.LatestRevision do
  @moduledoc """
  A workflow revision contains an immutable workflow definition.

  Workflow definitions need to be immutable since workflows can run for prolonged period of times,
  a change in the definition would invalidate all workflow executions.
  """
  use Ecto.Schema

  require Logger


  @schema_prefix Application.get_env(:realtime, :workflows_db_schema)

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @derive {Phoenix.Param, key: :id}


  schema "latest_revisions" do
    field(:version, :integer)
    field(:definition, :map)

    timestamps()

    belongs_to(:workflow, Realtime.Workflows.Workflow, type: Ecto.UUID)
    has_many(:executions, Realtime.Workflows.Execution)
  end

end
