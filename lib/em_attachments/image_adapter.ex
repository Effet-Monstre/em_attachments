defmodule EmAttachments.ImageAdapter do
  @moduledoc """
  Behaviour for image library adapters used by `EmAttachments.Plugins.Dimensions`.

  Configure globally:

      config :em_attachments, :config,
        image_adapter: EmAttachments.ImageAdapters.Vix

  Or per-plugin:

      plugins: [dimensions: {Plugins.Dimensions, adapter: EmAttachments.ImageAdapters.Mogrify}]
  """

  @callback dimensions(path :: String.t()) ::
              {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, term()}
end
