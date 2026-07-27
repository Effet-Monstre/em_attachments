defmodule EmAttachments.MemoryFile do
  @moduledoc """
  In-memory file that lazily materializes to disk only when a local path is required.

  Mirrors `EmAttachments.BackendFile` but holds raw bytes instead of a remote ID.
  The temp file is written at most once (on the first `local_path!/1` call) and the
  path is cached in the Agent and the original binary is released, so subsequent calls
  are served from disk. Call `cleanup/1` when the file is no longer needed. Upload
  pipelines consume and clean `MemoryFile` sources automatically.

  ## Usage

      mf   = MemoryFile.new(<<...>>, "thumb.jpg")
      path = EmAttachments.SourceFile.local_path!(mf)   # writes to disk once
      _    = EmAttachments.SourceFile.local_path!(mf)   # cached, no write
      MemoryFile.cleanup(mf)

  """

  use Agent

  @enforce_keys [:pid]
  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @doc "Creates a `MemoryFile` holding `data` in memory."
  @spec new(binary(), String.t()) :: t()
  def new(data, filename) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{data: data, filename: filename, size: byte_size(data), local_path: nil}
      end)

    %__MODULE__{pid: pid}
  end

  @doc false
  def from_path(path, filename) do
    size = File.stat!(path).size

    {:ok, pid} =
      Agent.start_link(fn ->
        %{data: nil, filename: filename, size: size, local_path: path}
      end)

    %__MODULE__{pid: pid}
  end

  @doc """
  Ensures the data is available at a local path.

  Writes to a temp file on the first call and caches the result. Returns
  `{:ok, path}` or `{:error, reason}` without raising.
  """
  @spec ensure_local(t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_local(%__MODULE__{pid: pid}) do
    Agent.get_and_update(pid, fn
      %{local_path: nil, data: data} = state ->
        tmp = tmp_path()

        case File.write(tmp, data) do
          :ok ->
            {{:ok, tmp}, %{state | data: nil, local_path: tmp}}

          {:error, _} = err ->
            File.rm(tmp)
            {err, state}
        end

      %{local_path: path} = state ->
        {{:ok, path}, state}
    end)
  end

  @doc "Returns the raw Agent state map."
  @spec state(t()) :: map()
  def state(%__MODULE__{pid: pid}), do: Agent.get(pid, & &1)

  @doc "Stops the Agent and deletes any written temp file."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{pid: pid}) do
    case safe_state(pid) do
      %{local_path: path} ->
        if path, do: File.rm(path)
        safe_stop(pid)

      nil ->
        :ok
    end

    :ok
  end

  defp safe_state(pid) do
    try do
      Agent.get(pid, & &1)
    catch
      :exit, _ -> nil
    end
  end

  defp safe_stop(pid) do
    try do
      Agent.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "em_attach_mf_#{EmAttachments.Util.random_id(8)}")
  end
end

defimpl EmAttachments.SourceFile, for: EmAttachments.MemoryFile do
  def local_path!(source) do
    case EmAttachments.MemoryFile.ensure_local(source) do
      {:ok, path} -> path
      {:error, reason} -> raise "EmAttachments.MemoryFile: #{inspect(reason)}"
    end
  end

  def fetch_local_path(source), do: EmAttachments.MemoryFile.ensure_local(source)

  def fetch_bytes(source) do
    case EmAttachments.MemoryFile.state(source) do
      %{data: data} when is_binary(data) -> {:ok, data}
      %{local_path: path} when is_binary(path) -> File.read(path)
    end
  end

  def filename(source), do: EmAttachments.MemoryFile.state(source).filename

  def size(source) do
    EmAttachments.MemoryFile.state(source).size
  end
end
