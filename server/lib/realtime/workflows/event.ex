defmodule Realtime.Workflows.Events do
  @moduledoc """
  Events generated during the execution of a workflow.

  Events are used to recover the state of a persistent workflow between restarts.
  """
  use Ecto.Schema

  alias Ecto.Changeset

  @schema_prefix Application.get_env(:realtime, :workflows_db_schema)

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @derive {Phoenix.Param, key: :id}

  @required_fields ~w(position event)a

  schema "events" do
    field :position, :integer
    field :event, :map

    timestamps()

    belongs_to :execution, Realtime.Workflows.Execution, type: Ecto.UUID
  end
end
