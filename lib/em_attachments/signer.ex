defmodule EmAttachments.Signer do
  @moduledoc """
  Signs what the library hands a client and later gets back from it, so a client can never
  point a record at a file it did not upload:

    - a stored file to attach (`c:sign/1` on an uploader, read by `cast_attachments/3`);
    - an upload slot to fill and complete (`EmAttachments.Plug.Upload`).

  A token is a JSON payload and its HMAC-SHA256, both base64url, joined by a dot. It carries
  its expiry and the purpose it was signed for (`salt`): a token signed for one purpose is
  refused for another. The key comes from `config :em_attachments, :config, secret_key: ...`
  (or `{:env, "VAR"}`), at least 32 bytes.
  """

  alias EmAttachments.Config

  @type salt :: String.t()

  @doc "Signs `data` (JSON-encodable) for `salt`, valid `max_age` seconds."
  @spec sign(salt(), term(), pos_integer()) :: String.t()
  def sign(salt, data, max_age) when is_binary(salt) and is_integer(max_age) do
    expires = System.system_time(:second) + max_age
    payload = Jason.encode!(%{"d" => data, "e" => expires}) |> Base.url_encode64(padding: false)
    payload <> "." <> mac(salt, payload)
  end

  @doc "The data of a token signed for `salt`, or `{:error, :invalid | :expired}`."
  @spec verify(salt(), term()) :: {:ok, term()} | {:error, :invalid | :expired}
  def verify(salt, token) when is_binary(salt) and is_binary(token) do
    with [payload, signature] <- String.split(token, ".", parts: 2),
         true <- secure_compare(mac(salt, payload), signature),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"d" => data, "e" => expires}} when is_integer(expires) <- Jason.decode(json) do
      if expires > System.system_time(:second), do: {:ok, data}, else: {:error, :expired}
    else
      _ -> {:error, :invalid}
    end
  end

  def verify(_salt, _token), do: {:error, :invalid}

  defp mac(salt, payload) do
    key = :crypto.mac(:hmac, :sha256, Config.secret_key!(), "em_attachments:" <> salt)
    :crypto.mac(:hmac, :sha256, key, payload) |> Base.url_encode64(padding: false)
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
