defmodule EmAttachments.Plugins.UrlUpload do
  @moduledoc """
  Cast plugin that accepts `{:url, url}` values from changeset params.

  Downloads the remote file via `Req` and wraps the response body in a
  `MemoryFile` before passing it to the upload pipeline.

      plugin url_upload: EmAttachments.Plugins.UrlUpload
  """

  use EmAttachments.Plugin

  @impl true
  def cast({:url, url}, _ctx) when is_binary(url) do
    filename =
      case url |> URI.parse() |> Map.get(:path, "") |> Path.basename() do
        "" -> "upload"
        name -> name
      end

    case Req.get(url, decode_body: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, EmAttachments.MemoryFile.new(body, filename)}
      {:ok, %{status: status}} -> {:error, "download failed: HTTP #{status}"}
      {:error, reason} -> {:error, "download failed: #{inspect(reason)}"}
    end
  end

  def cast(_, _ctx), do: :skip
end
