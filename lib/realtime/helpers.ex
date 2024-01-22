defmodule Realtime.Helpers do
  @moduledoc """
  This module includes helper functions for different contexts that can't be union in one module.
  """

  alias Realtime.Api.Tenant
  alias Realtime.PostgresCdc
  alias Realtime.Rpc
  require Logger

  @spec cancel_timer(reference() | nil) :: non_neg_integer() | false | :ok | nil
  def cancel_timer(nil), do: nil
  def cancel_timer(ref), do: Process.cancel_timer(ref)

  def encrypt!(text, secret_key) do
    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, pad(text), true)
    |> Base.encode64()
  end

  def decrypt!(base64_text, secret_key) do
    crypto_text = Base.decode64!(base64_text)

    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, crypto_text, false)
    |> unpad()
  end

  @spec connect_db(%{
          :host => binary,
          :name => binary,
          :pass => binary,
          :pool => non_neg_integer,
          :port => binary,
          :queue_target => non_neg_integer,
          :socket_opts => list,
          :ssl_enforced => boolean,
          :user => binary,
          :application_name => binary,
          :backoff => :stop | :exp | :rand | :rand_exp,
          optional(any) => any
        }) :: {:error, any} | {:ok, pid}
  def connect_db(%{
        host: host,
        port: port,
        name: name,
        user: user,
        pass: pass,
        socket_opts: socket_opts,
        pool: pool,
        queue_target: queue_target,
        ssl_enforced: ssl_enforced,
        application_name: application_name,
        backoff: backoff
      }) do
    connect_db(
      host,
      port,
      name,
      user,
      pass,
      socket_opts,
      pool,
      queue_target,
      ssl_enforced,
      application_name,
      backoff
    )
  end

  @spec connect_db(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          list(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          String.t(),
          :stop | :exp | :rand | :rand_exp
        ) ::
          {:ok, pid} | {:error, Postgrex.Error.t() | term()}
  def connect_db(
        host,
        port,
        name,
        user,
        pass,
        socket_opts,
        pool \\ 5,
        queue_target \\ 5_000,
        ssl_enforced \\ true,
        application_name \\ "realtime_supabase",
        backoff_type \\ :rand_exp
      ) do
    Logger.metadata(application_name: application_name)
    metadata = Logger.metadata()
    {host, port, name, user, pass} = decrypt_creds(host, port, name, user, pass)

    [
      hostname: host,
      port: port,
      database: name,
      password: pass,
      username: user,
      pool_size: pool,
      queue_target: queue_target,
      parameters: [
        application_name: application_name
      ],
      socket_options: socket_opts,
      backoff_type: backoff_type,
      configure: fn args ->
        Logger.metadata(metadata)
        args
      end
    ]
    |> maybe_enforce_ssl_config(ssl_enforced)
    |> Postgrex.start_link()
  end

  @cdc "postgres_cdc_rls"
  @doc """
  Checks if the Tenant CDC extension information is properly configured and that we're able to query against the tenant database.
  """
  @spec check_tenant_connection(Tenant.t(), binary()) :: {:error, atom()} | {:ok, pid()}
  def check_tenant_connection(nil, _, _), do: {:error, :tenant_not_found}

  def check_tenant_connection(tenant, application_name) do
    tenant
    |> then(&PostgresCdc.filter_settings(@cdc, &1.extensions))
    |> then(fn settings ->
      ssl_enforced = default_ssl_param(settings)

      host = settings["db_host"]
      port = settings["db_port"]
      name = settings["db_name"]
      user = settings["db_user"]
      password = settings["db_password"]
      {:ok, addrtype} = detect_ip_version(host)

      socket_opts = [addrtype]

      opts = %{
        host: host,
        port: port,
        name: name,
        user: user,
        pass: password,
        socket_opts: socket_opts,
        pool: 1,
        queue_target: 1000,
        ssl_enforced: ssl_enforced,
        application_name: application_name,
        backoff: :stop
      }

      with {:ok, conn} <- connect_db(opts) do
        case Postgrex.query(conn, "SELECT 1", []) do
          {:ok, _} ->
            {:ok, conn}

          {:error, e} ->
            Process.exit(conn, :kill)
            Logger.error("Error connecting to tenant database: #{inspect(e)}")
            {:error, :tenant_database_unavailable}
        end
      end
    end)
  end

  @spec default_ssl_param(map) :: boolean
  def default_ssl_param(%{"ssl_enforced" => ssl_enforced}) when is_boolean(ssl_enforced),
    do: ssl_enforced

  def default_ssl_param(_), do: true

  @spec maybe_enforce_ssl_config(maybe_improper_list, boolean()) :: maybe_improper_list
  def maybe_enforce_ssl_config(db_config, ssl_enforced)
      when is_list(db_config) and is_boolean(ssl_enforced) do
    if ssl_enforced do
      enforce_ssl_config(db_config)
    else
      db_config
    end
  end

  def maybe_enforce_ssl_config(db_config, _) do
    enforce_ssl_config(db_config)
  end

  defp enforce_ssl_config(db_config) when is_list(db_config) do
    db_config ++ [ssl: true, ssl_opts: [verify: :verify_none]]
  end

  @doc """
  Gets the external id from a host connection string found in the conn.

  ## Examples

      iex> Realtime.Helpers.get_external_id("tenant.realtime.supabase.co")
      {:ok, "tenant"}

      iex> Realtime.Helpers.get_external_id("tenant.supabase.co")
      {:ok, "tenant"}

      iex> Realtime.Helpers.get_external_id("localhost")
      {:ok, "localhost"}

  """

  @spec get_external_id(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def get_external_id(host) when is_binary(host) do
    case String.split(host, ".", parts: 2) do
      [] -> {:error, :tenant_not_found_in_host}
      [id] -> {:ok, id}
      [id, _] -> {:ok, id}
    end
  end

  def decrypt_creds(host, port, name, user, pass) do
    secure_key = Application.get_env(:realtime, :db_enc_key)

    {
      decrypt!(host, secure_key),
      decrypt!(port, secure_key),
      decrypt!(name, secure_key),
      decrypt!(user, secure_key),
      decrypt!(pass, secure_key)
    }
  end

  @doc """
  Gets a short node name from a node name when a node name looks like `realtime-prod@fdaa:0:cc:a7b:b385:83c3:cfe3:2`

  ## Examples

      iex> node = Node.self()
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "nohost"

      iex> node = :"realtime-prod@fdaa:0:cc:a7b:b385:83c3:cfe3:2"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "83c3cfe3"

      iex> node = :"pink@127.0.0.1"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "127.0.0.1"

      iex> node = :"pink@10.0.1.1"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "10.0.1.1"

      iex> node = :"realtime@host.name.internal"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "host.name.internal"
  """

  @spec short_node_id_from_name(atom()) :: String.t()
  def short_node_id_from_name(name) when is_atom(name) do
    [_, host] = name |> Atom.to_string() |> String.split("@", parts: 2)

    case String.split(host, ":", parts: 8) do
      [_, _, _, _, _, one, two, _] ->
        one <> two

      _other ->
        host
    end
  end

  @doc """
  Takes the first N items from the queue and returns the list of items and the new queue.

  ## Examples

      iex> q = :queue.new()
      iex> q = :queue.in(1, q)
      iex> q = :queue.in(2, q)
      iex> q = :queue.in(3, q)
      iex> Realtime.Helpers.queue_take(q, 2)
      {[2, 1], {[], [3]}}
  """

  @spec queue_take(:queue.queue(), non_neg_integer()) :: {list(), :queue.queue()}
  def queue_take(q, count) do
    Enum.reduce_while(1..count, {[], q}, fn _, {items, queue} ->
      case :queue.out(queue) do
        {{:value, item}, new_q} ->
          {:cont, {[item | items], new_q}}

        {:empty, new_q} ->
          {:halt, {items, new_q}}
      end
    end)
  end

  @doc """
  Ensures connected users are connected to the closest region by killing and restart the connection process.
  """
  def rebalance() do
    Enum.reduce(:syn.group_names(:users), 0, fn tenant, acc ->
      case :syn.lookup(Extensions.PostgresCdcRls, tenant) do
        {pid, %{region: region}} ->
          platform_region = Realtime.Nodes.platform_region_translator(region)
          launch_node = Realtime.Nodes.launch_node(tenant, platform_region, false)
          current_node = node(pid)

          case launch_node do
            ^current_node -> acc
            _ -> stop_user_tenant_process(tenant, platform_region, acc)
          end

        _ ->
          acc
      end
    end)
  end

  @doc """
  Kills all connections to a tenant database in all connected nodes
  """
  @spec kill_connections_to_tenant_id_in_all_nodes(String.t(), atom()) :: list()
  def kill_connections_to_tenant_id_in_all_nodes(tenant_id, reason \\ :normal) do
    [node() | Node.list()]
    |> Task.async_stream(
      fn node ->
        Rpc.enhanced_call(node, __MODULE__, :kill_connections_to_tenant_id, [tenant_id, reason],
          timeout: 5000
        )
      end,
      timeout: 5000
    )
    |> Enum.map(& &1)
  end

  @doc """
  Kills all connections to a tenant database in the current node
  """
  @spec kill_connections_to_tenant_id(String.t(), atom()) :: :ok
  def kill_connections_to_tenant_id(tenant_id, reason) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    pids_to_kill =
      for pid <- Process.list(),
          info = Process.info(pid),
          dict = Keyword.get(info, :dictionary, []),
          match?({DBConnection.Connection, :init, 1}, dict[:"$initial_call"]),
          Keyword.get(dict, :"$logger_metadata$")[:external_id] == tenant_id,
          links = Keyword.get(info, :links) do
        links
        |> Enum.filter(&is_pid/1)
        |> Enum.filter(fn pid ->
          pid |> Process.info() |> Keyword.get(:dictionary, []) |> Keyword.get(:"$initial_call") ==
            {:supervisor, DBConnection.ConnectionPool.Pool, 1}
        end)
      end

    Enum.each(pids_to_kill, &Process.exit(&1, reason))
  end

  @doc """
  Kills all Ecto.Migration.Runner processes that are linked only to Ecto.MigratorSupervisor
  """
  @spec dirty_terminate_runners :: list()
  def dirty_terminate_runners() do
    Ecto.MigratorSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce([], fn
      {_, pid, :worker, [Ecto.Migration.Runner]}, acc ->
        if length(Process.info(pid)[:links]) < 2 do
          [{pid, Agent.stop(pid, :normal, 5_000)} | acc]
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  @doc """
  Detects the IP version for a given encrypted host.

  ## Examples
      # Using ipv4.google.com
      iex> Realtime.Helpers.detect_ip_version("SnSEgD5+ZsQoWpCJ+xDh7g==")
      {:ok, :inet}

      # Using ipv6.google.com
      iex> Realtime.Helpers.detect_ip_version("8vsiF4ELRsLa1yLdhZGBOw==")
      {:ok, :inet6}

      # Using invalid domain
      iex> Realtime.Helpers.detect_ip_version("ZNVOgBtti0+i/o6eZCPAwA==")
      {:error, :nxdomain}
  """
  @spec detect_ip_version(String.t()) :: {:ok, :inet | :inet6} | {:error, :nxdomain}
  def detect_ip_version(host) when is_binary(host) do
    secret_key = Application.get_env(:realtime, :db_enc_key)
    host = host |> decrypt!(secret_key) |> String.to_charlist()

    cond do
      match?({:ok, _}, :inet6_tcp.getaddr(host)) -> {:ok, :inet6}
      match?({:ok, _}, :inet.gethostbyname(host)) -> {:ok, :inet}
      true -> {:error, :nxdomain}
    end
  end

  def replication_slot_teardown(tenant) do
    {:ok, conn} = check_tenant_connection(tenant, "replication_slot_teardown")

    with {:ok, %{rows: rows}} <-
           Postgrex.query(
             conn,
             "select active_pid from pg_replication_slots where slot_name ilike '%realtime%'",
             []
           ) do
      Enum.each(rows, fn [pid] ->
        Postgrex.query(conn, "select pg_terminate_backend(#{pid})", [])
      end)

      :ok
    end
  end

  defp stop_user_tenant_process(tenant, platform_region, acc) do
    Extensions.PostgresCdcRls.handle_stop(tenant, 5_000)
    # credo:disable-for-next-line
    IO.inspect({"Stopped", tenant, platform_region})
    Process.sleep(1_500)
    acc + 1
  catch
    kind, reason ->
      # credo:disable-for-next-line
      IO.inspect({"Failed to stop", tenant, kind, reason})
  end

  defp pad(data) do
    to_add = 16 - rem(byte_size(data), 16)
    data <> :binary.copy(<<to_add>>, to_add)
  end

  defp unpad(data) do
    to_remove = :binary.last(data)
    :binary.part(data, 0, byte_size(data) - to_remove)
  end
end
