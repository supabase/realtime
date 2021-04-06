defmodule Realtime.Repo do
  @moduledoc false

  use Ecto.Repo,
      otp_app: :realtime,
      adapter: Ecto.Adapters.Postgres
end
