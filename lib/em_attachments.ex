defmodule EmAttachments do
  @moduledoc """
  File attachment library for Elixir. Inspired by Shrine for Rails.

  See `EmAttachments.Uploader` for how to define uploaders.
  """

  def url(file, opts \\ [])
  def url(nil, _opts), do: nil

  def url(%{uploader: uploader_str} = file, opts) when is_binary(uploader_str) do
    uploader = String.to_existing_atom(uploader_str)

    if Code.ensure_loaded?(uploader) do
      uploader.url(file, opts)
    end
  rescue
    ArgumentError -> nil
  end

  def url(_, _), do: nil
end
