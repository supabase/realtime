# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

import Protocol

defmodule Realtime.Adapters.Changes do
  defmodule(Transaction, do: defstruct([:changes, :commit_timestamp]))
  defmodule(NewRecord, do: defstruct([:type, :relation, :record, :schema, :table, :columns]))
  defmodule(UpdatedRecord, do: defstruct([:type, :relation, :old_record, :record, :schema, :table, :columns]))
  defmodule(DeletedRecord, do: defstruct([:type, :relation, :old_record, :schema, :table, :columns]))
  defmodule(TruncatedRelation, do: defstruct([:type, :relation, :schema, :table]))
end

Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.Transaction)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.NewRecord)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.UpdatedRecord)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.DeletedRecord)
Protocol.derive(Jason.Encoder, Realtime.Adapters.Changes.TruncatedRelation)
Protocol.derive(Jason.Encoder, Realtime.Decoder.Messages.Relation.Column)