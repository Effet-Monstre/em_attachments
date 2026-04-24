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

  # Simulates Repo.insert/update: runs prepare_changes callbacks in order.
  # This is exactly what Ecto.Repo.Schema does before writing to the DB.
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
  # Normal upload → promote flow
  # ---------------------------------------------------------------------------

  test "upload via Plug.Upload stores a cached struct change, promoted to stored struct on commit" do
    params = %{"avatar" => plug_upload(Fixtures.png_path())}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar])

    assert cs.valid?

    cached = get_change(cs, :avatar)
    assert %BasicUploader{} = cached
    assert cached.storage == :cache

    cs2 = commit(cs)
    assert cs2.valid?
    stored = get_change(cs2, :avatar)
    assert stored.storage == :store
    assert stored.id == cached.id

    record = apply_changes(cs2)
    assert record.avatar.storage == :store
    assert record.avatar.metadata.filename == "image.png"
    assert record.avatar.metadata.plugins.mime.type == "image/png"
  end

  test "upload via JSON hidden field (pre-cached) is promoted on commit" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "photo.png"})
    json = BasicUploader.serialize(cache_file)

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
  # Bare ID / JSON matching current file — no-op
  # ---------------------------------------------------------------------------

  test "bare file ID matching current stored file does nothing" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: stored_file}

    cs = changeset(record, %{"avatar" => stored_file.id}) |> cast_attachments([:avatar])

    assert cs.valid?
    refute Map.has_key?(cs.changes, :avatar)
  end

  test "bare file ID not matching current stored file returns error" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: stored_file}

    cs = changeset(record, %{"avatar" => "some-other-id"}) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  test "JSON with same stored file ID does nothing" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: stored_file}

    json = BasicUploader.serialize(stored_file)
    cs = changeset(record, %{"avatar" => json}) |> cast_attachments([:avatar])

    assert cs.valid?
    refute Map.has_key?(cs.changes, :avatar)
  end

  test "JSON with different stored-file ID returns error" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: stored_file}

    other_json =
      Jason.encode!(%{
        "id" => "other-id",
        "storage" => "store",
        "uploader" => "Elixir.EmAttachments.Test.BasicUploader",
        "metadata" => nil
      })

    cs = changeset(record, %{"avatar" => other_json}) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  test "cached JSON from failed form resubmission is promoted on commit" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "repost.png"})
    json = BasicUploader.serialize(cache_file)

    cs = changeset(%UserRecord{}, %{"avatar" => json}) |> cast_attachments([:avatar])

    assert cs.valid?
    assert %BasicUploader{storage: :cache} = get_change(cs, :avatar)

    cs2 = commit(cs)
    assert cs2.valid?
    stored = get_change(cs2, :avatar)
    assert stored.storage == :store
    assert stored.id == cache_file.id
    assert stored.metadata.filename == "repost.png"
  end

  # ---------------------------------------------------------------------------
  # Deletion via nil
  # ---------------------------------------------------------------------------

  test "nil param sets field to nil and deletes old file in callback" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: stored_file}

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
    {:ok, cache_file} =
      DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "img.png"})

    {:ok, stored_file} = DerivativeUploader.promote(cache_file)

    derivative_ids =
      stored_file.metadata.plugins.derivatives.variants
      |> Map.values()
      |> Enum.map(& &1.id)

    {_mod, store_opts} = EmAttachments.Config.store()
    store_fs_path = store_opts[:fs_path]

    for id <- derivative_ids do
      assert File.exists?(Path.join(store_fs_path, id)), "expected derivative #{id} to exist"
    end

    record = %DerivativeRecord{id: Ecto.UUID.generate(), avatar: stored_file}
    cs = cast(record, %{"avatar" => nil}, [:name]) |> cast_attachments([:avatar])
    commit(cs)

    for id <- derivative_ids do
      refute File.exists?(Path.join(store_fs_path, id)), "expected derivative #{id} to be deleted"
    end
  end

  test "unknown map param returns error" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: stored_file}

    cs = changeset(record, %{"avatar" => %{"keep" => "true"}}) |> cast_attachments([:avatar])

    refute cs.valid?
    assert cs.errors[:avatar] != nil
  end

  # ---------------------------------------------------------------------------
  # promote: false — deferred, file stays in cache
  # ---------------------------------------------------------------------------

  test "promote: false skips promotion and registers no prepare callback" do
    params = %{"avatar" => plug_upload(Fixtures.png_path())}
    cs = changeset(%UserRecord{}, params) |> cast_attachments([:avatar], promote: false)

    assert cs.valid?
    assert cs.prepare == []

    record = apply_changes(cs)
    assert record.avatar.storage == :cache
  end

  # ---------------------------------------------------------------------------
  # promote: true — deferred promotion of an existing cache file
  # ---------------------------------------------------------------------------

  test "promote: true with no new upload promotes existing cache file" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: cache_file}

    cs = changeset(record, %{}) |> cast_attachments([:avatar], promote: true)

    assert length(cs.prepare) == 1

    cs2 = commit(cs)
    assert cs2.valid?
    stored = get_change(cs2, :avatar)
    assert stored.storage == :store
    assert stored.id == cache_file.id

    final = apply_changes(cs2)
    assert final.avatar.storage == :store
  end

  test "promote: true with already-stored file is a no-op" do
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: stored_file}

    cs = changeset(record, %{}) |> cast_attachments([:avatar], promote: true)

    assert cs.prepare == []
    assert cs.changes == %{}
  end

  test "promote: true with no existing file is a no-op" do
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: nil}
    cs = changeset(record, %{}) |> cast_attachments([:avatar], promote: true)

    assert cs.prepare == []
    assert cs.changes == %{}
  end

  test "new upload overrides promote: true" do
    {:ok, old_cache} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "old.png"})
    record = %UserRecord{id: Ecto.UUID.generate(), avatar: old_cache}

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
      cached = get_change(cs, :avatar)
      assert cached.storage == :cache
      assert cached.metadata.plugins.mime.type == "image/png"
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

    test "rejected upload leaves no cached file" do
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
      # FixedDimensionsAdapter returns 800×600; StrictDimensionsUploader allows max 100×100
      params = %{"avatar" => plug_upload(Fixtures.png_path())}
      cs = strict_changeset(%StrictDimensionsRecord{}, params) |> cast_attachments([:avatar])

      refute cs.valid?
      {msg, _opts} = cs.errors[:avatar]
      assert msg =~ "max_width"
      assert msg =~ "max_height"
    end

    test "rejected upload leaves no cached file" do
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
    {:ok, cache_file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "logo.png"})
    {:ok, stored_file} = BasicUploader.promote(cache_file)

    {:ok, dumped} = BasicUploader.dump(stored_file)
    assert is_map(dumped)
    assert dumped[:storage] == "store"

    {:ok, loaded} = BasicUploader.load(dumped)
    assert loaded.storage == :store
    assert loaded.id == stored_file.id
    assert loaded.metadata.filename == "logo.png"
    assert loaded.metadata.plugins.mime.type == "image/png"
  end
end
