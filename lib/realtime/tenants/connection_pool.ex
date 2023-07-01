defmodule Realtime.Tenants.ConnectionPool do
  @moduledoc """
  A connection pool for managing tenant databases.
  """

  use GenServer

  alias Realtime.Helpers, as: H

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(args) do
    %{
      "id" => id,
      # "publication" => publication,
      # "subscribers_tid" => subscribers_tid,
      "db_host" => host,
      "db_port" => port,
      "db_name" => name,
      "db_user" => user,
      "db_password" => pass,
      "db_socket_opts" => socket_opts,
      "pool_size" => pool_size
    } = args

    Logger.metadata(external_id: id, project: id)

    {:ok, conn} = H.connect_db(host, port, name, user, pass, socket_opts, pool_size)

    state = %{conn: conn}

    {:ok, state}
  end
end
