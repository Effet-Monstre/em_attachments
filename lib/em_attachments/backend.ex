defmodule EmAttachments.Backend do
  @moduledoc """
  Behaviour for storage backends.
  """

  @callback put(id :: String.t(), source_path :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback get(id :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @callback delete(id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback url(id :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback presign_upload(id :: String.t(), opts :: keyword()) ::
              {:ok, %{url: String.t(), fields: map()}} | {:error, term()}
end
