defmodule Wardmast.Doctor.CaptureRunner do
  @moduledoc """
  Readiness of the *host* screenshot-capture runner (`priv/capture/runner.mjs`), for
  `arb server doctor` (via `Wardmast.Doctor.Platform`, `GET /api/server/platform`).

  Primary-host capture (local placement) runs the runner from the release's `priv/capture`, so it
  needs node >= 22, `playwright-core` in `priv/capture/node_modules` (vendored at release build
  time from `package-lock.json`, see `mix.exs`), and a headless Chromium. Only reported as
  `enabled` when some workspace repo has an effective `screenshots` block.
  """

  alias Wardmast.Screenshots.Config

  @min_node 22

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    workspaces = Keyword.get_lazy(opts, :workspaces, &read_workspaces/0)
    enabled? = Keyword.get(opts, :enabled?, &enabled_config?/1)

    if Enum.any?(workspaces, &workspace_enabled?(&1, enabled?)) do
      probe(opts)
    else
      %{enabled: false, problems: []}
    end
  end

  @doc "The `playwright-core` version pinned by `<dir>/package-lock.json` (nil when unreadable)."
  @spec pinned_version(String.t()) :: String.t() | nil
  def pinned_version(dir) do
    with {:ok, raw} <- File.read(Path.join(dir, "package-lock.json")),
         {:ok, %{"packages" => %{"node_modules/playwright-core" => %{"version" => v}}}} <-
           Jason.decode(raw) do
      v
    else
      _ -> nil
    end
  end

  defp probe(opts) do
    dir =
      Keyword.get_lazy(opts, :capture_dir, fn ->
        System.get_env("ARB_CAPTURE_DIR") || Application.app_dir(:wardmast, "priv/capture")
      end)

    node = opts |> Keyword.get(:node_version, &node_version/0) |> then(& &1.())
    chrome = opts |> Keyword.get(:chrome, &chrome/0) |> then(& &1.())
    playwright = playwright_version(dir)

    {node_str, node_problem} =
      case node do
        {:ok, v} ->
          if node_major(v) >= @min_node,
            do: {v, nil},
            else: {v, "node #{v} is older than the required v#{@min_node}"}

        _ ->
          {nil, "node not found on the server's PATH (v#{@min_node}+ required)"}
      end

    problems =
      Enum.reject(
        [
          node_problem,
          if(is_nil(playwright),
            do:
              "playwright-core is not installed in #{dir} " <>
                "(run `npm ci --ignore-scripts` there; release builds vendor it)"
          ),
          if(is_nil(chrome), do: "no headless Chromium found (set ARB_CHROME)")
        ],
        &is_nil/1
      )

    %{
      enabled: true,
      node: node_str,
      playwright_core: playwright,
      pinned_playwright_core: pinned_version(dir),
      chromium: chrome,
      dir: dir,
      problems: problems
    }
  end

  defp playwright_version(dir) do
    with {:ok, raw} <-
           File.read(Path.join([dir, "node_modules", "playwright-core", "package.json"])),
         {:ok, %{"version" => v}} <- Jason.decode(raw) do
      v
    else
      _ -> nil
    end
  end

  defp node_major("v" <> rest), do: node_major(rest)

  defp node_major(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp node_version do
    override = System.get_env("ARB_CAPTURE_NODE")
    node = override || System.find_executable("node")

    with true <- is_binary(node),
         {out, 0} <- System.cmd(node, ["--version"], stderr_to_stdout: true) do
      {:ok, String.trim(out)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp chrome do
    found = System.get_env("ARB_CHROME") || System.find_executable("chromium")
    if found && File.exists?(found), do: found
  end

  defp read_workspaces do
    Ash.read!(Wardmast.Tasks.Workspace)
  rescue
    _ -> []
  end

  defp workspace_enabled?(%{config: %{"worker" => %{"repos" => %{} = repos}}} = ws, enabled?) do
    Enum.any?(Map.keys(repos), fn repo -> enabled?.(Config.resolve(ws, repo)) end)
  end

  defp workspace_enabled?(_, _), do: false

  defp enabled_config?({:ok, _}), do: true
  defp enabled_config?(_), do: false
end
