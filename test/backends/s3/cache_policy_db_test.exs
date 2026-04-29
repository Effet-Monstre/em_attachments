defmodule EmAttachments.Test.CachePolicyUploader do
  use EmAttachments.Uploader,
    cache: [policy: :cache, prefix: "em_test_cp", cache_ttl: 1800],
    store: {nil, [prefix: "em_test_cp"]}

  plugin mime: EmAttachments.Plugins.Mime
  validates mime: [type: ~w(image/png image/jpeg), extension: ~w(png jpg jpeg)]
end

if Code.ensure_loaded?(Ecto.Schema) do
  defmodule EmAttachments.Test.CachePolicyDbUser do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "users" do
      field :name, :string
      field :avatar, EmAttachments.Test.CachePolicyUploader
      timestamps(type: :utc_datetime_usec)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      cast(user, attrs, [:name])
    end
  end
end

defmodule EmAttachments.S3.CachePolicyDbTest do
  use ExUnit.Case, async: false

  @moduletag :s3
  @moduletag :db

  import Ecto.Changeset
  import EmAttachments.Ecto

  alias EmAttachments.Backends.S3
  alias EmAttachments.Backends.S3.CacheRegistry
  alias EmAttachments.{Config, MemoryFile}
  alias EmAttachments.Test.{Repo, CachePolicyUploader, CachePolicyDbUser, Fixtures}

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup_all do
    pid =
      case CacheRegistry.start_link(backends: []) do
        {:ok, p} -> p
        {:error, {:already_started, p}} -> p
      end

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    uploader_opts = CachePolicyUploader.__uploader_opts__()
    {_mod, cache_opts} = Config.cache(uploader_opts)
    {_mod, store_opts} = Config.store(uploader_opts)

    %{cache_opts: cache_opts, store_opts: store_opts}
  end

  setup _ do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Happy path: upload → Repo.insert → sentinel removed, file permanent, DB ok
  # ---------------------------------------------------------------------------

  test "Repo.insert promotes cache file, sentinel removed, file permanent, DB record correct",
       %{cache_opts: cache_opts, store_opts: store_opts} do
    upload = %Plug.Upload{
      path: Fixtures.png_path(),
      filename: "avatar.png",
      content_type: "image/png"
    }

    cs =
      CachePolicyDbUser.changeset(%{"name" => "Alice", "avatar" => upload})
      |> cast_attachments([:avatar])

    assert cs.valid?
    cached = get_change(cs, :avatar)
    assert cached.storage == :cache
    id = cached.id

    on_exit(fn -> S3.expire_cache_file(id, cache_opts) end)

    # File already uploaded to store location during cache phase
    assert {:ok, _} = S3.get(id, store_opts)
    assert sentinel_exists?(id, cache_opts)

    {:ok, user} = Repo.insert(cs)

    assert user.avatar.storage == :store
    assert user.avatar.id == id
    assert user.avatar.metadata.filename == "avatar.png"

    refute sentinel_exists?(id, cache_opts)
    assert {:ok, _} = S3.get(id, store_opts)

    loaded = Repo.get!(CachePolicyDbUser, user.id)
    assert loaded.avatar.id == id
    assert loaded.avatar.storage == :store
    assert loaded.avatar.metadata.plugins.mime.type == "image/png"
  end

  # ---------------------------------------------------------------------------
  # DB failure after promotion: file stays permanently stored
  # ---------------------------------------------------------------------------

  test "file is permanently stored when DB insert fails after promotion",
       %{cache_opts: cache_opts, store_opts: store_opts} do
    upload = %Plug.Upload{
      path: Fixtures.png_path(),
      filename: "resilient.png",
      content_type: "image/png"
    }

    cs =
      CachePolicyDbUser.changeset(%{"name" => "Bob", "avatar" => upload})
      |> cast_attachments([:avatar])

    assert cs.valid?
    id = get_change(cs, :avatar).id

    on_exit(fn -> S3.expire_cache_file(id, cache_opts) end)

    assert {:ok, _} = S3.get(id, store_opts)
    assert sentinel_exists?(id, cache_opts)

    # Simulate DB failure: run prepare_changes (promotion) without Repo.insert
    cs2 = commit(cs)

    # Promotion ran: sentinel deleted, timer cancelled, file still at store location
    refute sentinel_exists?(id, cache_opts)
    assert {:ok, _} = S3.get(id, store_opts)
    assert get_change(cs2, :avatar).storage == :store
  end

  # ---------------------------------------------------------------------------
  # Resubmit after DB failure: same file ID reused, Repo.insert succeeds
  # ---------------------------------------------------------------------------

  test "resubmit with cached JSON after DB failure reuses same file ID and succeeds",
       %{cache_opts: cache_opts, store_opts: store_opts} do
    upload = %Plug.Upload{
      path: Fixtures.png_path(),
      filename: "resubmit.png",
      content_type: "image/png"
    }

    cs1 =
      CachePolicyDbUser.changeset(%{"name" => "Carol", "avatar" => upload})
      |> cast_attachments([:avatar])

    assert cs1.valid?
    cached = get_change(cs1, :avatar)
    id = cached.id
    json = CachePolicyUploader.serialize(cached)

    on_exit(fn -> S3.expire_cache_file(id, cache_opts) end)

    # Simulate DB failure: run promotion without Repo.insert
    commit(cs1)

    # Sentinel gone, file permanently stored
    refute sentinel_exists?(id, cache_opts)
    assert {:ok, _} = S3.get(id, store_opts)

    # Resubmit with corrected name and the cached JSON from the hidden form field
    cs2 =
      CachePolicyDbUser.changeset(%{"name" => "Carol Fixed", "avatar" => json})
      |> cast_attachments([:avatar])

    assert cs2.valid?
    assert get_change(cs2, :avatar).storage == :cache
    assert get_change(cs2, :avatar).id == id

    {:ok, user} = Repo.insert(cs2)

    # Same file ID reused — no re-upload, no extra copy
    assert user.avatar.storage == :store
    assert user.avatar.id == id
    assert user.name == "Carol Fixed"

    assert {:ok, _} = S3.get(id, store_opts)

    loaded = Repo.get!(CachePolicyDbUser, user.id)
    assert loaded.avatar.id == id
    assert loaded.avatar.storage == :store
  end

  # ---------------------------------------------------------------------------
  # CacheRegistry crash + startup scan recovery
  # ---------------------------------------------------------------------------

  test "after CacheRegistry crash, startup scan deletes expired file and sentinel",
       %{cache_opts: cache_opts, store_opts: store_opts} do
    # TTL of 2 seconds ensures the scan expires this file immediately after the sleep
    short_ttl_opts = Keyword.put(cache_opts, :cache_ttl, 2)
    id = unique()

    on_exit(fn -> S3.expire_cache_file(id, short_ttl_opts) end)

    source = MemoryFile.new("crash recovery content", "test.txt")
    assert :ok = S3.put(id, source, short_ttl_opts)

    assert {:ok, _} = S3.get(id, store_opts)
    assert sentinel_exists?(id, short_ttl_opts)

    # Kill the registry — its in-memory timer is lost, leaving file and sentinel orphaned
    registry_pid = Process.whereis(CacheRegistry)
    GenServer.stop(registry_pid, :normal)
    refute Process.alive?(registry_pid)

    # Wait so the sentinel's last_modified is older than cache_ttl (2 s)
    Process.sleep(3_000)

    # Restart with the backend explicitly listed — fires async startup scan immediately
    {:ok, new_pid} =
      CacheRegistry.start_link(backends: [short_ttl_opts], cleanup_interval: :timer.hours(1))

    on_exit(fn -> if Process.alive?(new_pid), do: GenServer.stop(new_pid) end)

    # Allow scan (ListObjects + 2 S3 deletes) to complete
    Process.sleep(5_000)

    assert {:error, {404, _}} = S3.get(id, store_opts)
    refute sentinel_exists?(id, short_ttl_opts)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp commit(changeset) do
    Enum.reduce(changeset.prepare, changeset, fn f, cs -> f.(cs) end)
  end

  defp sentinel_exists?(id, opts) do
    prefix = opts[:prefix] || "uploads"
    cache_prefix = "#{prefix}/cache/"

    case S3.list_cache_objects(opts, cache_prefix) do
      {:ok, objects} -> Enum.any?(objects, fn {key, _} -> String.ends_with?(key, "/#{id}") end)
      _ -> false
    end
  end

  defp unique, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
end
