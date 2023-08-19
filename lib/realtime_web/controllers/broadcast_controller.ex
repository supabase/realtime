defmodule RealtimeWeb.BroadcastController do
  use RealtimeWeb, :controller
  alias RealtimeWeb.Endpoint

  action_fallback(RealtimeWeb.FallbackController)

  defmodule Payload do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      embeds_many :messages, Message do
        field(:topic, :string)
        field(:payload, :map)
      end
    end

    def changeset(payload, attrs) do
      payload
      |> cast(attrs, [])
      |> cast_embed(:messages, required: true, with: &message_changeset/2)
    end

    def message_changeset(message, attrs) do
      message
      |> cast(attrs, [:topic, :payload])
      |> validate_required([:topic, :payload])
    end
  end

  def broadcast(%{assigns: %{tenant: %{external_id: tenant}}} = conn, attrs) do
    with %Ecto.Changeset{valid?: true} = changeset <- Payload.changeset(%Payload{}, attrs),
         %Ecto.Changeset{changes: %{messages: messages}} <- changeset do
      for %{changes: %{topic: sub_topic, payload: payload}} <- messages do
        Task.Supervisor.async(Realtime.TaskSupervisor, fn ->
          tenant_topic = "#{tenant}:#{sub_topic}"
          Endpoint.broadcast_from(self(), tenant_topic, "broadcast", payload)
        end)
      end

      conn
      |> put_status(202)
      |> text("")
    end
  end
end
