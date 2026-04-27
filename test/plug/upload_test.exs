if Code.ensure_loaded?(Phoenix.Router) do
  defmodule EmAttachments.Plug.UploadTest do
    use ExUnit.Case, async: false
    use Plug.Test

    alias EmAttachments.Test.{Fixtures, Router}

    @router_opts Router.init([])

    defp dispatch(conn), do: Router.call(conn, @router_opts)

    # Pre-populate body_params so Plug.Parsers (called inside the upload plug)
    # skips parsing and uses our test data directly.
    defp with_upload(conn, params) do
      conn
      |> Map.put(:body_params, params)
      |> Map.put(:params, params)
    end

    test "uploads a valid PNG and returns serialized file JSON" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "photo.png",
        content_type: "image/png"
      }

      conn =
        conn(:post, "/upload")
        |> with_upload(%{"file" => upload})
        |> dispatch()

      assert conn.status == 200
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["storage"] == "cache"
      assert is_binary(body["id"])
      assert body["uploader"] == to_string(EmAttachments.Test.BasicUploader)
    end

    test "returns 422 when no file is present in the request" do
      conn =
        conn(:post, "/upload")
        |> with_upload(%{})
        |> dispatch()

      assert conn.status == 422
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"] == "no file uploaded"
    end

    test "returns 422 when the uploader rejects the file type" do
      upload = %Plug.Upload{
        path: Fixtures.txt_path(),
        filename: "notes.txt",
        content_type: "text/plain"
      }

      conn =
        conn(:post, "/upload")
        |> with_upload(%{"file" => upload})
        |> dispatch()

      assert conn.status == 422
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert is_binary(body["error"])
    end

    test "finds the Plug.Upload struct under any param key name" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "avatar.png",
        content_type: "image/png"
      }

      conn =
        conn(:post, "/upload")
        |> with_upload(%{"avatar" => upload})
        |> dispatch()

      assert conn.status == 200
    end
  end
end
