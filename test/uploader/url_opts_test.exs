defmodule EmAttachments.Uploader.UrlOptsTest do
  use ExUnit.Case, async: false

  defmodule RecordingBackend do
    @behaviour EmAttachments.Backend

    @impl true
    def put(_id, _source, _opts), do: :ok
    @impl true
    def get(_id, _opts), do: {:ok, ""}
    @impl true
    def delete(_id, _opts), do: :ok
    @impl true
    def presign_upload(_id, _opts), do: {:error, :not_supported}

    @impl true
    def url(id, opts) do
      send(:persistent_term.get(__MODULE__), {:url, id, opts})
      {:ok, "/#{id}"}
    end
  end

  defmodule DerivativeUploader do
    use EmAttachments.Uploader,
      store: {EmAttachments.Uploader.UrlOptsTest.RecordingBackend, url_expires_in: 3600}

    plugin derivatives: EmAttachments.Plugins.Derivatives
  end

  setup do
    :persistent_term.put(RecordingBackend, self())

    file =
      struct(DerivativeUploader, %{
        id: "root.pdf",
        storage: :store,
        uploader: to_string(DerivativeUploader),
        metadata: %{
          filename: "contract.pdf",
          plugins: %{derivatives: %{variants: %{thumb: %{id: "thumb.png", storage: :store}}}}
        }
      })

    {:ok, asset: file}
  end

  test "the original filename and the call opts reach the backend", %{asset: file} do
    DerivativeUploader.url(file, response: [content_disposition: :attachment])

    assert_receive {:url, "root.pdf", opts}
    assert opts[:filename] == "contract.pdf"
    assert opts[:response] == [content_disposition: :attachment]
    assert opts[:url_expires_in] == 3600
  end

  test "derivative URLs receive the call opts", %{asset: file} do
    DerivativeUploader.url(file, derivatives: [:thumb], url_expires_in: 60)

    assert_receive {:url, "thumb.png", opts}
    assert opts[:url_expires_in] == 60
    refute Keyword.has_key?(opts, :derivatives)
  end
end
