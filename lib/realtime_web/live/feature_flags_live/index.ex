defmodule RealtimeWeb.FeatureFlagsLive.Index do
  use RealtimeWeb, :live_view

  alias Realtime.FeatureFlags
  alias Realtime.FeatureFlags.Cache
  alias RealtimeWeb.Endpoint

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Endpoint.subscribe("feature_flags")

    {:ok, assign(socket, flags: FeatureFlags.list_flags(), new_name: "")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, "Feature Flags")}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    flag = Enum.find(socket.assigns.flags, &(&1.id == id))

    case FeatureFlags.upsert_flag(%{name: flag.name, enabled: !flag.enabled}) do
      {:ok, updated} ->
        Cache.global_revalidate(updated)
        Endpoint.broadcast_from(self(), "feature_flags", "updated", updated)
        flags = Enum.map(socket.assigns.flags, fn f -> if f.id == id, do: updated, else: f end)
        {:noreply, assign(socket, flags: flags)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create", %{"name" => name}, socket) when name != "" do
    case FeatureFlags.upsert_flag(%{name: String.trim(name), enabled: false}) do
      {:ok, flag} ->
        Cache.global_revalidate(flag)
        Endpoint.broadcast_from(self(), "feature_flags", "updated", flag)
        flags = Enum.sort_by([flag | socket.assigns.flags], & &1.name)
        {:noreply, assign(socket, flags: flags, new_name: "")}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    flag = Enum.find(socket.assigns.flags, &(&1.id == id))

    case FeatureFlags.delete_flag(flag) do
      {:ok, _} ->
        Cache.distributed_invalidate_cache(flag.name)
        Endpoint.broadcast_from(self(), "feature_flags", "deleted", %{name: flag.name})
        {:noreply, assign(socket, flags: Enum.reject(socket.assigns.flags, &(&1.id == id)))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "updated", payload: updated}, socket) do
    flags =
      if Enum.any?(socket.assigns.flags, &(&1.id == updated.id)) do
        Enum.map(socket.assigns.flags, fn f -> if f.id == updated.id, do: updated, else: f end)
      else
        Enum.sort_by([updated | socket.assigns.flags], & &1.name)
      end

    {:noreply, assign(socket, flags: flags)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "deleted", payload: %{name: name}}, socket) do
    flags = Enum.reject(socket.assigns.flags, &(&1.name == name))
    {:noreply, assign(socket, flags: flags)}
  end
end
