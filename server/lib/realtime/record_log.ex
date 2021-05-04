defmodule Realtime.RecordLog do
  
  def open(file_name) do
    File.open(file_name, [:read, :write])
  end

  def close(path) do
    File.rm(path)
  end

  def insert(io, record) do
    bin = :erlang.term_to_binary(record)
    :file.write(io, <<byte_size(bin)::32, bin::binary>>)    
  end

  def first(path) do
    chars_path = String.to_charlist(path)
    {:ok, io} = :file.open(chars_path, [:read, :raw, :binary])
    record(io, 0)
  end

  def next(io, pos) do
    record(io, pos)
  end

  defp record(io, pos) do
    len = bin_len(io, pos)
    decode(io, pos + 4, len)    
  end

  defp bin_len(io, pos) do
    {:ok, <<len::32>>} = :file.pread(io, pos, 4)
    len
  end

  defp decode(io, pos, len) do
    {:ok, bin} = :file.pread(io, pos, len)
    rec = :erlang.binary_to_term(bin)
    {:ok, {io, pos + len, rec}}
  end  

end
