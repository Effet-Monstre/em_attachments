defmodule EmAttachments.UploaderTest do
  use ExUnit.Case, async: false

  alias EmAttachments.Test.{BasicUploader, DerivativeUploader, NoPluginUploader, InitAndUploadUploader, Fixtures}

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

  test "upload fails when file type cannot be detected" do
    input = %{path: Fixtures.txt_path(), filename: "doc.txt"}
    # Mime plugin cast fails on unknown type → pipeline returns cast error
    assert {:error, _reason} = BasicUploader.upload(input)
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

  @tag :local_backend
  test "url uses cache backend render_path for a cached file" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    url = BasicUploader.url(cached)
    assert is_binary(url)
    assert url =~ cached.id
    assert String.starts_with?(url, "/files/cache")
    refute String.starts_with?(url, "/files/store")
  end

  @tag :local_backend
  test "url uses store backend render_path for a promoted file" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = BasicUploader.upload(input)
    {:ok, stored} = BasicUploader.promote(cached)
    url = BasicUploader.url(stored)
    assert String.starts_with?(url, "/files/store")
    refute String.starts_with?(url, "/files/cache")
  end

  test "url resolves derivative after round-tripping through load_file with string keys" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = DerivativeUploader.upload(input)
    {:ok, stored} = DerivativeUploader.promote(cached)

    # Simulate what Ecto does: dump to map (string keys), then load back
    {:ok, dumped} = DerivativeUploader.dump(stored)
    {:ok, loaded} = DerivativeUploader.load(dumped)

    url = DerivativeUploader.url(loaded, derivatives: [:copy])
    assert is_binary(url)
    assert url =~ loaded.metadata.plugins.derivatives.variants.copy.id
  end

  test "url returns derivative URL when derivatives key matches" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = DerivativeUploader.upload(input)
    {:ok, stored} = DerivativeUploader.promote(cached)

    url = DerivativeUploader.url(stored, derivatives: [:copy])
    assert is_binary(url)
    assert url =~ stored.metadata.plugins.derivatives.variants.copy.id
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

  # ---------------------------------------------------------------------------
  # init/5 → upload/6 pipe
  # ---------------------------------------------------------------------------

  test "init result is available in upload/6 via deps" do
    {:ok, file} = InitAndUploadUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
    assert file.metadata.plugins.probe.saw_init == true
    assert file.metadata.plugins.probe.storage == :cache
  end

  test "init does not run again during promote" do
    {:ok, cached} = InitAndUploadUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
    {:ok, stored} = InitAndUploadUploader.promote(cached)
    assert stored.metadata.plugins.probe.saw_init == true
    assert stored.metadata.plugins.probe.storage == :store
  end

  # ---------------------------------------------------------------------------
  # direct-to-store (storage: :store)
  # ---------------------------------------------------------------------------

  test "upload with storage: :store returns a stored file" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"}, storage: :store)
    assert file.storage == :store
    assert file.metadata.plugins.mime.type == "image/png"
  end

  test "init runs during direct-to-store upload" do
    {:ok, file} = InitAndUploadUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"}, storage: :store)
    assert file.storage == :store
    assert file.metadata.plugins.probe.saw_init == true
    assert file.metadata.plugins.probe.storage == :store
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
    use EmAttachments.Uploader

    plugin potato: EmAttachments.Plugins.Derivatives

    def handle(:potato, %{file: file}) do
      %{small: File.read!(EmAttachments.SourceFile.local_path!(file))}
    end
  end

  test "url resolves derivatives under custom plugin key" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = PotatoUploader.upload(input)
    {:ok, stored} = PotatoUploader.promote(cached)

    url = PotatoUploader.url(stored, potato: [:small])
    assert is_binary(url)
    assert url =~ stored.metadata.plugins.potato.variants.small.id
  end

  test "url does not resolve under wrong key" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, cached} = PotatoUploader.upload(input)
    {:ok, stored} = PotatoUploader.promote(cached)

    url = PotatoUploader.url(stored, derivatives: [:small])
    # Falls back to original file URL (derivatives key not found in plugins)
    assert url =~ stored.id
    refute url =~ stored.metadata.plugins.potato.variants.small.id
  end
end
