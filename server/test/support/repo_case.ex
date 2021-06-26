defmodule RealtimeWeb.RepoCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require a Realtime.Repo.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Realtime.Repo

      import Ecto
      import Ecto.Query
      import RealtimeWeb.RepoCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Realtime.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, {:shared, self()})
    end

    :ok
  end
end
