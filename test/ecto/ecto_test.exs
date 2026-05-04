defmodule EmAttachments.EctoTest do
  use ExUnit.Case, async: false

  import EmAttachments.Ecto
  import Ecto.Changeset

  alias EmAttachments.Test.{
    BasicUploader,
    DerivativeUploader,
    DerivativeRecord,
    UserRecord,
    MimeAndDimensionsRecord,
    StrictDimensionsRecord,
    Fixtures
  }

  # Simulates Repo.insert/update: runs prepare_changes callbacks with repo = nil.
  # mark_permanent(nil, _) is a no-op, so these tests exercise the changeset
  # structure without needing a real database.
  defp commit(changeset) do
    Enum.reduce(changeset.prepare, changeset, fn f, cs -> f.(cs) end)
  end

  defp plug_upload(path, filename \\ "image.png") do
    %Plug.Upload{path: path, filename: filename, content_type: "image/png"}
  end

  defp changeset(%UserRecord{} = record, attrs) do
    cast(record, attrs, [:name])
  end

  # ---------------------------------------------------------------------------
  # Normal upload flow
  # ---------------------------------------------------------------------------

  test "upload via Plug.Upload stores directly to store, marked permanent on commit" do
    params = %{"avatar" => plug_upload(Fixtures.png_path())}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    assert cs.valid?

    file = get_change(cs, :avatar)
    assert %BasicUploader{} = file
    assert file.storage == :store

    cs2 = commit(cs)
    assert cs2.valid?
    assert get_change(cs2, :avatar).storage == :store
    assert get_change(cs2, :avatar).id == file.id

    record = apply_changes(cs2)
    assert record.avatar.storage == :store
    assert record.avatar.metadata.filename == "image.png"
    assert record.avatar.metadata.plugins.mime.type == "image/png"
  end

  test "upload via JSON hidden field (pending resubmit) is marked permanent on commit" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "photo.png"})
    json = BasicUploader.serialize(file)

    params = %{"avatar" => json}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    assert cs.valid?
    cs2 = commit(cs)
    assert get_change(cs2, :avatar).storage == :store
  end

  test "no avatar param leaves changeset unchanged" do
    cs = changeset(%UserRecord{}, %{"name" => "Alice"}) |> cast_attachments([:avatar])

    assert cs.valid?
    refute Map.has_key?(cs.changes, :avatar)
  end

  test "invalid file type produces an invalid changeset" do
    params = %{"avatar" => plug_upload(Fixtures.txt_path(), "doc.txt")}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  # ---------------------------------------------------------------------------
  # {:binary, data} and {:binary, data, filename} uploads
  # ---------------------------------------------------------------------------

  test "upload via {:binary, bytes} stores and marks permanent on commit" do
    data = File.read!(Fixtures.png_path())
    params = %{"avatar" => {:binary, data}}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    assert cs.valid?
    file = get_change(cs, :avatar)
    assert %BasicUploader{} = file
    assert file.storage == :store

    cs2 = commit(cs)
    assert cs2.valid?
    assert get_change(cs2, :avatar).storage == :store
  end

  test "upload via {:binary, bytes, filename} uses the provided filename" do
    data = File.read!(Fixtures.png_path())
    params = %{"avatar" => {:binary, data, "custom.png"}}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    assert cs.valid?
    cs2 = commit(cs)
    assert get_change(cs2, :avatar).metadata.filename == "custom.png"
  end

  test "upload via {:binary, bytes} with invalid MIME type produces an invalid changeset" do
    data = File.read!(Fixtures.txt_path())
    params = %{"avatar" => {:binary, data}}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  test "upload via {:binary, bytes} with promote: false registers no prepare callback" do
    data = File.read!(Fixtures.png_path())
    params = %{"avatar" => {:binary, data}}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar], promote: false)

    assert cs.valid?
    assert get_change(cs, :avatar).storage == :store
    assert cs.prepare == []
  end

  # ---------------------------------------------------------------------------
  # {:url, url} uploads — requires network
  # ---------------------------------------------------------------------------

  @tag :external
  test "upload via {:url, url} downloads, stores and marks permanent on commit" do
    params = %{"avatar" => {:url, "https://httpbin.org/image/png"}}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    assert cs.valid?
    file = get_change(cs, :avatar)
    assert %BasicUploader{} = file
    assert file.storage == :store

    cs2 = commit(cs)
    assert cs2.valid?
    assert get_change(cs2, :avatar).storage == :store
  end

  @tag :external
  test "upload via {:url, url} with bad HTTP status adds an error" do
    params = %{"avatar" => {:url, "https://httpbin.org/status/404"}}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  # ---------------------------------------------------------------------------
  # Bare ID / JSON matching current file — no-op
  # ---------------------------------------------------------------------------

  test "bare file ID matching current stored file does nothing" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: file}

    cs = changeset(record, %{"avatar" => file.id}) |> cast_attachments([:avatar])

    assert cs.valid?
    refute Map.has_key?(cs.changes, :avatar)
  end

  test "bare file ID not matching current stored file returns error" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: file}

    cs = changeset(record, %{"avatar" => "some-other-id"}) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  test "JSON with same stored file ID does nothing" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: file}

    json = BasicUploader.serialize(file)
    cs = changeset(record, %{"avatar" => json}) |> cast_attachments([:avatar])

    assert cs.valid?
    refute Map.has_key?(cs.changes, :avatar)
  end

  test "JSON with different store-file ID is treated as pending resubmit" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: file}

    other_json =
      Jason.encode!(%{
        "id" => "other-id",
        "storage" => "store",
        "uploader" => "Elixir.EmAttachments.Test.BasicUploader",
        "metadata" => nil
      })

    cs = changeset(record, %{"avatar" => other_json}) |> cast_attachments([:avatar])

    assert cs.valid?
    assert length(cs.prepare) == 1
  end

  test "pending file JSON from failed form resubmission is marked permanent on commit" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "repost.png"})
    json = BasicUploader.serialize(file)

    cs = changeset(%UserRecord{}, %{"avatar" => json}) |> cast_attachments([:avatar])

    assert cs.valid?
    assert %BasicUploader{storage: :store} = get_change(cs, :avatar)

    cs2 = commit(cs)
    assert cs2.valid?
    stored = get_change(cs2, :avatar)
    assert stored.storage == :store
    assert stored.id == file.id
    assert stored.metadata.filename == "repost.png"
  end

  # ---------------------------------------------------------------------------
  # Deletion via nil
  # ---------------------------------------------------------------------------

  test "nil param sets field to nil and deletes old file in callback" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: file}

    cs = changeset(record, %{"avatar" => nil}) |> cast_attachments([:avatar])

    assert get_change(cs, :avatar) == nil

    cs2 = commit(cs)
    assert get_change(cs2, :avatar) == nil
    assert apply_changes(cs2).avatar == nil
  end

  test "nil param on record with no existing file is a no-op" do
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: nil}
    cs = changeset(record, %{"avatar" => nil}) |> cast_attachments([:avatar])

    assert cs.valid?
  end

  @tag :local_backend
  test "nil param removes all derivative files from the store" do
    {:ok, file} =
      DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "img.png"})

    derivative_ids =
      file.metadata.plugins.derivatives.variants
      |> Map.values()
      |> Enum.map(& &1.id)

    {_mod, store_opts} = EmAttachments.Config.store()
    store_fs_path = store_opts[:fs_path]

    for id <- derivative_ids do
      assert File.exists?(Path.join(store_fs_path, id)), "expected derivative #{id} to exist"
    end

    record = %DerivativeRecord{id: Ecto.UUID.generate(), avatar: file}
    cs = cast(record, %{"avatar" => nil}, [:name]) |> cast_attachments([:avatar])
    commit(cs)

    for id <- derivative_ids do
      refute File.exists?(Path.join(store_fs_path, id)), "expected derivative #{id} to be deleted"
    end
  end

  test "unknown map param returns error" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: file}

    cs = changeset(record, %{"avatar" => %{"keep" => "true"}}) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  # ---------------------------------------------------------------------------
  # promote: false — deferred, file stays pending
  # ---------------------------------------------------------------------------

  test "promote: false skips mark_permanent and registers no prepare callback" do
    params = %{"avatar" => plug_upload(Fixtures.png_path())}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar], promote: false)

    assert cs.valid?
    assert cs.prepare == []

    record = apply_changes(cs)
    assert record.avatar.storage == :store
  end

  # ---------------------------------------------------------------------------
  # promote: true — deferred mark_permanent of an existing file
  # ---------------------------------------------------------------------------

  test "promote: true with existing file registers mark_permanent callback" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: file}

    cs = changeset(record, %{}) |> cast_attachments([:avatar], promote: true)

    assert length(cs.prepare) == 1

    cs2 = commit(cs)
    assert cs2.valid?
    stored = get_change(cs2, :avatar)
    assert stored.storage == :store
    assert stored.id == file.id
  end

  test "promote: true with no existing file is a no-op" do
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: nil}
    cs = changeset(record, %{}) |> cast_attachments([:avatar], promote: true)

    assert cs.prepare == []
    assert cs.changes == %{}
  end

  test "new upload overrides promote: true" do
    {:ok, old_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "old.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: old_file}

    new_upload = plug_upload(Fixtures.png_path(), "new.png")
    params = %{"avatar" => new_upload}
    cs = changeset(record, params) |> cast_attachments([:avatar], promote: true)

    assert cs.valid?
    cs2 = commit(cs)
    stored = get_change(cs2, :avatar)
    assert stored.storage == :store
    assert stored.metadata.filename == "new.png"
  end

  # ---------------------------------------------------------------------------
  # Plugin validations via Ecto
  # ---------------------------------------------------------------------------

  describe "MIME validation via cast_attachments" do
    defp mda_changeset(%MimeAndDimensionsRecord{} = record, attrs),
      do: cast(record, attrs, [:name])

    test "accepts PNG — valid MIME type and dimensions within bounds" do
      params = %{"avatar" => plug_upload(Fixtures.png_path())}
      cs = mda_changeset(%MimeAndDimensionsRecord{}, params) |> cast_attachments([:avatar])

      assert cs.valid?
      file = get_change(cs, :avatar)
      assert file.storage == :store
      assert file.metadata.plugins.mime.type == "image/png"
    end

    test "rejects GIF — detected type not in the allowed list" do
      params = %{"avatar" => plug_upload(Fixtures.gif_path(), "anim.gif")}
      cs = mda_changeset(%MimeAndDimensionsRecord{}, params) |> cast_attachments([:avatar])

      refute cs.valid?
      {msg, _opts} = cs.errors[:avatar]
      assert msg =~ "image/gif"
    end

    test "rejects unknown file type — MIME detection itself fails" do
      params = %{"avatar" => plug_upload(Fixtures.txt_path(), "data.txt")}
      cs = mda_changeset(%MimeAndDimensionsRecord{}, params) |> cast_attachments([:avatar])

      refute cs.valid?
      assert cs.errors[:avatar] != nil
    end

    test "rejected upload leaves no file change" do
      params = %{"avatar" => plug_upload(Fixtures.gif_path(), "anim.gif")}
      cs = mda_changeset(%MimeAndDimensionsRecord{}, params) |> cast_attachments([:avatar])

      refute cs.valid?
      assert get_change(cs, :avatar) == nil
    end
  end

  describe "dimensions validation via cast_attachments" do
    defp strict_changeset(%StrictDimensionsRecord{} = record, attrs),
      do: cast(record, attrs, [:name])

    test "rejects PNG when dimensions exceed max_width and max_height" do
      params = %{"avatar" => plug_upload(Fixtures.png_path())}
      cs = strict_changeset(%StrictDimensionsRecord{}, params) |> cast_attachments([:avatar])

      refute cs.valid?
      {msg, _opts} = cs.errors[:avatar]
      assert msg =~ "max_width"
      assert msg =~ "max_height"
    end

    test "rejected upload leaves no file change" do
      params = %{"avatar" => plug_upload(Fixtures.png_path())}
      cs = strict_changeset(%StrictDimensionsRecord{}, params) |> cast_attachments([:avatar])

      refute cs.valid?
      assert get_change(cs, :avatar) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple fields
  # ---------------------------------------------------------------------------

  test "cast_attachments handles multiple keys in one call" do
    params = %{"avatar" => plug_upload(Fixtures.png_path())}

    cs =
      changeset(%UserRecord{}, params)
      |> cast_attachments([:avatar, :avatar])

    assert cs.valid?
  end

  # ---------------------------------------------------------------------------
  # Data round-trip: dump / load
  # ---------------------------------------------------------------------------

  test "dump and load round-trip preserves stored file metadata" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "logo.png"})

    {:ok, dumped} = BasicUploader.dump(file)
    assert is_map(dumped)
    assert dumped[:storage] == "store"

    {:ok, loaded} = BasicUploader.load(dumped)
    assert loaded.storage == :store
    assert loaded.id == file.id
    assert loaded.metadata.filename == "logo.png"
    assert loaded.metadata.plugins.mime.type == "image/png"
  end
end
