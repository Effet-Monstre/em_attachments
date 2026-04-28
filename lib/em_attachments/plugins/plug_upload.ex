if Code.ensure_loaded?(Plug.Upload) do
  defmodule EmAttachments.Plugins.PlugUpload do
    @moduledoc """
    Cast plugin that accepts `%Plug.Upload{}` values from changeset params.

    Converts the upload to a `TempFile` so the rest of the pipeline has no
    knowledge of `Plug.Upload`.

    Included in the default plugin set when Plug is available. To use a
    different key or disable it, override `:default_plugins` in config:

        config :em_attachments, :config,
          default_plugins: [plug_upload: EmAttachments.Plugins.PlugUpload]
    """

    use EmAttachments.Plugin

    @impl true
    def cast(%Plug.Upload{} = upload, _ctx),
      do: {:ok, EmAttachments.TempFile.from_plug(upload)}

    def cast(_, _ctx), do: :skip
  end
end
