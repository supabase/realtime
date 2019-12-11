# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

require Protocol

defmodule Realtime.Adapters.Changes do
  defmodule(Transaction, do: defstruct([:changes, :commit_timestamp]))
  defmodule(NewRecord, do: defstruct([:type, :record, :schema, :table, :columns,  :commit_timestamp]))
  defmodule(UpdatedRecord, do: defstruct([:type, :old_record, :record, :schema, :table, :columns, :commit_timestamp]))
  defmodule(DeletedRecord, do: defstruct([:type, :old_record, :schema, :table, :columns, :commit_timestamp]))
  defmodule(TruncatedRelation, do: defstruct([:type, :schema, :table, :commit_timestamp]))
end

Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.Transaction)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.NewRecord)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.UpdatedRecord)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.DeletedRecord)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.TruncatedRelation)
Protocol.derive(Jason.Encoder, Realtime.Decoder.Messages.Relation.Column)