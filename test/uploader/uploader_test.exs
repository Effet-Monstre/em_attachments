defmodule EmAttachments.UploaderTest do
  use ExUnit.Case, async: false

  alias EmAttachments.Test.{
    BasicUploader,
    DerivativeUploader,
    NoPluginUploader,
    InitAndUploadUploader,
    Fixtures
  }

  # ---------------------------------------------------------------------------
  # upload/1 → store
  # ---------------------------------------------------------------------------

  test "upload stores file directly in store and returns a struct" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    assert {:ok, file} = BasicUploader.upload(input)
    assert file.storage == :store
    assert file.id != nil
    assert file.metadata.filename == "logo.png"
    assert file.metadata.plugins.mime.type == "image/png"
    assert file.uploader == to_string(BasicUploader)
  end

  test "upload fails when file type cannot be detected" do
    input = %{path: Fixtures.txt_path(), filename: "doc.txt"}
    assert {:error, _reason} = BasicUploader.upload(input)
  end

  test "upload with no plugins succeeds for any file" do
    input = %{path: Fixtures.txt_path(), filename: "notes.txt"}
    assert {:ok, file} = NoPluginUploader.upload(input)
    assert file.storage == :store
  end

  # ---------------------------------------------------------------------------
  # url/2
  # ---------------------------------------------------------------------------

  test "url returns a string for a stored file" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = BasicUploader.upload(input)
    url = BasicUploader.url(file)
    assert is_binary(url)
    assert url =~ file.id
  end

  @tag :local_backend
  test "url uses store backend render_path" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = BasicUploader.upload(input)
    url = BasicUploader.url(file)
    assert is_binary(url)
    assert String.starts_with?(url, "/files/store")
  end

  test "url resolves derivative after round-tripping through load_file with string keys" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = DerivativeUploader.upload(input)

    {:ok, dumped} = DerivativeUploader.dump(file)
    {:ok, loaded} = DerivativeUploader.load(dumped)

    url = DerivativeUploader.url(loaded, derivatives: [:copy])
    assert is_binary(url)
    assert url =~ loaded.metadata.plugins.derivatives.variants.copy.id
  end

  test "url returns derivative URL when derivatives key matches" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = DerivativeUploader.upload(input)

    url = DerivativeUploader.url(file, derivatives: [:copy])
    assert is_binary(url)
    assert url =~ file.metadata.plugins.derivatives.variants.copy.id
  end

  test "url falls back to original file when derivative key not found" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = DerivativeUploader.upload(input)

    url = DerivativeUploader.url(file, derivatives: [:nonexistent])
    assert is_binary(url)
    assert url =~ file.id
  end

  # ---------------------------------------------------------------------------
  # serialize / deserialize
  # ---------------------------------------------------------------------------

  test "serialize produces JSON for a store file" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = BasicUploader.upload(input)
    json = BasicUploader.serialize(file)
    assert is_binary(json)
    decoded = Jason.decode!(json)
    assert decoded["storage"] == "store"
  end

  test "deserialize round-trips a store file" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = BasicUploader.upload(input)
    json = BasicUploader.serialize(file)
    assert {:ok, restored} = BasicUploader.deserialize(json)
    assert restored.id == file.id
    assert restored.storage == :store
  end

  # ---------------------------------------------------------------------------
  # init/2 → upload/3 pipe
  # ---------------------------------------------------------------------------

  test "init result is available in upload/3 via deps" do
    {:ok, file} = InitAndUploadUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
    assert file.metadata.plugins.probe.saw_init == true
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  test "delete removes file from store" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = BasicUploader.upload(input)
    assert :ok = BasicUploader.delete(file)
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
    {:ok, file} = PotatoUploader.upload(input)

    url = PotatoUploader.url(file, potato: [:small])
    assert is_binary(url)
    assert url =~ file.metadata.plugins.potato.variants.small.id
  end

  test "url does not resolve under wrong key" do
    input = %{path: Fixtures.png_path(), filename: "logo.png"}
    {:ok, file} = PotatoUploader.upload(input)

    url = PotatoUploader.url(file, derivatives: [:small])
    assert url =~ file.id
    refute url =~ file.metadata.plugins.potato.variants.small.id
  end
end
