if Code.ensure_loaded?(Plug.Conn) do
  defmodule EmAttachments.Plug.Upload do
    @moduledoc """
    The upload endpoint an application mounts: a client uploads a file and gets back a
    **signed token**, the only thing `cast_attachments/3` takes from it to attach the file
    to a record. Who may upload is the application's pipeline; what is accepted is the
    plug's options.

        # router.ex, behind the application's authentication
        forward "/api/uploads", EmAttachments.Plug.Upload,
          uploader: MyApp.FileUploader,
          max_size: 100_000_000,
          validates: [mime: [type: ~w(image/png image/jpeg application/pdf)]]

    In a Phoenix router, `EmAttachments.Router.attachments/2` mounts it with the file route
    (`EmAttachments.Plug.File`) under one path.

    Two ways in, the same answer:

      - **Direct** (the bytes never pass through the application on S3):
        1. `POST /presign` (optional `size`): `{url, fields, token, complete_url}`;
        2. a `multipart/form-data` POST to `url` with every `fields` entry as given, then
           `file` last (S3's presigned POST, or `POST /local` on the Local backend, whose
           fields carry the slot's `token`);
        3. `POST /complete` with `token` and `filename`: the object is checked from its first
           bytes, stored under its asset id, and its file returned.
      - **Through the application**: `POST /` with a multipart `file`.

    Success is `200` with `{token, id, filename, size, content_type}`. A refusal is `422`
    with `{error, message}`, `error` one of `too_large`, `not_accepted`, `invalid_token`,
    `not_found`, `no_file`; a storage failure is `502` with `error: "storage"`.

    ## Options

      - `:uploader` (required)
      - `:max_size` in bytes (100 MB by default)
      - `:validates` merged over the uploader's own (`validates mime: [...]`)
      - `:expires_in` the presigned slot's lifetime in seconds (3600 by default)
      - `:on_storage_error` `{module, function}` called with the reason of a storage failure
        (to report it), before the `502`
      - `:action` (`:upload`, `:presign`, `:local`, `:complete`) instead of routing by path
      - `:base` the path its other routes are under (`EmAttachments.Router` sets it)
      - `:local_url` where the Local backend's slot is posted (`<base>/local` by default)
    """

    @behaviour Plug

    import Plug.Conn

    alias EmAttachments.Uploader.Pipeline

    @default_max_size 100_000_000

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{} = conn, opts) do
      opts = Keyword.put_new(opts, :max_size, @default_max_size)

      case opts[:action] || action(conn) do
        :upload -> through_app(conn, opts)
        :presign -> presign(conn, opts)
        :local -> local(conn, opts)
        :complete -> complete(conn, opts)
        nil -> conn |> send_resp(404, "") |> halt()
      end
    end

    defp action(%{method: "POST", path_info: []}), do: :upload
    defp action(%{method: "POST", path_info: ["presign"]}), do: :presign
    defp action(%{method: "POST", path_info: ["local"]}), do: :local
    defp action(%{method: "POST", path_info: ["complete"]}), do: :complete
    defp action(_conn), do: nil

    defp through_app(conn, opts) do
      conn = parse(conn, opts[:max_size])

      case find_upload(conn.body_params) do
        nil ->
          refuse(conn, :no_file)

        upload ->
          uploader = opts[:uploader]

          upload
          |> EmAttachments.TempFile.from_plug()
          |> uploader.upload(upload_opts(opts))
          |> answer(conn, opts)
      end
    end

    defp presign(conn, opts) do
      conn = parse(conn, 1_000_000)
      max_size = opts[:max_size]

      case integer(conn.body_params["size"]) do
        size when is_integer(size) and size > max_size ->
          refuse(conn, :too_large)

        _size ->
          slot_opts = [
            max_size: max_size,
            expires_in: opts[:expires_in] || 3600,
            upload_url: opts[:local_url] || sibling(conn, opts, "local")
          ]

          case opts[:uploader].presign(slot_opts) do
            {:ok, slot} ->
              json(conn, 200, Map.put(slot, :complete_url, sibling(conn, opts, "complete")))

            {:error, reason} ->
              storage_error(conn, reason, opts)
          end
      end
    end

    defp local(conn, opts) do
      conn = parse(conn, opts[:max_size])
      uploader = opts[:uploader]

      with %{"token" => token} when is_binary(token) <- conn.body_params,
           %Plug.Upload{} = upload <- conn.body_params["file"] do
        case Pipeline.fill_slot(uploader, token, EmAttachments.TempFile.from_plug(upload)) do
          :ok -> conn |> send_resp(204, "") |> halt()
          {:error, reason} when reason in [:invalid, :expired] -> refuse(conn, :invalid_token)
          {:error, :too_large} -> refuse(conn, :too_large)
          {:error, reason} -> storage_error(conn, reason, opts)
        end
      else
        _missing -> refuse(conn, :no_file)
      end
    end

    defp complete(conn, opts) do
      conn = parse(conn, 1_000_000)
      uploader = opts[:uploader]

      case conn.body_params["token"] do
        token when is_binary(token) ->
          complete_opts = [filename: conn.body_params["filename"]] ++ upload_opts(opts)

          token
          |> uploader.complete(complete_opts)
          |> answer(conn, opts)

        _none ->
          refuse(conn, :invalid_token)
      end
    end

    defp upload_opts(opts) do
      [max_size: opts[:max_size]] ++
        if(opts[:validates], do: [validates: opts[:validates]], else: [])
    end

    defp answer({:ok, file}, conn, opts) do
      json(conn, 200, %{
        token: opts[:uploader].sign(file),
        id: file.id,
        filename: file.metadata[:filename],
        size: file.metadata[:size],
        content_type: get_in(file.metadata, [:plugins, :mime, :type])
      })
    end

    defp answer({:error, reason}, conn, _opts) when is_list(reason) or is_binary(reason),
      do: refuse(conn, :not_accepted, Enum.join(List.wrap(reason), ", "))

    defp answer({:error, reason}, conn, _opts) when reason in [:invalid, :expired],
      do: refuse(conn, :invalid_token)

    defp answer({:error, reason}, conn, _opts) when reason in [:too_large, :not_found],
      do: refuse(conn, reason)

    defp answer({:error, reason}, conn, opts), do: storage_error(conn, reason, opts)

    @messages %{
      too_large: "file is too large",
      not_accepted: "file type is not accepted",
      invalid_token: "upload token is invalid or expired",
      not_found: "nothing was uploaded for this token",
      no_file: "no file uploaded"
    }

    defp refuse(conn, code, message \\ nil) do
      json(conn, 422, %{error: code, message: message || @messages[code]})
    end

    defp storage_error(conn, reason, opts) do
      with {module, function} <- opts[:on_storage_error], do: apply(module, function, [reason])
      json(conn, 502, %{error: :storage, message: EmAttachments.Error.message(reason)})
    end

    # This plug's other routes: under `:base` (`EmAttachments.Router`), else its mount.
    defp sibling(_conn, %{base: base}, name), do: base <> "/" <> name
    defp sibling(conn, opts, name) when is_list(opts), do: sibling(conn, Map.new(opts), name)
    defp sibling(conn, _opts, name), do: "/" <> Enum.join(conn.script_name ++ [name], "/")

    defp parse(conn, length) do
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason,
          length: length
        )
      )
    end

    defp integer(value) when is_integer(value), do: value

    defp integer(value) when is_binary(value) do
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> nil
      end
    end

    defp integer(_value), do: nil

    defp find_upload(params) when is_map(params) do
      Enum.find_value(params, fn
        {_key, %Plug.Upload{} = upload} -> upload
        _ -> nil
      end)
    end

    defp json(conn, status, data) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(data))
      |> halt()
    end
  end
end
