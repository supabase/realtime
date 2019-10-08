defmodule Realtime.Adapters.Changes do
  defmodule(Transaction, do: defstruct([:changes, :commit_timestamp]))
  defmodule(NewRecord, do: defstruct([:type, :relation, :record, :schema, :table, :columns]))
  defmodule(UpdatedRecord, do: defstruct([:type, :relation, :old_record, :record, :schema, :table, :columns]))
  defmodule(DeletedRecord, do: defstruct([:type, :relation, :old_record, :schema, :table, :columns]))
  defmodule(TruncatedRelation, do: defstruct([:type, :relation, :schema, :table]))
end
