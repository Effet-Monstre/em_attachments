defmodule EmAttachments.Backends.LocalTest do
  use ExUnit.Case, async: true

  alias EmAttachments.Backends.Local

  setup do
    dir = Path.join(System.tmp_dir!(), "local_backend_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, opts: [fs_path: dir, render_path: "/files"]}
  end

  test "put then get round-trips content", %{opts: opts} do
    src = write_tmp("hello local backend")
    assert :ok = Local.put("file1", src, opts)
    assert {:ok, "hello local backend"} = Local.get("file1", opts)
  end

  test "delete removes the file", %{opts: opts} do
    src = write_tmp("delete me")
    Local.put("file2", src, opts)
    assert :ok = Local.delete("file2", opts)
    assert {:error, _} = Local.get("file2", opts)
  end

  test "url returns render_path/id", %{opts: opts} do
    assert {:ok, "/files/some-id"} = Local.url("some-id", opts)
  end

  test "presign_upload returns not_supported", %{opts: opts} do
    assert {:error, :not_supported} = Local.presign_upload("id", opts)
  end

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "src_#{unique()}")
    File.write!(path, content)
    path
  end

  defp unique, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
end
