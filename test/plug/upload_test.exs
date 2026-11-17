if Code.ensure_loaded?(Phoenix.Router) do
  defmodule EmAttachments.Plug.UploadTest do
    use ExUnit.Case, async: false
    import Plug.Test

    alias EmAttachments.Test.{BasicUploader, Fixtures, Router}

    @router_opts Router.init([])

    defp dispatch(conn), do: Router.call(conn, @router_opts)

    # Pre-populate body_params so Plug.Parsers (called inside the upload plug)
    # skips parsing and uses our test data directly.
    defp with_params(conn, params) do
      conn
      |> Map.put(:body_params, params)
      |> Map.put(:params, params)
    end

    defp post(path, params), do: conn(:post, path) |> with_params(params) |> dispatch()

    defp body(conn), do: Jason.decode!(conn.resp_body)

    defp png(filename \\ "photo.png") do
      %Plug.Upload{path: Fixtures.png_path(), filename: filename, content_type: "image/png"}
    end

    describe "through the application (POST /)" do
      test "uploads a valid PNG and answers its signed token" do
        conn = post("/upload", %{"file" => png()})

        assert conn.status == 200
        body = body(conn)
        assert {:ok, file} = BasicUploader.verify(body["token"])
        assert file.id == body["id"]
        assert body["filename"] == "photo.png"
        assert body["content_type"] == "image/png"
        assert is_integer(body["size"])
        refute Map.has_key?(body, "uploader")
      end

      test "returns 422 when no file is present in the request" do
        conn = post("/upload", %{})

        assert conn.status == 422
        assert body(conn)["error"] == "no_file"
      end

      test "returns 422 not_accepted when the uploader rejects the file type" do
        upload = %Plug.Upload{path: Fixtures.txt_path(), filename: "notes.txt"}
        conn = post("/upload", %{"file" => upload})

        assert conn.status == 422
        assert body(conn)["error"] == "not_accepted"
        assert body(conn)["message"] =~ "invalid MIME type"
      end

      test "applies the plug's own validations over the uploader's" do
        conn = post("/strict", %{"file" => png()})

        assert conn.status == 422
        assert body(conn)["error"] == "not_accepted"
      end

      test "refuses a file over max_size" do
        conn = post("/tiny", %{"file" => png()})

        assert conn.status == 422
        assert body(conn)["error"] == "too_large"
      end

      test "finds the Plug.Upload struct under any param key name" do
        assert post("/upload", %{"avatar" => png()}).status == 200
      end
    end

    describe "direct: presign, POST to the slot, complete" do
      test "a slot on the Local backend points to the plug's own /local" do
        conn = post("/upload/presign", %{"size" => 1234})

        assert conn.status == 200
        assert %{"url" => "/upload/local", "fields" => fields, "token" => token} = body(conn)
        # The client posts the fields as they are: on Local they carry the slot's token.
        assert fields == %{"token" => token}

        assert {:ok, %{id: _, max_size: 100_000_000}} =
                 EmAttachments.Uploader.Pipeline.verify_slot(BasicUploader, token)
      end

      test "a size announced over max_size is refused before anything is signed" do
        conn = post("/tiny/presign", %{"size" => "999999"})

        assert conn.status == 422
        assert body(conn)["error"] == "too_large"
      end

      test "the whole flow answers the stored file's token" do
        %{"token" => slot} = body(post("/upload/presign", %{}))

        assert post("/upload/local", %{"token" => slot, "file" => png()}).status == 204

        conn = post("/upload/complete", %{"token" => slot, "filename" => "../dir/My photo.png"})

        assert conn.status == 200
        body = body(conn)
        assert {:ok, file} = BasicUploader.verify(body["token"])
        assert file.id =~ ~r/\.png$/
        assert body["filename"] == "My photo.png"
        assert body["content_type"] == "image/png"

        # The slot is gone: completing it again finds nothing.
        assert body(post("/upload/complete", %{"token" => slot}))["error"] == "not_found"
      end

      test "a refused file is not kept, its slot removed" do
        %{"token" => slot} = body(post("/upload/presign", %{}))
        txt = %Plug.Upload{path: Fixtures.txt_path(), filename: "notes.txt"}
        assert post("/upload/local", %{"token" => slot, "file" => txt}).status == 204

        conn = post("/upload/complete", %{"token" => slot, "filename" => "notes.txt"})

        assert conn.status == 422
        assert body(conn)["error"] == "not_accepted"
        assert body(post("/upload/complete", %{"token" => slot}))["error"] == "not_found"
      end

      test "a forged or missing slot token is refused" do
        assert body(post("/upload/local", %{"token" => "nope", "file" => png()}))["error"] ==
                 "invalid_token"

        assert body(post("/upload/complete", %{"token" => "nope"}))["error"] == "invalid_token"
        assert body(post("/upload/complete", %{}))["error"] == "invalid_token"
        assert body(post("/upload/local", %{"file" => png()}))["error"] == "no_file"
      end

      test "a file token is no slot token" do
        token = body(post("/upload", %{"file" => png()}))["token"]

        assert body(post("/upload/complete", %{"token" => token}))["error"] == "invalid_token"
      end

      test "the slot's max_size holds when filling it" do
        %{"token" => slot} = body(post("/tiny/presign", %{}))

        conn = post("/tiny/local", %{"token" => slot, "file" => png()})
        assert conn.status == 422
        assert body(conn)["error"] == "too_large"
      end
    end

    test "route by route (`:action`, `:local_url`), the same flow" do
      %{"url" => "/files/local", "fields" => fields} = body(post("/files/presign", %{}))

      assert post("/files/local", Map.put(fields, "file", png())).status == 204

      conn = post("/files/complete", %{"token" => fields["token"], "filename" => "a.png"})
      assert {:ok, _file} = BasicUploader.verify(body(conn)["token"])
    end

    test "anything else is a 404" do
      assert dispatch(conn(:get, "/upload/presign")).status == 404
      assert dispatch(conn(:post, "/upload/other")).status == 404
    end
  end
end
