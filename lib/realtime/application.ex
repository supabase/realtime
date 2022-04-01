defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false

  defmodule JwtSecretError, do: defexception([:message])
  defmodule JwtClaimValidatorsError, do: defexception([:message])

  def start(_type, _args) do
    app_dir =
      if System.get_env("MIX_ENV") == "prod" do
        :code.root_dir()
      else
        "."
      end

    :ok = update_config_from_file("#{app_dir}/config.yml")
    topologies = Application.get_env(:libcluster, :topologies) || []

    if Application.fetch_env!(:realtime, :secure_channels) do
      case Application.fetch_env!(:realtime, :jwt_claim_validators) |> Jason.decode() do
        {:ok, claims} when is_map(claims) ->
          Application.put_env(:realtime, :jwt_claim_validators, claims)

        _ ->
          raise JwtClaimValidatorsError,
            message: "JWT claim validators is not a valid JSON object"
      end
    end

    Registry.start_link(keys: :duplicate, name: Realtime.Registry)
    Registry.start_link(keys: :unique, name: Realtime.Registry.Unique)

    :syn.add_node_to_scopes([:users])

    extensions_supervisors =
      Enum.reduce(Application.get_env(:realtime, :extensions), [], fn
        {_, %{supervisor: name}}, acc ->
          [
            %{
              id: name,
              start: {name, :start_link, []},
              restart: :transient
            }
            | acc
          ]

        _, acc ->
          acc
      end)

    children =
      [
        {Cluster.Supervisor, [topologies, [name: Realtime.ClusterSupervisor]]},
        Realtime.Repo,
        RealtimeWeb.Telemetry,
        {Phoenix.PubSub, name: Realtime.PubSub},
        RealtimeWeb.Endpoint,
        RealtimeWeb.Presence,
        Realtime.PromEx,
        {Cachex, name: :tenants}
      ] ++ extensions_supervisors

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Realtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    RealtimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @spec update_config_from_file(Path.t()) :: :ok | :error
  def update_config_from_file(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, configs} ->
          updated =
            Enum.reduce(configs, Application.get_all_env(:realtime), fn el, acc ->
              handle_config_update(el, acc)
            end)

          :ok = Application.put_all_env(realtime: updated)
          :ok

        other ->
          Logger.error("Can't update configs from file #{inspect(other, pretty: true)}")
          :error
      end
    else
      Logger.warning("Custom config file doesn't exist #{inspect(path)}")
    end
  end

  def handle_config_update({"endpoint_port", port}, acc) do
    updated_endpoint = Keyword.put(acc[RealtimeWeb.Endpoint], :http, port: port)
    Keyword.put(acc, RealtimeWeb.Endpoint, updated_endpoint)
  end

  def handle_config_update({"db_repo", [db_conf]}, acc) do
    updated_repo =
      Enum.reduce(db_conf, acc[Realtime.Repo], fn {k, v}, acc ->
        Keyword.put(acc, String.to_atom(k), v)
      end)

    Keyword.put(acc, Realtime.Repo, updated_repo)
  end

  def handle_config_update({"cluster", false}, acc), do: acc

  def handle_config_update({"cluster", [cluster_conf]}, acc) do
    if cluster_conf["cookie"] do
      String.to_atom(cluster_conf["cookie"])
      |> Node.set_cookie()
    end

    debug = if cluster_conf["debug"], do: true, else: false
    Application.put_env(:libcluster, :debug, debug)

    topology = [
      strategy: Elixir.Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: cluster_conf["service"],
        application_name: cluster_conf["application_name"],
        polling_interval: cluster_conf["polling_interval"]
      ]
    ]

    updated_topologies =
      Application.get_env(:libcluster, :topologies)
      |> Keyword.put(:k8s, topology)

    Application.put_env(:libcluster, :topologies, updated_topologies)
    acc
  end

  def handle_config_update(_, acc), do: acc
end
