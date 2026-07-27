defmodule EmAttachments.TempFile do
  @moduledoc false

  @enforce_keys [:path, :filename, :size]
  defstruct [:path, :filename, :size, managed: false]

  @type t :: %__MODULE__{
          path: String.t(),
          filename: String.t(),
          size: non_neg_integer(),
          managed: boolean()
        }

  def new(path, filename) do
    %__MODULE__{path: path, filename: filename, size: File.stat!(path).size}
  end

  @doc false
  def managed(path, filename) do
    %__MODULE__{path: path, filename: filename, size: File.stat!(path).size, managed: true}
  end

  @doc false
  def cleanup(%__MODULE__{managed: true, path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  def cleanup(%__MODULE__{}), do: :ok

  def from_map(%{path: path, filename: filename}), do: new(path, filename)
  def from_map(%{"path" => path, "filename" => filename}), do: new(path, filename)

  if Code.ensure_loaded?(Plug.Upload) do
    def from_plug(%Plug.Upload{path: path, filename: filename}), do: new(path, filename)
  end
end
