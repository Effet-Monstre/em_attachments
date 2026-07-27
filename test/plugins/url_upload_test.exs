defmodule EmAttachments.Plugins.UrlUploadTest do
  use ExUnit.Case, async: false

  alias EmAttachments.{Plugins.UrlUpload, TempFile}

  defp ctx(name) do
    %{
      uploader: __MODULE__,
      plugin_key: :url_upload,
      plugin_opts: [req_options: [plug: {Req.Test, name}, retry: false]]
    }
  end

  defp url_tmp_files do
    Path.join(System.tmp_dir!(), "em_attach_url_*") |> Path.wildcard() |> MapSet.new()
  end

  test "streams a successful response into a managed tempfile" do
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, &Plug.Conn.send_resp(&1, 200, "downloaded"))

    assert {:ok, %TempFile{managed: true} = source} =
             UrlUpload.cast({:url, "http://example.test/files/report.txt"}, ctx(name))

    assert source.filename == "report.txt"
    assert File.read!(source.path) == "downloaded"
    assert :ok = TempFile.cleanup(source)
    refute File.exists?(source.path)
  end

  test "sequential URL uploads remove each managed download before starting the next" do
    before = url_tmp_files()
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, &Plug.Conn.send_resp(&1, 200, EmAttachments.Test.Fixtures.proper_png()))

    for index <- 1..6 do
      assert {:ok, %TempFile{} = source} =
               UrlUpload.cast({:url, "http://example.test/image-#{index}.png"}, ctx(name))

      assert MapSet.difference(url_tmp_files(), before) == MapSet.new([source.path])
      assert {:ok, _file} = EmAttachments.Test.BasicUploader.upload(source)
      assert url_tmp_files() == before
    end
  end

  test "removes the downloaded body after an HTTP error" do
    before = url_tmp_files()
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, &Plug.Conn.send_resp(&1, 404, "missing"))

    assert {:error, "download failed: HTTP 404"} =
             UrlUpload.cast({:url, "http://example.test/missing"}, ctx(name))

    assert url_tmp_files() == before
  end

  test "removes partial files after a transport error" do
    before = url_tmp_files()
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, &Req.Test.transport_error(&1, :econnreset))

    assert {:error, message} =
             UrlUpload.cast({:url, "http://example.test/interrupted"}, ctx(name))

    assert message =~ "download failed"
    assert url_tmp_files() == before
  end
end
