defmodule RealtimeWeb.InspectorLive.Index do
  use RealtimeWeb, :live_view

  defmodule Connection do
    use Ecto.Schema
    import Ecto.Changeset

    schema "f" do
      field(:log_level, :string)
      field(:token, :string)
      field(:path, :string)
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [:log_level, :token, :path])
    end
  end

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
    conn_changeset = Connection.changeset(%Connection{})
    message_changeset = Message.changeset(%Message{})

    socket =
      socket
      |> assign(subscribed_state: "Connect")
      |> assign(conn_changeset: conn_changeset)
      |> assign(message_changeset: message_changeset)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("connect", params, socket) do
    socket =
      socket
      |> assign(subscribed_state: "Connecting...")
      |> push_event("connect", params)

    {:noreply, socket}
  end

  def handle_event("subscribed", _params, socket) do
    {:noreply, assign(socket, subscribed_state: "Connected")}
  end

  def handle_event("send_message", params, socket) do
    {:noreply, push_event(socket, "send_message", params)}
  end

  def handle_event("local_storage", params, socket) do
    conn_changeset = Connection.changeset(%Connection{}, params)

    {:noreply, assign(socket, conn_changeset: conn_changeset)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Inspector - Supabase Realtime")
  end
end
