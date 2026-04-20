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

  alias EmAttachments.Backends.S3.Signer

  @impl true
  def put(id, source_path, opts) do
    url = object_url(id, opts)
    acl_headers = acl_header(opts[:acl])
    body = File.read!(source_path)
    headers = Signer.sign_request(:put, url, acl_headers, :unsigned, opts)

    case Req.put(url, headers: headers, body: body) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
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
      :public_read -> {:ok, public_url(id, opts)}
      _ -> {:ok, Signer.presign_url(object_url(id, opts), opts[:url_expires_in] || opts[:expires_in] || 3600, opts)}
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

  defp acl_header(nil), do: %{}
  defp acl_header(:private), do: %{"x-amz-acl" => "private"}
  defp acl_header(:public_read), do: %{"x-amz-acl" => "public-read"}
  defp acl_header(:authenticated_read), do: %{"x-amz-acl" => "authenticated-read"}
  defp acl_header(other), do: %{"x-amz-acl" => to_string(other)}
end
