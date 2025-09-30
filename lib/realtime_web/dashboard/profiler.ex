defmodule RealtimeWeb.Dashboard.Profiler do
  @moduledoc """
  Live Dashboard page to profile using Linux perf
  """

  use Phoenix.LiveDashboard.PageBuilder, refresher?: false
  alias Realtime.Profiler

  @impl true
  def menu_link(_, capabilities) do
    # case :os.type() do
    #   {:unix, :linux} -> {:ok, "Profiler"}
    #   _ -> {:disabled, "Profiler not available"}
    # end
    {:ok, "Profiler"}
  end

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:running?, Profiler.running?())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="prose">
      <h1>Profiler</h1>
      <%= if @running? do %>
        <div class="alert alert-info">
          Profiler is running
        </div>
      <% else %>
        <button phx-click="start_profiler" phx-value-enable="true" class="btn btn-primary" >
          Start Profiler
        </button>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("start_profiler", _params, socket) do
    Profiler.start()
    {:noreply, assign(socket, :running?, true)}
  end
end
