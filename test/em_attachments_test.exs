defmodule EmAttachmentsTest do
  use ExUnit.Case, async: true

  test "url/2 returns nil for nil" do
    assert EmAttachments.url(nil) == nil
  end

  test "url/2 returns nil for unknown uploader string" do
    file = %{uploader: "NonExistentUploader123", id: "x", storage: :store, metadata: nil}
    assert EmAttachments.url(file) == nil
  end

  describe "plugin_data/2" do
    test "reads from a plugin/handle ctx (the :plugins key)" do
      ctx = %{file: :ignored, plugins: %{mime: %{type: "image/png", extension: "png"}}}
      assert EmAttachments.plugin_data(ctx, :mime) == %{type: "image/png", extension: "png"}
    end

    test "reads from a stored file struct (metadata.plugins)" do
      file = %{metadata: %{plugins: %{mime: %{type: "image/jpeg", extension: "jpg"}}}}
      assert EmAttachments.plugin_data(file, :mime) == %{type: "image/jpeg", extension: "jpg"}
    end

    test "returns nil for an absent key" do
      assert EmAttachments.plugin_data(%{plugins: %{}}, :mime) == nil
    end

    test "returns nil for a container without plugin data" do
      assert EmAttachments.plugin_data(%{file: :x}, :mime) == nil
      assert EmAttachments.plugin_data(nil, :mime) == nil
    end
  end
end
