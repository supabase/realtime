defmodule Realtime.DNS do
  @moduledoc false
  def getaddrs(host, family, timeout), do: :inet.getaddrs(host, family, timeout)
end
