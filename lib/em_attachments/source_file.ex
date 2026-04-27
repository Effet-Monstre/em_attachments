defprotocol EmAttachments.SourceFile do
  @moduledoc """
  Protocol for any file that can be used as an upload source.

  Implemented by:

  - `EmAttachments.TempFile` — already-local file, `local_path!/1` is a direct field read
  - `Plug.Upload` — already-local upload, `local_path!/1` returns `upload.path` directly
    (no copying into a separate tmp file)
  - `EmAttachments.BackendFile` — lazy remote file that downloads on the first
    `local_path!/1` call and caches the result; subsequent calls are instant

  ## Usage in plugins and `handle/2`

      def handle(:derivatives, %{file: source}) do
        path = EmAttachments.SourceFile.local_path!(source)
        # ... use path
      end

      def upload(source, _key, _uploader, _deps, _opts, {:cache, _mod, _backend_opts}) do
        path = EmAttachments.SourceFile.local_path!(source)
        # ...
      end
  """

  @doc """
  Returns the local filesystem path for the file.

  For `TempFile` and `Plug.Upload` this is a direct field read — no I/O.
  For `BackendFile` the file is downloaded on the first call; the path is cached
  so every subsequent call returns instantly. Raises on failure.
  """
  @spec local_path!(t()) :: String.t()
  def local_path!(source)

  @doc "Returns the original filename."
  @spec filename(t()) :: String.t()
  def filename(source)

  @doc "Returns the file size in bytes, or `nil` if not yet known."
  @spec size(t()) :: non_neg_integer() | nil
  def size(source)

  @doc """
  Like `local_path!/1` but returns `{:ok, path} | {:error, reason}` instead of raising.
  Useful for backends that need to fall back to a local download when a server-side transfer
  is not possible.
  """
  @spec fetch_local_path(t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_local_path(source)

  @doc """
  Returns the file content as a binary without necessarily writing to disk.

  For `MemoryFile` this is a pure memory read — no I/O.
  For `TempFile` and `Plug.Upload` this reads the local file.
  For `BackendFile` this reads from the local cache if already downloaded,
  otherwise fetches from the backend directly (skipping the disk write that
  `local_path!/1` would perform).

  Backends that send file content over a network (e.g. S3) should prefer this
  over `local_path!/1` + `File.read` so that `MemoryFile` sources never touch disk.
  """
  @spec fetch_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def fetch_bytes(source)
end

defimpl EmAttachments.SourceFile, for: EmAttachments.TempFile do
  def local_path!(source), do: source.path
  def fetch_local_path(source), do: {:ok, source.path}
  def fetch_bytes(source), do: File.read(source.path)
  def filename(source), do: source.filename
  def size(source), do: source.size
end

if Code.ensure_loaded?(Plug.Upload) do
  defimpl EmAttachments.SourceFile, for: Plug.Upload do
    def local_path!(source), do: source.path
    def fetch_local_path(source), do: {:ok, source.path}
    def fetch_bytes(source), do: File.read(source.path)
    def filename(source), do: source.filename
    def size(source), do: File.stat!(source.path).size
  end
end
