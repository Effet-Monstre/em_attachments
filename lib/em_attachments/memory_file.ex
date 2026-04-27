defmodule EmAttachments.MemoryFile do
  @moduledoc """
  In-memory file that lazily materializes to disk only when a local path is required.

  Mirrors `EmAttachments.BackendFile` but holds raw bytes instead of a remote ID.
  The temp file is written at most once (on the first `local_path!/1` call) and the
  path is cached in the Agent so subsequent calls are free. Call `cleanup/1` when the
  file is no longer needed.

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
        %{data: data, filename: filename, local_path: nil}
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
          :ok -> {{:ok, tmp}, %{state | local_path: tmp}}
          {:error, _} = err -> {err, state}
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
    %{local_path: path} = Agent.get(pid, & &1)
    if path, do: File.rm(path)
    Agent.stop(pid)
    :ok
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

  def fetch_bytes(source), do: {:ok, EmAttachments.MemoryFile.state(source).data}

  def filename(source), do: EmAttachments.MemoryFile.state(source).filename

  def size(source) do
    byte_size(EmAttachments.MemoryFile.state(source).data)
  end
end
