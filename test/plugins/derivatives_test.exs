defmodule EmAttachments.Plugins.DerivativesTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Plugins.Derivatives, SourceFile, TempFile, BackendFile, Backends.Local}
  alias EmAttachments.Test.Fixtures

  setup do
    dir = Path.join(System.tmp_dir!(), "deriv_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    backend = {Local, [fs_path: dir, render_path: "/files"]}
    {:ok, backend: backend}
  end

  # Generic handler — same derivatives for both cache and store phases.
  defmodule UploaderWithDerivatives do
    def handle(:derivatives, %{file: file}) do
      content = File.read!(SourceFile.local_path!(file))
      %{copy: content}
    end

    def handle(_, _), do: :skip
  end

  # Phase-specific handlers — different derivatives per phase.
  defmodule UploaderWithStoreDerivatives do
    def handle(:derivatives, %{file: file, store: :cache}) do
      content = File.read!(SourceFile.local_path!(file))
      %{thumb: content}
    end

    def handle(:derivatives, %{file: file, store: :store}) do
      content = File.read!(SourceFile.local_path!(file))
      %{full: content}
    end

    def handle(_, _), do: :skip
  end

  defp upload_ctx(uploader, deps \\ %{}),
    do: %{plugin_key: :derivatives, uploader: uploader, deps: deps, plugin_opts: []}

  # ---------------------------------------------------------------------------
  # upload/3 — cache phase
  # ---------------------------------------------------------------------------

  describe "upload/3 (cache phase)" do
    test "returns variants with copy_to_store: true for generic handler", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{copy: %{id: _, storage: :cache}}, copy_to_store: true}} =
               Derivatives.upload(tf, {:cache, mod, opts}, upload_ctx(UploaderWithDerivatives))
    end

    test "returns variants with copy_to_store: false for cache-specific handler",
         %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{thumb: _}, copy_to_store: false}} =
               Derivatives.upload(tf, {:cache, mod, opts}, upload_ctx(UploaderWithStoreDerivatives))
    end

    test "returns :skip when uploader has no handle/2", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")
      assert :skip = Derivatives.upload(tf, {:cache, mod, opts}, upload_ctx(__MODULE__))
    end
  end

  # ---------------------------------------------------------------------------
  # upload/3 — store phase
  # ---------------------------------------------------------------------------

  describe "upload/3 (store phase)" do
    test "re-runs generic handler and uploads to store when copy_to_store: true", %{
      backend: {mod, opts}
    } do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(tf, {:cache, mod, opts}, upload_ctx(UploaderWithDerivatives))

      assert {:ok, %{variants: %{copy: %{id: _, storage: :store}}}} =
               Derivatives.upload(
                 tf,
                 {:store, mod, opts},
                 upload_ctx(UploaderWithDerivatives, %{derivatives: cache_data})
               )
    end

    test "calls store-specific handler when copy_to_store: false", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(tf, {:cache, mod, opts}, upload_ctx(UploaderWithStoreDerivatives))

      assert {:ok, %{variants: %{full: %{id: _, storage: :store}}}} =
               Derivatives.upload(
                 tf,
                 {:store, mod, opts},
                 upload_ctx(UploaderWithStoreDerivatives, %{derivatives: cache_data})
               )
    end

    test "returns :skip when no cache variants in deps", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert :skip =
               Derivatives.upload(tf, {:store, mod, opts}, upload_ctx(UploaderWithDerivatives))
    end

    test "copies cached derivatives to store without re-running handler when source is BackendFile",
         %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(tf, {:cache, mod, opts}, upload_ctx(UploaderWithDerivatives))

      assert cache_data.copy_to_store == true
      %{copy: %{id: cache_deriv_id}} = cache_data.variants

      bf = BackendFile.new(mod, opts, "original-id", "img.png", nil)

      assert {:ok, %{variants: %{copy: %{id: store_deriv_id, storage: :store}}}} =
               Derivatives.upload(
                 bf,
                 {:store, mod, opts},
                 upload_ctx(UploaderWithDerivatives, %{derivatives: cache_data})
               )

      refute store_deriv_id == cache_deriv_id
      assert File.exists?(Path.join(opts[:fs_path], store_deriv_id))

      BackendFile.cleanup(bf)
    end
  end

  # ---------------------------------------------------------------------------
  # destroy/2
  # ---------------------------------------------------------------------------

  describe "destroy/2" do
    test "deletes all stored derivative assets", %{backend: {mod, opts} = backend} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(tf, {:cache, mod, opts}, upload_ctx(UploaderWithDerivatives))

      {:ok, store_data} =
        Derivatives.upload(
          tf,
          {:store, mod, opts},
          upload_ctx(UploaderWithDerivatives, %{derivatives: cache_data})
        )

      file = %{
        id: "main",
        storage: :store,
        metadata: %{filename: "img.png", size: tf.size, plugins: %{derivatives: store_data}},
        uploader: "T"
      }

      assert :ok =
               Derivatives.destroy(file, %{plugin_key: :derivatives, plugin_opts: [], backend: backend})

      for {_key, %{id: id}} <- store_data do
        refute File.exists?(Path.join(opts[:fs_path], id))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # url/3
  # ---------------------------------------------------------------------------

  describe "url/3" do
    test "returns derivative URL when path navigates to a stored file", %{backend: backend} do
      file = %{
        id: "main",
        storage: :store,
        metadata: %{
          size: 0,
          filename: "f",
          plugins: %{derivatives: %{variants: %{copy: %{id: "deriv-id", storage: :store}}}}
        },
        uploader: "T"
      }

      ctx = %{plugin_key: :derivatives, plugin_opts: [], backend: backend}
      assert {:ok, url} = Derivatives.url(file, [:copy], ctx)
      assert url =~ "deriv-id"
    end

    test "returns :skip when plugin_call_opts is nil" do
      ctx = %{plugin_key: :derivatives, plugin_opts: [], backend: {Local, []}}
      assert :skip = Derivatives.url(%{}, nil, ctx)
    end

    test "returns :skip when derivative not found" do
      file = %{
        id: "main",
        storage: :store,
        metadata: %{size: 0, filename: "f", plugins: %{derivatives: %{}}},
        uploader: "T"
      }

      ctx = %{
        plugin_key: :derivatives,
        plugin_opts: [],
        backend: {Local, [fs_path: "/tmp", render_path: "/f"]}
      }

      assert :skip = Derivatives.url(file, [:missing], ctx)
    end
  end

  defp unique, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
end
