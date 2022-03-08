defmodule Ewalrus do
  require Logger

  alias Ewalrus.SubscriptionManager

  @moduledoc """
  Documentation for `Ewalrus`.
  """

  @doc """
  Start db poller.

  """
  @spec start(String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :already_started}
  def start(
        scope,
        host,
        db_name,
        db_user,
        db_pass,
        poll_interval \\ 500,
        publication \\ "supabase_multiplayer",
        slot_name \\ "supabase_multiplayer_replication_slot"
      ) do
    IO.inspect({12_312_312})

    case :global.whereis_name({:supervisor, scope}) do
      :undefined ->
        opts = [
          id: scope,
          db_host: host,
          db_name: db_name,
          db_user: db_user,
          db_pass: db_pass,
          poll_interval: poll_interval,
          publication: publication,
          slot_name: slot_name
        ]

        {:ok, pid} =
          DynamicSupervisor.start_child(Ewalrus.RlsSupervisor, %{
            id: scope,
            start: {Ewalrus.DbSupervisor, :start_link, [opts]},
            restart: :transient
          })

        :global.register_name({:supervisor, scope}, pid)

      _ ->
        {:error, :already_started}
    end
  end

  def subscribe(scope, subs_id, topic, claims) do
    pid = manager_pid(scope)

    if pid do
      opts = %{
        topic: topic,
        id: subs_id,
        claims: claims
      }

      # TODO: move inside to SubscriptionManager
      bin_subs_id = UUID.string_to_binary!(subs_id)
      :syn.join(Ewalrus.Subscribers, scope, self(), bin_subs_id)
      SubscriptionManager.subscribe(pid, opts)
    end
  end

  def unsubscribe(scope, subs_id) do
    pid = manager_pid(scope)
    me = self()

    if pid do
      SubscriptionManager.unsubscribe(pid, subs_id)

      case :syn.members(Ewalrus.Subscribers, scope) do
        [{^me, ^subs_id}] ->
          stop(scope)

        _ ->
          :ok
      end
    end
  end

  def stop(scope) do
    case :global.whereis_name({:supervisor, scope}) do
      :undefined ->
        nil

      pid ->
        :global.whereis_name({:db_instance, scope})
        |> GenServer.stop(:normal)

        Supervisor.stop(pid, :normal)
    end
  end

  @spec manager_pid(any()) :: pid() | nil
  defp manager_pid(scope) do
    case :global.whereis_name({:subscription_manager, scope}) do
      :undefined ->
        nil

      pid ->
        pid
    end
  end

  def dummy_params() do
    %{
      claims: %{
        "aud" => "authenticated",
        "email" => "jwt@test.com",
        "exp" => 1_663_819_211,
        "iat" => 1_632_283_191,
        "iss" => "supabase",
        "role" => "authenticated",
        "sub" => "bbb51e4e-f371-4463-bf0a-af8f56dc9a73"
      },
      id: UUID.uuid1(),
      topic: "public"
    }
  end
end
