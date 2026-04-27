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
  """

  @behaviour EmAttachments.Backend

  alias EmAttachments.{BackendFile, SourceFile}
  alias EmAttachments.Backends.S3.Signer

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
    do_put(id, source, opts)
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
    url = object_url(id, opts)
    headers = Signer.sign_request(:delete, url, %{}, :unsigned, opts)

    case Req.delete(url, headers: headers) do
      {:ok, %{status: s}} when s in [200, 204] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
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

  defp object_url(id, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = opts[:prefix] || "uploads"
    "#{build_bucket_url(bucket, opts)}/#{prefix}/#{id}"
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

  # S3 server-side copy — no local download needed when source and dest share a bucket.
  defp copy_object(source_id, source_opts, dest_id, dest_opts) do
    dest_url = object_url(dest_id, dest_opts)
    source_bucket = Keyword.fetch!(source_opts, :bucket)
    source_prefix = source_opts[:prefix] || "uploads"
    copy_source = "/#{source_bucket}/#{source_prefix}/#{source_id}"
    copy_headers = acl_header(dest_opts[:acl]) |> Map.put("x-amz-copy-source", copy_source)
    # Sign with the empty-body hash (correct for CopyObject; body is zero bytes)
    headers = Signer.sign_request(:put, dest_url, copy_headers, "", dest_opts)

    case Req.put(dest_url, headers: headers, body: "") do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
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
