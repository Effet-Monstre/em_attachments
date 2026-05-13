defmodule EmAttachments.SweeperTest do
  use ExUnit.Case, async: false

  @moduletag :db

  import Ecto.Query

  alias EmAttachments.Test.{Repo, NoPluginUploader, DerivativeUploader, Fixtures}
  alias EmAttachments.{Upload, Sweeper}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    original_config = EmAttachments.Config.all()

    Application.put_env(
      :em_attachments,
      :config,
      Keyword.merge(original_config, schema_name: "em_attachments", table_name: "uploads")
    )

    on_exit(fn -> Application.put_env(:em_attachments, :config, original_config) end)
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

      [row] = Repo.all(from(u in {upload_source(), Upload}), prefix: upload_prefix())
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
  # Expired pending uploads with derivative variants
  # ---------------------------------------------------------------------------

  describe "expired pending uploads with derivatives" do
    test "sweep/1 deletes the derivative file from the store backend" do
      {:ok, file} =
        DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "main.png"})

      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      # Main row (full serialized JSON): sweep processes it via uploader.delete/1
      # which calls Derivatives.destroy → deletes derivative files.
      insert_pending_row!(file, expires_at: past())

      assert backend_file_exists?(file.id), "main file must exist before sweep"
      assert backend_file_exists?(deriv_id), "derivative file must exist before sweep"

      Sweeper.sweep(Repo)

      refute backend_file_exists?(deriv_id),
             "derivative file must be deleted when expired main row is swept"
    end

    test "sweep/1 deletes the derivative file via its own tracking row" do
      {:ok, file} =
        DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "main.png"})

      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      # Only the derivative row is expired; the main row is not inserted (simulate
      # the case where only the leaf row remains, e.g. after partial cleanup).
      insert_derivative_pending_row!(file, deriv_id, expires_at: past())

      assert backend_file_exists?(deriv_id), "derivative file must exist before sweep"

      Sweeper.sweep(Repo)

      refute backend_file_exists?(deriv_id),
             "derivative file must be deleted when its own tracking row expires"
    end

    test "sweep/1 removes both main and derivative tracking rows from the database" do
      {:ok, file} =
        DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "main.png"})

      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      insert_pending_row!(file, expires_at: past())
      insert_derivative_pending_row!(file, deriv_id, expires_at: past())

      Sweeper.sweep(Repo)

      assert Upload.expired_pending(Repo, 100) == [],
             "all expired tracking rows (main + derivative) must be removed"
    end

    test "sweep/1 does not delete derivative files that belong to non-expired rows" do
      {:ok, file} =
        DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "main.png"})

      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      insert_pending_row!(file, expires_at: future())
      insert_derivative_pending_row!(file, deriv_id, expires_at: future())

      Sweeper.sweep(Repo)

      assert backend_file_exists?(file.id),
             "main file must remain when rows have not expired"

      assert backend_file_exists?(deriv_id),
             "derivative file must remain when rows have not expired"
    end
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

  defp insert_derivative_pending_row!(main_file, derivative_id, opts) do
    expires_at = Keyword.get(opts, :expires_at, future())

    {:ok, row} =
      Upload.insert_pending(Repo, %{
        asset_id: derivative_id,
        uploader: to_string(main_file.__struct__),
        serialized:
          Jason.encode!(%{
            id: derivative_id,
            storage: "store",
            uploader: to_string(main_file.__struct__)
          }),
        expires_at: expires_at
      })

    row
  end

  defp upload_source, do: EmAttachments.Config.table_name()
  defp upload_prefix, do: EmAttachments.Config.schema_name()

  defp past, do: DateTime.add(DateTime.utc_now(), -3600, :second)
  defp future, do: DateTime.add(DateTime.utc_now(), 3600, :second)
end
