if Code.ensure_loaded?(Phoenix.Router) do
  defmodule EmAttachments.Plug.FileTest do
    @moduledoc """
    A stored file by its URL's token (`GET /files/:token`, `EmAttachments.Router`): a redirect
    to the store's short-lived URL, a 404 for anything else.
    """
    use ExUnit.Case, async: false
    import Plug.Test

    alias EmAttachments.Test.{BasicUploader, Fixtures, Router}

    @router_opts Router.init([])

    defp get(path), do: conn(:get, path) |> Router.call(@router_opts)

    defp stored do
      {:ok, file} = BasicUploader.upload(%{path: Fixtures.png_path(), filename: "a.png"})
      file
    end

    test "redirects to the file, cached a minute less than its URL lives" do
      file = stored()
      conn = get("/files/" <> BasicUploader.url_token(file, name: "Bail"))

      assert conn.status == 302
      assert [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location == BasicUploader.url(file)
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=240"]
    end

    test "the same file, name and period give the same token" do
      file = stored()
      assert BasicUploader.url_token(file, name: "a") == BasicUploader.url_token(file, name: "a")
      refute BasicUploader.url_token(file, name: "a") == BasicUploader.url_token(file, name: "b")
    end

    test "a token names the file and its name" do
      file = stored()
      token = BasicUploader.url_token(file, name: "Bail")

      assert {:ok, %{id: id}, "Bail"} = BasicUploader.verify_url_token(token)
      assert id == file.id
    end

    test "a forged, foreign or expired token is a 404" do
      file = stored()

      assert get("/files/nope").status == 404
      assert get("/files/" <> BasicUploader.sign(file)).status == 404

      expired =
        EmAttachments.Signer.sign_until(
          "url",
          %{"i" => file.id, "f" => BasicUploader.serialize(file)},
          System.system_time(:second) - 1
        )

      assert BasicUploader.verify_url_token(expired) == {:error, :expired}
      assert get("/files/" <> expired).status == 404
    end
  end
end
