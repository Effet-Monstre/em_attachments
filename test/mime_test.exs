defmodule EmAttachments.MimeTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{MemoryFile, Mime}
  alias EmAttachments.Test.Fixtures

  defp detect_bytes(bytes) do
    path = Path.join(System.tmp_dir!(), "em_mime_#{Fixtures.random()}")
    File.write!(path, bytes)

    try do
      Mime.detect(path)
    after
      File.rm(path)
    end
  end

  defp detect_fixture(path) do
    try do
      Mime.detect(path)
    after
      File.rm(path)
    end
  end

  describe "detect/1" do
    test "recognises the image fixtures" do
      assert {:ok, {"image/png", "png"}} = detect_fixture(Fixtures.png_path())
      assert {:ok, {"image/jpeg", "jpg"}} = detect_fixture(Fixtures.jpeg_path())
      assert {:ok, {"image/gif", "gif"}} = detect_fixture(Fixtures.gif_path())
    end

    test "recognises formats by magic bytes alone" do
      assert {:ok, {"application/pdf", "pdf"}} = detect_bytes("%PDF-1.7\nrest")
      assert {:ok, {"application/zip", "zip"}} = detect_bytes(<<"PK", 3, 4, 0, 0, 0, 0>>)
      assert {:ok, {"image/webp", "webp"}} = detect_bytes(<<"RIFF", 0::32, "WEBP", 0, 0, 0, 0>>)
      assert {:ok, {"video/mp4", "mp4"}} = detect_bytes(<<0::32, "ftyp", 0, 0, 0, 0>>)
      assert {:ok, {"image/bmp", "bmp"}} = detect_bytes(<<"BM", 0, 0, 0, 0>>)
    end

    test "ignores the filename extension and reads the bytes" do
      assert {:ok, {"image/png", "png"}} =
               detect_fixture(Fixtures.txt_path(Fixtures.proper_png()))
    end

    test "returns no type rather than an error for unknown bytes" do
      assert {:ok, {nil, nil}} = detect_fixture(Fixtures.txt_path())
    end

    test "returns an error for a missing file" do
      assert {:error, :enoent} = Mime.detect("/nonexistent/em_attachments/file")
    end
  end

  describe "detect_source/1" do
    test "detects through the SourceFile protocol" do
      source = MemoryFile.new(Fixtures.proper_png(), "logo.png")
      assert {:ok, {"image/png", "png"}} = Mime.detect_source(source)
      MemoryFile.cleanup(source)
    end
  end

  describe "extension_suffix/1" do
    test "prefixes a known extension with a dot and yields nothing for an unknown one" do
      assert Mime.extension_suffix("png") == ".png"
      assert Mime.extension_suffix(nil) == ""
    end
  end
end
