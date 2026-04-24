defmodule EmAttachments.Backends.S3.Signer do
  @moduledoc false

  @doc """
  Returns signed headers for an S3 request (AWS Signature v4).
  `body` may be a binary or `:unsigned` to skip payload hashing (for streaming).
  """
  def sign_request(method, url, headers, body, opts) do
    {access_key, secret_key, region} = credentials(opts)
    now = DateTime.utc_now()
    datetime_str = format_datetime(now)
    date_str = format_date(now)
    uri = URI.parse(url)

    payload_hash =
      case body do
        :unsigned -> "UNSIGNED-PAYLOAD"
        b -> sha256_hex(b)
      end

    base_headers =
      Map.merge(
        Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), v} end),
        %{
          "host" => uri.host,
          "x-amz-date" => datetime_str,
          "x-amz-content-sha256" => payload_hash
        }
      )

    sorted = Enum.sort_by(base_headers, &elem(&1, 0))
    canonical_headers = Enum.map_join(sorted, "", fn {k, v} -> "#{k}:#{String.trim(v)}\n" end)
    signed_headers_str = Enum.map_join(sorted, ";", &elem(&1, 0))

    canonical_uri = encode_uri_path(uri.path || "/")
    canonical_query = normalize_query(uri.query)

    canonical_request =
      Enum.join(
        [
          String.upcase(to_string(method)),
          canonical_uri,
          canonical_query,
          canonical_headers,
          signed_headers_str,
          payload_hash
        ],
        "\n"
      )

    credential_scope = "#{date_str}/#{region}/s3/aws4_request"

    string_to_sign =
      Enum.join(
        ["AWS4-HMAC-SHA256", datetime_str, credential_scope, sha256_hex(canonical_request)],
        "\n"
      )

    signing_key = derive_signing_key(secret_key, date_str, region)

    signature =
      :crypto.mac(:hmac, :sha256, signing_key, string_to_sign)
      |> Base.encode16(case: :lower)

    authorization =
      "AWS4-HMAC-SHA256 " <>
        "Credential=#{access_key}/#{credential_scope}, " <>
        "SignedHeaders=#{signed_headers_str}, " <>
        "Signature=#{signature}"

    Map.put(base_headers, "authorization", authorization) |> Map.to_list()
  end

  @doc "Generates a presigned GET URL."
  def presign_url(url, expires_in, opts) do
    {access_key, secret_key, region} = credentials(opts)
    now = DateTime.utc_now()
    datetime_str = format_datetime(now)
    date_str = format_date(now)
    uri = URI.parse(url)

    credential = "#{access_key}/#{date_str}/#{region}/s3/aws4_request"

    params = [
      {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
      {"X-Amz-Credential", credential},
      {"X-Amz-Date", datetime_str},
      {"X-Amz-Expires", to_string(expires_in)},
      {"X-Amz-SignedHeaders", "host"}
    ]

    canonical_query =
      params
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} ->
        "#{uri_encode(k)}=#{uri_encode(v)}"
      end)

    canonical_request =
      Enum.join(
        [
          "GET",
          encode_uri_path(uri.path || "/"),
          canonical_query,
          "host:#{uri.host}\n",
          "host",
          "UNSIGNED-PAYLOAD"
        ],
        "\n"
      )

    credential_scope = "#{date_str}/#{region}/s3/aws4_request"

    string_to_sign =
      Enum.join(
        ["AWS4-HMAC-SHA256", datetime_str, credential_scope, sha256_hex(canonical_request)],
        "\n"
      )

    signing_key = derive_signing_key(secret_key, date_str, region)

    signature =
      :crypto.mac(:hmac, :sha256, signing_key, string_to_sign)
      |> Base.encode16(case: :lower)

    full_query = canonical_query <> "&X-Amz-Signature=#{signature}"
    %{uri | query: full_query} |> URI.to_string()
  end

  @doc "Generates a presigned POST policy for direct browser uploads to S3."
  def presign_post(bucket_url, bucket, key_prefix, expires_in, opts) do
    {access_key, secret_key, region} = credentials(opts)
    now = DateTime.utc_now()
    datetime_str = format_datetime(now)
    date_str = format_date(now)

    expiration =
      now
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    credential = "#{access_key}/#{date_str}/#{region}/s3/aws4_request"

    conditions = [
      %{"bucket" => bucket},
      ["starts-with", "$key", key_prefix],
      %{"x-amz-algorithm" => "AWS4-HMAC-SHA256"},
      %{"x-amz-credential" => credential},
      %{"x-amz-date" => datetime_str}
    ]

    policy =
      %{"expiration" => expiration, "conditions" => conditions}
      |> Jason.encode!()
      |> Base.encode64()

    signing_key = derive_signing_key(secret_key, date_str, region)

    signature =
      :crypto.mac(:hmac, :sha256, signing_key, policy)
      |> Base.encode16(case: :lower)

    fields = %{
      "key" => "#{key_prefix}${filename}",
      "x-amz-algorithm" => "AWS4-HMAC-SHA256",
      "x-amz-credential" => credential,
      "x-amz-date" => datetime_str,
      "policy" => policy,
      "x-amz-signature" => signature
    }

    {bucket_url, fields}
  end

  defp derive_signing_key(secret_key, date_str, region) do
    :crypto.mac(:hmac, :sha256, "AWS4#{secret_key}", date_str)
    |> then(&:crypto.mac(:hmac, :sha256, &1, region))
    |> then(&:crypto.mac(:hmac, :sha256, &1, "s3"))
    |> then(&:crypto.mac(:hmac, :sha256, &1, "aws4_request"))
  end

  defp credentials(opts) do
    access_key =
      opts[:access_key_id] || System.get_env("AWS_ACCESS_KEY_ID") ||
        raise "missing :access_key_id"

    secret_key =
      opts[:secret_access_key] || System.get_env("AWS_SECRET_ACCESS_KEY") ||
        raise "missing :secret_access_key"

    region = opts[:region] || System.get_env("AWS_REGION") || "us-east-1"
    {access_key, secret_key, region}
  end

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  end

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y%m%d")
  end

  defp encode_uri_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &uri_encode_path_segment/1)
  end

  defp uri_encode_path_segment(""), do: ""
  defp uri_encode_path_segment(s), do: URI.encode(s, &URI.char_unreserved?/1)

  defp uri_encode(s), do: URI.encode(s, &URI.char_unreserved?/1)

  defp normalize_query(nil), do: ""

  defp normalize_query(query) do
    query
    |> URI.decode_query()
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{uri_encode(k)}=#{uri_encode(v)}" end)
  end
end
