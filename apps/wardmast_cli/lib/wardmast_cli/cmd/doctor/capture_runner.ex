defmodule WardmastCli.Cmd.Doctor.CaptureRunner do
  @moduledoc """
  The host screenshot-capture runner check of `ward server doctor` (bd-71t1wd): node,
  `playwright-core` and Chromium on the *server's* host, from the platform's `capture_runner`
  (`Wardmast.Doctor.CaptureRunner`). No row when no repo enables screenshots (or an older server).
  """

  alias WardmastCli.Cmd.Doctor.Checks.Result

  @spec checks(map() | nil) :: [Result.t()]
  def checks(%{"enabled" => true} = r) do
    base = %Result{id: "capture_runner", group: :core, name: "host capture runner"}

    case List.wrap(r["problems"]) do
      [] ->
        [
          %{
            base
            | status: :ok,
              detail:
                "node #{r["node"]}, playwright-core #{r["playwright_core"]}, chromium #{r["chromium"]}"
          }
        ]

      problems ->
        [
          %{
            base
            | status: :warn,
              detail: Enum.join(problems, "; "),
              hint:
                "Screenshot capture on this host will fail. Install node >= 22 and Chromium, and " <>
                  "run `npm ci --ignore-scripts` in #{r["dir"]} if playwright-core is missing."
          }
        ]
    end
  end

  def checks(_), do: []
end
