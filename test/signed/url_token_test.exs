defmodule EmAttachments.UrlTokenTest do
  @moduledoc "With tracking, a URL reaches a file only while a record holds it."
  use ExUnit.Case, async: false

  @moduletag :db

  import EmAttachments.Ecto

  alias EmAttachments.Test.{BasicUploader, DbUser, Fixtures, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    original_config = EmAttachments.Config.all()
    Application.put_env(:em_attachments, :config, Keyword.put(original_config, :repo, Repo))
    on_exit(fn -> Application.put_env(:em_attachments, :config, original_config) end)
    :ok
  end

  test "held by a record, then released" do
    {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
    token = BasicUploader.url_token(file)

    # Not claimed yet: no record holds it.
    assert BasicUploader.verify_url_token(token) == {:error, :not_found}

    {:ok, user} =
      %{"name" => "user", "avatar" => BasicUploader.sign(file)}
      |> DbUser.changeset()
      |> cast_attachments([:avatar])
      |> Repo.insert()

    assert {:ok, %{id: id}, nil} = BasicUploader.verify_url_token(token)
    assert id == file.id

    :ok = release(Repo, [user.avatar])
    assert BasicUploader.verify_url_token(token) == {:error, :not_found}
  end
end
