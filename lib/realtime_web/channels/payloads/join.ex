defmodule RealtimeWeb.Channels.Payloads.Join do
  @moduledoc """
  Payload validation for the phx_join event.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Config
  alias RealtimeWeb.Channels.Payloads.Broadcast
  alias RealtimeWeb.Channels.Payloads.Presence

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

  def presence_key(%__MODULE__{config: %Config{presence: %Presence{key: ""}}}), do: UUID.uuid1()
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
