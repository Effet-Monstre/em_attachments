defmodule EmAttachments.ClaimTest do
  @moduledoc """
  A file reaches one record: its token is claimed on save, refused afterwards, and the slots
  of direct uploads are tracked until completed.
  """
  use ExUnit.Case, async: false

  @moduletag :db

  import Ecto.Query
  import EmAttachments.Ecto

  alias EmAttachments.Test.{BasicUploader, DbUser, Fixtures, Repo}
  alias EmAttachments.Upload
  alias EmAttachments.Uploader.Pipeline

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    original_config = EmAttachments.Config.all()
    Application.put_env(:em_attachments, :config, Keyword.put(original_config, :repo, Repo))
    on_exit(fn -> Application.put_env(:em_attachments, :config, original_config) end)
    :ok
  end

  defp upload, do: BasicUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})

  defp insert(token) do
    %{"name" => "user-#{System.unique_integer([:positive])}", "avatar" => token}
    |> DbUser.changeset()
    |> cast_attachments([:avatar])
    |> Repo.insert()
  end

  defp rows(asset_id) do
    Repo.all(
      from(u in {EmAttachments.Config.table_name(), Upload}, where: u.asset_id == ^asset_id),
      prefix: EmAttachments.Config.schema_name()
    )
  end

  test "a token attaches its file to one record only" do
    {:ok, file} = upload()
    token = BasicUploader.sign(file)

    assert {:ok, user} = insert(token)
    assert user.avatar.id == file.id
    assert [%Upload{status: "permanent"}] = rows(file.id)

    assert {:error, changeset} = insert(token)
    assert {"has already been used or has expired", _} = changeset.errors[:avatar]
  end

  test "a file released (its record deleted) can't be claimed again" do
    {:ok, file} = upload()
    token = BasicUploader.sign(file)
    {:ok, user} = insert(token)

    assert :ok = release(Repo, [user.avatar, nil])
    assert [%Upload{status: "pending"}] = rows(file.id)

    assert {:error, _} = insert(token)
  end

  test "a pending upload past its expiry can't be claimed" do
    {:ok, file} = upload()

    Repo.update_all(
      from(u in {EmAttachments.Config.table_name(), Upload}, where: u.asset_id == ^file.id),
      [set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]],
      prefix: EmAttachments.Config.schema_name()
    )

    assert {:error, _} = insert(BasicUploader.sign(file))
  end

  test "a refused save gives the claim back" do
    {:ok, file} = upload()
    token = BasicUploader.sign(file)
    {:ok, _} = insert(token)

    {:ok, other} = upload()
    other_token = BasicUploader.sign(other)

    # The unique name makes the insert fail after the claim: rolled back with it.
    name = "taken-#{System.unique_integer([:positive])}"
    {:ok, _} = DbUser.changeset(%{"name" => name}) |> Repo.insert()

    assert {:error, _} =
             %{"name" => name, "avatar" => other_token}
             |> DbUser.changeset()
             |> Ecto.Changeset.unique_constraint(:name)
             |> cast_attachments([:avatar])
             |> Repo.insert()

    assert [%Upload{status: "pending"}] = rows(other.id)
    assert {:ok, _} = insert(other_token)
  end

  describe "direct uploads" do
    test "a slot is tracked until completed, then forgotten" do
      {:ok, %{token: slot}} = BasicUploader.presign(upload_url: "/up/local", max_size: 1_000_000)
      {:ok, %{id: slot_id}} = Pipeline.verify_slot(BasicUploader, slot)

      assert [%Upload{status: "pending"}] = rows(slot_id)

      png = %Plug.Upload{path: Fixtures.png_path(), filename: "x"}
      assert :ok = Pipeline.fill_slot(BasicUploader, slot, EmAttachments.TempFile.from_plug(png))

      assert {:ok, file} = BasicUploader.complete(slot, filename: "photo.png")
      assert rows(slot_id) == []
      assert [%Upload{status: "pending"}] = rows(file.id)
      assert file.metadata.filename == "photo.png"

      assert {:ok, _} = insert(BasicUploader.sign(file))
    end

    test "completing applies the call's validations" do
      {:ok, %{token: slot}} = BasicUploader.presign(upload_url: "/up/local")
      png = %Plug.Upload{path: Fixtures.png_path(), filename: "x"}
      :ok = Pipeline.fill_slot(BasicUploader, slot, EmAttachments.TempFile.from_plug(png))

      assert {:error, [_ | _]} =
               BasicUploader.complete(slot, validates: [mime: [type: ["image/gif"]]])
    end

    test "the Local backend has no slot without the plug's URL" do
      assert {:error, :not_supported} = BasicUploader.presign()
    end
  end
end
