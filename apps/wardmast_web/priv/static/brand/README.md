# Wardmast brand assets

The Wardmast mark is `[/]`: two brackets (the *ward*) around a rising slash
(the *mast*). Original work; no third-party artwork.

| File | Purpose |
| --- | --- |
| `wardmast-mark.svg` | Master icon (64x64 tile, dark ground, lime brackets, pale slash) |
| `wardmast-wordmark-light.svg` | `[wardmast]` wordmark for light backgrounds (transparent) |
| `wardmast-wordmark-dark.svg` | `[wardmast]` wordmark for dark backgrounds (transparent) |
| `png/wardmast-mark-{16,32,48,64,128,256,512,1024}.png` | Rounded-tile raster icons |
| `png/wardmast-mark-maskable-512.png` | Full-bleed square, for maskable/PWA icons |
| `png/wardmast-apple-touch-180.png` | Full-bleed 180px, apple-touch icon |
| `favicon.ico` | 16/32/48 multi-size ICO (also served at `/favicon.ico`) |

Desktop/menubar shells (bd-6tif6q) can take the 16-1024 PNGs directly; 1024
is the source for `.icns`/`.ico` bundling.

Colours: ground `#0e1116`, accent `#a3e635`, ink `#f1f3f5`; light-mode
wordmark uses `#4d7c0f` / `#1f2430`. They mirror the dashboard's
`--wm-accent` / `--wm-accent-ink` brand tokens in
`apps/wardmast_web/assets/css/app.css` (light and dark), which feed
`--arb-live`, the dashboard's accent. The maskable and apple-touch PNGs scale
the mark to 80% so it sits inside the maskable safe zone.

## Regenerating rasters

    elixir scripts/gen_brand_icons.exs

Pure Elixir (no ImageMagick/rsvg). It also refreshes `../favicon.ico` and
`../images/{apple-touch-icon,icon-192,icon-512}.png`. Keep its geometry in
sync with `wardmast-mark.svg` and `WardmastWeb.CoreComponents.Brandmark`.
