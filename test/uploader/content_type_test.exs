defmodule EmAttachments.Uploader.ContentTypeTest do
  use ExUnit.Case, async: false

  alias EmAttachments.Test.Fixtures

  defmodule RecordingBackend do
    @behaviour EmAttachments.Backend

    def owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def put(id, _source, opts) do
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:put, id, opts[:content_type], opts[:filename]}
      )

      :ok
    end

    @impl true
    def get(_id, _opts), do: {:ok, ""}
    @impl true
    def delete(_id, _opts), do: :ok
    @impl true
    def url(id, _opts), do: {:ok, "/#{id}"}
    @impl true
    def presign_upload(_id, _opts), do: {:error, :not_supported}
  end

  defmodule PlainUploader do
    use EmAttachments.Uploader,
      store: {EmAttachments.Uploader.ContentTypeTest.RecordingBackend, []}

    plugin mime: EmAttachments.Plugins.Mime
  end

  defmodule NoMimeUploader do
    use EmAttachments.Uploader,
      store: {EmAttachments.Uploader.ContentTypeTest.RecordingBackend, []}
  end

  defmodule TranscodingUploader do
    use EmAttachments.Uploader,
      store: {EmAttachments.Uploader.ContentTypeTest.RecordingBackend, []}

    plugin mime: EmAttachments.Plugins.Mime
    plugin derivatives: EmAttachments.Plugins.Derivatives

    def handle(:derivatives, _ctx) do
      %{thumb: <<"GIF89a", 1::16-little, 1::16-little, 0, 0, 0, 0x3B>>}
    end
  end

  setup do
    RecordingBackend.owner(self())
    :ok
  end

  test "the detected type and original filename reach the backend" do
    {:ok, _file} = PlainUploader.upload(%{path: Fixtures.png_path(), filename: "logo.png"})
    assert_receive {:put, _id, "image/png", "logo.png"}
  end

  test "the type is detected even without the mime plugin declared" do
    {:ok, _file} = NoMimeUploader.upload(%{path: Fixtures.jpeg_path(), filename: "photo.jpg"})
    assert_receive {:put, _id, "image/jpeg", "photo.jpg"}
  end

  test "an undetectable file is uploaded with no type rather than a wrong one" do
    {:ok, _file} = NoMimeUploader.upload(%{path: Fixtures.txt_path(), filename: "notes.txt"})
    assert_receive {:put, _id, nil, "notes.txt"}
  end

  test "each derivative declares its own type, not the source's" do
    {:ok, file} = TranscodingUploader.upload(%{path: Fixtures.png_path(), filename: "logo.png"})

    assert %{thumb: %{id: derivative_id}} = file.metadata.plugins.derivatives.variants
    assert_receive {:put, ^derivative_id, "image/gif", _}
    assert String.ends_with?(derivative_id, ".gif")

    root_id = file.id
    assert_receive {:put, ^root_id, "image/png", "logo.png"}
    assert String.ends_with?(root_id, ".png")
  end
end
