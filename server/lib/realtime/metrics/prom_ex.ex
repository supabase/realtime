defmodule Realtime.Metrics.PromEx do
  use PromEx, otp_app: :realtime

  @impl true
  def plugins do
    [Realtime.Metrics.PromEx.Plugins.Realtime]
  end
end
