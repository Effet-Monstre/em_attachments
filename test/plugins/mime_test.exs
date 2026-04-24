defmodule EmAttachments.Plugins.MimeTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Plugins.Mime, TempFile}
  alias EmAttachments.Test.Fixtures

  defp cache_upload(tf), do: Mime.init(tf, %{plugin_key: :mime, uploader: nil, deps: %{}, plugin_opts: []})

  defp tmp_file(content, name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "mime_test_#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}_#{name}"
      )

    File.write!(path, content)
    TempFile.new(path, name)
  end

  describe "init/2 (cache phase)" do
    test "detects PNG from magic bytes" do
      tf = TempFile.new(Fixtures.png_path(), "image.png")
      assert {:ok, %{type: "image/png", extension: "png"}} = cache_upload(tf)
    end

    test "detects JPEG from magic bytes" do
      tf = TempFile.new(Fixtures.jpeg_path(), "photo.jpg")
      assert {:ok, %{type: "image/jpeg", extension: "jpg"}} = cache_upload(tf)
    end

    test "detects GIF87a from magic bytes" do
      tf = tmp_file(<<"GIF87a", 0, 0>>, "anim.gif")
      assert {:ok, %{type: "image/gif", extension: "gif"}} = cache_upload(tf)
    end

    test "detects GIF89a from magic bytes" do
      tf = tmp_file(<<"GIF89a", 0, 0>>, "anim.gif")
      assert {:ok, %{type: "image/gif", extension: "gif"}} = cache_upload(tf)
    end

    test "detects WebP from magic bytes" do
      tf = tmp_file(<<"RIFF", 0::32, "WEBP">>, "image.webp")
      assert {:ok, %{type: "image/webp", extension: "webp"}} = cache_upload(tf)
    end

    test "detects PDF from magic bytes" do
      tf = tmp_file(<<"%PDF-1.4">>, "doc.pdf")
      assert {:ok, %{type: "application/pdf", extension: "pdf"}} = cache_upload(tf)
    end

    test "detects ZIP from magic bytes" do
      tf = tmp_file(<<"PK", 0x03, 0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0>>, "archive.zip")
      assert {:ok, %{type: "application/zip", extension: "zip"}} = cache_upload(tf)
    end

    test "detects MP3 (ID3 tag) from magic bytes" do
      tf = tmp_file(<<"ID3", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>, "audio.mp3")
      assert {:ok, %{type: "audio/mpeg", extension: "mp3"}} = cache_upload(tf)
    end

    test "detects MP3 (0xFF 0xFB sync) from magic bytes" do
      tf = tmp_file(<<0xFF, 0xFB, 0x90, 0x00>>, "audio.mp3")
      assert {:ok, %{type: "audio/mpeg", extension: "mp3"}} = cache_upload(tf)
    end

    test "detects MP4 (ftyp box) from magic bytes" do
      tf = tmp_file(<<0x00, 0x00, 0x00, 0x20, "ftyp", "isom", 0>>, "video.mp4")
      assert {:ok, %{type: "video/mp4", extension: "mp4"}} = cache_upload(tf)
    end

    test "detects BMP from magic bytes" do
      tf = tmp_file(<<"BM", 0, 0, 0, 0, 0, 0, 0, 0>>, "image.bmp")
      assert {:ok, %{type: "image/bmp", extension: "bmp"}} = cache_upload(tf)
    end

    test "detects TIFF little-endian from magic bytes" do
      tf = tmp_file(<<0x49, 0x49, 0x2A, 0x00, 0, 0, 0, 0>>, "image.tiff")
      assert {:ok, %{type: "image/tiff", extension: "tiff"}} = cache_upload(tf)
    end

    test "detects TIFF big-endian from magic bytes" do
      tf = tmp_file(<<0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 0>>, "image.tiff")
      assert {:ok, %{type: "image/tiff", extension: "tiff"}} = cache_upload(tf)
    end

    test "returns error for unknown type" do
      tf = TempFile.new(Fixtures.txt_path(), "file.txt")
      assert {:error, :unknown_mime_type} = cache_upload(tf)
    end
  end

  defp validate(validation_opts, own_result),
    do: Mime.validate(nil, own_result, %{plugin_key: :mime, plugin_opts: [], validation_opts: validation_opts})

  describe "validate/3" do
    test "passes when type is in allowed list" do
      assert :ok = validate([type: ~w(image/png)], %{type: "image/png", extension: "png"})
    end

    test "fails when type is not in allowed list" do
      assert {:error, msg} = validate([type: ~w(image/png)], %{type: "image/jpeg", extension: "jpg"})
      assert msg =~ "image/jpeg"
    end

    test "passes when extension is in allowed list" do
      assert :ok = validate([extension: ~w(png jpg)], %{type: "image/png", extension: "png"})
    end

    test "fails when extension is not in allowed list" do
      assert {:error, msg} = validate([extension: ~w(png)], %{type: "image/jpeg", extension: "jpg"})
      assert msg =~ "jpg"
    end

    test "accumulates multiple errors" do
      result = validate([type: ~w(image/png), extension: ~w(png)], %{type: "image/gif", extension: "gif"})
      assert {:error, errors} = result
      assert is_list(errors)
      assert length(errors) == 2
    end

    test "no validation opts always passes" do
      assert :ok = validate([], %{type: "anything", extension: "any"})
    end
  end
end
