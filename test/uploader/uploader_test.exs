defmodule EmAttachments.UploaderTest do
  use ExUnit.Case, async: false

  alias EmAttachments.Test.{BasicUploader, DerivativeUploader, NoPluginUploader, Fixtures}

  # ---------------------------------------------------------------------------
  # upload/1 → cache
  # ---------------------------------------------------------------------------

  test "upload stores file in cache and returns a struct" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    assert {:ok, file} = BasicUploader.upload(input)
    assert file.storage == :cache
    assert file.id != nil
    assert file.metadata.filename == "logo.png"
    assert file.metadata.plugins.mime.type == "image/png"
    assert file.uploader == to_string(BasicUploader)
  end

  test "upload fails validation when MIME type not allowed" do
    input = %{path: Fixtures.txt_path(), filename: "doc.txt"}
    assert {:error, errors} = BasicUploader.upload(input)
    assert is_list(errors)
  end

  test "upload with no plugins succeeds for any file" do
    input = %{path: Fixtures.txt_path(), filename: "notes.txt"}
    assert {:ok, file} = NoPluginUploader.upload(input)
    assert file.storage == :cache
  end

  # ---------------------------------------------------------------------------
  # promote/1 → store
  # ---------------------------------------------------------------------------

  test "promote moves file from cache to store" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    assert {:ok, stored} = BasicUploader.promote(cached)
    assert stored.storage == :store
    assert stored.id == cached.id
  end

  test "promote is idempotent when already in store" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    {:ok, stored} = BasicUploader.promote(cached)
    assert {:ok, ^stored} = BasicUploader.promote(stored)
  end

  # ---------------------------------------------------------------------------
  # url/2
  # ---------------------------------------------------------------------------

  test "url returns a string for a stored file" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    {:ok, stored} = BasicUploader.promote(cached)
    url = BasicUploader.url(stored)
    assert is_binary(url)
    assert url =~ stored.id
  end

  test "url returns derivative URL when derivatives key matches" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = DerivativeUploader.upload(input)
    {:ok, stored} = DerivativeUploader.promote(cached)

    url = DerivativeUploader.url(stored, derivatives: [:copy])
    assert is_binary(url)
    assert url =~ stored.metadata.plugins.derivatives.copy.id
  end

  test "url falls back to original file when derivative key not found" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = DerivativeUploader.upload(input)
    {:ok, stored} = DerivativeUploader.promote(cached)

    url = DerivativeUploader.url(stored, derivatives: [:nonexistent])
    assert is_binary(url)
    assert url =~ stored.id
  end

  # ---------------------------------------------------------------------------
  # serialize / deserialize
  # ---------------------------------------------------------------------------

  test "serialize produces JSON for cache file" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    json = BasicUploader.serialize(cached)
    assert is_binary(json)
    decoded = Jason.decode!(json)
    assert decoded["storage"] == "cache"
  end

  test "deserialize round-trips a cache file with valid signature" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    json = BasicUploader.serialize(cached)
    assert {:ok, restored} = BasicUploader.deserialize(json)
    assert restored.id == cached.id
    assert restored.storage == :cache
  end

  test "deserialize rejects tampered JSON" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    json = BasicUploader.serialize(cached)
    data = Jason.decode!(json)
    tampered = Jason.encode!(Map.put(data, "id", "evil.fakeit"))
    assert {:error, :invalid_signature} = BasicUploader.deserialize(tampered)
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  test "delete removes file from store" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    {:ok, stored} = BasicUploader.promote(cached)
    assert :ok = BasicUploader.delete(stored)
  end

  # ---------------------------------------------------------------------------
  # url dispatch by plugin key
  # ---------------------------------------------------------------------------

  defmodule PotatoUploader do
    use EmAttachments.Uploader,
      plugins: [potato: EmAttachments.Plugins.Derivatives]

    def cast(:derivatives, file) do
      %{small: File.read!(file.path)}
    end
  end

  test "url resolves derivatives under custom plugin key" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = PotatoUploader.upload(input)
    {:ok, stored} = PotatoUploader.promote(cached)

    url = PotatoUploader.url(stored, potato: [:small])
    assert is_binary(url)
    assert url =~ stored.metadata.plugins.potato.small.id
  end

  test "url does not resolve under wrong key" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = PotatoUploader.upload(input)
    {:ok, stored} = PotatoUploader.promote(cached)

    url = PotatoUploader.url(stored, derivatives: [:small])
    # Falls back to original file URL (derivatives key not found in plugins)
    assert url =~ stored.id
    refute url =~ stored.metadata.plugins.potato.small.id
  end
end
