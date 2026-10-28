defmodule SqlLogex.Env do
  @moduledoc """
  What a policy is evaluated against: the session settings and the row being checked.

  `settings` models the settings `current_setting(name, true)` reads. Realtime sets exactly six of
  them, in `Realtime.Tenants.Authorization` (`authorize/5` passes them to `realtime.authorize`, and
  `set_conn_config/2` does the same with `set_config`), always with the exact strings it sends:

    * `role`
    * `realtime.topic`
    * `request.jwt.claims`
    * `request.jwt.claim.sub`
    * `request.jwt.claim.role`
    * `request.headers`

  Names are stored lowercase. A `nil` value stands for `set_config(name, NULL)`, which resets the
  setting, and a reset custom setting reads as `''`, never NULL (`SqlLogex.Value.current_setting/2`).
  A setting that is absent from the map can't be answered, so reading it is unsupported.

  `row` maps the column names of the checked row to values, for `realtime.messages` `topic` and
  `extension` as `{:text, binary}`. A column that is absent is unsupported when read.
  """

  alias SqlLogex.Value

  @type t :: %__MODULE__{
          settings: %{optional(String.t()) => String.t() | nil},
          row: %{optional(String.t()) => Value.t()}
        }

  defstruct settings: %{}, row: %{}

  @doc "Builds an env, lowercasing the setting names (ASCII only, like Postgres does for GUC names)."
  @spec new(%{optional(String.t()) => String.t() | nil}, %{optional(String.t()) => Value.t()}) :: t
  def new(settings, row) when is_map(settings) and is_map(row) do
    %__MODULE__{settings: Map.new(settings, fn {name, value} -> {String.downcase(name, :ascii), value} end), row: row}
  end
end
