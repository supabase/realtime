defmodule Realtime.Tenants.Connect.PiperTest do
  use ExUnit.Case, async: true
  alias Realtime.Tenants.Connect.Piper

  defmodule Piper1 do
    @behaviour Piper
    def run(acc), do: {:ok, Map.put(acc, :piper1, "Piper1")}
  end

  defmodule Piper2 do
    @behaviour Piper
    def run(acc), do: Map.get(acc, :piper1) && {:ok, Map.put(acc, :piper2, "Piper2")}
  end

  defmodule Piper3 do
    @behaviour Piper
    def run(acc), do: Map.get(acc, :piper2) && {:ok, Map.put(acc, :piper3, "Piper3")}
  end

  defmodule PiperErr do
    @behaviour Piper
    def run(_acc), do: {:error, "PiperErr"}
  end

  defmodule PiperBadReturn do
    @behaviour Piper
    def run(_acc), do: nil
  end

  defmodule PiperException do
    @behaviour Piper
    def run(_acc), do: raise("PiperException")
  end

  @pipeline [
    Realtime.Tenants.Connect.PiperTest.Piper1,
    Realtime.Tenants.Connect.PiperTest.Piper2,
    Realtime.Tenants.Connect.PiperTest.Piper3
  ]
  test "runs pipeline as expected and accumlates outputs" do
    assert {:ok,
            %{
              piper1: "Piper1",
              piper2: "Piper2",
              piper3: "Piper3",
              initial: "state"
            }} = Piper.run(@pipeline, %{initial: "state"})
  end

  test "runs pipeline and handles error" do
    assert {:error, "PiperErr"} =
             Piper.run(@pipeline ++ [Realtime.Tenants.Connect.PiperTest.PiperErr], %{
               initial: "state"
             })
  end

  test "runs pipeline and handles bad return with raise" do
    assert_raise ArgumentError, fn ->
      Piper.run(@pipeline ++ [Realtime.Tenants.Connect.PiperTest.PiperBadReturn], %{})
    end
  end

  test "on pipeline job function, raises exception" do
    assert_raise RuntimeError, fn ->
      Piper.run(@pipeline ++ [Realtime.Tenants.Connect.PiperTest.PiperException], %{})
    end
  end
end
