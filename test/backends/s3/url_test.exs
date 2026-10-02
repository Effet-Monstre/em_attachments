defmodule EmAttachments.Backends.S3.UrlTest do
  use ExUnit.Case, async: true

  alias EmAttachments.Backends.S3

  @opts [
    bucket: "test-bucket",
    region: "us-east-1",
    access_key_id: "test-access-key",
    secret_access_key: "test-secret-key"
  ]

  defp url_query(extra) do
    {:ok, url} = S3.url("abc.pdf", Keyword.merge(@opts, extra))
    URI.decode_query(URI.parse(url).query || "")
  end

  test "signs overrides as response-* parameters" do
    plain = url_query([])
    query = url_query(response: [content_type: "application/pdf", cache_control: "no-store"])

    assert query["response-content-type"] == "application/pdf"
    assert query["response-cache-control"] == "no-store"
    refute query["X-Amz-Signature"] == plain["X-Amz-Signature"]
  end

  test "a disposition mode carries the filename" do
    assert url_query(response: [content_disposition: :attachment], filename: "report.pdf")[
             "response-content-disposition"
           ] == ~s(attachment; filename="report.pdf")
  end

  test "a public object is presigned only with overrides" do
    assert {:ok, "https://test-bucket.s3.amazonaws.com/uploads/abc.pdf"} =
             S3.url("abc.pdf", Keyword.put(@opts, :acl, :public_read))

    assert url_query(acl: :public_read, response: [content_type: "application/pdf"])[
             "X-Amz-Signature"
           ]
  end

  test "rejects unknown override keys" do
    assert_raise ArgumentError, fn -> url_query(response: [content_typ: "application/pdf"]) end
  end
end
