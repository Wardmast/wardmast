defmodule Wardmast.AttachmentFixture do
  @moduledoc """
  Tiny image binaries for the attachment tests. Only the header is real — the
  magic number and the dimensions the sniffer reads — and the rest is padding,
  so a test can ask for an image of an exact size without a codec.
  """

  @png_magic <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc "A PNG header for a `width` x `height` image, padded with zeros to `bytes` (min header size)."
  @spec png(pos_integer(), pos_integer(), keyword()) :: binary()
  def png(width \\ 4, height \\ 3, opts \\ []) do
    header =
      @png_magic <>
        <<13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0, 0::32>> <>
        <<0::32, "IEND", 0::32>>

    pad(header, Keyword.get(opts, :bytes, byte_size(header)), opts[:salt])
  end

  @doc "A JPEG with an SOF0 frame header for `width` x `height`."
  @spec jpeg(pos_integer(), pos_integer()) :: binary()
  def jpeg(width \\ 4, height \\ 3) do
    <<0xFF, 0xD8, 0xFF, 0xC0, 17::16, 8, height::16, width::16, 3, 1, 0x22, 0, 2, 0x11, 1, 3,
      0x11, 1, 0xFF, 0xD9>>
  end

  @doc "A lossy WebP (`VP8 `) header for `width` x `height`."
  @spec webp(pos_integer(), pos_integer()) :: binary()
  def webp(width \\ 4, height \\ 3) do
    chunk = <<0, 0, 0, 0x9D, 0x01, 0x2A, width::little-16, height::little-16>>
    body = "WEBP" <> "VP8 " <> <<byte_size(chunk)::little-32>> <> chunk
    "RIFF" <> <<byte_size(body)::little-32>> <> body
  end

  @doc "A GIF — a real image format the store deliberately refuses."
  @spec gif() :: binary()
  def gif, do: "GIF89a" <> <<1, 0, 1, 0, 0, 0, 0>> <> ";"

  # Pads past the IEND chunk (decoders ignore trailing bytes) so the sha256
  # can be varied with `salt` while the dimensions stay put.
  defp pad(binary, bytes, salt) do
    binary = if salt, do: binary <> to_string(salt), else: binary
    missing = bytes - byte_size(binary)
    if missing > 0, do: binary <> :binary.copy(<<0>>, missing), else: binary
  end
end
