defmodule EmAttachments.Backend do
  @moduledoc """
  Behaviour for storage backends.
  """

  @optional_callbacks [finalize: 2]

  @callback put(id :: String.t(), source :: EmAttachments.SourceFile.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback get(id :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @callback delete(id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback url(id :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback presign_upload(id :: String.t(), opts :: keyword()) ::
              {:ok, %{url: String.t(), fields: map()}} | {:error, term()}

  @doc """
  Optional post-confirmation hook called by the Sweeper for each permanent row.

  Use this to perform backend-level finalization such as changing an S3 object's ACL
  from private to public-read. Opts come from `Config.finalize_opts/0`.

  If the asset no longer exists, return `{:error, :not_found}` — the Sweeper will
  log a warning and delete the tracking row without retrying.
  """
  @callback finalize(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Builds the opts for a `put/3` call, adding the file metadata every backend may declare
  about the object it is about to write.
  """
  @spec put_opts(keyword(), EmAttachments.SourceFile.t(), String.t() | nil) :: keyword()
  def put_opts(backend_opts, source, content_type) do
    Keyword.merge(backend_opts,
      content_type: content_type,
      filename: EmAttachments.SourceFile.filename(source)
    )
  end
end
