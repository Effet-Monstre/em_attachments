defmodule EmAttachments.EctoRepoTest do
  use ExUnit.Case, async: false

  @moduletag :db

  import Ecto.Changeset
  import EmAttachments.Ecto

  alias EmAttachments.Test.{Repo, DbUser, BasicUploader, CmdStdoutDbUser, Fixtures}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    original_config = EmAttachments.Config.all()
    Application.put_env(:em_attachments, :config, Keyword.put(original_config, :repo, Repo))
    on_exit(fn -> Application.put_env(:em_attachments, :config, original_config) end)
    :ok
  end

  # ── Happy path ─────────────────────────────────────────────────────────────

  test "Plug.Upload stores directly to store, Repo.insert marks permanent and persists" do
    upload = %Plug.Upload{
      path: Fixtures.png_path(),
      filename: "avatar.png",
      content_type: "image/png"
    }

    cs =
      DbUser.changeset(%{"name" => "Alice", "avatar" => upload})
      |> cast_attachments([:avatar])

    assert cs.valid?
    assert get_change(cs, :avatar).storage == :store

    {:ok, user} = Repo.insert(cs)

    assert user.avatar.storage == :store
    assert user.avatar.metadata.filename == "avatar.png"
    assert user.avatar.metadata.plugins.mime.type == "image/png"

    loaded = Repo.get!(DbUser, user.id)
    assert loaded.avatar.id == user.avatar.id
    assert loaded.avatar.storage == :store
    assert loaded.avatar.metadata.plugins.mime.type == "image/png"
  end

  # ── Validation error → serialize → resubmit via JSON → store ──────────────

  test "invalid file produces error changeset; valid file stored and resubmitted via JSON" do
    # Step 1: bad upload fails MIME validation
    bad = %Plug.Upload{
      path: Fixtures.txt_path(),
      filename: "doc.txt",
      content_type: "text/plain"
    }

    bad_cs =
      DbUser.changeset(%{"avatar" => bad})
      |> cast_attachments([:avatar])

    refute bad_cs.valid?
    assert bad_cs.errors[:avatar] != nil
    assert {:error, _} = Repo.insert(bad_cs)

    # Step 2: valid file is uploaded and serialized for the hidden form field
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "photo.png"})
    json = BasicUploader.serialize(file)

    # Step 3: form resubmitted with corrected data + the pending JSON
    good_cs =
      DbUser.changeset(%{"name" => "Bob", "avatar" => json})
      |> cast_attachments([:avatar])

    assert good_cs.valid?
    assert get_change(good_cs, :avatar).storage == :store

    {:ok, user} = Repo.insert(good_cs)
    assert user.avatar.storage == :store
    assert user.avatar.id == file.id
    assert user.avatar.metadata.filename == "photo.png"
  end

  # ── File removal ───────────────────────────────────────────────────────────

  test "nil avatar param deletes file from store and sets DB column to nil" do
    user = insert_user_with_avatar!()
    {_mod, store_opts} = EmAttachments.Config.store()
    original_id = user.avatar.id

    cs =
      DbUser.changeset(user, %{"avatar" => nil})
      |> cast_attachments([:avatar])

    assert get_change(cs, :avatar) == nil

    {:ok, updated} = Repo.update(cs)
    assert updated.avatar == nil

    if match?({EmAttachments.Backends.Local, _}, EmAttachments.Config.store()) do
      refute File.exists?(Path.join(store_opts[:fs_path], original_id))
    end

    reloaded = Repo.get!(DbUser, user.id)
    assert reloaded.avatar == nil
  end

  # ── No argument passed ─────────────────────────────────────────────────────

  test "absent avatar key leaves existing file and DB unchanged" do
    user = insert_user_with_avatar!()

    cs =
      DbUser.changeset(user, %{"name" => "Updated"})
      |> cast_attachments([:avatar])

    refute Map.has_key?(cs.changes, :avatar)

    {:ok, updated} = Repo.update(cs)
    assert updated.name == "Updated"
    assert updated.avatar.id == user.avatar.id
    assert updated.avatar.storage == :store
  end

  # ── Replace file ───────────────────────────────────────────────────────────

  test "uploading a new file replaces old file in store and DB" do
    user = insert_user_with_avatar!()
    original_id = user.avatar.id
    {_mod, store_opts} = EmAttachments.Config.store()

    new_upload = %Plug.Upload{
      path: Fixtures.png_path(),
      filename: "new.png",
      content_type: "image/png"
    }

    cs =
      DbUser.changeset(user, %{"avatar" => new_upload})
      |> cast_attachments([:avatar])

    {:ok, updated} = Repo.update(cs)
    assert updated.avatar.storage == :store
    assert updated.avatar.metadata.filename == "new.png"
    assert updated.avatar.id != original_id

    if match?({EmAttachments.Backends.Local, _}, EmAttachments.Config.store()) do
      refute File.exists?(Path.join(store_opts[:fs_path], original_id))
    end

    reloaded = Repo.get!(DbUser, user.id)
    assert reloaded.avatar.id == updated.avatar.id
  end

  # ── Delayed promote ────────────────────────────────────────────────────────

  test "promote: false keeps file in store but skips mark_permanent; promote: true marks permanent later" do
    upload = %Plug.Upload{
      path: Fixtures.png_path(),
      filename: "deferred.png",
      content_type: "image/png"
    }

    # Step 1: insert with promote: false — pending row stays in tracking table
    cs =
      DbUser.changeset(%{"name" => "Carol", "avatar" => upload})
      |> cast_attachments([:avatar], promote: false)

    assert cs.valid?
    assert cs.prepare == []

    {:ok, user} = Repo.insert(cs)
    assert user.avatar.storage == :store
    assert user.avatar.metadata.filename == "deferred.png"

    # Step 2: reload from DB — file round-trips correctly
    loaded = Repo.get!(DbUser, user.id)
    assert loaded.avatar.storage == :store
    assert loaded.avatar.id == user.avatar.id

    # Step 3: mark permanent later — cast_attachments with promote: true triggers mark_permanent
    promote_cs =
      DbUser.changeset(loaded, %{})
      |> cast_attachments([:avatar], promote: true)

    assert length(promote_cs.prepare) == 2

    {:ok, promoted} = Repo.update(promote_cs)
    assert promoted.avatar.storage == :store
    assert promoted.avatar.id == loaded.avatar.id

    # Step 4: verify final state in DB
    final = Repo.get!(DbUser, user.id)
    assert final.avatar.storage == :store
    assert final.avatar.metadata.filename == "deferred.png"
  end

  # ── Dump / load round-trip ─────────────────────────────────────────────────

  test "stored file metadata survives DB dump/load round-trip" do
    user = insert_user_with_avatar!()

    loaded = Repo.get!(DbUser, user.id)
    assert loaded.avatar.storage == :store
    assert loaded.avatar.metadata.plugins.mime.type == "image/png"
    assert loaded.avatar.metadata.filename == "avatar.png"
  end

  # ── External / real-file tests ─────────────────────────────────────────────

  @tag :external
  test "real JPEG from internet: MIME detected as image/jpeg, stored, round-trips through DB" do
    path = Fixtures.real_jpeg_path()

    upload = %Plug.Upload{
      path: path,
      filename: "real.jpg",
      content_type: "image/jpeg"
    }

    cs =
      DbUser.changeset(%{"name" => "JPEG test", "avatar" => upload})
      |> cast_attachments([:avatar])

    assert cs.valid?
    {:ok, user} = Repo.insert(cs)
    assert user.avatar.metadata.plugins.mime.type == "image/jpeg"

    loaded = Repo.get!(DbUser, user.id)
    assert loaded.avatar.storage == :store
    assert loaded.avatar.metadata.plugins.mime.type == "image/jpeg"
  end

  @tag :external
  test "real PNG from internet: MIME detected as image/png, stored, round-trips through DB" do
    path = Fixtures.real_png_path()

    upload = %Plug.Upload{
      path: path,
      filename: "real.png",
      content_type: "image/png"
    }

    cs =
      DbUser.changeset(%{"name" => "PNG test", "avatar" => upload})
      |> cast_attachments([:avatar])

    assert cs.valid?
    {:ok, user} = Repo.insert(cs)
    assert user.avatar.metadata.plugins.mime.type == "image/png"

    loaded = Repo.get!(DbUser, user.id)
    assert loaded.avatar.storage == :store
  end

  # ── :cmd_stdout derivative with binary input ───────────────────────────────

  test "binary {:binary, data} input + :cmd_stdout derivative: stored in DB, content is valid PNG" do
    png_data = Fixtures.proper_png()

    cs =
      CmdStdoutDbUser.changeset(%{"name" => "Thumb User", "avatar" => {:binary, png_data, "photo.png"}})
      |> cast_attachments([:avatar])

    assert cs.valid?
    assert get_change(cs, :avatar).storage == :store

    {:ok, user} = Repo.insert(cs)
    assert user.avatar.storage == :store
    assert user.avatar.metadata.plugins.mime.type == "image/png"

    thumb = user.avatar.metadata.plugins.derivatives.variants.thumb
    assert thumb.storage == :store

    if match?({EmAttachments.Backends.Local, _}, EmAttachments.Config.store()) do
      {_mod, store_opts} = EmAttachments.Config.store()
      content = File.read!(Path.join(store_opts[:fs_path], thumb.id))
      assert <<0x89, ?P, ?N, ?G, _::binary>> = content
    end

    loaded = Repo.get!(CmdStdoutDbUser, user.id)
    assert loaded.avatar.storage == :store
    loaded_thumb = loaded.avatar.metadata.plugins.derivatives.variants.thumb
    assert loaded_thumb.id == thumb.id
    assert loaded_thumb.storage == :store
  end

  # ── Transaction rollback ───────────────────────────────────────────────────

  test "DB constraint failure after mark_permanent rolls back the tracking row update" do
    # Create a user whose name we will conflict with in the failing insert
    {:ok, _} = Repo.insert(DbUser.changeset(%{"name" => "ConstraintTarget"}))

    # Insert a pending tracking row with a known asset_id
    asset_id = "rollback-#{System.unique_integer([:positive])}"
    expires = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, _} =
      EmAttachments.Upload.insert_pending(Repo, %{
        asset_id: asset_id,
        uploader: to_string(BasicUploader),
        serialized:
          Jason.encode!(%{id: asset_id, storage: "store", uploader: to_string(BasicUploader)}),
        status: "pending",
        expires_at: expires
      })

    # Build a valid changeset: prepare_changes calls mark_permanent, but the insert
    # will fail due to the unique constraint on name.
    cs =
      DbUser.changeset(%{"name" => "ConstraintTarget"})
      |> prepare_changes(fn cs ->
        EmAttachments.Upload.mark_permanent(cs.repo, asset_id)
        cs
      end)

    # The insert fails; mark_permanent ran inside the transaction but is rolled back
    assert {:error, failed_cs} = Repo.insert(cs)
    assert failed_cs.errors[:name] != nil

    # The tracking row is still pending — the mark_permanent UPDATE was rolled back
    table = EmAttachments.Config.table_name()
    prefix = EmAttachments.Config.schema_name()
    import Ecto.Query
    [row] = Repo.all(from(u in {table, EmAttachments.Upload}, where: u.asset_id == ^asset_id), prefix: prefix)
    assert row.status == "pending"
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp insert_user_with_avatar! do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "avatar.png"})

    cs =
      DbUser.changeset(%DbUser{}, %{"name" => "Seed User"})
      |> put_change(:avatar, file)

    {:ok, user} = Repo.insert(cs)
    user
  end
end
