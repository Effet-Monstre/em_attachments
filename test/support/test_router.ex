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

    # Route by route, as an application declaring each path with its verb does.
    @opts [uploader: EmAttachments.Test.BasicUploader, local_url: "/files/local"]
    post("/files/presign", EmAttachments.Plug.Upload, [action: :presign] ++ @opts)
    post("/files/local", EmAttachments.Plug.Upload, [action: :local] ++ @opts)
    post("/files/complete", EmAttachments.Plug.Upload, [action: :complete] ++ @opts)
  end
end
