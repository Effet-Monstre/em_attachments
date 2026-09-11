defmodule EmAttachments.Backends.S3.ContentTypeTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Backends.S3, BackendFile, MemoryFile}

  defp opts(name, extra \\ []) do
    Keyword.merge(
      [
        bucket: "test-bucket",
        prefix: "uploads",
        region: "us-east-1",
        access_key_id: "test-access-key",
        secret_access_key: "test-secret-key",
        req_options: [plug: {Req.Test, name}, retry: false]
      ],
      extra
    )
  end

  defp capture_request do
    name = {__MODULE__, make_ref()}
    owner = self()

    Req.Test.stub(name, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, Map.new(conn.req_headers)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    name
  end

  defp signed_headers(%{"authorization" => auth}) do
    [_, list] = Regex.run(~r/SignedHeaders=([^,]+)/, auth)
    String.split(list, ";")
  end

  describe "put/3" do
    test "sends the content type and includes it in the signature" do
      name = capture_request()
      source = MemoryFile.new("body", "logo.png")

      assert :ok = S3.put("abc.png", source, opts(name, content_type: "image/png"))

      assert_receive {:request, headers}
      assert headers["content-type"] == "image/png"
      assert "content-type" in signed_headers(headers)

      MemoryFile.cleanup(source)
    end

    test "omits the header entirely when no type was detected" do
      name = capture_request()
      source = MemoryFile.new("body", "unknown.bin")

      assert :ok = S3.put("abc", source, opts(name, content_type: nil))

      assert_receive {:request, headers}
      refute Map.has_key?(headers, "content-type")
      refute "content-type" in signed_headers(headers)

      MemoryFile.cleanup(source)
    end

    test "sets a content disposition with the original filename when asked" do
      name = capture_request()
      source = MemoryFile.new("body", ~s(my "report".pdf))

      assert :ok =
               S3.put(
                 "abc.pdf",
                 source,
                 opts(name, content_disposition: :attachment, filename: ~s(my "report".pdf))
               )

      assert_receive {:request, headers}
      assert headers["content-disposition"] == ~s(attachment; filename="my report.pdf")
      assert "content-disposition" in signed_headers(headers)

      MemoryFile.cleanup(source)
    end

    test "strips quotes and control characters from the disposition filename" do
      name = capture_request()
      source = MemoryFile.new("body", "x")
      evil = ~s(re"port\r\nX-Amz-Acl: public-read.pdf)

      assert :ok =
               S3.put(
                 "abc.pdf",
                 source,
                 opts(name, content_disposition: :inline, filename: evil)
               )

      assert_receive {:request, headers}

      assert headers["content-disposition"] ==
               ~s(inline; filename="reportX-Amz-Acl: public-read.pdf")

      MemoryFile.cleanup(source)
    end

    test "leaves content disposition alone by default" do
      name = capture_request()
      source = MemoryFile.new("body", "logo.png")

      assert :ok = S3.put("abc.png", source, opts(name, content_type: "image/png"))

      assert_receive {:request, headers}
      refute Map.has_key?(headers, "content-disposition")

      MemoryFile.cleanup(source)
    end
  end

  describe "same-bucket copy" do
    test "replaces metadata instead of inheriting the source object's missing type" do
      name = capture_request()
      backend_opts = opts(name)
      source = BackendFile.new(S3, backend_opts, "legacy-id", "legacy", 4)

      assert :ok =
               S3.put("abc.png", source, Keyword.put(backend_opts, :content_type, "image/png"))

      assert_receive {:request, headers}
      assert headers["x-amz-copy-source"] == "/test-bucket/uploads/legacy-id"
      assert headers["x-amz-metadata-directive"] == "REPLACE"
      assert headers["content-type"] == "image/png"
      assert "content-type" in signed_headers(headers)

      BackendFile.cleanup(source)
    end
  end
end
