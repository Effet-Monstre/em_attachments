defmodule EmAttachments.Uploader.CleanupTest do
  use ExUnit.Case, async: false

  alias EmAttachments.{MemoryFile, SourceFile, TempFile}
  alias EmAttachments.Test.Fixtures

  defmodule FailingBackend do
    def put(_id, source, _opts) do
      _ = SourceFile.local_path!(source)
      {:error, :store_failed}
    end
  end

  defmodule FailingBackendUploader do
    use EmAttachments.Uploader, store: {FailingBackend, []}
  end

  defmodule RaisingPlugin do
    use EmAttachments.Plugin

    def init(source, _ctx) do
      _ = SourceFile.local_path!(source)
      raise "plugin failed"
    end
  end

  defmodule RaisingUploader do
    use EmAttachments.Uploader
    plugin raising: RaisingPlugin
  end

  defmodule RollbackBackend do
    def put(id, source, _opts) do
      _ = SourceFile.local_path!(source)
      send(Process.whereis(__MODULE__), {:put, id})

      Agent.get_and_update(RollbackCounter, fn
        :always_ok -> {:ok, :always_ok}
        0 -> {:ok, 1}
        count -> {{:error, :root_store_failed}, count + 1}
      end)
    end

    def delete(id, _opts) do
      send(Process.whereis(__MODULE__), {:delete, id})
      :ok
    end
  end

  defmodule ValidationRollbackUploader do
    use EmAttachments.Uploader, store: {RollbackBackend, []}
    plugin mime: EmAttachments.Plugins.Mime
    plugin derivatives: EmAttachments.Plugins.Derivatives
    validates mime: [type: ["application/pdf"]]

    def handle(:derivatives, %{file: file}) do
      %{copy: File.read!(SourceFile.local_path!(file))}
    end
  end

  defmodule StoreRollbackUploader do
    use EmAttachments.Uploader, store: {RollbackBackend, []}
    plugin derivatives: EmAttachments.Plugins.Derivatives

    def handle(:derivatives, %{file: file}) do
      %{copy: File.read!(SourceFile.local_path!(file))}
    end
  end

  defmodule RaisingAfterDerivatives do
    use EmAttachments.Plugin

    def init(_source, _ctx), do: raise("later plugin failed")
  end

  defmodule PluginExceptionRollbackUploader do
    use EmAttachments.Uploader, store: {RollbackBackend, []}
    plugin derivatives: EmAttachments.Plugins.Derivatives
    plugin raising: RaisingAfterDerivatives

    def handle(:derivatives, %{file: file}) do
      %{copy: File.read!(SourceFile.local_path!(file))}
    end
  end

  setup do
    Process.register(self(), RollbackBackend)
    if pid = Process.whereis(RollbackCounter), do: Agent.stop(pid)
    {:ok, counter_pid} = Agent.start_link(fn -> :always_ok end, name: RollbackCounter)

    on_exit(fn ->
      if Process.alive?(counter_pid), do: Agent.stop(counter_pid)
    end)

    :ok
  end

  test "sequential memory uploads release each agent and tempfile before the next file" do
    for _ <- 1..8 do
      source = MemoryFile.new(Fixtures.proper_png(), "image.png")
      path = SourceFile.local_path!(source)

      assert {:ok, _file} = EmAttachments.Test.BasicUploader.upload(source)
      refute Process.alive?(source.pid)
      refute File.exists?(path)
    end
  end

  test "validation errors release the memory source and materialized tempfile" do
    source = MemoryFile.new("not an image", "bad.txt")
    path = SourceFile.local_path!(source)

    assert {:error, _errors} = EmAttachments.Test.BasicUploader.upload(source)
    refute Process.alive?(source.pid)
    refute File.exists?(path)
  end

  test "backend errors release the memory source and materialized tempfile" do
    source = MemoryFile.new("content", "file.bin")
    path = SourceFile.local_path!(source)

    assert {:error, :store_failed} = FailingBackendUploader.upload(source)
    refute Process.alive?(source.pid)
    refute File.exists?(path)
  end

  test "plugin exceptions release the memory source without masking the exception" do
    source = MemoryFile.new("content", "file.bin")
    path = SourceFile.local_path!(source)

    assert_raise RuntimeError, "plugin failed", fn -> RaisingUploader.upload(source) end
    refute Process.alive?(source.pid)
    refute File.exists?(path)
  end

  test "managed tempfiles are consumed but caller-owned tempfiles are preserved" do
    managed_path = Fixtures.png_path()
    managed = TempFile.managed(managed_path, "managed.png")

    assert {:ok, _file} = EmAttachments.Test.BasicUploader.upload(managed)
    refute File.exists?(managed_path)

    caller_path = Fixtures.png_path()
    caller_owned = TempFile.new(caller_path, "caller.png")

    assert {:ok, _file} = EmAttachments.Test.BasicUploader.upload(caller_owned)
    assert File.exists?(caller_path)
    File.rm!(caller_path)
  end

  test "Plug-owned upload paths are preserved" do
    path = Fixtures.png_path()
    upload = %Plug.Upload{path: path, filename: "plug.png", content_type: "image/png"}
    source = TempFile.from_plug(upload)

    assert {:ok, _file} = EmAttachments.Test.BasicUploader.upload(source)
    assert File.exists?(path)
    File.rm!(path)
  end

  test "validation failures roll back derivative assets already stored by plugins" do
    assert {:error, _} =
             ValidationRollbackUploader.upload(%{
               path: Fixtures.png_path(),
               filename: "image.png"
             })

    assert_receive {:put, derivative_id}
    assert_receive {:delete, ^derivative_id}
  end

  test "root backend failures roll back derivative assets" do
    Agent.update(RollbackCounter, fn _ -> 0 end)

    assert {:error, :root_store_failed} =
             StoreRollbackUploader.upload(%{
               path: Fixtures.png_path(),
               filename: "image.png"
             })

    assert_receive {:put, derivative_id}
    assert_receive {:put, root_id}

    deleted =
      for _ <- 1..2,
          do:
            (
              assert_receive({:delete, id})
              id
            )

    assert Enum.sort(deleted) == Enum.sort([derivative_id, root_id])
  end

  test "a later plugin exception rolls back assets from completed plugins" do
    assert_raise RuntimeError, "later plugin failed", fn ->
      PluginExceptionRollbackUploader.upload(%{
        path: Fixtures.png_path(),
        filename: "image.png"
      })
    end

    assert_receive {:put, derivative_id}
    assert_receive {:delete, ^derivative_id}
  end
end
