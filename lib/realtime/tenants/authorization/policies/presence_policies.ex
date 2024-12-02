defmodule Realtime.Tenants.Authorization.Policies.PresencePolicies do
  @moduledoc """
    PresencePolicies structure that holds the required authorization information for a given connection within the scope of a tracking / receiving presence messages
  """
  require Logger

  defstruct read: false, write: false

  @type t :: %__MODULE__{
          read: boolean(),
          write: boolean()
        }
end
