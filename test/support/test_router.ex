if Code.ensure_loaded?(Phoenix.Router) do
  defmodule EmAttachments.Test.Router do
    use Phoenix.Router, helpers: false

    forward("/upload", EmAttachments.Plug.Upload, uploader: EmAttachments.Test.BasicUploader)

    forward("/strict", EmAttachments.Plug.Upload,
      uploader: EmAttachments.Test.BasicUploader,
      validates: [mime: [type: ~w(image/jpeg)]]
    )

    forward("/tiny", EmAttachments.Plug.Upload,
      uploader: EmAttachments.Test.BasicUploader,
      max_size: 10
    )

    # Uploads and files under one path, as an application mounts them.
    import EmAttachments.Router
    attachments("/files", uploader: EmAttachments.Test.BasicUploader)
  end
end
