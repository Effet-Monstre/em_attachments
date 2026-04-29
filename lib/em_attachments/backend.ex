defmodule EmAttachments.Backend do
  @moduledoc """
  Behaviour for storage backends.
  """

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

  @callback bulk_delete(ids :: [String.t()], opts :: keyword()) :: :ok | {:error, term()}

  @callback bulk_put(
              files :: [{String.t(), EmAttachments.SourceFile.t()}],
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @optional_callbacks bulk_delete: 2, bulk_put: 2

  @doc """
  Uploads multiple files, using `bulk_put/2` if the backend supports it, otherwise
  falling back to parallel `put/3` calls via `Task.async_stream`.
  """
  def put_many(backend_mod, files, opts) do
    if function_exported?(backend_mod, :bulk_put, 2) do
      backend_mod.bulk_put(files, opts)
    else
      files
      |> Task.async_stream(
        fn {id, source} -> backend_mod.put(id, source, opts) end,
        max_concurrency: 10,
        ordered: false
      )
      |> Enum.reduce_while(:ok, fn
        {:ok, :ok}, _ -> {:cont, :ok}
        {:ok, {:error, _} = err}, _ -> {:halt, err}
        {:exit, reason}, _ -> {:halt, {:error, {:task_exit, reason}}}
      end)
    end
  end

  @doc """
  Deletes multiple files, using `bulk_delete/2` if the backend supports it, otherwise
  falling back to parallel `delete/3` calls via `Task.async_stream`.
  """
  def delete_many(backend_mod, ids, opts) do
    if function_exported?(backend_mod, :bulk_delete, 2) do
      backend_mod.bulk_delete(ids, opts)
    else
      ids
      |> Task.async_stream(
        fn id -> backend_mod.delete(id, opts) end,
        max_concurrency: 10,
        ordered: false
      )
      |> Enum.reduce_while(:ok, fn
        {:ok, :ok}, _ -> {:cont, :ok}
        {:ok, {:error, _} = err}, _ -> {:halt, err}
        {:exit, reason}, _ -> {:halt, {:error, {:task_exit, reason}}}
      end)
    end
  end
end
