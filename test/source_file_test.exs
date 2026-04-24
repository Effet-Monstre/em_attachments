defmodule EmAttachments.SourceFileTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{BackendFile, SourceFile, TempFile, Backends.Local}
  alias EmAttachments.Test.Fixtures

  # ---------------------------------------------------------------------------
  # TempFile implementation
  # ---------------------------------------------------------------------------

  describe "SourceFile - TempFile" do
    test "local_path!/1 returns the path directly" do
      path = Fixtures.png_path()
      tf = TempFile.new(path, "img.png")
      assert SourceFile.local_path!(tf) == path
    end

    test "filename/1 returns the filename" do
      tf = TempFile.new(Fixtures.txt_path(), "notes.txt")
      assert SourceFile.filename(tf) == "notes.txt"
    end

    test "size/1 returns the file size" do
      tf = TempFile.new(Fixtures.txt_path("hello"), "f.txt")
      assert SourceFile.size(tf) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # Plug.Upload implementation (only when Plug is available)
  # ---------------------------------------------------------------------------

  if Code.ensure_loaded?(Plug.Upload) do
    describe "SourceFile - Plug.Upload" do
      test "local_path!/1 returns the upload path without copying" do
        path = Fixtures.png_path()
        upload = %Plug.Upload{path: path, filename: "img.png", content_type: "image/png"}
        assert SourceFile.local_path!(upload) == path
      end

      test "filename/1 returns the upload filename" do
        upload = %Plug.Upload{
          path: Fixtures.txt_path(),
          filename: "report.csv",
          content_type: "text/csv"
        }

        assert SourceFile.filename(upload) == "report.csv"
      end

      test "size/1 stats the file on disk" do
        path = Fixtures.txt_path("hello")
        upload = %Plug.Upload{path: path, filename: "f.txt", content_type: "text/plain"}
        assert SourceFile.size(upload) == 5
      end
    end
  end

  # ---------------------------------------------------------------------------
  # BackendFile implementation
  # ---------------------------------------------------------------------------

  setup do
    dir = Path.join(System.tmp_dir!(), "bftest_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp backend(dir), do: {Local, [fs_path: dir, render_path: "/f"]}

  defp store_file(content, dir) do
    id = "bf_#{unique()}"
    File.write!(Path.join(dir, id), content)
    id
  end

  describe "BackendFile" do
    test "downloads lazily on first local_path! call", %{dir: dir} do
      id = store_file("hello", dir)
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, id, "file.txt", 5)

      path = SourceFile.local_path!(source)
      assert File.read!(path) == "hello"
      BackendFile.cleanup(source)
    end

    test "second call returns the same cached path without re-downloading", %{dir: dir} do
      id = store_file("world", dir)
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, id, "file.txt", 5)

      path1 = SourceFile.local_path!(source)
      path2 = SourceFile.local_path!(source)
      assert path1 == path2
      BackendFile.cleanup(source)
    end

    test "cleanup removes the downloaded tmp file", %{dir: dir} do
      id = store_file("data", dir)
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, id, "file.txt", 4)

      tmp = SourceFile.local_path!(source)
      assert File.exists?(tmp)
      BackendFile.cleanup(source)
      refute File.exists?(tmp)
    end

    test "cleanup is safe when no download occurred", %{dir: dir} do
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, "not_used", "file.txt", nil)
      assert :ok = BackendFile.cleanup(source)
    end

    test "filename/1 and size/1 work without downloading", %{dir: dir} do
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, "irrelevant", "report.csv", 1024)
      assert SourceFile.filename(source) == "report.csv"
      assert SourceFile.size(source) == 1024
      BackendFile.cleanup(source)
    end

    test "size/1 returns nil when not provided", %{dir: dir} do
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, "irrelevant", "f.txt")
      assert SourceFile.size(source) == nil
      BackendFile.cleanup(source)
    end

    test "local_path!/1 raises when file is missing from backend", %{dir: dir} do
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, "nonexistent", "f.txt", nil)

      assert_raise RuntimeError, ~r/EmAttachments\.BackendFile/, fn ->
        SourceFile.local_path!(source)
      end

      BackendFile.cleanup(source)
    end

    test "ensure_local/1 returns error tuple without raising", %{dir: dir} do
      {mod, opts} = backend(dir)
      source = BackendFile.new(mod, opts, "nonexistent", "f.txt", nil)
      assert {:error, _} = BackendFile.ensure_local(source)
      BackendFile.cleanup(source)
    end
  end

  defp unique, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
end
