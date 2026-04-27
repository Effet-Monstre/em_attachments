if Code.ensure_loaded?(Phoenix.Router) do
  defmodule EmAttachments.Test.Router do
    use Phoenix.Router, helpers: false

    forward "/upload", EmAttachments.Plug.Upload,
      uploader: EmAttachments.Test.BasicUploader
  end
end
