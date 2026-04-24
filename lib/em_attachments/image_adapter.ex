defmodule EmAttachments.ImageAdapter do
  @moduledoc """
  Behaviour for image library adapters used by `EmAttachments.Plugins.Dimensions`.

  Pass a module implementing this behaviour via the plugin `adapter:` opt:

      plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: MyApp.ImageAdapter}

  Alternatively, pass an anonymous function directly:

      plugin dimensions: {EmAttachments.Plugins.Dimensions,
        adapter: fn path -> {:ok, %{width: 100, height: 100}} end}
  """

  @callback dimensions(path :: String.t()) ::
              {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, term()}
end
