defmodule EmAttachments.Plugins.DimensionsTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{Plugins.Dimensions, TempFile}
  alias EmAttachments.Test.Fixtures

  defp cache_upload(tf, opts),
    do: Dimensions.init(tf, %{plugin_key: :dimensions, uploader: nil, deps: %{}, plugin_opts: opts})

  describe "init/2 (cache phase)" do
    test "calls function adapter and returns dimensions" do
      tf = TempFile.new(Fixtures.png_path(), "image.png")
      adapter = fn _path -> {:ok, %{width: 800, height: 600}} end
      assert {:ok, %{width: 800, height: 600}} = cache_upload(tf, adapter: adapter)
    end

    test "propagates error returned by function adapter" do
      tf = TempFile.new(Fixtures.png_path(), "image.png")
      adapter = fn _path -> {:error, :unsupported_format} end
      assert {:error, :unsupported_format} = cache_upload(tf, adapter: adapter)
    end

    test "returns error when no adapter opt is provided" do
      tf = TempFile.new(Fixtures.png_path(), "image.png")
      assert {:error, msg} = cache_upload(tf, [])
      assert msg =~ "adapter"
    end

    test "returns error when adapter module is not loaded" do
      tf = TempFile.new(Fixtures.png_path(), "image.png")
      assert {:error, msg} = cache_upload(tf, adapter: Does.Not.Exist)
      assert msg =~ "not available"
    end
  end

  defp validate(validation_opts, own_result),
    do: Dimensions.validate(nil, own_result, %{plugin_key: :dimensions, plugin_opts: [], validation_opts: validation_opts})

  describe "validate/3" do
    test "passes when no validation opts are set" do
      assert :ok = validate([], %{width: 9999, height: 9999})
    end

    test "passes when all dimensions are within bounds" do
      opts = [min_width: 100, max_width: 1000, min_height: 100, max_height: 1000]
      assert :ok = validate(opts, %{width: 500, height: 500})
    end

    test "passes when dimensions are exactly at the boundaries" do
      opts = [min_width: 200, max_width: 200, min_height: 100, max_height: 100]
      assert :ok = validate(opts, %{width: 200, height: 100})
    end

    test "fails when width exceeds max_width" do
      assert {:error, msg} = validate([max_width: 100], %{width: 200, height: 50})
      assert msg =~ "max_width"
      assert msg =~ "200"
      assert msg =~ "100"
    end

    test "fails when width is below min_width" do
      assert {:error, msg} = validate([min_width: 100], %{width: 50, height: 200})
      assert msg =~ "min_width"
      assert msg =~ "50"
      assert msg =~ "100"
    end

    test "fails when height exceeds max_height" do
      assert {:error, msg} = validate([max_height: 100], %{width: 50, height: 200})
      assert msg =~ "max_height"
    end

    test "fails when height is below min_height" do
      assert {:error, msg} = validate([min_height: 100], %{width: 50, height: 50})
      assert msg =~ "min_height"
    end

    test "accumulates multiple errors" do
      assert {:error, errors} = validate([max_width: 100, max_height: 100], %{width: 200, height: 200})
      assert is_list(errors)
      assert length(errors) == 2
    end

    test "accumulates all four bound errors" do
      opts = [min_width: 500, max_width: 100, min_height: 500, max_height: 100]
      assert {:error, errors} = validate(opts, %{width: 200, height: 200})
      assert is_list(errors)
      assert length(errors) == 4
    end

    test "treats missing width/height as 0 when checking min bounds" do
      assert {:error, msg} = validate([min_width: 1], %{})
      assert msg =~ "min_width"
    end

    test "treats missing width/height as 0 when checking max bounds" do
      assert :ok = validate([max_width: 0], %{})
    end
  end
end
