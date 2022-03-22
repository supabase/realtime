defmodule Multiplayer.SynHandler do
  @behaviour :syn_event_handler

  require Logger

  @impl true
  def on_process_left(Ewalrus.Subscribers, tenant, pid, %{bin_id: subs_id}, _reason) do
    if node() == node(pid) do
      Logger.debug(
        "Subscriber is disconnected #{inspect([tenant: tenant, id: subs_id |> UUID.binary_to_string!()],
        pretty: true)}"
      )

      Ewalrus.unsubscribe(tenant, subs_id)
    end
  end

  def on_process_left(_scope, _group_name, _pid, _meta, _reason) do
    :ok
  end
end
