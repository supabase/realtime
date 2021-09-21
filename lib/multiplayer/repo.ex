defmodule Multiplayer.Repo do
  use Ecto.Repo,
    otp_app: :multiplayer,
    adapter: Ecto.Adapters.Postgres
end
