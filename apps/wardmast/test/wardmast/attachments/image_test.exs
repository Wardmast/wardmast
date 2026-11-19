defmodule Wardmast.Attachments.ImageTest do
  use ExUnit.Case, async: true

  alias Wardmast.AttachmentFixture, as: Fixture
  alias Wardmast.Attachments.Image

  test "sniffs png, jpeg and webp by magic number and reads the dimensions" do
    assert {:ok, %{type: "image/png", ext: "png", width: 640, height: 480}} =
             Image.inspect_binary(Fixture.png(640, 480))

    assert {:ok, %{type: "image/jpeg", ext: "jpg", width: 800, height: 600}} =
             Image.inspect_binary(Fixture.jpeg(800, 600))

    assert {:ok, %{type: "image/webp", ext: "webp", width: 320, height: 200}} =
             Image.inspect_binary(Fixture.webp(320, 200))
  end

  test "refuses gif, svg, html and empty bodies" do
    for body <- [Fixture.gif(), "<svg xmlns='http://www.w3.org/2000/svg'/>", "<html></html>", ""] do
      assert {:error, :unsupported_type} = Image.inspect_binary(body)
    end
  end

  test "a truncated header of a supported type is refused, not guessed" do
    assert {:error, :corrupt} = Image.inspect_binary(binary_part(Fixture.png(), 0, 12))
  end
end
