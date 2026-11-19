defmodule Wardmast.Mergers.ImageHosting do
  @moduledoc """
  Shared bits of the forge adapters' `host_images/3` (before/after screenshots
  for the PR/MR description, `docs/design/ui-screenshot-capture.md` §7).
  """

  @doc "Image MIME type for a file name by extension (`application/octet-stream` when unknown)."
  @spec content_type(String.t()) :: String.t()
  def content_type(name) do
    case name |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end
end
