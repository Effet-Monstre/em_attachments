defmodule EmAttachments.SweeperTest do
  use ExUnit.Case, async: false

  @moduletag :db

  alias EmAttachments.Test.{Repo, NoPluginUploader, Fixtures}
  alias EmAttachments.{Upload, Sweeper}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Expired pending (cached) uploads — must be cleaned up
  # ---------------------------------------------------------------------------

  describe "expired pending uploads" do
    test "sweep/1 deletes the file from the store backend" do
      {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "cached.png"})
      insert_pending_row!(file, expires_at: past())

      assert backend_file_exists?(file.id), "expected file to exist before sweep"

      Sweeper.sweep(Repo)

      refute backend_file_exists?(file.id),
             "expected expired pending file to be deleted from the store"
    end

    test "sweep/1 removes the tracking row from the database" do
      {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "cached.png"})
      insert_pending_row!(file, expires_at: past())

      Sweeper.sweep(Repo)

      assert Upload.expired_pending(Repo, 100) == [],
             "expected expired pending tracking row to be removed"
    end
  end

  # ---------------------------------------------------------------------------
  # Non-expired pending uploads — must not be touched
  # ---------------------------------------------------------------------------

  describe "non-expired pending uploads" do
    test "sweep/1 does not delete the file from the store backend" do
      {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "fresh.png"})
      insert_pending_row!(file, expires_at: future())

      assert backend_file_exists?(file.id), "expected file to exist before sweep"

      Sweeper.sweep(Repo)

      assert backend_file_exists?(file.id),
             "expected non-expired pending file to remain in the store"
    end

    test "sweep/1 leaves the tracking row untouched" do
      {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "fresh.png"})
      insert_pending_row!(file, expires_at: future())

      Sweeper.sweep(Repo)

      [row] = Repo.all(Upload)
      assert row.status == "pending"
      assert row.asset_id == file.id
    end
  end

  # ---------------------------------------------------------------------------
  # Permanent uploads — file stays, tracking row cleaned up
  # ---------------------------------------------------------------------------

  describe "permanent uploads" do
    test "sweep/1 does NOT delete the file from the store backend" do
      {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "perm.png"})
      insert_permanent_row!(file)

      assert backend_file_exists?(file.id), "expected file to exist before sweep"

      Sweeper.sweep(Repo)

      assert backend_file_exists?(file.id),
             "expected permanent file to remain in the store after sweep"
    end

    test "sweep/1 removes the tracking row from the database" do
      {:ok, file} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "perm.png"})
      insert_permanent_row!(file)

      Sweeper.sweep(Repo)

      assert Upload.all_permanent(Repo, 100) == [],
             "expected permanent tracking row to be cleaned up after sweep"
    end
  end

  # ---------------------------------------------------------------------------
  # Mixed scenario
  # ---------------------------------------------------------------------------

  test "sweep/1 only removes expired pending files; permanent and non-expired pending files remain" do
    {:ok, expired} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "expired.png"})
    {:ok, fresh} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "fresh.png"})
    {:ok, permanent} = NoPluginUploader.upload(%{path: Fixtures.png_path(), filename: "perm.png"})

    insert_pending_row!(expired, expires_at: past())
    insert_pending_row!(fresh, expires_at: future())
    insert_permanent_row!(permanent)

    Sweeper.sweep(Repo)

    refute backend_file_exists?(expired.id),
           "expected expired pending file to be deleted"

    assert backend_file_exists?(fresh.id),
           "expected non-expired pending file to remain"

    assert backend_file_exists?(permanent.id),
           "expected permanent file to remain"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_pending_row!(file, opts) do
    expires_at = Keyword.get(opts, :expires_at, future())

    {:ok, row} =
      Upload.insert_pending(Repo, %{
        asset_id: file.id,
        uploader: to_string(file.__struct__),
        serialized: file.__struct__.serialize(file),
        expires_at: expires_at
      })

    row
  end

  defp insert_permanent_row!(file) do
    {:ok, row} =
      Upload.insert_pending(Repo, %{
        asset_id: file.id,
        uploader: to_string(file.__struct__),
        serialized: file.__struct__.serialize(file),
        status: "permanent",
        expires_at: future()
      })

    row
  end

  defp backend_file_exists?(file_id) do
    {backend_mod, backend_opts} = EmAttachments.Config.store()

    case backend_mod.get(file_id, backend_opts) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -3600, :second)
  defp future, do: DateTime.add(DateTime.utc_now(), 3600, :second)
end
