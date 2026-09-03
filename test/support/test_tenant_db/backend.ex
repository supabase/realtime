defmodule TestTenantDb.Backend do
  @moduledoc false
  # Strategy for provisioning the test suite's tenant databases:
  #
  #   * TestTenantDb.Backend.Docker   — ephemeral supabase/postgres docker
  #     containers, one per pool worker (the default).
  #   * TestTenantDb.Backend.External — pre-existing, external
  #     Postgres-wire-compatible servers (e.g. Multigres) on
  #     EXTERNAL_TENANT_DB_PORTS (USE_EXTERNAL_TENANT_DB=true).
  #
  # The backend is resolved exactly once per run, in test_helper.exs, and
  # stashed in :persistent_term.
  #
  # Each backend is self-contained: it owns its pool workers and (for
  # pre-provisioned resources) its own registry. TestTenantDb only calls the
  # callbacks below.

  alias Realtime.Env

  @key {__MODULE__, :current}

  # Number of concurrent ExUnit cases this backend supports.
  @callback max_cases() :: pos_integer()

  # One-off setup before the pool starts. Runs before TestTenantDb.start_link/1.
  @callback prepare!() :: :ok

  # Poolboy worker module and pool size.
  @callback pool_spec(max_cases :: pos_integer()) :: {module(), pos_integer()}

  # Port of a checked-out pool worker.
  @callback worker_port(pid()) :: pos_integer()

  # Ensure the tenant's database exists
  @callback storage_up!(tenant :: struct()) :: :ok

  # A database of its own for a single test started with additional postgres settings.
  @callback start_database!(postgres_args :: [binary()]) :: {port :: pos_integer(), cleanup :: (-> :ok)}

  def resolve! do
    backend = choose()
    :persistent_term.put(@key, backend)
    backend
  end

  def current, do: :persistent_term.get(@key)

  def choose do
    if Env.get_boolean("USE_EXTERNAL_TENANT_DB", false) do
      TestTenantDb.Backend.External
    else
      TestTenantDb.Backend.Docker
    end
  end
end
