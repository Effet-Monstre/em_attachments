defmodule EmAttachments.Test.Fixtures do
  @moduledoc false

  @doc "Returns a path to a minimal valid PNG file."
  def png_path do
    path = Path.join(System.tmp_dir!(), "test_#{random()}.png")
    # Minimal 1×1 transparent PNG (67 bytes).
    png =
      <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
        0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00,
        0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

    File.write!(path, png)
    path
  end

  @doc "Returns a path to a minimal JPEG file."
  def jpeg_path do
    path = Path.join(System.tmp_dir!(), "test_#{random()}.jpg")
    # Minimal JPEG SOI + EOI.
    File.write!(path, <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0xFF, 0xD9>>)
    path
  end

  @doc "Returns a path to a minimal GIF89a file."
  def gif_path do
    path = Path.join(System.tmp_dir!(), "test_#{random()}.gif")
    # Minimal 1×1 GIF89a (header + logical screen descriptor + trailer).
    File.write!(path, <<"GIF89a", 1::16-little, 1::16-little, 0, 0, 0, 0x3B>>)
    path
  end

  @doc "Returns a path to a plain text file."
  def txt_path(content \\ "hello world") do
    path = Path.join(System.tmp_dir!(), "test_#{random()}.txt")
    File.write!(path, content)
    path
  end

  def random, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
end
