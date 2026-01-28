defmodule Clustered do
  @moduledoc """
  Uses the gist https://gist.github.com/ityonemo/177cbc96f8c8722bfc4d127ff9baec62 to start a node for testing
  """

  @doc """
  Starts a node for testing.

  Can receive an auxiliary module to be evaluated in the node so you are able to setup functions within the test context and outside of the normal code context

  e.g.
  ```
  @aux_mod (quote do
              defmodule Aux do
                def checker(res), do: res
              end
            end)

  Code.eval_quoted(@aux_mod)
  test "clustered call" do
    {:ok, node} = Clustered.start(@aux_mod)
    assert ok = :rpc.call(node, Aux, :checker, [:ok])
  end
  ```
  """
  @spec start(any(), keyword()) :: {:ok, node}
  def start(aux_mod \\ nil, opts \\ []) do
    {:ok, pid, node} = start_disconnected(aux_mod, opts)

    :ok = wait_for_gen_rpc(pid)

    true = Node.connect(node)

    max_clients = Application.get_env(:realtime, :max_gen_rpc_clients, 5)

    for key <- 1..max_clients do
      _ = :gen_rpc.call({node, key}, :erlang, :node, [], 5_000)
    end

    {:ok, node}
  end

  @doc """
  Similar to `start/2` but the node is not connected automatically
  """
  @spec start_disconnected(any(), keyword()) :: {:ok, :peer.server_ref(), node}
  def start_disconnected(aux_mod \\ nil, opts \\ []) do
    extra_config = Keyword.get(opts, :extra_config, [])
    phoenix_port = Keyword.get(opts, :phoenix_port, 4012)
    name = Keyword.get(opts, :name, :peer.random_name())

    :ok =
      case :net_kernel.start([:"main@127.0.0.1"]) do
        {:ok, _} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          raise "Failed to start node: #{inspect(reason)}"
      end

    true = :erlang.set_cookie(:cookie)

    {:ok, pid, node} =
      ExUnit.Callbacks.start_supervised(%{
        id: {:peer, name},
        start:
          {:peer, :start_link,
           [
             %{
               name: name,
               host: ~c"127.0.0.1",
               longnames: true,
               connection: :standard_io
             }
           ]}
      })

    :peer.call(pid, :erlang, :set_cookie, [:cookie])

    :ok = :peer.call(pid, :code, :add_paths, [:code.get_path()])

    # We need to load the app first as it has default app env that we want to override
    :ok = :peer.call(pid, Application, :ensure_loaded, [:gen_rpc])

    for {app_name, _, _} <- Application.loaded_applications(),
        {key, value} <- Application.get_all_env(app_name) do
      :ok = :peer.call(pid, Application, :put_env, [app_name, key, value])
    end

    endpoint = Application.get_env(:realtime, RealtimeWeb.Endpoint)

    :ok =
      :peer.call(pid, Application, :put_env, [
        :realtime,
        RealtimeWeb.Endpoint,
        Keyword.put(endpoint, :http, port: phoenix_port)
      ])

    # Configure gen_rpc swapping port definitons
    gen_rpc_tcp_server_port = Application.fetch_env!(:gen_rpc, :tcp_server_port)
    gen_rpc_tcp_client_port = Application.fetch_env!(:gen_rpc, :tcp_client_port)

    :ok = :peer.call(pid, Application, :put_env, [:gen_rpc, :tcp_server_port, gen_rpc_tcp_client_port])
    :ok = :peer.call(pid, Application, :put_env, [:gen_rpc, :tcp_client_port, gen_rpc_tcp_server_port])

    # We need to override this value as the current implementation overrides the string with a map leading to errors
    :ok = :peer.call(pid, Application, :put_env, [:realtime, :jwt_claim_validators, "{}"])

    # Override with extra config
    for {app_name, key, value} <- extra_config do
      :ok = :peer.call(pid, Application, :put_env, [app_name, key, value])
    end

    {:ok, _} = :peer.call(pid, Application, :ensure_all_started, [:gen_rpc])
    {:ok, _} = :peer.call(pid, Application, :ensure_all_started, [:mix])
    :ok = :peer.call(pid, Mix, :env, [Mix.env()])

    Enum.each(
      [:logger, :runtime_tools, :prom_ex, :mix, :os_mon, :realtime],
      fn app -> {:ok, _} = :peer.call(pid, Application, :ensure_all_started, [app]) end
    )

    if aux_mod do
      {{:module, _, _, _}, []} = :peer.call(pid, Code, :eval_quoted, [aux_mod])
    end

    {:ok, pid, node}
  end

  defp wait_for_gen_rpc(pid) do
    port = :peer.call(pid, Application, :get_env, [:gen_rpc, :tcp_server_port])

    case port do
      port when is_integer(port) and port > 0 -> wait_for_port({127, 0, 0, 1}, port, 50, 100)
      _ -> raise "gen_rpc tcp_server_port is not configured: #{inspect(port)}"
    end
  end

  defp wait_for_port(_host, _port, 0, _delay_ms), do: raise("gen_rpc tcp server did not start in time")

  defp wait_for_port(host, port, attempts, delay_ms) do
    case :gen_tcp.connect(host, port, [:binary, active: false], 200) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        Process.sleep(delay_ms)
        wait_for_port(host, port, attempts - 1, delay_ms)
    end
  end
end
