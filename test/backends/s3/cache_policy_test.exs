defmodule EmAttachments.Backends.S3.CachePolicyTest do
  use ExUnit.Case, async: false

  alias EmAttachments.Backends.S3
  alias EmAttachments.Backends.S3.CacheRegistry
  alias EmAttachments.{BackendFile, MemoryFile}

  @moduletag :s3

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup_all do
    bucket = System.get_env("TEST_S3_BUCKET") || raise "TEST_S3_BUCKET not set"
    region = System.get_env("AWS_REGION") || "us-east-1"

    base = [
      bucket: bucket,
      prefix: "em_test_cache_policy",
      access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
      region: region,
      acl: :private
    ]

    store_opts = base
    cache_opts = Keyword.merge(base, policy: :cache, cache_ttl: 1800)

    # Start CacheRegistry for these tests (no scan — bucket cleanup is test-managed)
    pid =
      case CacheRegistry.start_link(backends: []) do
        {:ok, p} -> p
        {:error, {:already_started, p}} -> p
      end

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{store_opts: store_opts, cache_opts: cache_opts}
  end

  setup %{store_opts: store_opts, cache_opts: cache_opts} do
    id = "test_#{unique()}"

    on_exit(fn ->
      # expire_cache_file deletes both the actual file and the sentinel
      S3.expire_cache_file(id, cache_opts)
    end)

    source = MemoryFile.new("cache policy test content", "test.txt")
    %{id: id, source: source, store_opts: store_opts, cache_opts: cache_opts}
  end

  # ---------------------------------------------------------------------------
  # Core put / delete behaviour
  # ---------------------------------------------------------------------------

  test "put with policy: :cache uploads file to store location and creates sentinel",
       %{id: id, source: source, store_opts: store_opts, cache_opts: cache_opts} do
    assert :ok = S3.put(id, source, cache_opts)

    # Actual file readable at the store location
    assert {:ok, "cache policy test content"} = S3.get(id, store_opts)

    # Sentinel exists under the cache/ sub-prefix
    assert sentinel_exists?(id, cache_opts)
  end

  test "delete with policy: :cache is a no-op — file and sentinel remain untouched",
       %{id: id, source: source, store_opts: store_opts, cache_opts: cache_opts} do
    :ok = S3.put(id, source, cache_opts)

    assert :ok = S3.delete(id, cache_opts)

    # Both actual file and sentinel still present
    assert {:ok, _} = S3.get(id, store_opts)
    assert sentinel_exists?(id, cache_opts)
  end

  # ---------------------------------------------------------------------------
  # Promotion flow
  # ---------------------------------------------------------------------------

  test "promoting a cache file skips the HTTP copy, cancels timer, and removes the sentinel",
       %{id: id, source: source, store_opts: store_opts, cache_opts: cache_opts} do
    :ok = S3.put(id, source, cache_opts)

    assert {:ok, original_body} = S3.get(id, store_opts)
    assert sentinel_exists?(id, cache_opts)

    # Simulate pipeline's store_mod.put(id, BackendFile(cache), store_opts)
    bf = BackendFile.new(S3, cache_opts, id, "test.txt", nil)
    assert :ok = S3.put(id, bf, store_opts)
    BackendFile.cleanup(bf)

    # File still intact after no-op copy
    assert {:ok, ^original_body} = S3.get(id, store_opts)

    # Timer cancelled — registry no longer holds this id
    bucket = store_opts[:bucket]
    assert :not_found = CacheRegistry.cancel(bucket, id)

    # Sentinel removed during promotion (by put, not delete)
    refute sentinel_exists?(id, cache_opts)

    # cache_mod.delete is a no-op — file remains
    assert :ok = S3.delete(id, cache_opts)
    assert {:ok, ^original_body} = S3.get(id, store_opts)
  end

  # ---------------------------------------------------------------------------
  # expire_cache_file (timer expiry path)
  # ---------------------------------------------------------------------------

  test "expire_cache_file deletes both the actual file and the sentinel",
       %{id: id, source: source, store_opts: store_opts, cache_opts: cache_opts} do
    :ok = S3.put(id, source, cache_opts)

    assert :ok = S3.expire_cache_file(id, cache_opts)

    assert {:error, {404, _}} = S3.get(id, store_opts)
    refute sentinel_exists?(id, cache_opts)
  end

  # ---------------------------------------------------------------------------
  # CacheRegistry timer
  # ---------------------------------------------------------------------------

  test "CacheRegistry auto-deletes file after TTL expires",
       %{id: id, source: source, store_opts: store_opts, cache_opts: cache_opts} do
    short_ttl_opts = Keyword.put(cache_opts, :cache_ttl, 2)
    :ok = S3.put(id, source, short_ttl_opts)

    assert {:ok, _} = S3.get(id, store_opts)
    assert sentinel_exists?(id, short_ttl_opts)

    # Wait for the 2-second timer to fire and complete the async deletion
    Process.sleep(4_000)

    assert {:error, {404, _}} = S3.get(id, store_opts)
    refute sentinel_exists?(id, short_ttl_opts)
  end

  # ---------------------------------------------------------------------------
  # list_cache_objects / cleanup scan
  # ---------------------------------------------------------------------------

  test "list_cache_objects returns sentinel key with its last_modified",
       %{id: id, source: source, cache_opts: cache_opts} do
    :ok = S3.put(id, source, cache_opts)

    prefix = cache_opts[:prefix] || "uploads"
    cache_prefix = "#{prefix}/cache/"

    assert {:ok, objects} = S3.list_cache_objects(cache_opts, cache_prefix)

    keys = Enum.map(objects, &elem(&1, 0))
    assert Enum.any?(keys, &String.ends_with?(&1, "/#{id}"))

    timestamps = Enum.map(objects, &elem(&1, 1))
    assert Enum.all?(timestamps, &match?(%DateTime{}, &1))
  end

  # ---------------------------------------------------------------------------
  # bulk_delete
  # ---------------------------------------------------------------------------

  test "bulk_delete removes multiple store files in one request",
       %{store_opts: store_opts} do
    ids = for _ <- 1..5, do: "bulk_#{unique()}"

    on_exit(fn -> Enum.each(ids, &S3.delete(&1, store_opts)) end)

    for id <- ids do
      src = MemoryFile.new("bulk content #{id}", "f.txt")
      assert :ok = S3.put(id, src, store_opts)
    end

    assert :ok = S3.bulk_delete(ids, store_opts)

    for id <- ids do
      assert {:error, {404, _}} = S3.get(id, store_opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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
