defmodule EmAttachments.Plugins.UrlUpload do
  @moduledoc """
  Cast plugin that accepts `{:url, url}` values from changeset params.

  Streams the remote file via `Req` into a managed tempfile before passing it
  to the upload pipeline. The tempfile is removed when processing finishes.

  Plugin options:
    - `:req_options` — options merged into the `Req.get/2` call.

      plugin url_upload: EmAttachments.Plugins.UrlUpload
  """

  use EmAttachments.Plugin

  @impl true
  def cast({:url, url}, ctx) when is_binary(url) do
    filename =
      case url |> URI.parse() |> Map.get(:path, "") |> Path.basename() do
        "" -> "upload"
        name -> name
      end

    path =
      Path.join(
        System.tmp_dir!(),
        "em_attach_url_#{EmAttachments.Util.random_id(8)}"
      )

    req_options = Keyword.get(ctx.plugin_opts, :req_options, [])
    options = Keyword.merge(req_options, decode_body: false, into: File.stream!(path))

    try do
      case Req.get(url, options) do
        {:ok, %{status: 200}} ->
          {:ok, EmAttachments.TempFile.managed(path, filename)}

        {:ok, %{status: status}} ->
          File.rm(path)
          {:error, "download failed: HTTP #{status}"}

        {:error, reason} ->
          File.rm(path)
          {:error, "download failed: #{inspect(reason)}"}
      end
    rescue
      exception ->
        File.rm(path)
        reraise exception, __STACKTRACE__
    end
  end

  def cast(_, _ctx), do: :skip
end
