defmodule EmAttachments.Router do
  @moduledoc """
  Mounts an uploader's routes in a Phoenix router, under one path, behind the scope's pipelines
  (who may upload and read is the application's):

      import EmAttachments.Router

      scope "/" do
        pipe_through [:api, :authenticated]

        attachments "/api/files",
          uploader: MyApp.FileUploader,
          max_size: 100_000_000,
          validates: [mime: [type: ~w(image/png image/jpeg application/pdf)]]
      end

  gives:

      POST /api/files            a slot for a direct upload (`EmAttachments.Plug.Upload`),
                                 with the URL completing it (`complete_url`)
      POST /api/files/local      the Local backend's slot, filled
      POST /api/files/complete   the slot's file checked, its signed token
      GET  /api/files/:token     a stored file, by its URL's token (`EmAttachments.Plug.File`)

  The path is a string, or anything that expands to one at compile time (a route helper
  macro). The options go to both plugs (`EmAttachments.Plug.Upload`'s, and `:url_expires_in`).
  A file's URL is the path, then its token: `"/api/files/" <> MyApp.FileUploader.url_token(file)`.
  """

  @doc "Mounts the upload and file routes of an uploader under `path`."
  defmacro attachments(path, opts) do
    path =
      case Macro.expand(path, __CALLER__) do
        path when is_binary(path) ->
          String.trim_trailing(path, "/")

        other ->
          raise ArgumentError,
                "attachments/2 needs a path known at compile time, got: #{Macro.to_string(other)}"
      end

    upload = EmAttachments.Plug.Upload
    file = EmAttachments.Plug.File

    quote do
      Phoenix.Router.post(
        unquote(path),
        unquote(upload),
        [action: :presign, base: unquote(path)] ++ unquote(opts)
      )

      Phoenix.Router.post(
        unquote(path <> "/local"),
        unquote(upload),
        [action: :local, base: unquote(path)] ++ unquote(opts)
      )

      Phoenix.Router.post(
        unquote(path <> "/complete"),
        unquote(upload),
        [action: :complete, base: unquote(path)] ++ unquote(opts)
      )

      Phoenix.Router.get(unquote(path <> "/:token"), unquote(file), unquote(opts))
    end
  end
end
