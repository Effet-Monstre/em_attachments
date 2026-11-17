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
    case File.rm(dest_path(id, opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def url(id, opts) do
    render_path = Keyword.fetch!(opts, :render_path)
    {:ok, "#{render_path}/#{id}"}
  end

  @impl true
  def head(id, opts) do
    case File.stat(dest_path(id, opts)) do
      {:ok, %{type: :regular, size: size}} -> {:ok, %{size: size}}
      {:ok, _other} -> {:error, :not_found}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_range(id, first, last, opts) do
    case File.open(dest_path(id, opts), [:read, :binary]) do
      {:ok, file} ->
        try do
          case :file.pread(file, first, last - first + 1) do
            {:ok, data} -> {:ok, data}
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(file)
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  A local store has no presigned URL of its own: the upload goes to the
  `EmAttachments.Plug.Upload` mounted in the application (`:upload_url`, given by the plug),
  which checks the slot's token (a field, `:slot_token`) and writes the file at `id`.
  """
  @impl true
  def presign_upload(_id, opts) do
    case opts[:upload_url] do
      url when is_binary(url) -> {:ok, %{url: url, fields: %{"token" => opts[:slot_token]}}}
      nil -> {:error, :not_supported}
    end
  end

  defp dest_path(id, opts) do
    fs_path = Keyword.fetch!(opts, :fs_path)
    Path.join(fs_path, id)
  end
end
