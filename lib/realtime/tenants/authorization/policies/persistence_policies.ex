defmodule Realtime.Tenants.Authorization.Policies.PersistencePolicies do
  @moduledoc """
  PersistencePolicies structure that holds whether a connection is authorized to persist messages for a given Topic.
  """
  defstruct write: nil

  @type t :: %__MODULE__{
          write: boolean() | nil
        }
end
