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

  @doc """
  The name to download a file as: `name` ending with the extension of the file's actual type
  (its asset id's, read from its bytes), `.jpg` and `.jpeg` being one. A legacy id without
  extension leaves `name` as it is.

      download_name(file, "Bail signé")   # => "Bail signé.pdf"
  """
  @spec download_name(%{id: String.t()}, String.t()) :: String.t()
  def download_name(%{id: id}, name) when is_binary(id) and is_binary(name) do
    extension = Path.extname(id)

    if extension == "" or same_extension?(Path.extname(name), extension),
      do: name,
      else: name <> extension
  end

  defp same_extension?(given, actual) do
    jpeg = ~w(.jpg .jpeg)
    given = String.downcase(given)
    given == actual or (given in jpeg and actual in jpeg)
  end

  @doc """
  Fetches the data produced by a plugin, by its key.

  Works with the `ctx` passed to a plugin's `init/2` or `upload/3`, the map passed
  to an uploader's `handle/2`, or an already-stored file struct. Returns `nil` when
  the key is absent (e.g. the plugin did not run before the caller, or isn't declared).

      def handle(:derivatives, %{file: file} = ctx) do
        case EmAttachments.plugin_data(ctx, :mime) do
          %{type: "image/" <> _} -> %{thumb: thumbnail(file)}
          _ -> :skip
        end
      end

  Note: in a plugin or `handle/2`, only the plugins declared *before* the caller are
  available. Declare data-producing plugins (e.g. `:mime`) before their consumers, or
  use `use EmAttachments.Plugin, depends_on: [...]` to force the order.
  """
  def plugin_data(container, key)
  def plugin_data(%{plugins: plugins}, key) when is_map(plugins), do: Map.get(plugins, key)

  def plugin_data(%{metadata: %{plugins: plugins}}, key) when is_map(plugins),
    do: Map.get(plugins, key)

  def plugin_data(_, _), do: nil
end
