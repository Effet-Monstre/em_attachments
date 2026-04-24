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

  # ---------------------------------------------------------------------------
  # upload/6 — cache phase
  # ---------------------------------------------------------------------------

  describe "upload/6 (cache phase)" do
    test "returns variants with copy_to_store: true for generic handler", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{copy: %{id: _, storage: :cache}}, copy_to_store: true}} =
               Derivatives.upload(
                 tf,
                 :derivatives,
                 UploaderWithDerivatives,
                 %{},
                 [],
                 {:cache, mod, opts}
               )
    end

    test "returns variants with copy_to_store: false for cache-specific handler",
         %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{thumb: _}, copy_to_store: false}} =
               Derivatives.upload(
                 tf,
                 :derivatives,
                 UploaderWithStoreDerivatives,
                 %{},
                 [],
                 {:cache, mod, opts}
               )
    end

    test "returns :skip when uploader has no handle/2", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert :skip =
               Derivatives.upload(tf, :derivatives, __MODULE__, %{}, [], {:cache, mod, opts})
    end
  end

  # ---------------------------------------------------------------------------
  # upload/6 — store phase
  # ---------------------------------------------------------------------------

  describe "upload/6 (store phase)" do
    test "re-runs generic handler and uploads to store when copy_to_store: true", %{
      backend: {mod, opts}
    } do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(
          tf,
          :derivatives,
          UploaderWithDerivatives,
          %{},
          [],
          {:cache, mod, opts}
        )

      deps = %{derivatives: cache_data}

      assert {:ok, %{variants: %{copy: %{id: _, storage: :store}}}} =
               Derivatives.upload(
                 tf,
                 :derivatives,
                 UploaderWithDerivatives,
                 deps,
                 [],
                 {:store, mod, opts}
               )
    end

    test "calls store-specific handler when copy_to_store: false", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(
          tf,
          :derivatives,
          UploaderWithStoreDerivatives,
          %{},
          [],
          {:cache, mod, opts}
        )

      deps = %{derivatives: cache_data}

      assert {:ok, %{variants: %{full: %{id: _, storage: :store}}}} =
               Derivatives.upload(
                 tf,
                 :derivatives,
                 UploaderWithStoreDerivatives,
                 deps,
                 [],
                 {:store, mod, opts}
               )
    end

    test "returns :skip when no cache variants in deps", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert :skip =
               Derivatives.upload(
                 tf,
                 :derivatives,
                 UploaderWithDerivatives,
                 %{},
                 [],
                 {:store, mod, opts}
               )
    end

    test "copies cached derivatives to store without re-running handler when source is BackendFile",
         %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(tf, :derivatives, UploaderWithDerivatives, %{}, [],
          {:cache, mod, opts})

      assert cache_data.copy_to_store == true
      %{copy: %{id: cache_deriv_id}} = cache_data.variants

      # Use a BackendFile as source (as the pipeline does during promotion)
      bf = BackendFile.new(mod, opts, "original-id", "img.png", nil)
      deps = %{derivatives: cache_data}

      assert {:ok, %{variants: %{copy: %{id: store_deriv_id, storage: :store}}}} =
               Derivatives.upload(bf, :derivatives, UploaderWithDerivatives, deps, [],
                 {:store, mod, opts})

      # New store ID was allocated (not the same as cache derivative ID)
      refute store_deriv_id == cache_deriv_id
      # Store file exists with the cached content
      assert File.exists?(Path.join(opts[:fs_path], store_deriv_id))

      BackendFile.cleanup(bf)
    end
  end

  # ---------------------------------------------------------------------------
  # destroy/4
  # ---------------------------------------------------------------------------

  describe "destroy/4" do
    test "deletes all stored derivative assets", %{backend: {mod, opts} = backend} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, cache_data} =
        Derivatives.upload(
          tf,
          :derivatives,
          UploaderWithDerivatives,
          %{},
          [],
          {:cache, mod, opts}
        )

      {:ok, store_data} =
        Derivatives.upload(
          tf,
          :derivatives,
          UploaderWithDerivatives,
          %{derivatives: cache_data},
          [],
          {:store, mod, opts}
        )

      file = %{
        id: "main",
        storage: :store,
        metadata: %{filename: "img.png", size: tf.size, plugins: %{derivatives: store_data}},
        uploader: "T"
      }

      assert :ok = Derivatives.destroy(file, :derivatives, backend, [])

      for {_key, %{id: id}} <- store_data do
        refute File.exists?(Path.join(opts[:fs_path], id))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # url/5
  # ---------------------------------------------------------------------------

  describe "url/5" do
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

      assert {:ok, url} = Derivatives.url(file, [:copy], :derivatives, [], backend)
      assert url =~ "deriv-id"
    end

    test "returns :skip when plugin_call_opts is nil" do
      assert :skip = Derivatives.url(%{}, nil, :derivatives, [], {Local, []})
    end

    test "returns :skip when derivative not found" do
      file = %{
        id: "main",
        storage: :store,
        metadata: %{size: 0, filename: "f", plugins: %{derivatives: %{}}},
        uploader: "T"
      }

      assert :skip =
               Derivatives.url(
                 file,
                 [:missing],
                 :derivatives,
                 [],
                 {Local, [fs_path: "/tmp", render_path: "/f"]}
               )
    end
  end

  defp unique, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
end
