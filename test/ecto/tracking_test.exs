defmodule EmAttachments.TrackingTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Integration tests for `em_attachments_uploads` row lifecycle.

  Verifies that:
  - upload/1 inserts pending rows for the main file AND every plugin-generated asset
    (e.g. derivative variants) when a repo is configured.
  - prepare_changes (via cast_attachments) marks all those rows permanent atomically
    inside the Repo.insert/update transaction.
  - A transaction rollback reverts the mark_permanent for every row — main and
    derivative alike — leaving them as "pending".
  """

  @moduletag :db

  import Ecto.Changeset
  import Ecto.Query
  import EmAttachments.Ecto

  alias EmAttachments.Test.{Repo, DerivativeUploader, Fixtures}
  alias EmAttachments.Upload

  # A real DB-backed schema using DerivativeUploader so prepare_changes
  # exercises the full mark_permanent path for both main and derivative rows.
  defmodule DerivativeDbUser do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "users" do
      field :name, :string
      field :avatar, EmAttachments.Test.DerivativeUploader
      timestamps(type: :utc_datetime_usec)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      cast(user, attrs, [:name])
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Point Config.repo() at the test repo so maybe_insert_pending fires.
    original_config = EmAttachments.Config.all()
    Application.put_env(:em_attachments, :config, Keyword.put(original_config, :repo, Repo))
    on_exit(fn -> Application.put_env(:em_attachments, :config, original_config) end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Row insertion
  # ---------------------------------------------------------------------------

  describe "upload/1 inserts pending tracking rows" do
    test "inserts one pending row for the main file ID" do
      {:ok, file} = DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)
    end

    test "inserts one pending row for each derivative ID" do
      {:ok, file} = DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)
    end

    test "total row count is 1 (main) + number of derivative variants" do
      # DerivativeUploader produces one 'copy' variant → expect 2 rows
      {:ok, _file} = DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})

      assert Repo.aggregate(Upload, :count) == 2
    end

    test "derivative row carries minimal serialized JSON (no full metadata)" do
      {:ok, file} = DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      [row] = Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)
      parsed = Jason.decode!(row.serialized)

      assert parsed["id"] == deriv_id
      assert parsed["storage"] == "store"
      assert is_nil(parsed["metadata"]),
             "derivative row must not carry full file metadata"
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_changes marks all rows permanent
  # ---------------------------------------------------------------------------

  describe "cast_attachments + Repo.insert (prepare_changes)" do
    test "marks main and all derivative rows permanent on successful insert" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "avatar.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar])

      assert cs.valid?
      {:ok, user} = Repo.insert(cs)

      file = user.avatar
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      assert [%Upload{status: "permanent"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      assert [%Upload{status: "permanent"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)
    end

    test "with promote: false, all rows remain pending after insert" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "avatar.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar], promote: false)

      assert cs.valid?
      {:ok, user} = Repo.insert(cs)

      file = user.avatar
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)
    end

    test "promote: true on an existing file marks main and derivative rows permanent" do
      # First insert without promotion
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "avatar.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar], promote: false)

      {:ok, user} = Repo.insert(cs)

      file = user.avatar
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      # Rows are still pending
      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      # Now promote via cast_attachments promote: true
      promote_cs =
        DerivativeDbUser.changeset(user, %{})
        |> cast_attachments([:avatar], promote: true)

      {:ok, _} = Repo.update(promote_cs)

      assert [%Upload{status: "permanent"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      assert [%Upload{status: "permanent"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Transaction rollback
  # ---------------------------------------------------------------------------

  describe "transaction rollback" do
    test "reverts mark_permanent for main and all derivative rows" do
      {:ok, file} = DerivativeUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      # Both rows start as pending
      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)

      # mark_permanent inside a transaction that is then rolled back
      assert {:error, :test_rollback} =
               Repo.transaction(fn ->
                 :ok = DerivativeUploader.mark_permanent(Repo, file)
                 Repo.rollback(:test_rollback)
               end)

      # Both rows must be back to "pending"
      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)
    end

    test "prepare_changes rollback (DB-level transaction failure) reverts all rows" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "avatar.png",
        content_type: "image/png"
      }

      # The changeset schedules mark_permanent via prepare_changes; we force the
      # outer transaction to roll back by including an impossible prepare_changes
      # callback that runs after mark_permanent.
      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar])
        |> prepare_changes(fn cs ->
          # Simulate a mid-transaction failure after mark_permanent has run.
          cs.repo.rollback(:simulated_failure)
        end)

      assert cs.valid?

      # The file struct and its derivative ID are embedded in the changeset change.
      file = get_change(cs, :avatar)
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      assert {:error, :simulated_failure} = Repo.insert(cs)

      # mark_permanent ran inside the transaction but was rolled back — rows stay pending.
      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^deriv_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Record deletion — enqueue as pending
  # ---------------------------------------------------------------------------

  describe "cast_attachments + Repo.delete (record deletion)" do
    test "resets permanent tracking row to pending when record is deleted" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "a.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar])

      {:ok, user} = Repo.insert(cs)
      file = user.avatar

      assert [%Upload{status: "permanent"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      Ecto.Changeset.change(user)
      |> cast_attachments([:avatar])
      |> Repo.delete()

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      [row] = Repo.all(from u in Upload, where: u.asset_id == ^file.id)
      assert DateTime.compare(row.expires_at, DateTime.utc_now()) != :gt
    end

    test "inserts new pending row when no tracking row exists (sweeper already ran)" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "a.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar])

      {:ok, user} = Repo.insert(cs)
      file = user.avatar

      # Simulate sweeper having already cleaned up all tracking rows
      Repo.delete_all(from u in Upload, where: u.asset_id == ^file.id)
      assert [] = Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      Ecto.Changeset.change(user)
      |> cast_attachments([:avatar])
      |> Repo.delete()

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)
    end

    test "rollback on delete does not leave a pending row behind" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "a.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar])

      {:ok, user} = Repo.insert(cs)
      file = user.avatar

      # Simulate sweeper having cleaned up so there is no pre-existing row to complicate assertions
      Repo.delete_all(from u in Upload, where: u.asset_id == ^file.id)

      assert {:error, :simulated_failure} =
               Repo.transaction(fn ->
                 Ecto.Changeset.change(user)
                 |> cast_attachments([:avatar])
                 |> Repo.delete()

                 Repo.rollback(:simulated_failure)
               end)

      assert [] = Repo.all(from u in Upload, where: u.asset_id == ^file.id)
    end

    @tag :local_backend
    test "sweeper deletes main file and derivatives from storage after record delete" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "a.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar])

      {:ok, user} = Repo.insert(cs)
      file = user.avatar
      deriv_id = file.metadata.plugins.derivatives.variants.copy.id

      {_mod, store_opts} = EmAttachments.Config.store()
      store_path = store_opts[:fs_path]

      assert File.exists?(Path.join(store_path, file.id))
      assert File.exists?(Path.join(store_path, deriv_id))

      Ecto.Changeset.change(user)
      |> cast_attachments([:avatar])
      |> Repo.delete()

      assert [%Upload{status: "pending"}] =
               Repo.all(from u in Upload, where: u.asset_id == ^file.id)

      EmAttachments.Sweeper.sweep(Repo)

      refute File.exists?(Path.join(store_path, file.id))
      refute File.exists?(Path.join(store_path, deriv_id))
      assert [] = Repo.all(from u in Upload, where: u.asset_id == ^file.id)
    end

    test "cast_attachments on a regular insert does not produce a spurious delete-pending row" do
      upload = %Plug.Upload{
        path: Fixtures.png_path(),
        filename: "a.png",
        content_type: "image/png"
      }

      cs =
        DerivativeDbUser.changeset(%{"name" => unique_name(), "avatar" => upload})
        |> cast_attachments([:avatar])

      {:ok, user} = Repo.insert(cs)
      file = user.avatar

      rows = Repo.all(from u in Upload, where: u.asset_id == ^file.id)
      assert length(rows) == 1
      assert hd(rows).status == "permanent"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name, do: "user-#{System.unique_integer([:positive])}"
end
