defmodule RealtimeWeb.InspectorLive.Index do
  use RealtimeWeb, :live_view

  alias RealtimeWeb.InspectorLive.ConnComponent

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
      |> validate_required([:event, :payload])
      |> validate_change(:payload, fn :payload, payload ->
        case Jason.decode(payload) do
          {:ok, _} -> []
          {:error, %Jason.DecodeError{} = error} -> [payload: "invalid JSON: #{Exception.message(error)}"]
        end
      end)
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Message.changeset(%Message{event: "test", payload: ~s({"some":"data"})})

    socket =
      socket
      |> assign(active_nav: :inspector)
      |> assign(changeset: changeset)
      |> assign(page_title: "Inspector - Supabase Realtime")
      |> assign(health: health_idle())
      |> assign(share_url: nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Only the non-secret connection shape lives in the URL; the component merges these onto its
    # existing changeset so a typed token/bearer isn't wiped on every validate round-trip.
    send_update(ConnComponent, id: :conn, url_params: params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => message_params}, socket) do
    case Ecto.Changeset.apply_action(Message.changeset(%Message{}, message_params), :validate) do
      {:ok, message} ->
        socket =
          push_event(socket, "send_message", %{
            "message" => %{"event" => message.event, "payload" => Jason.decode!(message.payload)}
          })

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("transport_status", %{"status" => status} = params, socket) do
    socket =
      case status do
        "ok" ->
          update_health(socket, :transport, &%{&1 | status: :open, rtt_ms: params["latency_ms"], reason: nil})

        "sent" ->
          update_health(socket, :transport, fn t ->
            if t.status == :idle, do: %{t | status: :connecting}, else: t
          end)

        "disconnected" ->
          assign(socket, :health, health_idle())

        error_status when error_status in ["error", "timeout"] ->
          update_health(socket, :transport, &%{&1 | status: :error, reason: error_status})
      end

    {:noreply, socket}
  end

  def handle_event("channel_status", %{"status" => status} = params, socket) do
    socket =
      case status do
        "joining" ->
          update_health(socket, :channel, &%{&1 | status: :joining, reason: nil})

        "joined" ->
          socket
          |> update_health(:channel, fn c ->
            %{c | status: :joined, joined_at: DateTime.utc_now(), host: params["host"], reason: nil}
          end)
          |> update_health(:broadcast, fn _ -> %{status: :active} end)

        "errored" ->
          update_health(socket, :channel, &%{&1 | status: :errored, reason: params["reason"]})

        "timed_out" ->
          update_health(socket, :channel, &%{&1 | status: :timed_out, reason: nil})

        "closed" ->
          assign(socket, :health, health_idle())
      end

    send_update(ConnComponent, id: :conn, subscribed_state: subscribed_state(status))

    {:noreply, socket}
  end

  def handle_event("presence_synced", %{"count" => count}, socket) do
    {:noreply, update_health(socket, :presence, fn _ -> %{status: :synced, count: count} end)}
  end

  def handle_event("postgres_subscribed", %{"schema" => schema, "table" => table, "filter" => filter}, socket) do
    socket =
      update_health(socket, :postgres, fn _ ->
        %{status: :subscribed, schema: schema, table: table, filter: filter, reason: nil}
      end)

    {:noreply, socket}
  end

  def handle_event("postgres_error", %{"reason" => reason}, socket) do
    {:noreply, update_health(socket, :postgres, &%{&1 | status: :error, reason: reason})}
  end

  @impl true
  def handle_info({:share_url, url}, socket) do
    {:noreply, assign(socket, share_url: url)}
  end

  defp update_health(socket, key, fun) do
    update(socket, :health, &Map.update!(&1, key, fun))
  end

  defp subscribed_state("joined"), do: "Reconnect"
  defp subscribed_state("joining"), do: "Connecting..."
  defp subscribed_state(_), do: "Connect"

  defp health_idle do
    %{
      transport: %{status: :idle, rtt_ms: nil, reason: nil},
      channel: %{status: :idle, joined_at: nil, host: nil, reason: nil},
      broadcast: %{status: :idle},
      presence: %{status: :idle, count: 0},
      postgres: %{status: :idle, schema: nil, table: nil, filter: nil, reason: nil}
    }
  end

  @doc false
  def status_variant(status) when status in [:open, :joined, :active, :synced, :subscribed], do: :success
  def status_variant(status) when status in [:connecting, :joining], do: :info
  def status_variant(status) when status in [:error, :errored, :timed_out], do: :error
  def status_variant(_), do: :neutral

  @doc false
  def status_pulse?(status), do: status in [:connecting, :joining]

  @doc false
  def channel_label(%{status: :joined, host: host}), do: "Connected to #{host}"
  def channel_label(%{status: :joining}), do: "Connecting..."
  def channel_label(%{status: :errored, reason: reason}), do: "Error: #{reason}"
  def channel_label(%{status: :timed_out}), do: "Timed out"
  def channel_label(_), do: "Not connected"

  @doc false
  def postgres_label(%{status: :subscribed, schema: schema, table: table}), do: "Subscribed: #{schema}.#{table}"
  def postgres_label(%{status: :error, reason: reason}), do: "Error: #{reason}"
  def postgres_label(_), do: "Not subscribed"
end
