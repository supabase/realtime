defmodule RealtimeWeb.InspectorLive.Index do
  use RealtimeWeb, :live_view

  defmodule Message do
    use Ecto.Schema
    import Ecto.Changeset

    schema "f" do
      field(:event, :string)
      field(:payload, :string)
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [:event, :payload])
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Message.changeset(%Message{event: "test", payload: ~s({"some":"data"})})

    socket =
      socket
      |> assign(changeset: changeset)
      |> assign(page_title: "Inspector - Supabase Realtime")
      |> assign(realtime_connected: false)
      |> assign(connected_to: nil)
      |> assign(postgres_subscribed: false)
      |> assign(presence_subscribed: false)
      |> assign(broadcast_subscribed: false)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", params, socket) do
    {:noreply, push_event(socket, "send_message", params)}
  end

  def handle_event("postgres_subscribed", _params, socket) do
    socket =
      socket
      |> assign(postgres_subscribed: true)

    {:noreply, socket}
  end

  def handle_event("presence_subscribed", params, socket) do
    socket =
      socket
      |> assign(presence_subscribed: true)

    {:noreply, socket}
  end

  def handle_event("broadcast_subscribed", %{"path" => path}, socket) do
    socket =
      socket
      |> assign(realtime_connected: true)
      |> assign(connected_to: path)
      |> assign(broadcast_subscribed: true)
      |> push_patch(to: Routes.inspector_index_path(socket, :index))

    {:noreply, socket}
  end
end
