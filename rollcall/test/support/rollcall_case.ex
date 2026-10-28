defmodule Rollcall.Case do
  @moduledoc """
  Test harness for Rollcall.

  Each test gets a unique scope in the `:scope` context key.
  Two tests never share a tracker.
  Tests that do not use traces can set `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Rollcall.Case
    end
  end

  setup do
    {:ok, scope: unique_scope()}
  end

  @doc "Returns a scope that no other test uses."
  def unique_scope, do: "scope-#{System.unique_integer([:positive])}"
end
