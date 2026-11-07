defmodule Rollcall.Case do
  @moduledoc """
  Test harness for Rollcall.

  Each test gets a unique scope in the `:scope` context key, and its own
  instance of the library in the `:rollcall` context key. The instance has the
  default options. Two tests never share a tracker.
  A test that needs other options starts another instance with `unique_name/0`.
  Tests that do not use traces can set `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Rollcall.Case
    end
  end

  setup do
    rollcall = unique_name()
    start_supervised!({Rollcall, name: rollcall})

    {:ok, scope: unique_scope(), rollcall: rollcall}
  end

  @doc "Returns a scope that no other test uses."
  def unique_scope, do: "scope-#{System.unique_integer([:positive])}"

  @doc "Returns the name of an instance that no other test uses."
  def unique_name, do: :"rollcall-#{System.unique_integer([:positive])}"
end
