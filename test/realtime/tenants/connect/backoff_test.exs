defmodule Realtime.Tenants.Connect.BackoffTest do
  use Realtime.DataCase, async: true
  alias Realtime.Tenants.Connect.Backoff

  setup do
    {:ok, acc: %{tenant_id: random_string()}}
  end

  test "does not apply backoff for a given tenant if never called", %{acc: acc} do
    assert {:ok, acc} == Backoff.run(acc)
  end

  test "applies backoff if the user as called more than once during the configured space", %{acc: acc} do
    # emulate calls
    for _ <- 1..10, do: Backoff.run(acc)

    assert {:error, :tenant_connect_backoff} = Backoff.run(acc)
  end

  @tag timeout: 130_000
  test "resets backoff after the configured space", %{acc: acc} do
    # emulate calls
    for _ <- 1..10, do: Backoff.run(acc)

    # emulate block
    assert {:error, :tenant_connect_backoff} = Backoff.run(acc)

    # wait for the timer to expire
    Process.sleep(70_000)

    # check that the backoff has been reset
    assert {:ok, acc} == Backoff.run(acc)
  end
end
