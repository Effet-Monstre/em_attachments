defmodule EmAttachments.Mime do
  @moduledoc """
  Magic-byte MIME detection. No external dependency, no trust in filenames.

  Returns `{:ok, {type, extension}}`, or `{:ok, {nil, nil}}` when no signature
  matches — an unknown file is not an error, it just has no type to declare.
  """

  alias EmAttachments.SourceFile

  @spec detect(String.t()) :: {:ok, {String.t() | nil, String.t() | nil}} | {:error, term()}
  def detect(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          file |> IO.binread(16) |> detect_bytes()
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec detect_source(SourceFile.t()) ::
          {:ok, {String.t() | nil, String.t() | nil}} | {:error, term()}
  def detect_source(source) do
    with {:ok, path} <- SourceFile.fetch_local_path(source), do: detect(path)
  end

  @doc """
  Like `detect_source/1` but reports an undetectable file the same way as an unreadable
  one: as having no type. Callers that store a file regardless of its type want this.
  """
  @spec type_and_extension(SourceFile.t()) :: {String.t() | nil, String.t() | nil}
  def type_and_extension(source) do
    case detect_source(source) do
      {:ok, pair} -> pair
      {:error, _} -> {nil, nil}
    end
  end

  @doc "Returns `\".jpg\"` for a known extension, `\"\"` for `nil`."
  @spec extension_suffix(String.t() | nil) :: String.t()
  def extension_suffix(nil), do: ""
  def extension_suffix(ext) when is_binary(ext), do: "." <> ext

  # PNG
  defp detect_bytes(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>),
    do: {:ok, {"image/png", "png"}}

  # JPEG
  defp detect_bytes(<<0xFF, 0xD8, 0xFF, _::binary>>),
    do: {:ok, {"image/jpeg", "jpg"}}

  # GIF
  defp detect_bytes(<<"GIF87a", _::binary>>), do: {:ok, {"image/gif", "gif"}}
  defp detect_bytes(<<"GIF89a", _::binary>>), do: {:ok, {"image/gif", "gif"}}

  # WebP — RIFF????WEBP
  defp detect_bytes(<<"RIFF", _::32, "WEBP", _::binary>>),
    do: {:ok, {"image/webp", "webp"}}

  # PDF
  defp detect_bytes(<<"%PDF", _::binary>>),
    do: {:ok, {"application/pdf", "pdf"}}

  # ZIP
  defp detect_bytes(<<"PK", 0x03, 0x04, _::binary>>),
    do: {:ok, {"application/zip", "zip"}}

  # MP3
  defp detect_bytes(<<"ID3", _::binary>>), do: {:ok, {"audio/mpeg", "mp3"}}
  defp detect_bytes(<<0xFF, 0xFB, _::binary>>), do: {:ok, {"audio/mpeg", "mp3"}}
  defp detect_bytes(<<0xFF, 0xF3, _::binary>>), do: {:ok, {"audio/mpeg", "mp3"}}

  # MP4 / MOV (ftyp box)
  defp detect_bytes(<<_::32, "ftyp", _::binary>>), do: {:ok, {"video/mp4", "mp4"}}

  # BMP
  defp detect_bytes(<<"BM", _::binary>>), do: {:ok, {"image/bmp", "bmp"}}

  # TIFF (little-endian and big-endian)
  defp detect_bytes(<<0x49, 0x49, 0x2A, 0x00, _::binary>>), do: {:ok, {"image/tiff", "tiff"}}
  defp detect_bytes(<<0x4D, 0x4D, 0x00, 0x2A, _::binary>>), do: {:ok, {"image/tiff", "tiff"}}

  # No magic bytes matched — leave type/extension unset rather than failing the upload.
  defp detect_bytes(_), do: {:ok, {nil, nil}}
end
