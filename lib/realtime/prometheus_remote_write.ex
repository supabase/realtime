defmodule Realtime.PrometheusRemoteWrite do
  @moduledoc false
  use Rustler, otp_app: :realtime, crate: "prometheus_remote_write", mode: :release

  def encode(_text, _timestamp_ms), do: :erlang.nif_error(:nif_not_loaded)
  def decode(_bytes), do: :erlang.nif_error(:nif_not_loaded)
end
