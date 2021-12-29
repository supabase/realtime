# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

require Protocol

defmodule Realtime.Adapters.Changes do
  defmodule(Transaction, do: defstruct([:changes, :commit_timestamp]))

  defmodule NewRecord do
    @derive {Jason.Encoder, except: [:is_rls_enabled, :subscription_ids]}
    defstruct [
      :columns,
      :commit_timestamp,
      :errors,
      :schema,
      :table,
      :record,
      :subscription_ids,
      :type,
      is_rls_enabled: true
    ]
  end

  defmodule UpdatedRecord do
    @derive {Jason.Encoder, except: [:is_rls_enabled, :subscription_ids]}
    defstruct [
      :columns,
      :commit_timestamp,
      :errors,
      :schema,
      :table,
      :old_record,
      :record,
      :subscription_ids,
      :type,
      is_rls_enabled: true
    ]
  end

  defmodule DeletedRecord do
    @derive {Jason.Encoder, except: [:is_rls_enabled, :subscription_ids]}
    defstruct [
      :columns,
      :commit_timestamp,
      :errors,
      :schema,
      :table,
      :old_record,
      :subscription_ids,
      :type,
      is_rls_enabled: true
    ]
  end

  defmodule(TruncatedRelation, do: defstruct([:type, :schema, :table, :commit_timestamp]))
end

Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.Transaction)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.TruncatedRelation)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Postgres.Decoder.Messages.Relation.Column)
