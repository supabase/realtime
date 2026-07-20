defmodule RealtimeWeb.InspectorLive.ConnComponent do
  use RealtimeWeb, :live_component

  @url_params ~w(host project channel schema table filter enable_presence enable_db_changes private_channel log_level)

  defmodule Connection do
    use Ecto.Schema
    import Ecto.Changeset

    schema "f" do
      field(:log_level, :string, default: "error")
      field(:token, :string)
      field(:host, :string)
      field(:project, :string)
      field(:channel, :string, default: "room_a")
      field(:schema, :string, default: "public")
      field(:table, :string, default: "*")
      field(:filter, :string)
      field(:bearer, :string)
      field(:enable_broadcast, :boolean, default: true)
      field(:enable_presence, :boolean, default: false)
      field(:enable_db_changes, :boolean, default: false)
      field(:private_channel, :boolean, default: false)
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [
        :log_level,
        :token,
        :host,
        :project,
        :channel,
        :schema,
        :table,
        :filter,
        :bearer,
        :enable_broadcast,
        :enable_presence,
        :enable_db_changes,
        :private_channel
      ])
      |> validate_required([:channel])
    end

    def submit_changeset(form, params \\ %{}) do
      form
      |> changeset(params)
      |> validate_required([:token])
      |> validate_host_or_project()
    end

    defp validate_host_or_project(changeset) do
      if get_field(changeset, :host) in [nil, ""] and get_field(changeset, :project) in [nil, ""] do
        add_error(changeset, :project, "can't be blank")
      else
        changeset
      end
    end
  end

  @impl true
  def mount(socket) do
    changeset = Connection.changeset(%Connection{})

    socket =
      socket
      |> assign(subscribed_state: "Connect")
      |> assign(changeset: changeset)
      |> assign(url_params: %{})
      |> assign(connected_snapshot: nil)

    {:ok, socket}
  end

  @impl true
  def update(%{url_params: params} = assigns, socket) do
    # Preserve any already-entered secrets (they never travel in the URL) while applying the
    # non-secret shape coming from the URL.
    current = socket.assigns.changeset
    token = Ecto.Changeset.get_field(current, :token)
    bearer = Ecto.Changeset.get_field(current, :bearer)

    merged =
      params
      |> Map.put("token", token)
      |> Map.put("bearer", bearer)
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    socket =
      socket
      |> assign(Map.delete(assigns, :url_params))
      |> assign(:changeset, Connection.changeset(%Connection{}, merged))
      |> assign(:url_params, params)

    {:ok, socket}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate", %{"connection" => conn}, socket) do
    conn = derive_host(conn)
    changeset = Connection.changeset(%Connection{}, conn)

    socket =
      socket
      |> assign(changeset: changeset)
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :index, Map.take(conn, @url_params)),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("connect", %{"connection" => conn} = params, socket) do
    case Ecto.Changeset.apply_action(Connection.submit_changeset(%Connection{}, conn), :validate) do
      {:ok, connection} ->
        send_share_url(conn)

        socket =
          socket
          |> assign(changeset: Connection.changeset(%Connection{}, conn))
          |> assign(subscribed_state: "Connecting...")
          |> assign(connected_snapshot: connection)
          |> push_event("connect", params)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("disconnect", _params, socket) do
    socket =
      socket
      |> assign(subscribed_state: "Connect")
      |> assign(connected_snapshot: nil)
      |> push_event("disconnect", %{})

    {:noreply, socket}
  end

  def handle_event("clear_local_storage", _params, socket) do
    socket =
      socket
      |> assign(:changeset, Connection.changeset(%Connection{}))
      |> push_event("clear_local_storage", %{})
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :index),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("local_storage", params, socket) do
    params = Map.reject(params, fn {_, v} -> v in [nil, ""] end)
    changeset = Connection.changeset(socket.assigns.changeset, params)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("cancel", params, socket) do
    changeset = Connection.changeset(%Connection{}, params)

    {:noreply, assign(socket, changeset: changeset)}
  end

  defp stale_connection?(_changeset, nil), do: false

  defp stale_connection?(changeset, connected_snapshot) do
    Ecto.Changeset.apply_changes(changeset) != connected_snapshot
  end

  defp derive_host(%{"project" => project} = conn) when project not in [nil, ""] do
    Map.put(conn, "host", "https://#{project}.supabase.co")
  end

  defp derive_host(conn), do: conn

  defp send_share_url(conn) do
    url = Routes.inspector_index_url(RealtimeWeb.Endpoint, :index, Map.take(conn, @url_params))
    send(self(), {:share_url, url})
  end
end
