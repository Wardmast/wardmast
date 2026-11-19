defmodule Wardmast.Attachments.Image do
  @moduledoc """
  Magic-number sniffing for ticket attachments (`docs/design/ui-screenshot-capture.md`
  §10): the store holds `png`, `webp` and `jpg` images and nothing else.

  The type comes from the **bytes**, never from the filename or a
  client-supplied content type, so a `.png` that is really HTML or SVG (which
  can carry script) is refused. The same header read yields the pixel
  dimensions, which the per-image size ceiling needs. No codec is involved: a
  header that is present but cut short is `{:error, :corrupt}`; a body that is
  not one of the three formats is `{:error, :unsupported_type}`.
  """

  @type info :: %{
          type: String.t(),
          ext: String.t(),
          width: pos_integer(),
          height: pos_integer()
        }

  @png_magic <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc "Content types the store accepts."
  @spec types() :: [String.t()]
  def types, do: ["image/png", "image/webp", "image/jpeg"]

  @doc "The content type for a stored extension (`png`, `webp`, `jpg`)."
  @spec content_type(String.t()) :: String.t() | nil
  def content_type("png"), do: "image/png"
  def content_type("webp"), do: "image/webp"
  def content_type("jpg"), do: "image/jpeg"
  def content_type(_), do: nil

  @doc "Sniff `binary`: its type, extension and pixel dimensions."
  @spec inspect_binary(binary()) :: {:ok, info()} | {:error, :unsupported_type | :corrupt}
  def inspect_binary(<<@png_magic, rest::binary>>), do: png(rest)
  def inspect_binary(<<0xFF, 0xD8, 0xFF, rest::binary>>), do: jpeg(rest)
  def inspect_binary(<<"RIFF", _size::little-32, "WEBP", rest::binary>>), do: webp(rest)
  def inspect_binary(_), do: {:error, :unsupported_type}

  # --- PNG: the IHDR chunk is first and fixed-layout.
  defp png(<<_len::32, "IHDR", w::32, h::32, _::binary>>), do: found("image/png", "png", w, h)
  defp png(_), do: {:error, :corrupt}

  # --- JPEG: walk the marker segments to the first start-of-frame.
  defp jpeg(rest), do: jpeg_segments(<<0xFF, rest::binary>>)

  defp jpeg_segments(<<0xFF, marker, len::16, seg::binary>>) when marker in 0xC0..0xCF do
    if marker in [0xC4, 0xC8, 0xCC] do
      skip_segment(marker, len, seg)
    else
      case seg do
        <<_precision, h::16, w::16, _::binary>> -> found("image/jpeg", "jpg", w, h)
        _ -> {:error, :corrupt}
      end
    end
  end

  defp jpeg_segments(<<0xFF, 0xFF, rest::binary>>), do: jpeg_segments(<<0xFF, rest::binary>>)
  defp jpeg_segments(<<0xFF, marker, len::16, seg::binary>>), do: skip_segment(marker, len, seg)
  defp jpeg_segments(_), do: {:error, :corrupt}

  defp skip_segment(_marker, len, seg) when len >= 2 do
    skip = len - 2

    case seg do
      <<_::binary-size(^skip), next::binary>> -> jpeg_segments(next)
      _ -> {:error, :corrupt}
    end
  end

  defp skip_segment(_marker, _len, _seg), do: {:error, :corrupt}

  # --- WebP: the first chunk says which flavour (lossy / lossless / extended).
  defp webp(
         <<"VP8 ", _size::little-32, _tag::24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16,
           _::binary>>
       ),
       do: found("image/webp", "webp", Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF))

  defp webp(<<"VP8L", _size::little-32, 0x2F, bits::little-32, _::binary>>) do
    w = Bitwise.band(bits, 0x3FFF) + 1
    h = Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1
    found("image/webp", "webp", w, h)
  end

  defp webp(<<"VP8X", _size::little-32, _flags::32, w::little-24, h::little-24, _::binary>>),
    do: found("image/webp", "webp", w + 1, h + 1)

  defp webp(_), do: {:error, :corrupt}

  defp found(_type, _ext, w, h) when w < 1 or h < 1, do: {:error, :corrupt}
  defp found(type, ext, w, h), do: {:ok, %{type: type, ext: ext, width: w, height: h}}
end
