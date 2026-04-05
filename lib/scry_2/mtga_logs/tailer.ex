defmodule Scry2.MtgaLogs.Tailer do
  @moduledoc """
  Pure file-tailing helpers.

  No GenServer, no persistence — just the primitive for reading new
  bytes from a file starting at an offset, detecting rotation via inode
  change, and advancing the cursor.

  The Watcher GenServer composes this with `EventParser` and the
  `MtgaLogs` context to land raw events in the database.
  """

  @type tail_result :: %{
          bytes: binary(),
          new_offset: non_neg_integer(),
          rotated?: boolean(),
          inode: non_neg_integer() | nil
        }

  @doc """
  Reads new bytes from `file_path` starting at `offset`.

  If the file's current size is smaller than `offset`, we assume the
  file was truncated or rotated and return the whole current contents
  with `rotated?: true` and `new_offset: byte_size(bytes)`.

  Returns `{:error, reason}` when the file can't be opened.
  """
  @spec read_since(String.t(), non_neg_integer()) ::
          {:ok, tail_result()} | {:error, term()}
  def read_since(file_path, offset) when is_binary(file_path) and is_integer(offset) do
    with {:ok, %File.Stat{size: size, inode: inode}} <- File.stat(file_path) do
      cond do
        size < offset ->
          # File was truncated/rotated — re-read from 0.
          case File.read(file_path) do
            {:ok, bytes} ->
              {:ok,
               %{
                 bytes: bytes,
                 new_offset: byte_size(bytes),
                 rotated?: true,
                 inode: inode
               }}

            {:error, _} = error ->
              error
          end

        size == offset ->
          {:ok, %{bytes: "", new_offset: offset, rotated?: false, inode: inode}}

        true ->
          read_range(file_path, offset, size - offset, inode)
      end
    end
  end

  defp read_range(file_path, offset, length, inode) do
    case File.open(file_path, [:read, :binary], fn device ->
           case :file.position(device, {:bof, offset}) do
             {:ok, ^offset} ->
               case IO.binread(device, length) do
                 :eof -> ""
                 {:error, _} -> :read_error
                 bytes when is_binary(bytes) -> bytes
               end

             {:error, _} ->
               :seek_error
           end
         end) do
      {:ok, :seek_error} ->
        {:error, :seek_failed}

      {:ok, :read_error} ->
        {:error, :read_failed}

      {:ok, bytes} when is_binary(bytes) ->
        {:ok,
         %{
           bytes: bytes,
           new_offset: offset + byte_size(bytes),
           rotated?: false,
           inode: inode
         }}

      {:error, _} = error ->
        error
    end
  end
end
