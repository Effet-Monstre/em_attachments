if Code.ensure_loaded?(Mogrify) do
  defmodule EmAttachments.ImageAdapters.Mogrify do
    @moduledoc "ImageAdapter backed by the `mogrify` hex package."

    @behaviour EmAttachments.ImageAdapter

    @impl true
    def dimensions(path) do
      info = Mogrify.identify(path)
      {:ok, %{width: info.width, height: info.height}}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
