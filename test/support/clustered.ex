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
    tenant = Containers.checkout_tenant()
    {:ok, node} = Clustered.start(@aux_mod)
    assert ok = :rpc.call(node, Aux, :checker, [:ok])
  end
  ```
  """
  def start(aux_mod \\ nil) do
    :net_kernel.start([:"main@127.0.0.1"])
    :erlang.set_cookie(:cookie)

    {:ok, pid, node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io
      })

    :peer.call(pid, :erlang, :set_cookie, [:cookie])

    Node.connect(node)

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])

    for {app_name, _, _} <- Application.loaded_applications(),
        {key, val} <- Application.get_all_env(app_name) do
      :ok = :erpc.call(node, Application, :put_env, [app_name, key, val])
    end

    # We need to override this value as the current implementation overrides the string with a map leading to errors
    :ok = :erpc.call(node, Application, :put_env, [:realtime, :jwt_claim_validators, "{}"])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:mix])
    :ok = :erpc.call(node, Mix, :env, [Mix.env()])

    Enum.map(
      [:logger, :runtime_tools, :prom_ex, :mix, :os_mon, :realtime],
      fn app -> {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [app]) end
    )

    if aux_mod do
      {{:module, _, _, _}, []} = :erpc.call(node, Code, :eval_quoted, [aux_mod])
    end

    {:ok, node}
  end

  def stop() do
    Node.stop()
  end
end
