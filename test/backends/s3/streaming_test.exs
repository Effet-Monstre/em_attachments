defmodule EmAttachments.Backends.S3.StreamingTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Backends.S3, MemoryFile}

  defp opts(name) do
    [
      bucket: "test-bucket",
      prefix: "uploads",
      region: "us-east-1",
      access_key_id: "test-access-key",
      secret_access_key: "test-secret-key",
      req_options: [plug: {Req.Test, name}, retry: false]
    ]
  end

  test "streams uploads from a local path instead of retaining a file-sized binary" do
    name = {__MODULE__, make_ref()}
    owner = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:uploaded, body, Plug.Conn.get_req_header(conn, "content-length")})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    source = MemoryFile.new(String.duplicate("stream-me", 10_000), "large.bin")
    assert :ok = S3.put("asset", source, opts(name))
    assert %{data: nil, local_path: path} = MemoryFile.state(source)
    assert File.exists?(path)

    assert_receive {:uploaded, body, [content_length]}
    assert byte_size(body) == String.to_integer(content_length)
    assert body == String.duplicate("stream-me", 10_000)

    MemoryFile.cleanup(source)
  end
end
