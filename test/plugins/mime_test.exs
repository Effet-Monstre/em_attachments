defmodule EmAttachments.Plugins.MimeTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Plugins.Mime, TempFile}
  alias EmAttachments.Test.Fixtures

  describe "cast/4" do
    test "detects PNG from magic bytes" do
      tf = TempFile.new(Fixtures.png_path(), "image.png")
      assert {:ok, %{type: "image/png", extension: "png"}} = Mime.cast(tf, nil, %{}, [])
    end

    test "detects JPEG from magic bytes" do
      tf = TempFile.new(Fixtures.jpeg_path(), "photo.jpg")
      assert {:ok, %{type: "image/jpeg", extension: "jpg"}} = Mime.cast(tf, nil, %{}, [])
    end

    test "returns error for unknown type" do
      path = Fixtures.txt_path()
      tf = TempFile.new(path, "file.txt")
      assert {:error, :unknown_mime_type} = Mime.cast(tf, nil, %{}, [])
    end
  end

  describe "validate/4" do
    test "passes when type is in allowed list" do
      assert :ok = Mime.validate([type: ~w(image/png)], nil, %{type: "image/png", extension: "png"}, [])
    end

    test "fails when type is not in allowed list" do
      assert {:error, msg} = Mime.validate([type: ~w(image/png)], nil, %{type: "image/jpeg", extension: "jpg"}, [])
      assert msg =~ "image/jpeg"
    end

    test "passes when extension is in allowed list" do
      assert :ok = Mime.validate([extension: ~w(png jpg)], nil, %{type: "image/png", extension: "png"}, [])
    end

    test "fails when extension is not in allowed list" do
      assert {:error, msg} = Mime.validate([extension: ~w(png)], nil, %{type: "image/jpeg", extension: "jpg"}, [])
      assert msg =~ "jpg"
    end

    test "accumulates multiple errors" do
      result = Mime.validate(
        [type: ~w(image/png), extension: ~w(png)],
        nil,
        %{type: "image/gif", extension: "gif"},
        []
      )
      assert {:error, errors} = result
      assert is_list(errors)
      assert length(errors) == 2
    end

    test "no validation opts always passes" do
      assert :ok = Mime.validate([], nil, %{type: "anything", extension: "any"}, [])
    end
  end
end
