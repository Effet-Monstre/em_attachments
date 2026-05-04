defmodule EmAttachments.Plugins.DerivativesTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Plugins.Derivatives, SourceFile, TempFile, MemoryFile, Backends.Local}
  alias EmAttachments.Test.Fixtures

  # ---------------------------------------------------------------------------
  # Spy backends — records finalize/2 calls as messages to the calling process.
  # self() inside finalize/2 is the process that called after_confirm/2, which is
  # the test process when tests invoke Derivatives.after_confirm/2 synchronously.
  # ---------------------------------------------------------------------------

  defmodule SpyBackend do
    def finalize(id, opts) do
      send(self(), {:finalize, id, opts})
      :ok
    end
  end

  defmodule SpyBackendNotFound do
    def finalize(id, _opts) do
      send(self(), {:finalize, id})
      {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Test uploaders / fixture helpers
  # ---------------------------------------------------------------------------

  defmodule UploaderWithDerivatives do
    def handle(:derivatives, %{file: file}) do
      content = File.read!(SourceFile.local_path!(file))
      %{copy: content}
    end

    def handle(_, _), do: :skip
  end

  defmodule UploaderWithTempFileDerivative do
    def handle(:derivatives, %{file: file}) do
      input = SourceFile.local_path!(file)
      output = Path.join(System.tmp_dir!(), "deriv_tf_#{rand_id()}.copy")
      File.cp!(input, output)
      %{processed: TempFile.new(output, "processed")}
    end

    def handle(_, _), do: :skip
    defp rand_id, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
  end

  defmodule UploaderWithMemoryFileDerivative do
    def handle(:derivatives, %{file: file}) do
      data = File.read!(SourceFile.local_path!(file))
      %{processed: MemoryFile.new(data, "processed")}
    end

    def handle(_, _), do: :skip
  end

  defmodule UploaderWithCmdDerivative do
    def handle(:derivatives, _) do
      %{copy: {:cmd, "cp", [:input, :output]}}
    end

    def handle(_, _), do: :skip
  end

  defmodule UploaderWithCmdStdoutDerivative do
    def handle(:derivatives, _) do
      %{content: {:cmd_stdout, "cat", [:input]}}
    end

    def handle(_, _), do: :skip
  end

  defmodule UploaderWithImageResize do
    def handle(:derivatives, _) do
      %{thumb: {:cmd_stdout, "magick", [:input, "-resize", "5x5!", "png:-"]}}
    end

    def handle(_, _), do: :skip
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    dir = Path.join(System.tmp_dir!(), "deriv_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    backend = {Local, [fs_path: dir, render_path: "/files"]}
    {:ok, backend: backend}
  end

  defp upload_ctx(uploader, deps \\ %{}),
    do: %{plugin_key: :derivatives, uploader: uploader, deps: deps, plugin_opts: []}

  defp file_with_variants(variants) do
    %{
      id: "main",
      storage: :store,
      metadata: %{
        size: 0,
        filename: "img.png",
        plugins: %{derivatives: %{variants: variants}}
      },
      uploader: "T"
    }
  end

  # ---------------------------------------------------------------------------
  # upload/3
  # ---------------------------------------------------------------------------

  describe "upload/3" do
    test "generates and uploads variants to store backend", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{copy: %{id: _, storage: :store}}}} =
               Derivatives.upload(tf, {mod, opts}, upload_ctx(UploaderWithDerivatives))
    end

    test "returns :skip when uploader has no handle/2", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")
      assert :skip = Derivatives.upload(tf, {mod, opts}, upload_ctx(__MODULE__))
    end

    test "returns :skip when handle/2 returns :skip", %{backend: {mod, opts}} do
      defmodule SkipUploader do
        def handle(_, _), do: :skip
      end

      tf = TempFile.new(Fixtures.png_path(), "img.png")
      assert :skip = Derivatives.upload(tf, {mod, opts}, upload_ctx(SkipUploader))
    end
  end

  # ---------------------------------------------------------------------------
  # destroy/2
  # ---------------------------------------------------------------------------

  describe "destroy/2" do
    test "deletes all derivative assets from the backend", %{backend: {mod, opts} = backend} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      {:ok, data} =
        Derivatives.upload(tf, {mod, opts}, upload_ctx(UploaderWithDerivatives))

      file = %{
        id: "main",
        storage: :store,
        metadata: %{filename: "img.png", size: tf.size, plugins: %{derivatives: data}},
        uploader: "T"
      }

      assert :ok =
               Derivatives.destroy(file, %{plugin_key: :derivatives, plugin_opts: [], backend: backend})

      for {_key, %{id: id}} <- data.variants do
        refute File.exists?(Path.join(opts[:fs_path], id))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # after_confirm/2
  # ---------------------------------------------------------------------------

  describe "after_confirm/2" do
    test "calls finalize on each derivative with merged opts when backend exports finalize/2" do
      file =
        file_with_variants(%{
          thumb: %{id: "deriv-thumb", storage: :store},
          small: %{id: "deriv-small", storage: :store}
        })

      ctx = %{
        plugin_key: :derivatives,
        plugin_opts: [],
        backend: {SpyBackend, [bucket: "mybucket", acl: :private]},
        finalize_opts: [acl: :public_read]
      }

      assert :ok = Derivatives.after_confirm(file, ctx)

      # Both variants must be finalized with merged opts (finalize_opts overrides backend_opts)
      ids_finalized =
        for _ <- 1..2 do
          assert_receive {:finalize, id, opts}
          assert opts[:acl] == :public_read
          assert opts[:bucket] == "mybucket"
          id
        end

      assert Enum.sort(ids_finalized) == ["deriv-small", "deriv-thumb"]
      refute_received {:finalize, _, _}
    end

    test "handles nested derivative trees" do
      file =
        file_with_variants(%{
          group: %{
            large: %{id: "nested-large", storage: :store},
            small: %{id: "nested-small", storage: :store}
          }
        })

      ctx = %{
        plugin_key: :derivatives,
        plugin_opts: [],
        backend: {SpyBackend, []},
        finalize_opts: [acl: :public_read]
      }

      assert :ok = Derivatives.after_confirm(file, ctx)

      ids = for _ <- 1..2, do: (assert_receive({:finalize, id, _}); id)
      assert Enum.sort(ids) == ["nested-large", "nested-small"]
    end

    test "skips finalize when backend does not export finalize/2" do
      file = file_with_variants(%{thumb: %{id: "deriv-1", storage: :store}})

      ctx = %{
        plugin_key: :derivatives,
        plugin_opts: [],
        backend: {Local, [fs_path: "/tmp", render_path: "/f"]},
        finalize_opts: [acl: :public_read]
      }

      assert :ok = Derivatives.after_confirm(file, ctx)
      refute_received {:finalize, _, _}
    end

    test "returns :ok and logs warning when backend returns {:error, :not_found}" do
      file = file_with_variants(%{thumb: %{id: "gone", storage: :store}})

      ctx = %{
        plugin_key: :derivatives,
        plugin_opts: [],
        backend: {SpyBackendNotFound, []},
        finalize_opts: []
      }

      assert :ok = Derivatives.after_confirm(file, ctx)
      assert_received {:finalize, "gone"}
    end

    test "returns :ok when file has no derivatives" do
      file = file_with_variants(%{})

      ctx = %{
        plugin_key: :derivatives,
        plugin_opts: [],
        backend: {SpyBackend, []},
        finalize_opts: []
      }

      assert :ok = Derivatives.after_confirm(file, ctx)
      refute_received {:finalize, _, _}
    end

    test "defaults finalize_opts to [] when key is absent from ctx" do
      file = file_with_variants(%{thumb: %{id: "d1", storage: :store}})

      # ctx without :finalize_opts — should not crash; ACL stays as the backend default
      ctx = %{
        plugin_key: :derivatives,
        plugin_opts: [],
        backend: {SpyBackend, [acl: :private]}
      }

      assert :ok = Derivatives.after_confirm(file, ctx)
      assert_receive {:finalize, "d1", opts}
      assert opts[:acl] == :private
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

  # ---------------------------------------------------------------------------
  # Source passthrough types
  # ---------------------------------------------------------------------------

  describe "upload/3 — source passthrough types" do
    test "accepts TempFile returned directly from handle/2", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{processed: %{id: _, storage: :store}}}} =
               Derivatives.upload(tf, {mod, opts}, upload_ctx(UploaderWithTempFileDerivative))
    end

    test "accepts MemoryFile returned directly from handle/2", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{processed: %{id: _, storage: :store}}}} =
               Derivatives.upload(tf, {mod, opts}, upload_ctx(UploaderWithMemoryFileDerivative))
    end

    test "{:cmd, ...} tuple auto-executes with input path supplied", %{backend: {mod, opts}} do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{copy: %{id: _, storage: :store}}}} =
               Derivatives.upload(tf, {mod, opts}, upload_ctx(UploaderWithCmdDerivative))
    end

    test "{:cmd_stdout, ...} tuple captures stdout as uploaded derivative", %{
      backend: {mod, opts}
    } do
      tf = TempFile.new(Fixtures.png_path(), "img.png")

      assert {:ok, %{variants: %{content: %{id: id, storage: :store}}}} =
               Derivatives.upload(tf, {mod, opts}, upload_ctx(UploaderWithCmdStdoutDerivative))

      assert {:ok, stored_content} = Local.get(id, opts)
      assert byte_size(stored_content) > 0
    end

    test "{:cmd_stdout, magick resize} generates PNG thumbnail from binary MemoryFile input",
         %{backend: {mod, opts}} do
      mf = MemoryFile.new(Fixtures.proper_png(), "photo.png")

      assert {:ok, %{variants: %{thumb: %{id: id, storage: :store}}}} =
               Derivatives.upload(mf, {mod, opts}, upload_ctx(UploaderWithImageResize))

      assert {:ok, stored} = Local.get(id, opts)
      assert <<0x89, ?P, ?N, ?G, _::binary>> = stored

      MemoryFile.cleanup(mf)
    end
  end

  defp unique, do: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
end
