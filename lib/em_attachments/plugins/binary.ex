defmodule EmAttachments.Plugins.Binary do
  @moduledoc """
  Cast plugin that accepts `{:binary, data}` and `{:binary, data, filename}` values
  from changeset params.

  Wraps the binary in a `MemoryFile` before passing it to the upload pipeline.

      plugin binary: EmAttachments.Plugins.Binary
  """

  use EmAttachments.Plugin

  @impl true
  def cast({:binary, data}, _ctx) when is_binary(data) do
    {:ok, EmAttachments.MemoryFile.new(data, "upload")}
  end

  def cast({:binary, data, filename}, _ctx) when is_binary(data) and is_binary(filename) do
    {:ok, EmAttachments.MemoryFile.new(data, filename)}
  end

  def cast(_, _ctx), do: :skip
end
