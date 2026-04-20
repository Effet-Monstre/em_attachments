defmodule EmAttachments.Plugins.Mime do
  @moduledoc """
  Detects the real MIME type from magic bytes (not from file extension or browser-provided content-type).

  Cast result: `%{type: "image/png", extension: "png"}`

  Validation options:
    - `:type` — list of allowed MIME types
    - `:extension` — list of allowed extensions
  """

  use EmAttachments.Plugin

  @impl true
  def cast(temp_file, _uploader, _deps, _opts) do
    case detect(temp_file.path) do
      {:ok, {type, ext}} -> {:ok, %{type: type, extension: ext}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def validate(validation_opts, _temp_file, own_result, _plugin_opts) do
    errors =
      []
      |> check_type(validation_opts[:type], own_result[:type])
      |> check_extension(validation_opts[:extension], own_result[:extension])

    case errors do
      [] -> :ok
      [single] -> {:error, single}
      many -> {:error, many}
    end
  end

  defp check_type(errors, nil, _), do: errors
  defp check_type(errors, allowed, detected) do
    if detected in allowed,
      do: errors,
      else: ["invalid MIME type #{inspect(detected)}, allowed: #{Enum.join(allowed, ", ")}" | errors]
  end

  defp check_extension(errors, nil, _), do: errors
  defp check_extension(errors, allowed, detected) do
    if detected in allowed,
      do: errors,
      else: ["invalid extension #{inspect(detected)}, allowed: #{Enum.join(allowed, ", ")}" | errors]
  end

  # Magic bytes detection — no external dependency.
  defp detect(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        bytes = IO.binread(file, 16)
        File.close(file)
        detect_bytes(bytes)

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  defp detect_bytes(_), do: {:error, :unknown_mime_type}
end
