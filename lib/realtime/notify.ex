defmodule Realtime.Notify do
  use GenServer

  require Logger

  # import Jason

  @doc """
  Initialize the GenServer
  """
  @spec start_link([String.t], [any])  :: {:ok, pid}
  def start_link(channel, otp_opts \\ []), do: GenServer.start_link(__MODULE__, channel, otp_opts)

  @doc """
  When the GenServer starts subscribe to the given channel
  """
  @spec init([String.t])  :: {:ok, []}
  def init(channel) do
    Logger.debug("Starting #{ __MODULE__ } with channel subscription: #{channel}")
    pg_config = Realtime.Repo.config()
    {:ok, pid} = Postgrex.Notifications.start_link(pg_config)
    {:ok, ref} = Postgrex.Notifications.listen(pid, channel)
    {:ok, {pid, channel, ref}}
  end

  @doc """
  Listen for changes
  """
  def handle_info({:notification, _pid, _ref, "db_changes", payload}, _state) do
    # IO.puts "NOTIFY #{payload}"
    # Logger.debug("NOTIFY #{payload}")
    RealtimeWeb.NotifyChannel.handle_info(Jason.decode!(payload))
    {:noreply, :event_handled}
  end

  def handle_info(_, _state), do: {:noreply, :event_received}
end