defmodule EmAttachments.Backends.S3 do
  @moduledoc """
  S3 backend using AWS Signature v4. No ExAws dependency.

  Options:
    - `:bucket` (required) — S3 bucket name
    - `:prefix` — key prefix, defaults to `"uploads"`
    - `:region` — AWS region, defaults to `"us-east-1"` or `AWS_REGION` env var
    - `:access_key_id` — defaults to `AWS_ACCESS_KEY_ID` env var
    - `:secret_access_key` — defaults to `AWS_SECRET_ACCESS_KEY` env var
    - `:acl` — `:private` (default) | `:public_read` | `:authenticated_read`
    - `:url_expires_in` — presigned URL TTL in seconds, defaults to 3600
    - `:policy` — set to `:cache` to enable the cache policy (see below)
    - `:cache_ttl` — seconds before a cache-policy file is auto-deleted, defaults to 1800

  ## Cache policy (`policy: :cache`)

  When both the cache and store backends point to the same S3 bucket and prefix,
  setting `policy: :cache` on the **cache** opts uploads the file immediately to its
  final store location and writes a small empty sentinel object at
  `{prefix}/cache/{id}`. A `EmAttachments.Backends.S3.CacheRegistry` timer fires
  after `cache_ttl` seconds and deletes the file if it was never promoted.

  On promotion, `put/3` detects the same-key copy and short-circuits: no data is
  moved, the timer is cancelled, and the pipeline's follow-up `delete/3` removes only
  the sentinel. The actual file remains intact at its final location.

  Requires `EmAttachments.Backends.S3.CacheRegistry` to be running in the
  application supervision tree.
  """

  @behaviour EmAttachments.Backend

  alias EmAttachments.{BackendFile, SourceFile}
  alias EmAttachments.Backends.S3.{CacheRegistry, Signer}

  @impl true
  def put(id, %BackendFile{} = source, opts) do
    state = BackendFile.state(source)

    if state.backend_mod == __MODULE__ and same_bucket?(state.backend_opts, opts) do
      copy_object(state.id, state.backend_opts, id, opts)
    else
      do_put(id, source, opts)
    end
  end

  def put(id, source, opts) do
    with :ok <- do_put(id, source, opts),
         :ok <- maybe_write_sentinel(id, opts) do
      :ok
    end
  end

  @impl true
  def get(id, opts) do
    url = object_url(id, opts)
    headers = Signer.sign_request(:get, url, %{}, :unsigned, opts)

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(id, opts) do
    if opts[:policy] == :cache do
      bucket = Keyword.fetch!(opts, :bucket)
      CacheRegistry.cancel(bucket, id)
      delete_sentinel(id, opts)
    else
      do_delete(object_url(id, opts), opts)
    end
  end

  @impl true
  def url(id, opts) do
    case opts[:acl] do
      :public_read ->
        {:ok, public_url(id, opts)}

      _ ->
        {:ok,
         Signer.presign_url(
           object_url(id, opts),
           opts[:url_expires_in] || opts[:expires_in] || 3600,
           opts
         )}
    end
  end

  @impl true
  def presign_upload(id, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = opts[:prefix] || "uploads"
    expires_in = opts[:url_expires_in] || 3600
    bucket_url = build_bucket_url(bucket, opts)
    {url, fields} = Signer.presign_post(bucket_url, bucket, "#{prefix}/#{id}", expires_in, opts)
    {:ok, %{url: url, fields: fields}}
  end

  @impl true
  def bulk_delete(ids, opts) do
    prefix = opts[:prefix] || "uploads"
    bucket = Keyword.fetch!(opts, :bucket)
    keys = Enum.map(ids, fn id -> "#{prefix}/#{id}" end)

    keys
    |> Enum.chunk_every(1000)
    |> Enum.reduce_while(:ok, fn chunk, _ ->
      case do_bulk_delete(chunk, bucket, opts) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  @impl true
  def bulk_put(files, opts) do
    files
    |> Task.async_stream(
      fn {id, source} -> put(id, source, opts) end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, _ -> {:cont, :ok}
      {:ok, {:error, _} = err}, _ -> {:halt, err}
      {:exit, reason}, _ -> {:halt, {:error, {:task_exit, reason}}}
    end)
  end

  @doc false
  def expire_cache_file(id, opts) do
    do_delete(object_url(id, opts), opts)
    do_delete(sentinel_url(id, opts), opts)
    :ok
  end

  @doc false
  def list_cache_objects(opts, prefix) do
    bucket = Keyword.fetch!(opts, :bucket)
    bucket_url = build_bucket_url(bucket, opts)
    encoded_prefix = URI.encode(prefix, &URI.char_unreserved?/1)
    url = "#{bucket_url}/?list-type=2&prefix=#{encoded_prefix}"
    headers = Signer.sign_request(:get, url, %{}, :unsigned, opts)

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_list_objects_xml(body)}
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp object_url(id, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = opts[:prefix] || "uploads"
    "#{build_bucket_url(bucket, opts)}/#{prefix}/#{id}"
  end

  defp sentinel_url(id, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = opts[:prefix] || "uploads"
    "#{build_bucket_url(bucket, opts)}/#{prefix}/cache/#{id}"
  end

  defp public_url(id, opts) do
    object_url(id, opts)
  end

  defp build_bucket_url(bucket, opts) do
    region = opts[:region] || System.get_env("AWS_REGION") || "us-east-1"

    if region == "us-east-1" do
      "https://#{bucket}.s3.amazonaws.com"
    else
      "https://#{bucket}.s3.#{region}.amazonaws.com"
    end
  end

  defp do_put(id, source, opts) do
    url = object_url(id, opts)

    case SourceFile.fetch_bytes(source) do
      {:ok, body} ->
        headers = Signer.sign_request(:put, url, acl_header(opts[:acl]), :unsigned, opts)

        case Req.put(url, headers: headers, body: body) do
          {:ok, %{status: s}} when s in 200..299 -> :ok
          {:ok, %{status: s, body: b}} -> {:error, {s, b}}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp maybe_write_sentinel(id, opts) do
    if opts[:policy] == :cache do
      case put_sentinel(id, opts) do
        :ok ->
          ttl = opts[:cache_ttl] || 1800
          bucket = Keyword.fetch!(opts, :bucket)
          CacheRegistry.register(bucket, id, opts, ttl)
          :ok

        err ->
          err
      end
    else
      :ok
    end
  end

  defp put_sentinel(id, opts) do
    url = sentinel_url(id, opts)
    headers = Signer.sign_request(:put, url, %{"x-amz-acl" => "private"}, "", opts)

    case Req.put(url, headers: headers, body: "") do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_sentinel(id, opts) do
    do_delete(sentinel_url(id, opts), opts)
  end

  defp do_delete(url, opts) do
    headers = Signer.sign_request(:delete, url, %{}, :unsigned, opts)

    case Req.delete(url, headers: headers) do
      {:ok, %{status: s}} when s in [200, 204] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  # S3 server-side copy — no local download needed when source and dest share a bucket.
  defp copy_object(source_id, source_opts, dest_id, dest_opts) do
    if source_opts[:policy] == :cache and
         source_id == dest_id and
         (source_opts[:prefix] || "uploads") == (dest_opts[:prefix] || "uploads") do
      # Promotion: file already in place at the store location.
      # Cancel the timer early; the pipeline's cache_mod.delete/3 will remove the sentinel.
      bucket = Keyword.fetch!(source_opts, :bucket)
      CacheRegistry.cancel(bucket, source_id)
      :ok
    else
      do_copy_object(source_id, source_opts, dest_id, dest_opts)
    end
  end

  defp do_copy_object(source_id, source_opts, dest_id, dest_opts) do
    dest_url = object_url(dest_id, dest_opts)
    source_bucket = Keyword.fetch!(source_opts, :bucket)
    source_prefix = source_opts[:prefix] || "uploads"
    copy_source = "/#{source_bucket}/#{source_prefix}/#{source_id}"
    copy_headers = acl_header(dest_opts[:acl]) |> Map.put("x-amz-copy-source", copy_source)
    headers = Signer.sign_request(:put, dest_url, copy_headers, "", dest_opts)

    case Req.put(dest_url, headers: headers, body: "") do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_bulk_delete(keys, bucket, opts) do
    body = build_delete_objects_xml(keys)
    bucket_url = build_bucket_url(bucket, opts)
    md5 = :crypto.hash(:md5, body) |> Base.encode64()
    url = "#{bucket_url}/?delete"

    extra_headers = %{
      "content-md5" => md5,
      "content-type" => "application/xml"
    }

    headers = Signer.sign_request(:post, url, extra_headers, body, opts)

    case Req.post(url, headers: headers, body: body) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_delete_objects_xml(keys) do
    objects = Enum.map_join(keys, "", fn key -> "<Object><Key>#{key}</Key></Object>" end)
    ~s(<?xml version="1.0" encoding="UTF-8"?><Delete>#{objects}</Delete>)
  end

  defp parse_list_objects_xml(body) do
    Regex.scan(
      ~r/<Contents>.*?<Key>(.*?)<\/Key>.*?<LastModified>(.*?)<\/LastModified>.*?<\/Contents>/s,
      body
    )
    |> Enum.map(fn [_, key, last_modified] ->
      {:ok, dt, _} = DateTime.from_iso8601(last_modified)
      {key, dt}
    end)
  end

  defp same_bucket?(source_opts, dest_opts) do
    Keyword.fetch!(source_opts, :bucket) == Keyword.fetch!(dest_opts, :bucket)
  end

  defp acl_header(nil), do: %{}
  defp acl_header(:private), do: %{"x-amz-acl" => "private"}
  defp acl_header(:public_read), do: %{"x-amz-acl" => "public-read"}
  defp acl_header(:authenticated_read), do: %{"x-amz-acl" => "authenticated-read"}
  defp acl_header(other), do: %{"x-amz-acl" => to_string(other)}
end
