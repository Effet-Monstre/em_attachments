defmodule EmAttachments.TempFile do
  @moduledoc false

  @enforce_keys [:path, :filename, :size]
  defstruct [:path, :filename, :size]

  @type t :: %__MODULE__{
          path: String.t(),
          filename: String.t(),
          size: non_neg_integer()
        }

  def new(path, filename) do
    %__MODULE__{path: path, filename: filename, size: File.stat!(path).size}
  end

  def from_map(%{path: path, filename: filename}), do: new(path, filename)
  def from_map(%{"path" => path, "filename" => filename}), do: new(path, filename)

  if Code.ensure_loaded?(Plug.Upload) do
    def from_plug(%Plug.Upload{path: path, filename: filename}), do: new(path, filename)
  end
end
