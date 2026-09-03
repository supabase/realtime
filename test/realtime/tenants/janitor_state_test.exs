defmodule Realtime.Tenants.JanitorStateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Realtime.Tenants.Janitor

  test "removes failed maintenance tasks from state" do
    for reason <- [:killed, {:shutdown, :failed}] do
      ref = make_ref()
      state = %Janitor{tasks: %{ref => ["tenant"]}}

      capture_log(fn ->
        assert {:noreply, result} =
                 Janitor.handle_info({:DOWN, ref, :process, self(), reason}, state)

        refute Map.has_key?(result.tasks, ref)
      end)
    end
  end
end
