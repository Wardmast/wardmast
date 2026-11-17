defmodule WardmastWeb.BrandAssetsTest do
  use ExUnit.Case, async: true

  @brand Path.expand("../../priv/static/brand", __DIR__)

  test "README lists every brand file" do
    readme = File.read!(Path.join(@brand, "README.md"))

    for f <-
          ~w(wardmast-mark.svg wardmast-wordmark-light.svg wardmast-wordmark-dark.svg favicon.ico) do
      assert File.exists?(Path.join(@brand, f)), f
      assert readme =~ f
    end
  end

  test "PNG sizes are real PNGs of the stated dimensions" do
    for s <- [16, 32, 48, 64, 128, 256, 512, 1024] do
      <<137, "PNG", 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _::binary>> =
        File.read!(Path.join(@brand, "png/wardmast-mark-#{s}.png"))

      assert {w, h} == {s, s}
    end
  end

  test "favicon.ico holds 16/32/48 images" do
    <<0::16-little, 1::16-little, n::16-little, entries::binary>> =
      File.read!(Path.join(@brand, "favicon.ico"))

    sizes = for <<w, _h, _::binary-size(14) <- binary_part(entries, 0, n * 16)>>, do: w
    assert sizes == [16, 32, 48]
  end

  test "static paths serve the brand directory" do
    assert "brand" in WardmastWeb.static_paths()
  end

  test "brand SVGs carry no legacy name" do
    for f <- Path.wildcard(Path.join(@brand, "*.{svg,md}")) do
      refute File.read!(f) =~ ~r/arbiter/i, f
    end
  end
end
