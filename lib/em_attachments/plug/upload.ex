if Code.ensure_loaded?(Plug.Conn) do
  defmodule EmAttachments.Plug.Upload do
    @moduledoc """
    A Plug endpoint for AJAX / direct file uploads to the cache.

    The response JSON can be submitted as a hidden form field value and will be
    processed by `cast_attachments/2` on the next form submit.

    ## Usage

        # router.ex
        forward "/attachments/logo", EmAttachments.Plug.Upload,
          uploader: MyApp.LogoUploader

        # or inside a pipeline
        plug EmAttachments.Plug.Upload, uploader: MyApp.LogoUploader
    """

    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{} = conn, opts) do
      uploader = Keyword.fetch!(opts, :uploader)

      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], length: opts[:max_size] || 100_000_000))

      case find_upload(conn.body_params) do
        nil ->
          conn |> put_status(422) |> json(%{error: "no file uploaded"}) |> halt()

        upload ->
          case uploader.upload(upload) do
            {:ok, file} ->
              json_body = uploader.serialize(file)
              conn |> put_resp_content_type("application/json") |> send_resp(200, json_body)

            {:error, reason} ->
              conn |> put_status(422) |> json(%{error: inspect(reason)}) |> halt()
          end
      end
    end

    defp find_upload(params) when is_map(params) do
      Enum.find_value(params, fn
        {_key, %Plug.Upload{} = upload} -> upload
        _ -> nil
      end)
    end

    defp json(conn, data) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(conn.status || 200, Jason.encode!(data))
    end
  end
end
