defmodule EmAttachments.Backends.S3.SignerTest do
  use ExUnit.Case, async: true

  alias EmAttachments.Backends.S3.Signer

  @opts [
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "us-east-1"
  ]

  test "sign_request returns a list of headers including authorization" do
    headers =
      Signer.sign_request(
        :put,
        "https://mybucket.s3.amazonaws.com/uploads/file.txt",
        %{},
        :unsigned,
        @opts
      )

    assert is_list(headers)
    auth = Enum.find_value(headers, fn {k, v} -> k == "authorization" and v end)
    assert auth =~ "AWS4-HMAC-SHA256"
    assert auth =~ "Credential=AKIAIOSFODNN7EXAMPLE"
    assert auth =~ "SignedHeaders="
    assert auth =~ "Signature="
  end

  test "sign_request includes x-amz-date header" do
    headers =
      Signer.sign_request(:get, "https://mybucket.s3.amazonaws.com/test", %{}, :unsigned, @opts)

    date_header = Enum.find_value(headers, fn {k, v} -> k == "x-amz-date" and v end)
    assert date_header =~ ~r/^\d{8}T\d{6}Z$/
  end

  test "presign_url returns a URL with AWS query params" do
    url = Signer.presign_url("https://mybucket.s3.amazonaws.com/uploads/file.txt", 3600, @opts)
    assert url =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
    assert url =~ "X-Amz-Credential="
    assert url =~ "X-Amz-Signature="
    assert url =~ "X-Amz-Expires=3600"
  end

  test "presign_post returns url and fields map" do
    {url, fields} =
      Signer.presign_post(
        "https://mybucket.s3.amazonaws.com",
        "mybucket",
        "cache/",
        3600,
        @opts
      )

    assert String.starts_with?(url, "https://")
    assert is_map(fields)
    assert Map.has_key?(fields, "policy")
    assert Map.has_key?(fields, "x-amz-signature")
    assert Map.has_key?(fields, "x-amz-credential")
  end

  test "presign_url produces different signatures for different expiry" do
    url1 = Signer.presign_url("https://mybucket.s3.amazonaws.com/file", 3600, @opts)
    url2 = Signer.presign_url("https://mybucket.s3.amazonaws.com/file", 7200, @opts)
    # Different expiry → different canonical request → different signature
    refute url1 == url2
  end
end
