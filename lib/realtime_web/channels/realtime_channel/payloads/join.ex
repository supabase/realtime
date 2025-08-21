defmodule RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.PostgresChange do
  @moduledoc """
  Validate postgres_changes field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join

  embedded_schema do
    field :event, :string
    field :schema, :string
    field :table, :string
    field :filter, :string
  end

  def changeset(postgres_change, attrs) do
    cast(postgres_change, attrs, [:event, :schema, :table, :filter], message: &Join.error_message/2)
  end
end

defmodule RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.Broadcast do
  @moduledoc """
  Validate broadcast field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join

  embedded_schema do
    field :ack, :boolean, default: false
    field :self, :boolean, default: false
  end

  def changeset(broadcast, attrs) do
    cast(broadcast, attrs, [:ack, :self], message: &Join.error_message/2)
  end
end

defmodule RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.Presence do
  @moduledoc """
  Validate presence field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join

  embedded_schema do
    field :enabled, :boolean, default: true
    field :key, :string, default: UUID.uuid1()
  end

  def changeset(presence, attrs) do
    cast(presence, attrs, [:enabled, :key], message: &Join.error_message/2)
  end
end

defmodule RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config do
  @moduledoc """
  Validate config field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.Broadcast
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.Presence
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.PostgresChange

  embedded_schema do
    embeds_one :broadcast, Broadcast
    embeds_one :presence, Presence
    embeds_many :postgres_changes, PostgresChange
    field :private, :boolean, default: false
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:private], message: &Join.error_message/2)
    |> cast_embed(:broadcast, invalid_message: "unable to parse, expected a map")
    |> cast_embed(:presence, invalid_message: "unable to parse, expected a map ")
    |> cast_embed(:postgres_changes, invalid_message: "unable to parse, expected an array of maps")
  end
end

defmodule RealtimeWeb.Channels.RealtimeChannel.Payloads.Join do
  @moduledoc """
  Payload validation for the phx_join event.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.Broadcast
  alias RealtimeWeb.Channels.RealtimeChannel.Payloads.Join.Config.Presence

  embedded_schema do
    embeds_one :config, Config
    field :access_token, :string
    field :user_token, :string
  end

  def changeset(join, attrs) do
    join
    |> cast(attrs, [:access_token, :user_token], message: &error_message/2)
    |> cast_embed(:config, invalid_message: "unable to parse, expected a map")
  end

  @spec validate(map()) :: {:ok, %__MODULE__{}} | {:error, :invalid_join_payload, map()}
  def validate(params) do
    case changeset(%__MODULE__{}, params) do
      %Ecto.Changeset{valid?: true} = changeset ->
        {:ok, Ecto.Changeset.apply_changes(changeset)}

      %Ecto.Changeset{valid?: false} = changeset ->
        errors = Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))
        {:error, :invalid_join_payload, errors}
    end
  end

  def presence_enabled?(%__MODULE__{config: %Config{presence: %Presence{enabled: enabled}}}), do: enabled
  def presence_enabled?(_), do: true

  def presence_key(%__MODULE__{config: %Config{presence: %Presence{key: key}}}), do: key
  def presence_key(_), do: UUID.uuid1()

  def ack_broadcast?(%__MODULE__{config: %Config{broadcast: %Broadcast{ack: ack}}}), do: ack
  def ack_broadcast?(_), do: false

  def self_broadcast?(%__MODULE__{config: %Config{broadcast: %Broadcast{self: self}}}), do: self
  def self_broadcast?(_), do: false

  def private?(%__MODULE__{config: %Config{private: private}}), do: private
  def private?(_), do: false

  def error_message(_field, meta) do
    type = Keyword.get(meta, :type)

    if type,
      do: "unable to parse, expected #{type}",
      else: "unable to parse"
  end
end
