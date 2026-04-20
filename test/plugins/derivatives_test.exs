defmodule EmAttachments.Plugins.DerivativesTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Plugins.Derivatives, TempFile, Backends.Local}
  alias EmAttachments.Test.Fixtures

  setup do
    dir = Path.join(System.tmp_dir!(), "deriv_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    backend = {Local, [fs_path: dir, render_path: "/files"]}
    {:ok, backend: backend}
  end

  defmodule UploaderWithDerivatives do
    def cast(:derivatives, file) do
      content = File.read!(file.path)
      %{copy: content}
    end
  end

  test "cast/4 returns pending map when uploader defines cast(:derivatives)" do
    tf = TempFile.new(Fixtures.png_path(), "img.png")
    assert {:ok, %{pending: %{copy: %{path: path, id: _}}}} =
             Derivatives.cast(tf, UploaderWithDerivatives, %{}, [])

    assert File.exists?(path)
  end

  test "cast/4 returns empty map when uploader has no cast/2" do
    tf = TempFile.new(Fixtures.png_path(), "img.png")
    assert {:ok, %{}} = Derivatives.cast(tf, __MODULE__, %{}, [])
  end

  test "after_upload/4 uploads pending derivatives inline", %{backend: {mod, opts} = backend} do
    tf = TempFile.new(Fixtures.png_path(), "img.png")
    {:ok, pending_data} = Derivatives.cast(tf, UploaderWithDerivatives, %{}, [])

    file = %{
      id: "main-file-id",
      storage: :store,
      metadata: %{size: tf.size, filename: tf.filename, plugins: %{derivatives: pending_data}},
      uploader: "Test"
    }

    assert {:ok, updated} = Derivatives.after_upload(file, :derivatives, backend, [])
    assert %{id: _, storage: :store} = updated.metadata.plugins.derivatives.copy
  end

  test "after_upload/4 skips when async: true", %{backend: backend} do
    file = %{
      id: "id",
      storage: :store,
      metadata: %{size: 0, filename: "f", plugins: %{derivatives: %{pending: %{copy: %{path: "/tmp/x", id: "y"}}}}},
      uploader: "T"
    }

    assert {:ok, ^file} = Derivatives.after_upload(file, :derivatives, backend, async: true)
  end

  test "url/5 returns derivative URL when path navigates to a stored file", %{backend: {mod, opts} = backend} do
    file = %{
      id: "main",
      storage: :store,
      metadata: %{
        size: 0,
        filename: "f",
        plugins: %{
          derivatives: %{copy: %{id: "deriv-id", storage: :store}}
        }
      },
      uploader: "T"
    }

    result = Derivatives.url(file, [:copy], :derivatives, [], backend)
    assert {:ok, url} = result
    assert url =~ "deriv-id"
  end

  test "url/5 returns :skip when plugin_call_opts is nil" do
    assert :skip = Derivatives.url(%{}, nil, :derivatives, [], {Local, []})
  end

  test "url/5 returns :skip when derivative not found" do
    file = %{
      id: "main",
      storage: :store,
      metadata: %{size: 0, filename: "f", plugins: %{derivatives: %{}}},
      uploader: "T"
    }

    assert :skip = Derivatives.url(file, [:missing], :derivatives, [], {Local, [fs_path: "/tmp", render_path: "/f"]})
  end

  defp unique, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
end
