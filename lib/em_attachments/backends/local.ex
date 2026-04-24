defmodule EmAttachments.Backends.Local do
  @moduledoc """
  Local filesystem backend.

  Options:
    - `:fs_path` (required) — absolute path where files are stored
    - `:render_path` (required) — URL prefix used for `url/2`
  """

  @behaviour EmAttachments.Backend

  @impl true
  def put(id, source, opts) do
    path = EmAttachments.SourceFile.local_path!(source)
    dest = dest_path(id, opts)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(path, dest)
    :ok
  end

  @impl true
  def get(id, opts) do
    File.read(dest_path(id, opts))
  end

  @impl true
  def delete(id, opts) do
    File.rm(dest_path(id, opts))
    :ok
  end

  @impl true
  def url(id, opts) do
    render_path = Keyword.fetch!(opts, :render_path)
    {:ok, "#{render_path}/#{id}"}
  end

  @impl true
  def presign_upload(_id, _opts) do
    {:error, :not_supported}
  end

  defp dest_path(id, opts) do
    fs_path = Keyword.fetch!(opts, :fs_path)
    Path.join(fs_path, id)
  end
end
