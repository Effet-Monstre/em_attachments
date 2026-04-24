if Code.ensure_loaded?(Vix.Vips) do
  defmodule EmAttachments.ImageAdapters.Vix do
    @moduledoc "ImageAdapter backed by the `vix` hex package (libvips bindings)."

    @behaviour EmAttachments.ImageAdapter

    @impl true
    def dimensions(path) do
      {:ok, image} = Vix.Vips.Image.new_from_file(path)
      {:ok, %{width: Vix.Vips.Image.width(image), height: Vix.Vips.Image.height(image)}}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
