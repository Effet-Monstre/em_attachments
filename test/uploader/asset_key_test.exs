defmodule EmAttachments.Uploader.AssetKeyTest do
  use ExUnit.Case, async: false

  alias EmAttachments.Test.{BasicUploader, DerivativeUploader, Fixtures, NoPluginUploader}

  @uuid_v7 "[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"

  defp assert_asset_id(id, extension) do
    assert id =~ ~r/^#{@uuid_v7}#{extension}$/
  end

  test "asset id is a uuid v7 carrying the detected extension" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "logo.png"})
    assert_asset_id(file.id, "\\.png")
  end

  test "the extension comes from the bytes, never from the submitted filename" do
    path = Fixtures.txt_path(Fixtures.proper_png())
    {:ok, file} = BasicUploader.upload(%{path: path, filename: "definitely-a-document.txt"})
    assert_asset_id(file.id, "\\.png")
  end

  test "an uploader with no mime plugin still gets an extension" do
    {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.jpeg_path(), filename: "photo.jpg"})
    assert_asset_id(file.id, "\\.jpg")
  end

  test "unrecognised bytes yield a bare uuid with no trailing dot" do
    {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.txt_path(), filename: "notes.txt"})
    assert_asset_id(file.id, "")
  end

  test "derivative ids follow the same scheme as the file they belong to" do
    {:ok, file} = DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "logo.png"})

    assert %{copy: %{id: derivative_id}} = file.metadata.plugins.derivatives.variants
    assert_asset_id(file.id, "\\.png")
    assert_asset_id(derivative_id, "\\.png")
  end

  test "reprocessing mints a fresh id and keeps the extension" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "logo.png"})
    {:ok, reprocessed} = BasicUploader.reprocess(file)

    refute reprocessed.id == file.id
    assert_asset_id(reprocessed.id, "\\.png")
  end
end
