defmodule EmAttachmentsTest do
  use ExUnit.Case, async: true

  test "url/2 returns nil for nil" do
    assert EmAttachments.url(nil) == nil
  end

  test "url/2 returns nil for unknown uploader string" do
    file = %{uploader: "NonExistentUploader123", id: "x", storage: :store, metadata: nil}
    assert EmAttachments.url(file) == nil
  end
end
