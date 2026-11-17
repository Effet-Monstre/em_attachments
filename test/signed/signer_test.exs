defmodule EmAttachments.SignerTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Signer, Util}

  test "gives back what it signed, for the same purpose only" do
    token = Signer.sign("file", %{"a" => 1}, 60)

    assert {:ok, %{"a" => 1}} = Signer.verify("file", token)
    assert {:error, :invalid} = Signer.verify("upload", token)
  end

  test "refuses a tampered, truncated or foreign token" do
    token = Signer.sign("file", "data", 60)
    [payload, mac] = String.split(token, ".")
    forged = Base.url_encode64(~s({"d":"other","e":9999999999}), padding: false)

    assert {:error, :invalid} = Signer.verify("file", forged <> "." <> mac)
    assert {:error, :invalid} = Signer.verify("file", payload)
    assert {:error, :invalid} = Signer.verify("file", payload <> ".x")
    assert {:error, :invalid} = Signer.verify("file", nil)
  end

  test "refuses an expired token" do
    assert {:error, :expired} = Signer.verify("file", Signer.sign("file", "data", -1))
  end

  describe "Util.sanitize_filename/1" do
    test "keeps the last path segment, without control characters or quotes" do
      assert Util.sanitize_filename("../../etc/pass\"wd") == "passwd"
      assert Util.sanitize_filename("C:\\Users\\me\\photo.jpg") == "photo.jpg"
      assert Util.sanitize_filename("a\u0000b\nc  d.pdf") == "abc d.pdf"
    end

    test "is nil when nothing is left" do
      assert Util.sanitize_filename("  ") == nil
      assert Util.sanitize_filename("dir/") == nil
      assert Util.sanitize_filename(<<0xFF>>) == nil
      assert Util.sanitize_filename(nil) == nil
    end

    test "truncates to 120 characters, the extension kept" do
      name = Util.sanitize_filename(String.duplicate("é", 200) <> ".jpeg")

      assert String.length(name) == 120
      assert String.ends_with?(name, "é.jpeg")
    end
  end

  test "EmAttachments.download_name/2 ends a name with the file's actual extension" do
    file = %EmAttachments.Test.BasicUploader{id: "0190.jpg"}

    assert EmAttachments.download_name(file, "Bail") == "Bail.jpg"
    assert EmAttachments.download_name(file, "photo.JPEG") == "photo.JPEG"
    assert EmAttachments.download_name(file, "photo.png") == "photo.png.jpg"
    assert EmAttachments.download_name(%{file | id: "legacy"}, "Bail") == "Bail"
  end

  test "EmAttachments.Error.message/1 tells a storage failure briefly" do
    body = "<Error><Code>PermanentRedirect</Code><Message>...</Message></Error>"

    assert EmAttachments.Error.message({301, body}) == "S3 301 PermanentRedirect"
    assert EmAttachments.Error.message({500, ""}) == "S3 500"
    assert EmAttachments.Error.message(:timeout) == "timeout"
    assert EmAttachments.Error.message(%RuntimeError{message: "boom"}) == "boom"
  end
end
