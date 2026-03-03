defmodule Realtime.PrometheusRemoteWriteTest do
  use ExUnit.Case, async: true

  alias Realtime.PrometheusRemoteWrite

  describe "encode/2 with beam metrics" do
    test "encodes successfully and produces non-empty compressed binary" do
      assert {:ok, binary} =
               PrometheusRemoteWrite.encode(PrometheusFixtures.beam_metrics(), PrometheusFixtures.timestamp())

      assert byte_size(binary) > 0
    end

    test "encodes larger payload for four memory type series" do
      {:ok, binary_multi} =
        PrometheusRemoteWrite.encode(PrometheusFixtures.beam_metrics(), PrometheusFixtures.timestamp())

      single_metric = "beam_memory_bytes{type=\"total\"} 52428800.0 #{PrometheusFixtures.timestamp()}\n"
      {:ok, binary_single} = PrometheusRemoteWrite.encode(single_metric, PrometheusFixtures.timestamp())

      assert byte_size(binary_multi) > byte_size(binary_single)
    end
  end

  describe "encode/2 with phoenix metrics" do
    test "encodes histogram payload without error" do
      assert {:ok, binary} =
               PrometheusRemoteWrite.encode(PrometheusFixtures.phoenix_metrics(), PrometheusFixtures.timestamp())

      assert is_binary(binary)
    end
  end

  describe "encode/2 with tenant connection metrics" do
    test "encodes successfully" do
      assert {:ok, binary} =
               PrometheusRemoteWrite.encode(
                 PrometheusFixtures.tenant_connection_metrics(),
                 PrometheusFixtures.timestamp()
               )

      assert byte_size(binary) > 0
    end

    test "two tenants produce a larger payload than one tenant" do
      {:ok, binary_two} =
        PrometheusRemoteWrite.encode(
          PrometheusFixtures.tenant_connection_metrics(),
          PrometheusFixtures.timestamp()
        )

      single_tenant = """
      # TYPE realtime_connections_connected gauge
      realtime_connections_connected{tenant="tenant-abc-123"} 42.0 #{PrometheusFixtures.timestamp()}
      """

      {:ok, binary_one} = PrometheusRemoteWrite.encode(single_tenant, PrometheusFixtures.timestamp())

      assert byte_size(binary_two) > byte_size(binary_one)
    end
  end

  describe "encode/2 with channel error metrics" do
    test "encodes counter metrics successfully" do
      assert {:ok, binary} =
               PrometheusRemoteWrite.encode(
                 PrometheusFixtures.channel_error_metrics(),
                 PrometheusFixtures.timestamp()
               )

      assert byte_size(binary) > 0
    end
  end

  describe "encode/2 with full combined payloads" do
    test "global payload encodes without error" do
      assert {:ok, binary} =
               PrometheusRemoteWrite.encode(PrometheusFixtures.full_global_payload(), PrometheusFixtures.timestamp())

      assert byte_size(binary) > 0
    end

    test "tenant payload encodes without error" do
      assert {:ok, binary} =
               PrometheusRemoteWrite.encode(PrometheusFixtures.full_tenant_payload(), PrometheusFixtures.timestamp())

      assert byte_size(binary) > 0
    end

    test "combined payload is larger than either part alone" do
      {:ok, binary_global} =
        PrometheusRemoteWrite.encode(PrometheusFixtures.full_global_payload(), PrometheusFixtures.timestamp())

      {:ok, binary_tenant} =
        PrometheusRemoteWrite.encode(PrometheusFixtures.full_tenant_payload(), PrometheusFixtures.timestamp())

      {:ok, binary_combined} =
        PrometheusRemoteWrite.encode(
          PrometheusFixtures.full_global_payload() <> PrometheusFixtures.full_tenant_payload(),
          PrometheusFixtures.timestamp()
        )

      assert byte_size(binary_combined) > byte_size(binary_global)
      assert byte_size(binary_combined) > byte_size(binary_tenant)
    end
  end

  describe "encode/2 error cases" do
    test "returns error tuple for invalid timestamp" do
      assert {:error, reason} = PrometheusRemoteWrite.encode("my_gauge 1.0\n", -99_999_999_999_999_999)
      assert reason =~ "invalid timestamp"
    end

    test "returns ok with empty payload for empty input" do
      assert {:ok, binary} = PrometheusRemoteWrite.encode("", PrometheusFixtures.timestamp())
      assert is_binary(binary)
    end
  end
end
