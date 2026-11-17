# Rasterises the Wardmast mark (apps/wardmast_web/priv/static/brand/wardmast-mark.svg)
# into PNG sizes and favicon.ico, with no external tools (pure Elixir + :zlib).
#
#     elixir scripts/gen_brand_icons.exs
#
# The geometry below must match wardmast-mark.svg (64x64 viewBox).
defmodule BrandIcons do
  @bg {14, 17, 22}
  @accent {163, 230, 53}
  @ink {241, 243, 245}
  @ss 4

  @out "apps/wardmast_web/priv/static"

  # Oriented rects {x1, y1, x2, y2, half_width, cap_extension}
  @brackets [
    {23, 13, 17, 13, 3.5, 3.5},
    {17, 13, 17, 51, 3.5, 3.5},
    {17, 51, 23, 51, 3.5, 3.5},
    {41, 13, 47, 13, 3.5, 3.5},
    {47, 13, 47, 51, 3.5, 3.5},
    {47, 51, 41, 51, 3.5, 3.5}
  ]
  @slash {29, 44, 35, 20, 2.5, 0}

  def run do
    for s <- [16, 32, 48, 64, 128, 256, 512, 1024] do
      write("#{@out}/brand/png/wardmast-mark-#{s}.png", png(s, 8))
    end

    # maskable / apple-touch: full-bleed square tile (radius 0), mark scaled to 80% so it stays inside the maskable safe zone
    write("#{@out}/brand/png/wardmast-mark-maskable-512.png", png(512, 0))
    write("#{@out}/brand/png/wardmast-apple-touch-180.png", png(180, 0))
    write("#{@out}/images/apple-touch-icon.png", png(180, 0))
    write("#{@out}/images/icon-192.png", png(192, 8))
    write("#{@out}/images/icon-512.png", png(512, 8))

    ico = ico([16, 32, 48])
    write("#{@out}/favicon.ico", ico)
    write("#{@out}/brand/favicon.ico", ico)
  end

  defp write(path, bin), do: File.write!(path, bin)

  defp inside?({x1, y1, x2, y2, hw, ext}, px, py) do
    dx = x2 - x1
    dy = y2 - y1
    len = :math.sqrt(dx * dx + dy * dy)
    ux = dx / len
    uy = dy / len
    rx = px - x1
    ry = py - y1
    along = rx * ux + ry * uy
    across = abs(-rx * uy + ry * ux)
    along >= -ext and along <= len + ext and across <= hw
  end

  # full-bleed tiles (radius 0) shrink the mark to 80% around the centre
  defp scale(v, 0), do: 32 + (v - 32) / 0.8
  defp scale(v, _r), do: v

  defp in_tile?(_x, _y, 0), do: true

  defp in_tile?(x, y, r) do
    cx = min(max(x, r), 64 - r)
    cy = min(max(y, r), 64 - r)
    (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
  end

  # returns {r, g, b, a} for one sample in 64-space
  defp sample(x, y, r) do
    cond do
      not in_tile?(x, y, r) -> {0, 0, 0, 0}
      inside?(@slash, x, y) -> with {a, b, c} <- @ink, do: {a, b, c, 255}
      Enum.any?(@brackets, &inside?(&1, x, y)) -> with {a, b, c} <- @accent, do: {a, b, c, 255}
      true -> with {a, b, c} <- @bg, do: {a, b, c, 255}
    end
  end

  defp pixel(ix, iy, size, r) do
    n = @ss * @ss

    {sr, sg, sb, sa} =
      for sy <- 0..(@ss - 1), sx <- 0..(@ss - 1), reduce: {0, 0, 0, 0} do
        {ar, ag, ab, aa} ->
          x = scale((ix + (sx + 0.5) / @ss) * 64 / size, r)
          y = scale((iy + (sy + 0.5) / @ss) * 64 / size, r)
          {cr, cg, cb, ca} = sample(x, y, r)
          {ar + cr * ca, ag + cg * ca, ab + cb * ca, aa + ca}
      end

    if sa == 0,
      do: <<0, 0, 0, 0>>,
      else: <<round(sr / sa), round(sg / sa), round(sb / sa), round(sa / n)>>
  end

  def png(size, radius) do
    raw =
      for y <- 0..(size - 1), into: <<>> do
        row = for x <- 0..(size - 1), into: <<>>, do: pixel(x, y, size, radius)
        <<0, row::binary>>
      end

    ihdr = <<size::32, size::32, 8, 6, 0, 0, 0>>

    "\x89PNG\r\n\x1a\n" <>
      chunk("IHDR", ihdr) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", "")
  end

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end

  def ico(sizes) do
    images = Enum.map(sizes, &{&1, png(&1, 8)})
    header = <<0::16-little, 1::16-little, length(images)::16-little>>
    base = 6 + 16 * length(images)

    {entries, _} =
      Enum.map_reduce(images, base, fn {s, bin}, off ->
        {<<s, s, 0, 0, 1::16-little, 32::16-little, byte_size(bin)::32-little, off::32-little>>,
         off + byte_size(bin)}
      end)

    IO.iodata_to_binary([header, entries, Enum.map(images, &elem(&1, 1))])
  end
end

BrandIcons.run()
