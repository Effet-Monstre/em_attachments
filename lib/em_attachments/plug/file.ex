if Code.ensure_loaded?(Plug.Conn) do
  defmodule EmAttachments.Plug.File do
    @moduledoc """
    Serves a stored file by the token of its URL (`c:EmAttachments.Uploader.url_token/2`): a
    redirect to a short-lived URL of the store (S3's presigned GET), shown inline, or downloaded
    with `?download=1`, named as the token says. A token that is invalid, expired, or names a
    file no record holds any more is a `404`.

    The token is the authorization: the application hands it only to who may see the record
    holding the file, and mounts this plug behind its own authentication if a URL alone must
    not be enough. Mounted by `EmAttachments.Router.attachments/2` as `GET <path>/:token`.

    ## Options

      - `:uploader` (required)
      - `:url_expires_in` the redirect's lifetime in seconds (300 by default); the browser keeps
        the redirect a minute less (`cache-control: private`)
    """

    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{} = conn, opts) do
      uploader = Keyword.fetch!(opts, :uploader)
      expires_in = opts[:url_expires_in] || 300
      conn = fetch_query_params(conn)

      case uploader.verify_url_token(token(conn)) do
        {:ok, file, name} ->
          disposition = if conn.query_params["download"], do: :attachment, else: :inline

          url =
            uploader.url(file,
              url_expires_in: expires_in,
              response: [content_disposition: disposition],
              filename: EmAttachments.download_name(file, name)
            )

          conn
          |> put_resp_header("cache-control", "private, max-age=#{max(expires_in - 60, 0)}")
          |> put_resp_header("location", url)
          |> send_resp(302, "")
          |> halt()

        {:error, _reason} ->
          conn |> send_resp(404, "") |> halt()
      end
    end

    defp token(%{path_params: %{"token" => token}}) when is_binary(token), do: token
    defp token(%{path_info: [_ | _] = path}), do: List.last(path)
    defp token(_conn), do: ""
  end
end
