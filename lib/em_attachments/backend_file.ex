defmodule EmAttachments.BackendFile do
  @moduledoc """
  Lazy, cache-once file reference backed by a storage backend.

  The file is not fetched until `EmAttachments.SourceFile.local_path!/1` is first
  called. After the initial download the local tmp path is cached in the Agent, so
  every subsequent call to `local_path!/1` is free. Call `cleanup/1` when the file
  is no longer needed to stop the Agent and remove the tmp file.

  ## Usage

      source = BackendFile.new(MyBackend, backend_opts, id, "photo.jpg", 204_800)
      path   = EmAttachments.SourceFile.local_path!(source)   # downloads once
      _path  = EmAttachments.SourceFile.local_path!(source)   # cached, no download
      BackendFile.cleanup(source)

"""

  use Agent

  @enforce_keys [:pid]
  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @doc """
  Creates a `BackendFile` referencing a stored file.

  `size` is optional; pass the value from stored metadata when available so that
  `SourceFile.size/1` works without triggering a download.
  """
  @spec new(module(), keyword(), String.t(), String.t(), non_neg_integer() | nil) :: t()
  def new(backend_mod, backend_opts, id, filename, size \\ nil) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          backend_mod: backend_mod,
          backend_opts: backend_opts,
          id: id,
          filename: filename,
          size: size,
          local_path: nil
        }
      end)

    %__MODULE__{pid: pid}
  end

  @doc """
  Ensures the file is available locally.

  Downloads from the backend on the first call and caches the result. Returns
  `{:ok, path}` or `{:error, reason}` without raising.
  """
  @spec ensure_local(t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_local(%__MODULE__{pid: pid}) do
    Agent.get_and_update(pid, fn
      %{local_path: nil, backend_mod: mod, backend_opts: opts, id: id} = state ->
        case mod.get(id, opts) do
          {:ok, content} ->
            tmp = tmp_path()
            File.write!(tmp, content)
            {{:ok, tmp}, %{state | local_path: tmp}}

          {:error, _} = err ->
            {err, state}
        end

      %{local_path: path} = state ->
        {{:ok, path}, state}
    end)
  end

  @doc "Returns the raw Agent state map (reads filename/size without downloading)."
  @spec state(t()) :: map()
  def state(%__MODULE__{pid: pid}), do: Agent.get(pid, & &1)

  @doc "Stops the Agent and deletes any downloaded tmp file."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{pid: pid}) do
    %{local_path: path} = Agent.get(pid, & &1)
    if path, do: File.rm(path)
    Agent.stop(pid)
    :ok
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "em_attach_bf_#{EmAttachments.Util.random_id(8)}")
  end
end

defimpl EmAttachments.SourceFile, for: EmAttachments.BackendFile do
  def local_path!(source) do
    case EmAttachments.BackendFile.ensure_local(source) do
      {:ok, path} -> path
      {:error, reason} -> raise "EmAttachments.BackendFile: #{inspect(reason)}"
    end
  end

  def fetch_local_path(source), do: EmAttachments.BackendFile.ensure_local(source)

  def filename(source), do: EmAttachments.BackendFile.state(source).filename
  def size(source), do: EmAttachments.BackendFile.state(source).size
end
